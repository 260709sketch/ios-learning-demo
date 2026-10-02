import Foundation

/// Login state and the user's library: profile, liked track IDs, playlists.
@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    @Published var profile: UserProfile?
    @Published var likedTrackIDs: Set<Int> = []
    @Published var userPlaylists: [PlaylistSummary] = []
    @Published var likedAlbums: [AlbumSummary] = []
    @Published var likedArtists: [ArtistSummary] = []
    @Published var isBootstrapped = false

    var isLoggedIn: Bool { NeteaseClient.shared.isLoggedIn && profile != nil }
    var hasAuthCookie: Bool { NeteaseClient.shared.isLoggedIn }
    var vipType: Int { profile?.vipType ?? 0 }

    var likedSongsPlaylist: PlaylistSummary? {
        userPlaylists.first(where: \.isLikedSongsList) ?? userPlaylists.first
    }

    var createdPlaylists: [PlaylistSummary] {
        guard let uid = profile?.userId else { return [] }
        return userPlaylists.filter { $0.creator?.userId == uid && !$0.isLikedSongsList }
    }

    var subscribedPlaylists: [PlaylistSummary] {
        guard let uid = profile?.userId else { return [] }
        return userPlaylists.filter { $0.creator?.userId != uid }
    }

    private init() {}

    /// Called at launch and after login succeeds.
    func bootstrap() async {
        defer { isBootstrapped = true }
        guard hasAuthCookie else { return }
        refreshCookieIfNeeded()
        do {
            profile = try await NeteaseAPI.userAccount()
        } catch {
            return
        }
        await refreshLibrary()
    }

    func refreshLibrary() async {
        guard let uid = profile?.userId else { return }
        async let playlists = try? NeteaseAPI.userPlaylists(uid: uid)
        async let liked = try? NeteaseAPI.likedTrackIDs(uid: uid)
        userPlaylists = await playlists ?? userPlaylists
        if let ids = await liked { likedTrackIDs = Set(ids) }
    }

    func refreshSublists() async {
        async let albums = try? NeteaseAPI.likedAlbums()
        async let artists = try? NeteaseAPI.likedArtists()
        likedAlbums = await albums ?? likedAlbums
        likedArtists = await artists ?? likedArtists
    }

    func isLiked(_ trackID: Int) -> Bool {
        likedTrackIDs.contains(trackID)
    }

    /// 判断歌曲是否已收藏（统一检查本地歌单）
    func isLiked(track: Track) -> Bool {
        LocalPlaylistStore.shared.contains(track)
    }

    func toggleLike(trackID: Int, track: Track? = nil) async {
        // 有 track 对象：所有歌曲先存本地歌单，再判断是否需要同步网易云
        if let track = track {
            let isInLocal = LocalPlaylistStore.shared.contains(track)
            // 判断是否是QQ音乐歌曲（有platformSongId或sourcePlatform为tx）
            let isQQMusic = track.sourcePlatform == "tx" || track.platformSongId != nil

            if isInLocal {
                LocalPlaylistStore.shared.removeTrack(track)
                if isQQMusic {
                    ToastCenter.shared.show("已从收藏的音乐移除")
                }
            } else {
                LocalPlaylistStore.shared.addTrack(track)
                if isQQMusic {
                    ToastCenter.shared.show("已收藏到收藏的音乐")
                }
            }

            // 判断是否是网易云歌曲（sourcePlatform为nil或wy/netease，且没有platformSongId）
            let isNetease = (track.sourcePlatform == nil || track.sourcePlatform == "wy" || track.sourcePlatform == "netease") && track.platformSongId == nil
            if isNetease && isLoggedIn {
                let like = !isInLocal
                if like { likedTrackIDs.insert(trackID) } else { likedTrackIDs.remove(trackID) }
                do {
                    try await NeteaseAPI.likeTrack(id: trackID, like: like)
                } catch {
                    if like { likedTrackIDs.remove(trackID) } else { likedTrackIDs.insert(trackID) }
                    ToastCenter.shared.show(error.localizedDescription)
                }
            }
            NowPlayingManager.shared.refreshLikeState()
            return
        }

        // 没有 track 对象：只处理网易云逻辑（兼容旧调用）
        guard isLoggedIn else {
            ToastCenter.shared.show(String(localized: "登录后即可收藏歌曲"))
            return
        }
        let like = !likedTrackIDs.contains(trackID)
        if like { likedTrackIDs.insert(trackID) } else { likedTrackIDs.remove(trackID) }
        do {
            try await NeteaseAPI.likeTrack(id: trackID, like: like)
        } catch {
            if like { likedTrackIDs.remove(trackID) } else { likedTrackIDs.insert(trackID) }
            ToastCenter.shared.show(error.localizedDescription)
        }
        NowPlayingManager.shared.refreshLikeState()
    }

    func logout() async {
        await NeteaseAPI.logout()
        QQMusicAuth.shared.logout()
        profile = nil
        likedTrackIDs = []
        userPlaylists = []
        likedAlbums = []
        likedArtists = []
    }

    /// Refresh the login cookie at most once per calendar day.
    private func refreshCookieIfNeeded() {
        let key = "auth.lastCookieRefresh"
        let today = Calendar.current.startOfDay(for: .now).timeIntervalSince1970
        guard UserDefaults.standard.double(forKey: key) < today else { return }
        UserDefaults.standard.set(today, forKey: key)
        Task { await NeteaseAPI.refreshLogin() }
    }
}

// MARK: - Toasts

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
}

@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    @Published var current: Toast?
    private var dismissTask: Task<Void, Never>?

    private init() {}

    func show(_ message: String) {
        current = Toast(message: message)
        dismissTask?.cancel()
        dismissTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            current = nil
        }
    }
}

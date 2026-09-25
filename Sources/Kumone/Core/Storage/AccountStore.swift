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

    /// 判断歌曲是否已收藏（QQ音乐歌曲检查本地歌单，网易云歌曲检查likedTrackIDs）
    func isLiked(track: Track) -> Bool {
        if track.sourcePlatform == "tx" {
            return LocalPlaylistStore.shared.contains(track)
        }
        return likedTrackIDs.contains(track.id)
    }

    func toggleLike(trackID: Int, track: Track? = nil) async {
        DebugLogger.shared.log("收藏", "=== toggleLike 开始 trackID=\(trackID) track=\(track != nil) name=\(track?.name ?? "nil") sourcePlatform=\(track?.sourcePlatform ?? "nil")")
        // QQ音乐歌曲：只存本地歌单，不需要登录网易云，不调用网易云API
        if let track = track, track.sourcePlatform == "tx" {
            DebugLogger.shared.log("收藏", "识别为QQ音乐歌曲，走本地歌单逻辑", level: .success)
            let isInLocal = LocalPlaylistStore.shared.contains(track)
            if isInLocal {
                LocalPlaylistStore.shared.removeTrack(track)
                ToastCenter.shared.show("已从本地歌单移除")
                DebugLogger.shared.log("收藏", "已从本地歌单移除", level: .success)
            } else {
                LocalPlaylistStore.shared.addTrack(track)
                ToastCenter.shared.show("已收藏到本地歌单")
                DebugLogger.shared.log("收藏", "已收藏到本地歌单 数量=\(LocalPlaylistStore.shared.count)", level: .success)
            }
            NowPlayingManager.shared.refreshLikeState()
            return
        }
        DebugLogger.shared.log("收藏", "未识别为QQ音乐，走网易云逻辑")

        // 网易云歌曲：需要登录，同步到网易云，同时存本地歌单
        guard isLoggedIn else {
            ToastCenter.shared.show(String(localized: "登录后即可收藏歌曲"))
            return
        }
        let like = !likedTrackIDs.contains(trackID)
        DebugLogger.shared.log("收藏", "网易云歌曲 trackID=\(trackID) like=\(like) track=\(track != nil) sourcePlatform=\(track?.sourcePlatform ?? "nil")")
        // Optimistic update
        if like { likedTrackIDs.insert(trackID) } else { likedTrackIDs.remove(trackID) }
        // 同步到本地歌单（收藏时添加，取消收藏时移除）
        if let track = track {
            if like {
                LocalPlaylistStore.shared.addTrack(track)
                DebugLogger.shared.log("收藏", "已添加到本地歌单 歌曲=\(track.name) 本地歌单数量=\(LocalPlaylistStore.shared.count)", level: .success)
            } else {
                LocalPlaylistStore.shared.removeTrack(track)
                DebugLogger.shared.log("收藏", "已从本地歌单移除 歌曲=\(track.name)", level: .success)
            }
        } else if !like {
            // 没有 track 对象时，按 id 和平台移除（平台为 nil 时只按 id 匹配网易云）
            LocalPlaylistStore.shared.removeTrack(trackID: trackID, sourcePlatform: nil)
            DebugLogger.shared.log("收藏", "无track对象，按id移除本地歌单 trackID=\(trackID)")
        }
        do {
            try await NeteaseAPI.likeTrack(id: trackID, like: like)
        } catch {
            if like { likedTrackIDs.remove(trackID) } else { likedTrackIDs.insert(trackID) }
            // 回滚本地歌单
            if let track = track {
                if like { LocalPlaylistStore.shared.removeTrack(track) } else { LocalPlaylistStore.shared.addTrack(track) }
            }
            ToastCenter.shared.show(error.localizedDescription)
        }
        NowPlayingManager.shared.refreshLikeState()
    }

    func logout() async {
        await NeteaseAPI.logout()
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

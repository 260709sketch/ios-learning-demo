import SwiftUI

struct ArtistDetailView: View {
    let artistID: Int
    /// QQ音乐歌手 mid（字符串），不为空时使用 QQ 音乐 API
    let singerMid: String?
    /// 初始歌手信息（QQ音乐歌手从搜索结果传入，避免额外请求）
    let initialArtist: ArtistSummary?

    init(artistID: Int, singerMid: String? = nil, initialArtist: ArtistSummary? = nil) {
        self.artistID = artistID
        self.singerMid = singerMid
        self.initialArtist = initialArtist
    }

    @State private var artist: ArtistSummary?
    @State private var hotSongs: [Track] = []
    @State private var albums: [AlbumSummary] = []
    @State private var epsAndSingles: [AlbumSummary] = []
    @State private var similar: [ArtistSummary] = []
    @State private var isFollowed = false
    @State private var isLoading = true
    @State private var errorMessage: String?

    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var account: AccountStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isQQ: Bool { initialArtist?.sourcePlatform == "tx" || (singerMid != nil && initialArtist?.sourcePlatform != "kg") }
    private var isKugou: Bool { initialArtist?.sourcePlatform == "kg" }

    private var isCompact: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone || horizontalSizeClass == .compact
        #else
        return false
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: isCompact ? 16 : 26) {
                if let artist {
                    if isCompact {
                        compactHeader(artist)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                    } else {
                        regularHeader(artist)
                            .padding(.horizontal, Theme.Layout.contentInset)
                            .padding(.top, 16)
                    }

                    if !hotSongs.isEmpty {
                        SectionHeader(title: "热门单曲")
                            .padding(.horizontal, isCompact ? 16 : Theme.Layout.contentInset)

                        TrackListView(
                            tracks: hotSongs,
                            style: .compact,
                            source: .artist(artistID),
                            context: .artist(id: artistID, name: artist.name)
                        )
                        .padding(.horizontal, isCompact ? 6 : Theme.Layout.contentInset - 10)
                    }

                    if !albums.isEmpty {
                        SectionHeader(title: "专辑")
                            .padding(.horizontal, isCompact ? 16 : Theme.Layout.contentInset)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                Spacer().frame(width: (isCompact ? 16 : Theme.Layout.contentInset) - 16)
                                ForEach(albums) { album in
                                    albumCard(album)
                                }
                                Spacer().frame(width: (isCompact ? 16 : Theme.Layout.contentInset) - 16)
                            }
                        }
                    }

                    if !epsAndSingles.isEmpty {
                        SectionHeader(title: "EP 与单曲")
                            .padding(.horizontal, isCompact ? 16 : Theme.Layout.contentInset)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                Spacer().frame(width: (isCompact ? 16 : Theme.Layout.contentInset) - 16)
                                ForEach(epsAndSingles) { album in
                                    albumCard(album)
                                }
                                Spacer().frame(width: (isCompact ? 16 : Theme.Layout.contentInset) - 16)
                            }
                        }
                    }

                    if !similar.isEmpty {
                        SectionHeader(title: "相似歌手")
                            .padding(.horizontal, isCompact ? 16 : Theme.Layout.contentInset)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                Spacer().frame(width: (isCompact ? 16 : Theme.Layout.contentInset) - 16)
                                ForEach(similar) { sim in
                                    NavigationLink {
                                        ArtistDetailView(artistID: sim.id, singerMid: sim.singerMid, initialArtist: sim)
                                    } label: {
                                        VStack(spacing: 8) {
                                            CachedAsyncImage(url: sim.picUrl?.resizedImageURL(256))
                                                .frame(width: isCompact ? 80 : 100, height: isCompact ? 80 : 100)
                                                .clipShape(Circle())
                                            Text(sim.name)
                                                .font(.system(size: 12, weight: .medium))
                                                .lineLimit(1)
                                        }
                                        .frame(width: isCompact ? 80 : 100)
                                    }
                                    .buttonStyle(.interactiveCard)
                                }
                                Spacer().frame(width: (isCompact ? 16 : Theme.Layout.contentInset) - 16)
                            }
                        }
                    }
                } else if isLoading {
                    loadingHeader
                } else if let errorMessage {
                    ErrorStateView(message: errorMessage) {
                        Task { await load() }
                    }
                    .frame(minHeight: 400)
                }

                PlayerClearanceSpacer()
            }
        }
        #if os(macOS)
        .navigationTitle(artist?.name ?? String(localized: "歌手"))
        #else
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: singerMid ?? String(artistID)) {
            await load()
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        DebugLogger.shared.log("歌手页", "开始加载 artistID=\(artistID) singerMid=\(singerMid ?? "nil") isQQ=\(isQQ) initialArtist=\(initialArtist?.name ?? "nil")")

        if isQQ, let mid = singerMid {
            // QQ音乐歌手：用初始信息，加载歌曲和专辑
            // 用 singerMid 构造头像 URL（QQ音乐歌手头像格式：T001R300x300M000{mid}.jpg）
            let avatarUrl = "https://y.gtimg.cn/music/photo_new/T001R300x300M000\(mid).jpg"
            if var base = initialArtist {
                // 更新头像（如果初始没有的话）
                artist = ArtistSummary(id: base.id, name: base.name, picUrl: base.picUrl ?? avatarUrl, albumSize: base.albumSize, musicSize: base.musicSize, followed: base.followed, alias: base.alias, sourcePlatform: "tx", singerMid: mid)
            } else {
                artist = ArtistSummary(id: artistID, name: "歌手", picUrl: avatarUrl, albumSize: 0, musicSize: 0, followed: false, alias: [], sourcePlatform: "tx", singerMid: mid)
            }
            isLoading = false
            DebugLogger.shared.log("歌手页", "QQ音乐模式 开始请求 songs+albums mid=\(mid) avatar=\(avatarUrl)")

            async let songsTask = try? QQMusicAPI.artistSongs(singerMid: mid, limit: 50)
            async let albumsTask = try? QQMusicAPI.artistAlbums(singerMid: mid, limit: 60)

            let (songsResult, albumsResult) = await (songsTask, albumsTask)
            hotSongs = songsResult?.tracks ?? []
            let songCount = songsResult?.total ?? (songsResult?.tracks.count ?? 0)
            let albumCount = albumsResult?.total ?? (albumsResult?.albums.count ?? 0)
            DebugLogger.shared.log("歌手页", "QQ音乐 songs 返回 \(hotSongs.count) 首 总数=\(songCount) albums 返回 \(albumsResult?.albums.count ?? 0) 张 总数=\(albumCount)", level: songCount == 0 ? .error : .success)
            // 更新歌手信息中的数量
            if let current = artist {
                artist = ArtistSummary(id: current.id, name: current.name, picUrl: current.picUrl, albumSize: albumCount, musicSize: songCount, followed: current.followed, alias: current.alias, sourcePlatform: "tx", singerMid: mid)
            }
            // QQ音乐专辑按 subType 分区：专辑在上面，EP与单曲在下面（与网易云一致）
            let allAlbums = albumsResult?.albums ?? []
            albums = allAlbums.filter { $0.subType == "专辑" || $0.subType == nil }
            epsAndSingles = allAlbums.filter { $0.subType == "EP" || $0.subType == "单曲" }
            DebugLogger.shared.log("歌手页", "QQ音乐专辑分区 专辑=\(albums.count) EP/单曲=\(epsAndSingles.count)")
            similar = []
            return
        }

        if isKugou, let authorID = singerMid {
            // 酷狗歌手：先获取详情（头像、歌曲数、专辑数），再加载歌曲和专辑
            let detail = try? await KugouAPI.artistDetail(authorID: authorID)
            let singerName = detail?.name ?? initialArtist?.name ?? "歌手"
            let avatar = detail?.avatar ?? initialArtist?.picUrl
            let songCount = detail?.songCount ?? 0
            let albumCount = detail?.albumCount ?? 0
            artist = ArtistSummary(id: initialArtist?.id ?? abs(authorID.hashValue), name: singerName, picUrl: avatar, albumSize: albumCount, musicSize: songCount, followed: false, alias: [], sourcePlatform: "kg", singerMid: authorID)
            isLoading = false

            async let songsTask = try? KugouAPI.artistSongs(authorID: authorID, limit: 50)
            async let albumsTask = try? KugouAPI.artistAlbums(authorID: authorID, limit: 60)

            let (songsResult, albumsResult) = await (songsTask, albumsTask)
            hotSongs = songsResult?.tracks ?? []
            // 根据 subType 区分专辑和 EP/单曲
            let allAlbums = albumsResult?.albums ?? []
            albums = allAlbums.filter { ($0.subType ?? "专辑") == "专辑" || $0.subType?.isEmpty == true }
            epsAndSingles = allAlbums.filter { $0.subType == "EP" || $0.subType == "单曲" }
            similar = []
            return
        }

        do {
            DebugLogger.shared.log("歌手页", "网易云模式 开始请求 artist id=\(artistID)")
            let response = try await NeteaseAPI.artist(id: artistID)
            artist = response.artist
            hotSongs = response.hotSongs
            isFollowed = response.artist.followed
            isLoading = false
            DebugLogger.shared.log("歌手页", "网易云 songs 返回 \(response.hotSongs.count) 首", level: .success)

            if let result = try? await NeteaseAPI.artistAlbums(id: artistID, limit: 60) {
                albums = result.hotAlbums.filter { $0.size > 1 }
                epsAndSingles = result.hotAlbums.filter { $0.size <= 1 }
            }
            if account.isLoggedIn {
                similar = (try? await NeteaseAPI.similarArtists(id: artistID)) ?? []
            }
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
            DebugLogger.shared.log("歌手页", "网易云请求失败 error=\(error.localizedDescription)", level: .error)
        }
    }

    // MARK: - Compact Header

    private func compactHeader(_ artist: ArtistSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                CachedAsyncImage(url: artist.picUrl?.resizedImageURL(384))
                    .frame(width: 100, height: 100)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 4)

                VStack(alignment: .leading, spacing: 5) {
                    Text(artist.name)
                        .font(.system(size: 18, weight: .bold))
                        .lineLimit(2)
                    if !artist.alias.isEmpty {
                        Text(artist.alias.joined(separator: " / "))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text("\(artist.musicSize) 首歌曲 · \(artist.albumSize) 张专辑")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            // Compact Action Bar
            HStack(spacing: 10) {
                Button {
                    player.play(tracks: hotSongs, source: .artist(artistID),
                                context: .artist(id: artistID, name: artist.name))
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                        Text("播放热门")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Theme.accentGradient, in: Capsule())
                    .shadow(color: Theme.accent.opacity(0.3), radius: 6, y: 2)
                }
                .buttonStyle(.pressable)

                if account.isLoggedIn {
                    Button {
                        toggleFollow()
                    } label: {
                        Image(systemName: isFollowed ? "checkmark" : "plus")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(isFollowed ? Theme.accent : .primary)
                            .frame(width: 38, height: 38)
                            .background(.primary.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.pressable)
                }
            }
        }
    }

    // MARK: - Regular Header

    private func regularHeader(_ artist: ArtistSummary) -> some View {
        HStack(alignment: .center, spacing: 28) {
            CachedAsyncImage(url: artist.picUrl?.resizedImageURL(512))
                .frame(width: 180, height: 180)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.25), radius: 16, y: 8)

            VStack(alignment: .leading, spacing: 8) {
                Text("歌手")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(artist.name)
                    .font(.largeTitle.weight(.bold))
                if !artist.alias.isEmpty {
                    Text(artist.alias.joined(separator: " / "))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Text("\(artist.musicSize) 首歌曲 · \(artist.albumSize) 张专辑")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)

                Spacer(minLength: 6)

                HStack(spacing: 10) {
                    Button {
                        player.play(tracks: hotSongs, source: .artist(artistID),
                                context: .artist(id: artistID, name: artist.name))
                    } label: {
                        Label("播放热门", systemImage: "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                            .background(Theme.accentGradient, in: Capsule())
                            .shadow(color: Theme.accent.opacity(0.3), radius: 6, y: 2)
                    }
                    .buttonStyle(.pressable)

                    if account.isLoggedIn {
                        Button {
                            toggleFollow()
                        } label: {
                            Label(isFollowed ? String(localized: "已关注") : String(localized: "关注"),
                                  systemImage: isFollowed ? "checkmark" : "plus")
                                .font(.system(size: 13, weight: .medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(.primary.opacity(0.06), in: Capsule())
                        }
                        .buttonStyle(.pressable)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func albumCard(_ album: AlbumSummary) -> some View {
        NavigationLink {
            AlbumDetailView(albumID: album.id, albumMid: album.albumMid, initialAlbum: album)
        } label: {
            CoverCardBody(
                coverURL: album.picUrl?.resizedImageURL(384),
                title: album.name,
                subtitle: album.publishYear
            )
        }
        .buttonStyle(.interactiveCard)
    }

    private func toggleFollow() {
        Task {
            do {
                try await NeteaseAPI.subscribeArtist(id: artistID, subscribe: !isFollowed)
                isFollowed.toggle()
                ToastCenter.shared.show(isFollowed ? String(localized: "已关注歌手") : String(localized: "已取消关注"))
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

    private var loadingHeader: some View {
        HStack(alignment: .center, spacing: isCompact ? 14 : 24) {
            SkeletonView(cornerRadius: isCompact ? 50 : 90)
                .clipShape(Circle())
                .frame(width: isCompact ? 100 : 180, height: isCompact ? 100 : 180)

            VStack(alignment: .leading, spacing: 10) {
                SkeletonView(cornerRadius: 4).frame(maxWidth: isCompact ? 150 : 180, minHeight: 14, maxHeight: 14)
                SkeletonView(cornerRadius: 4).frame(width: 100, height: 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, isCompact ? 16 : Theme.Layout.contentInset)
        .padding(.top, isCompact ? 12 : 16)
    }
}

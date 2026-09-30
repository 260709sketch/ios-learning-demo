import SwiftUI

/// 外部歌单详情页：完全照抄收藏歌单（LocalPlaylistView）代码，只改数据源
struct ExternalPlaylistView: View {
    let playlist: ExternalPlaylist
    @StateObject private var externalStore = ExternalPlaylistStore.shared
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var account: AccountStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    @State private var filter = ""

    private var playlistTracks: [Track] {
        externalStore.getTracks(for: playlist.id)
    }

    private var isCompact: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone || horizontalSizeClass == .compact
        #else
        return false
        #endif
    }

    private var filteredTracks: [Track] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return playlistTracks }
        return playlistTracks.filter {
            $0.name.lowercased().contains(query)
                || $0.artistNames.lowercased().contains(query)
                || $0.album.name.lowercased().contains(query)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: isCompact ? 16 : 20) {
                if isCompact {
                    compactHeader
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                } else {
                    regularHeader
                        .padding(.horizontal, Theme.Layout.contentInset)
                        .padding(.top, 16)
                }

                if playlistTracks.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("歌单为空")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 80)
                } else {
                    TrackListView(
                        tracks: filteredTracks,
                        source: .none,
                        onRemoved: { track in
                            externalStore.removeTrack(from: playlist.id, track: track)
                        }
                    )
                    .padding(.horizontal, isCompact ? 6 : Theme.Layout.contentInset - 10)
                }

                PlayerClearanceSpacer()
            }
        }
        .background(colorScheme == .dark ? Color.black : Color(uiColor: .systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !playlistTracks.isEmpty {
                    Menu {
                        Button(role: .destructive) {
                            externalStore.removePlaylist(playlist)
                        } label: {
                            Label("删除歌单", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }

    // MARK: - Compact (Mobile) Header

    private var compactHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    if let firstTrack = playlistTracks.first, let coverUrl = firstTrack.album.picUrl ?? playlist.coverURL {
                        CachedAsyncImage(url: URL(string: coverUrl)?.resizedImageURL(384), animated: false)
                            .aspectRatio(contentMode: .fill)
                    } else {
                        RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous)
                            .fill(LinearGradient(
                                colors: [Theme.accent, Theme.accent.opacity(0.7)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                        Image(systemName: "music.note.list")
                            .font(.system(size: 48, weight: .light))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 10, y: 4)

                VStack(alignment: .leading, spacing: 6) {
                    Text(playlist.name)
                        .font(.system(size: 16, weight: .bold))
                        .lineLimit(3)

                    Text("\(playlistTracks.count) 首")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }

            HStack(spacing: 10) {
                Button {
                    player.play(tracks: playable, source: .none)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                        Text("播放全部 (\(playable.count))")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Theme.accentGradient, in: Capsule())
                    .shadow(color: Theme.accent.opacity(0.3), radius: 6, y: 2)
                }
                .buttonStyle(.pressable)
                .disabled(playlistTracks.isEmpty)
            }
        }
    }

    // MARK: - Regular (Desktop / iPad) Header

    private var regularHeader: some View {
        HStack(alignment: .bottom, spacing: 24) {
            ZStack {
                if let firstTrack = playlistTracks.first, let coverUrl = firstTrack.album.picUrl ?? playlist.coverURL {
                    CachedAsyncImage(url: URL(string: coverUrl)?.resizedImageURL(512), animated: false)
                        .aspectRatio(contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Theme.accent, Theme.accent.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                    Image(systemName: "music.note.list")
                        .font(.system(size: 64, weight: .light))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            .frame(width: 200, height: 200)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 16, y: 8)

            VStack(alignment: .leading, spacing: 8) {
                Text("外部歌单")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(playlist.name)
                    .font(.title.weight(.bold))
                    .lineLimit(2)

                Text("\(playlistTracks.count) 首")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)

                Spacer(minLength: 4)

                actionRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 210)
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                player.play(tracks: playable, source: .none)
            } label: {
                Label("播放全部", systemImage: "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Theme.accentGradient, in: Capsule())
                    .shadow(color: Theme.accent.opacity(0.3), radius: 6, y: 2)
            }
            .buttonStyle(.pressable)
            .disabled(playlistTracks.isEmpty)

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("搜索歌单内歌曲", text: $filter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 130)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.primary.opacity(0.05), in: Capsule())
        }
    }

    private var playable: [Track] {
        if LXSourceStore.shared.activeSourceID != nil { return playlistTracks }
        return playlistTracks.filter {
            $0.playability(privilege: nil, isLoggedIn: account.isLoggedIn, vipType: account.vipType) == .playable
        }
    }
}

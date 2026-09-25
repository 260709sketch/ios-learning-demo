import SwiftUI

/// 收藏歌单详情页：完全照抄我喜欢的音乐（PlaylistDetailView）布局
struct LocalPlaylistView: View {
    @StateObject private var localStore = LocalPlaylistStore.shared
    @EnvironmentObject private var player: PlayerService
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isCompact: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone || horizontalSizeClass == .compact
        #else
        return false
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: isCompact ? 16 : 20) {
                // 头部：完全照抄 compactHeader
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 14) {
                        // 封面：有歌曲时显示第一首歌封面，没歌曲时显示默认渐变封面
                        ZStack {
                            if let firstTrack = localStore.tracks.first, let coverUrl = firstTrack.album.picUrl {
                                CachedAsyncImage(url: coverUrl.resizedImageURL(384), animated: false)
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
                            Text("收藏歌单")
                                .font(.system(size: 16, weight: .bold))
                                .lineLimit(3)

                            Text("\(localStore.count) 首")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 4)

                        Spacer()
                    }

                    // Compact Action Bar：完全照抄我喜欢的音乐
                    HStack(spacing: 10) {
                        Button {
                            player.play(tracks: localStore.tracks, source: .none)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "play.fill")
                                Text("播放全部 (\(localStore.count))")
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(Theme.accentGradient, in: Capsule())
                            .shadow(color: Theme.accent.opacity(0.3), radius: 6, y: 2)
                        }
                        .buttonStyle(.pressable)
                        .disabled(localStore.tracks.isEmpty)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                // 歌曲列表：直接用 TrackListView，和我喜欢的音乐完全一致
                if localStore.tracks.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("还没有收藏的歌曲")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("收藏歌曲时会自动保存一份到收藏歌单")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 80)
                } else {
                    TrackListView(
                        tracks: localStore.tracks,
                        source: .none,
                        onRemoved: { track in
                            LocalPlaylistStore.shared.removeTrack(track)
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
                if !localStore.tracks.isEmpty {
                    Menu {
                        Button(role: .destructive) {
                            LocalPlaylistStore.shared.removeAll()
                        } label: {
                            Label("清空收藏歌单", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }
}

import SwiftUI

/// 本地歌单详情页：照抄我喜欢的音乐页面布局
struct LocalPlaylistView: View {
    @StateObject private var localStore = LocalPlaylistStore.shared
    @EnvironmentObject private var player: PlayerService
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // 顶部：封面 + 标题信息
                HStack(alignment: .top, spacing: 16) {
                    // 封面：渐变背景 + 音乐图标
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(LinearGradient(
                                colors: [Theme.accent, Theme.accent.opacity(0.7)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                        Image(systemName: "music.note.list")
                            .font(.system(size: 48, weight: .light))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .frame(width: 120, height: 120)
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 4)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("本地歌单")
                            .font(.system(size: 20, weight: .bold))
                            .lineLimit(2)

                        Text("\(localStore.count) 首")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)

                        Text("收藏的歌曲自动保存到本地")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.top, 4)

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 20)

                // 播放全部按钮
                if !localStore.tracks.isEmpty {
                    Button {
                        player.play(tracks: localStore.tracks, source: .none)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 16))
                            Text("播放全部 (\(localStore.count))")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            LinearGradient(
                                colors: [Theme.accent, Theme.accent.opacity(0.85)],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            in: Capsule()
                        )
                        .shadow(color: Theme.accent.opacity(0.3), radius: 8, y: 3)
                    }
                    .buttonStyle(.pressable)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }

                // 歌曲列表
                if localStore.tracks.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("还没有收藏的歌曲")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("收藏歌曲时会自动保存一份到本地歌单")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 80)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(0..<localStore.tracks.count, id: \.self) { index in
                            let track = localStore.tracks[index]
                            Button {
                                player.play(tracks: localStore.tracks, source: .none, startAt: track)
                            } label: {
                                HStack(spacing: 12) {
                                    // 封面
                                    CachedAsyncImage(url: track.album.picUrl?.resizedImageURL(120), animated: false)
                                        .frame(width: 48, height: 48)
                                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                                    // 歌名和歌手
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(track.name)
                                            .font(.system(size: 16))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text(track.artistNames)
                                            .font(.system(size: 13))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }

                                    Spacer()

                                    // 收藏状态
                                    Image(systemName: "heart.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(.red)

                                    // 时长
                                    Text(track.duration.formattedDuration)
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    LocalPlaylistStore.shared.removeTrack(track)
                                } label: {
                                    Label("移除", systemImage: "trash")
                                }
                            }

                            if index < localStore.tracks.count - 1 {
                                Divider()
                                    .padding(.leading, 76)
                            }
                        }
                    }
                    .padding(.bottom, 20)
                }
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
                            Label("清空本地歌单", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }
}

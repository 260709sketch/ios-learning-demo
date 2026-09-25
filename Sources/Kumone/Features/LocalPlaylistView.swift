import SwiftUI

/// 本地歌单详情页：和歌单详情页样式一致
struct LocalPlaylistView: View {
    @StateObject private var localStore = LocalPlaylistStore.shared
    @EnvironmentObject private var player: PlayerService
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                // 顶部封面和信息
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top, spacing: 14) {
                            // 封面：渐变背景 + 音乐图标
                            ZStack {
                                RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous)
                                    .fill(Theme.accentGradient)
                                Image(systemName: "music.note.list")
                                    .font(.system(size: 48, weight: .light))
                                    .foregroundStyle(.white.opacity(0.9))
                            }
                            .frame(width: 120, height: 120)
                            .shadow(color: .black.opacity(0.2), radius: 10, y: 4)

                            VStack(alignment: .leading, spacing: 6) {
                                Text("本地歌单")
                                    .font(.system(size: 16, weight: .bold))
                                    .lineLimit(3)

                                Text("\(localStore.count) 首")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)

                                Text("收藏的歌曲自动保存到本地")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }

                        // 播放全部按钮
                        if !localStore.tracks.isEmpty {
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

                                // 清空按钮
                                Button {
                                    LocalPlaylistStore.shared.removeAll()
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(.red)
                                        .frame(width: 38, height: 38)
                                        .background(.primary.opacity(0.06), in: Circle())
                                }
                                .buttonStyle(.pressable)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 16)
                }
                .listRowBackground(Color.clear)

                // 歌曲列表
                if localStore.tracks.isEmpty {
                    Section {
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
                        .padding(.vertical, 60)
                    }
                } else {
                    Section {
                        ForEach(Array(localStore.tracks.enumerated()), id: \.element.id) { index, track in
                            TrackRow(
                                track: track,
                                index: index,
                                onPlay: {
                                    player.play(tracks: localStore.tracks, source: .none, startAt: track)
                                }
                            )
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    LocalPlaylistStore.shared.removeTrack(track)
                                } label: {
                                    Label("移除", systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("共 \(localStore.count) 首")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(colorScheme == .dark ? Color.black : Color(uiColor: .systemBackground))
                    }
                }
            }
        }
        .navigationTitle("本地歌单")
        .navigationBarTitleDisplayMode(.inline)
        .background(colorScheme == .dark ? Color.black : Color(uiColor: .systemGroupedBackground))
    }
}

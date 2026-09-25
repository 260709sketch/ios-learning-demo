import SwiftUI

/// 本地歌单页面：显示所有收藏到本地的歌曲
struct LocalPlaylistView: View {
    @StateObject private var localStore = LocalPlaylistStore.shared
    @EnvironmentObject private var player: PlayerService

    var body: some View {
        List {
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
                    .listRowBackground(Color.clear)
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
                    Text("共 \(localStore.count) 首")
                }
            }
        }
        .navigationTitle("本地歌单")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if !localStore.tracks.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
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

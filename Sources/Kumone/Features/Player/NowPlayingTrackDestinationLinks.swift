import SwiftUI

/// Links the current track metadata to its artist and album without requiring
/// the immersive presentation to own a second navigation stack.
/// 点击歌手名时，多名歌手弹出紧凑菜单选择，单名歌手直接跳转。
struct NowPlayingTrackDestinationLinks: View {
    let track: Track
    let font: Font
    let color: Color
    let onOpenDestination: (Destination) -> Void

    private var artists: [ArtistRef] {
        track.artists.filter { !$0.name.isEmpty }
    }

    private func destination(for artist: ArtistRef) -> Destination {
        if let mid = artist.singerMid, !mid.isEmpty {
            let platform = track.sourcePlatform ?? "tx"
            let summary = ArtistSummary(id: artist.id, name: artist.name, picUrl: nil, sourcePlatform: platform, singerMid: mid)
            return .artistWithMid(artist.id, mid, summary)
        }
        return .artist(artist.id)
    }

    private var albumDestination: Destination? {
        guard track.album.id > 0, !track.album.name.isEmpty else { return nil }
        if let mid = track.album.albumMid, !mid.isEmpty {
            let platform = track.sourcePlatform ?? "tx"
            let summary = AlbumSummary(id: track.album.id, name: track.album.name, picUrl: track.album.picUrl, sourcePlatform: platform, albumMid: mid)
            return .albumWithMid(track.album.id, mid, summary)
        }
        return .album(track.album.id)
    }

    var body: some View {
        HStack(spacing: 0) {
            // 歌手名区域
            Group {
                if artists.isEmpty {
                    Text(track.artistNames)
                } else if artists.count == 1, let first = artists.first {
                    // 单名歌手：直接点击跳转（用 Text + onTapGesture，避免 Button 在嵌套视图中点击失效）
                    Text(first.name)
                        .contentShape(Rectangle())
                        .padding(.vertical, 4)
                        .padding(.trailing, 4)
                        .onTapGesture {
                            onOpenDestination(destination(for: first))
                        }
                        .accessibilityLabel("打开歌手：\(first.name)")
                        .accessibilityAddTraits(.isButton)
                } else {
                    // 多名歌手：Menu 紧凑菜单，不占位置
                    Menu {
                        ForEach(artists, id: \.id) { artist in
                            Button(artist.name) {
                                onOpenDestination(destination(for: artist))
                            }
                        }
                    } label: {
                        Text(artists.map(\.name).joined(separator: " / "))
                            .contentShape(Rectangle())
                            .padding(.vertical, 4)
                            .padding(.trailing, 4)
                    }
                    .accessibilityLabel("选择歌手")
                }
            }

            // 专辑名：独立可点击
            if let albumDest = albumDestination {
                if !track.artistNames.isEmpty {
                    Text(" — ")
                }
                Text(track.album.name)
                    .contentShape(Rectangle())
                    .padding(.vertical, 4)
                    .padding(.leading, 4)
                    .onTapGesture {
                        onOpenDestination(albumDest)
                    }
                    .accessibilityLabel("打开专辑：\(track.album.name)")
                    .accessibilityAddTraits(.isButton)
            }
        }
        .font(font)
        .foregroundStyle(color)
        .lineLimit(1)
        .contentShape(Rectangle())
    }
}

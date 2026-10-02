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

    private func destination(for artist: ArtistRef) -> Destination? {
        if let mid = artist.singerMid, !mid.isEmpty {
            let platform = track.sourcePlatform ?? "tx"
            let summary = ArtistSummary(id: artist.id, name: artist.name, picUrl: nil, sourcePlatform: platform, singerMid: mid)
            return .artistWithMid(artist.id, mid, summary)
        }
        // 网易云歌手用 id 跳转
        if track.sourcePlatform == nil || track.sourcePlatform == "nc" {
            return .artist(artist.id)
        }
        return nil
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
                    if let dest = destination(for: first) {
                        // 单名歌手：直接点击跳转
                        Text(first.name)
                            .contentShape(Rectangle())
                            .padding(.vertical, 4)
                            .padding(.trailing, 4)
                            .onTapGesture {
                                onOpenDestination(dest)
                            }
                            .accessibilityLabel("打开歌手：\(first.name)")
                            .accessibilityAddTraits(.isButton)
                    } else {
                        Text(first.name)
                            .padding(.vertical, 4)
                            .padding(.trailing, 4)
                    }
                } else {
                    // 多名歌手：Menu 紧凑菜单，只显示可跳转的歌手
                    let clickable = artists.compactMap { artist -> (ArtistRef, Destination)? in
                        destination(for: artist).map { (artist, $0) }
                    }
                    if clickable.count == 1, let (artist, dest) = clickable.first {
                        // 只有一个可跳转歌手：显示所有歌手名，第一个可点击
                        HStack(spacing: 0) {
                            Text(artist.name)
                                .contentShape(Rectangle())
                                .padding(.vertical, 4)
                                .onTapGesture { onOpenDestination(dest) }
                                .accessibilityLabel("打开歌手：\(artist.name)")
                                .accessibilityAddTraits(.isButton)
                            if artists.count > 1 {
                                Text(" / " + artists.dropFirst().map(\.name).joined(separator: " / "))
                                    .padding(.vertical, 4)
                            }
                        }
                    } else if clickable.count > 1 {
                        Menu {
                            ForEach(Array(clickable), id: \.0.id) { (artist, dest) in
                                Button(artist.name) {
                                    onOpenDestination(dest)
                                }
                            }
                        } label: {
                            Text(artists.map(\.name).joined(separator: " / "))
                                .contentShape(Rectangle())
                                .padding(.vertical, 4)
                                .padding(.trailing, 4)
                        }
                        .accessibilityLabel("选择歌手")
                    } else {
                        Text(artists.map(\.name).joined(separator: " / "))
                            .padding(.vertical, 4)
                            .padding(.trailing, 4)
                    }
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

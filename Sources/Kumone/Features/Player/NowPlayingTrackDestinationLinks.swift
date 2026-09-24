import SwiftUI

/// Links the current track metadata to its artist and album without requiring
/// the immersive presentation to own a second navigation stack.
/// 点击歌手名时，多名歌手弹出选择菜单，单名歌手直接跳转。
struct NowPlayingTrackDestinationLinks: View {
    let track: Track
    let font: Font
    let color: Color
    let onOpenDestination: (Destination) -> Void

    @State private var showArtistPicker = false

    private var artists: [ArtistRef] {
        track.artists.filter { $0.id > 0 && !$0.name.isEmpty }
    }

    var body: some View {
        HStack(spacing: 0) {
            // 歌手名区域：整体可点击
            Group {
                if artists.isEmpty {
                    Text(track.artistNames)
                } else {
                    Text(artists.map(\.name).joined(separator: " / "))
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
            .onTapGesture {
                if artists.count == 1, let first = artists.first {
                    onOpenDestination(.artist(first.id))
                } else if artists.count > 1 {
                    showArtistPicker = true
                }
            }
            .accessibilityLabel(artists.count > 1 ? "选择歌手" : "打开歌手：\(artists.first?.name ?? "")")
            .confirmationDialog("选择歌手", isPresented: $showArtistPicker, titleVisibility: .visible) {
                ForEach(artists, id: \.id) { artist in
                    Button(artist.name) {
                        onOpenDestination(.artist(artist.id))
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("选择要查看的歌手主页")
            }

            // 专辑名：独立可点击
            if track.album.id > 0, !track.album.name.isEmpty {
                if !track.artistNames.isEmpty {
                    Text(" — ")
                }
                Button {
                    onOpenDestination(.album(track.album.id))
                } label: {
                    Text(track.album.name)
                        .contentShape(Rectangle())
                        .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("打开专辑：\(track.album.name)")
            }
        }
        .font(font)
        .foregroundStyle(color)
        .lineLimit(1)
        .accessibilityElement(children: .contain)
    }
}

import SwiftUI

private struct OpenLoginKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

private struct OpenDestinationKey: EnvironmentKey {
    static let defaultValue: (Destination) -> Void = { _ in }
}

extension EnvironmentValues {
    var openLogin: () -> Void {
        get { self[OpenLoginKey.self] }
        set { self[OpenLoginKey.self] = newValue }
    }

    var openDestination: (Destination) -> Void {
        get { self[OpenDestinationKey.self] }
        set { self[OpenDestinationKey.self] = newValue }
    }
}

struct PlayerChromeModifier: ViewModifier {
    @EnvironmentObject private var player: PlayerService
    let detailWidth: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) {
                PlayerBar()
                    .frame(width: detailWidth)
            }
            .overlay(alignment: .trailing) {
                rightPanel
            }
            .animation(AppAnimation.standard, value: player.activePanel)
    }

    @ViewBuilder
    private var rightPanel: some View {
        if let panel = player.activePanel {
            Group {
                switch panel {
                case .lyrics:
                    LyricsPanel()
                case .queue:
                    QueuePanel()
                }
            }
            .padding(.top, 12)
            .padding(.bottom, Theme.Layout.playerChromeClearance + 10)
            .padding(.trailing, 16)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }
}

enum SidebarItem: Hashable {
    case home
    case explore
    case fm
    case search
    case likedSongs
    case daily
    case recents
    case collections
    case cloud
    case playlist(Int)
}

enum Destination: Hashable {
    case playlist(Int)
    case radarPlaylist(Int)
    case album(Int)
    case artist(Int)
    case artistWithMid(Int, String, ArtistSummary)
    case albumWithMid(Int, String, AlbumSummary)
    case daily
    case toplists
    case recents
    case recentPlays
    case collections
    case cloud
    case search(String)
    case localPlaylist
    case externalPlaylist(ExternalPlaylist)
}

extension Array where Element == Destination {
    mutating func appendIfNotCurrent(_ destination: Destination) {
        guard last != destination else { return }
        append(destination)
    }
}

/// Registers all shared navigation destinations on a stack.
struct DestinationsModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.navigationDestination(for: Destination.self) { destination in
            Group {
                switch destination {
                case .playlist(let id):
                    PlaylistDetailView(playlistID: id)
                case .radarPlaylist(let id):
                    PlaylistDetailView(playlistID: id, recommendationContext: .radar)
                case .album(let id):
                    AlbumDetailView(albumID: id)
                case .artist(let id):
                    ArtistDetailView(artistID: id)
                case .artistWithMid(let id, let mid, let artist):
                    ArtistDetailView(artistID: id, singerMid: mid, initialArtist: artist)
                case .albumWithMid(let id, let mid, let album):
                    AlbumDetailView(albumID: id, albumMid: mid, initialAlbum: album)
                case .daily:
                    DailySongsView()
                case .toplists:
                    ToplistsView()
                case .recents:
                    RecentsView()
                case .recentPlays:
                    RecentPlaysView()
                case .collections:
                    CollectionsView()
                case .cloud:
                    CloudView()
                case .search(let query):
                    SearchView(query: query)
                case .localPlaylist:
                    LocalPlaylistView()
                case .externalPlaylist(let playlist):
                    ExternalPlaylistView(playlist: playlist)
                }
            }
            .playerContentInset()
        }
    }
}

extension View {
    func playerChrome(detailWidth: CGFloat) -> some View {
        modifier(PlayerChromeModifier(detailWidth: detailWidth))
    }

    /// Pages clear the floating player bar with an explicit trailing
    /// `PlayerClearanceSpacer` in their scroll content; safeAreaPadding
    /// proved unreliable inside navigation stacks (#12).
    func playerContentInset() -> some View {
        self
    }

    func appDestinations() -> some View {
        modifier(DestinationsModifier())
    }
}

/// Trailing spacer for scrollable pages so the last row clears the
/// floating player bar.
struct PlayerClearanceSpacer: View {
    @EnvironmentObject private var player: PlayerService

    var body: some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            // On iOS 26+, the native TabView bottom accessory automatically
            // expands the content safe area insets; keep only the breathing margin.
            Color.clear.frame(height: Theme.Layout.scrollBreathingMargin)
        } else {
            // On iOS < 26, customTabInterface floats above content and requires
            // explicit bottom clearance.
            Color.clear.frame(
                height: player.hasCurrentTrack
                    ? Theme.Layout.FloatingChrome.fullChromeClearance
                    : Theme.Layout.FloatingChrome.tabBarClearance
            )
        }
        #else
        Color.clear.frame(
            height: Theme.Layout.playerChromeClearance + Theme.Layout.scrollBreathingMargin
        )
        #endif
    }
}

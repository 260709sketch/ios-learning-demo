import Foundation

/// 本地歌单：收藏的歌曲自动保存一份到本地，不依赖网易云同步
@MainActor
final class LocalPlaylistStore: ObservableObject {
    static let shared = LocalPlaylistStore()

    @Published private(set) var tracks: [Track] = []

    private let defaultsKey = "localPlaylist.tracks"

    private init() {
        load()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return }
        if let decoded = try? JSONDecoder().decode([Track].self, from: data) {
            tracks = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(tracks) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    // MARK: - Operations

    func contains(_ track: Track) -> Bool {
        tracks.contains { $0.id == track.id && $0.sourcePlatform == track.sourcePlatform }
    }

    func contains(trackID: Int, sourcePlatform: String?) -> Bool {
        tracks.contains { $0.id == trackID && $0.sourcePlatform == sourcePlatform }
    }

    func addTrack(_ track: Track) {
        guard !contains(track) else { return }
        tracks.insert(track, at: 0) // 最新收藏的在最前面
        save()
    }

    func removeTrack(_ track: Track) {
        tracks.removeAll { $0.id == track.id && $0.sourcePlatform == track.sourcePlatform }
        save()
    }

    func removeTrack(trackID: Int, sourcePlatform: String?) {
        tracks.removeAll { $0.id == trackID && $0.sourcePlatform == sourcePlatform }
        save()
    }

    func removeAll() {
        tracks.removeAll()
        save()
    }

    var count: Int { tracks.count }
}

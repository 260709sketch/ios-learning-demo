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
        // sourcePlatform 为 nil 时（网易云歌曲）只按 id 匹配
        if track.sourcePlatform == nil {
            return tracks.contains { $0.id == track.id }
        }
        return tracks.contains { $0.id == track.id && $0.sourcePlatform == track.sourcePlatform }
    }

    func contains(trackID: Int, sourcePlatform: String?) -> Bool {
        if sourcePlatform == nil {
            return tracks.contains { $0.id == trackID }
        }
        return tracks.contains { $0.id == trackID && $0.sourcePlatform == sourcePlatform }
    }

    func addTrack(_ track: Track) {
        guard !contains(track) else {
            DebugLogger.shared.log("本地歌单", "歌曲已存在，跳过添加 id=\(track.id) name=\(track.name)")
            return
        }
        tracks.insert(track, at: 0) // 最新收藏的在最前面
        save()
        DebugLogger.shared.log("本地歌单", "添加成功 id=\(track.id) name=\(track.name) 总数=\(tracks.count)", level: .success)
    }

    func removeTrack(_ track: Track) {
        if track.sourcePlatform == nil {
            tracks.removeAll { $0.id == track.id }
        } else {
            tracks.removeAll { $0.id == track.id && $0.sourcePlatform == track.sourcePlatform }
        }
        save()
    }

    func removeTrack(trackID: Int, sourcePlatform: String?) {
        if sourcePlatform == nil {
            tracks.removeAll { $0.id == trackID }
        } else {
            tracks.removeAll { $0.id == trackID && $0.sourcePlatform == sourcePlatform }
        }
        save()
    }

    func removeAll() {
        tracks.removeAll()
        save()
    }

    func replaceAll(_ newTracks: [Track]) {
        tracks = newTracks
        save()
    }

    var count: Int { tracks.count }
}

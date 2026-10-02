import Foundation

/// 外部歌单：导入的网易云/QQ/酷狗歌单，保存在本地
struct ExternalPlaylist: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var sourcePlatform: String // "wy" / "tx" / "kg"
    var coverURL: String?
    var trackIDs: [Int] // 用 id+sourcePlatform 匹配歌曲
    var trackPlatforms: [String]
    var createdAt: Date

    init(id: String, name: String, sourcePlatform: String, coverURL: String? = nil, tracks: [Track]) {
        self.id = id
        self.name = name
        self.sourcePlatform = sourcePlatform
        self.coverURL = coverURL
        self.trackIDs = tracks.map { $0.id }
        self.trackPlatforms = tracks.map { $0.sourcePlatform ?? "wy" }
        self.createdAt = Date()
    }
}

@MainActor
final class ExternalPlaylistStore: ObservableObject {
    static let shared = ExternalPlaylistStore()

    @Published private(set) var playlists: [ExternalPlaylist] = []
    @Published private(set) var tracks: [String: [Track]] = [:] // playlistID -> tracks

    private let defaultsKey = "externalPlaylists"
    private let tracksKeyPrefix = "externalPlaylist.tracks."

    private init() {
        load()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return }
        if let decoded = try? JSONDecoder().decode([ExternalPlaylist].self, from: data) {
            playlists = decoded
        }
        // 加载每个歌单的歌曲
        for playlist in playlists {
            if let trackData = UserDefaults.standard.data(forKey: tracksKeyPrefix + playlist.id),
               let decodedTracks = try? JSONDecoder().decode([Track].self, from: trackData) {
                tracks[playlist.id] = decodedTracks
            }
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(playlists) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        for (playlistID, playlistTracks) in tracks {
            if let data = try? JSONEncoder().encode(playlistTracks) {
                UserDefaults.standard.set(data, forKey: tracksKeyPrefix + playlistID)
            }
        }
    }

    // MARK: - Operations

    func addPlaylist(name: String, sourcePlatform: String, coverURL: String?, tracks: [Track]) -> ExternalPlaylist {
        let id = UUID().uuidString
        let playlist = ExternalPlaylist(id: id, name: name, sourcePlatform: sourcePlatform, coverURL: coverURL, tracks: tracks)
        playlists.insert(playlist, at: 0)
        self.tracks[id] = tracks
        save()
        DebugLogger.shared.log("外部歌单", "添加歌单: \(name) 歌曲数: \(tracks.count)", level: .success)
        return playlist
    }

    func removePlaylist(_ playlist: ExternalPlaylist) {
        playlists.removeAll { $0.id == playlist.id }
        tracks.removeValue(forKey: playlist.id)
        UserDefaults.standard.removeObject(forKey: tracksKeyPrefix + playlist.id)
        save()
    }

    func getTracks(for playlistID: String) -> [Track] {
        tracks[playlistID] ?? []
    }

    func removeTrack(from playlistID: String, track: Track) {
        guard var playlistTracks = tracks[playlistID] else { return }
        if track.sourcePlatform == nil {
            playlistTracks.removeAll { $0.id == track.id }
        } else {
            playlistTracks.removeAll { $0.id == track.id && $0.sourcePlatform == track.sourcePlatform }
        }
        tracks[playlistID] = playlistTracks
        // 更新歌单的 trackIDs
        if let index = playlists.firstIndex(where: { $0.id == playlistID }) {
            var updated = playlists[index]
            updated.trackIDs = playlistTracks.map { $0.id }
            updated.trackPlatforms = playlistTracks.map { $0.sourcePlatform ?? "wy" }
            playlists[index] = updated
        }
        save()
    }

    var count: Int { playlists.count }
}

import Foundation

/// 本地最近播放记录管理器
/// 听歌时自动记录完整歌曲数据，按时间倒序排列，最多 100 首
final class RecentPlaysStore: ObservableObject {
    static let shared = RecentPlaysStore()

    @Published private(set) var recentTracks: [Track] = []

    private let defaultsKey = "recentPlaysTracks"
    private let maxCount = 100

    private init() {
        load()
    }

    /// 记录一首歌曲到最近播放
    func record(track: Track) {
        // 去重：如果已存在，先移除
        if let index = recentTracks.firstIndex(where: { $0.id == track.id }) {
            recentTracks.remove(at: index)
        }
        // 插入到最前面
        recentTracks.insert(track, at: 0)
        // 限制数量
        if recentTracks.count > maxCount {
            recentTracks = Array(recentTracks.prefix(maxCount))
        }
        save()
    }

    /// 清空最近播放
    func clear() {
        recentTracks.removeAll()
        save()
    }

    // MARK: - 持久化

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return }
        recentTracks = (try? JSONDecoder().decode([Track].self, from: data)) ?? []
    }

    private func save() {
        if let data = try? JSONEncoder().encode(recentTracks) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

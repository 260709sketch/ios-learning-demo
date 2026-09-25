import Foundation
import Combine

/// 调试日志系统：记录 LX 音源请求、QRC 歌词、播放状态等关键信息
final class DebugLogger: ObservableObject {
    static let shared = DebugLogger()

    @Published private(set) var logs: [LogEntry] = []
    private let maxLogs = 500
    private let queue = DispatchQueue(label: "debug.logger.queue")

    struct LogEntry: Identifiable, Equatable {
        let id = UUID()
        let time: Date
        let category: String
        let message: String
        let level: Level

        enum Level: String {
            case info = "INFO"
            case warning = "WARN"
            case error = "ERROR"
            case success = "OK"
        }
    }

    private init() {}

    /// 是否启用调试日志
    var enabled: Bool {
        UserDefaults.standard.bool(forKey: "settings.debugLogEnabled")
    }

    func log(_ category: String, _ message: String, level: LogEntry.Level = .info) {
        guard enabled else { return }
        queue.async {
            let entry = LogEntry(time: Date(), category: category, message: message, level: level)
            DispatchQueue.main.async {
                self.logs.append(entry)
                if self.logs.count > self.maxLogs {
                    self.logs.removeFirst(self.logs.count - self.maxLogs)
                }
            }
        }
    }

    func clear() {
        logs.removeAll()
    }

    /// 导出为文本
    func exportText() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return logs.map { entry in
            "[\(formatter.string(from: entry.time))] [\(entry.level.rawValue)] [\(entry.category)] \(entry.message)"
        }.joined(separator: "\n")
    }
}

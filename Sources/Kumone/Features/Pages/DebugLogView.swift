import SwiftUI

/// 调试日志查看页面
struct DebugLogView: View {
    @StateObject private var logger = DebugLogger.shared
    @State private var filter: String = ""

    var filteredLogs: [DebugLogger.LogEntry] {
        if filter.isEmpty { return logger.logs }
        return logger.logs.filter { $0.category.contains(filter) || $0.message.contains(filter) }
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Button("清空") { logger.clear() }
                    Spacer()
                    ShareLink(item: logger.exportText()) {
                        Label("导出", systemImage: "square.and.arrow.up")
                    }
                }
                TextField("筛选（分类/关键词）", text: $filter)
                    .textFieldStyle(.roundedBorder)
            }

            ForEach(filteredLogs.reversed()) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(entry.level.rawValue)
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundStyle(levelColor(entry.level))
                        Text(entry.category)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(entry.time, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(entry.message)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                .padding(.vertical, 2)
            }
        }
        .navigationTitle("调试日志")
    }

    private func levelColor(_ level: DebugLogger.LogEntry.Level) -> Color {
        switch level {
        case .error: return .red
        case .warning: return .orange
        case .success: return .green
        case .info: return .blue
        }
    }
}

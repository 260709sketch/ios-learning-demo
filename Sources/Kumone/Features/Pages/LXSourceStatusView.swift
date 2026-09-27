import SwiftUI

/// 音源状态查看页：显示当前激活音源、最近请求日志（返回 URL、音质、耗时等）。
struct LXSourceStatusView: View {
    @StateObject private var store = LXSourceStore.shared

    var body: some View {
        List {
            // 当前音源状态
            Section {
                if let activeID = store.activeSourceID,
                   let source = store.sources.first(where: { $0.id == activeID }) {
                    LabeledContent("音源名称", value: source.name)
                    LabeledContent("版本", value: source.version)
                    LabeledContent("作者", value: source.author)
                    if !source.sourceDescription.isEmpty {
                        LabeledContent("描述", value: source.sourceDescription)
                    }
                } else {
                    Text("未激活任何音源")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("当前音源")
            }

            // 请求统计
            Section {
                let total = store.requestLogs.count
                let success = store.requestLogs.filter { $0.success }.count
                let failed = total - success
                LabeledContent("总请求数", value: "\(total)")
                LabeledContent("成功", value: "\(success)")
                LabeledContent("失败", value: "\(failed)")
                if let avg = averageDuration {
                    LabeledContent("平均耗时", value: avg)
                }
            } header: {
                Text("请求统计")
            }

            // 最近请求日志
            Section {
                if store.requestLogs.isEmpty {
                    Text("暂无请求记录，播放一首歌曲后自动记录")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.requestLogs) { log in
                        requestLogRow(log)
                    }
                }
            } header: {
                HStack {
                    Text("最近请求")
                    Spacer()
                    if !store.requestLogs.isEmpty {
                        Button(role: .destructive) {
                            store.clearRequestLogs()
                        } label: {
                            Text("清空")
                                .font(.caption)
                        }
                    }
                }
            }
        }
        .navigationTitle("音源状态")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var averageDuration: String? {
        guard !store.requestLogs.isEmpty else { return nil }
        let avg = store.requestLogs.reduce(0.0) { $0 + $1.duration } / Double(store.requestLogs.count)
        return String(format: "%.1fs", avg)
    }

    private func requestLogRow(_ log: LXRequestLog) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: log.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(log.success ? .green : .red)
                Text(log.trackName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text(log.durationText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(log.trackArtist)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(spacing: 12) {
                if let actual = log.actualQuality {
                    Label(actual, systemImage: "hifispeaker.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let fileSize = log.fileSizeText {
                    Label(fileSize, systemImage: "doc.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Label(log.requestedQuality, systemImage: "arrow.down.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let url = log.url {
                Text(url)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let error = log.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// 数据备份与恢复页面
struct DataBackupView: View {
    @StateObject private var localStore = LocalPlaylistStore.shared
    @State private var showFilePicker = false
    @State private var showShareSheet = false
    @State private var backupFileURL: URL?
    @State private var statusMessage = ""
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    // 恢复确认
    @State private var pendingBackup: [String: Any]?
    @State private var pendingFileName = ""
    @State private var showConfirmAlert = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("会备份以下数据：")
                        .font(.headline)
                    Text("• 收藏歌单的所有歌曲")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("• 应用设置（音质、预加载、主题、播放页模式、歌词设置、AMLL设置等）")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("• 音源设置与自定义音源")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section {
                Button {
                    createBackup()
                } label: {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(.blue)
                        Text("备份数据")
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                }

                Button {
                    showFilePicker = true
                } label: {
                    HStack {
                        Image(systemName: "square.and.arrow.down")
                            .foregroundStyle(.green)
                        Text("恢复数据")
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                }
            }

            if !statusMessage.isEmpty {
                Section {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("数据备份")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showShareSheet) {
            if let url = backupFileURL {
                ActivityViewController(activityItems: [url])
            }
        }
        // 用 UIDocumentPickerViewController + asCopy:true，与音源导入一致
        .fullScreenCover(isPresented: $showFilePicker) {
            BackupDocumentPicker(
                onPick: { url in
                    showFilePicker = false
                    handlePickedFile(url)
                },
                onCancel: {
                    showFilePicker = false
                }
            )
            .ignoresSafeArea()
        }
        // 恢复确认对话框
        .alert("确认恢复备份", isPresented: $showConfirmAlert) {
            Button("取消", role: .cancel) {
                pendingBackup = nil
            }
            Button("恢复", role: .destructive) {
                if let backup = pendingBackup {
                    performRestore(backup: backup, fileName: pendingFileName)
                }
                pendingBackup = nil
            }
        } message: {
            if let backup = pendingBackup {
                let settingsCount = (backup["settings"] as? [String: Any])?.count ?? 0
                let playlistCount = ((backup["favoritePlaylist"] as? [[String: Any]]) ?? (backup["localPlaylist"] as? [[String: Any]]))?.count ?? 0
                let timestamp = backup["timestamp"] as? TimeInterval ?? 0
                let dateStr = timestamp > 0 ? DateFormatter.localizedString(from: Date(timeIntervalSince1970: timestamp), dateStyle: .medium, timeStyle: .short) : "未知"
                Text("文件：\(pendingFileName)\n备份时间：\(dateStr)\n设置项：\(settingsCount) 项\n收藏歌曲：\(playlistCount) 首\n\n恢复后将覆盖当前数据，确定继续吗？")
            } else {
                Text("")
            }
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("确定", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
    }

    // MARK: - 备份

    private func createBackup() {
        do {
            // 1. 导出所有 UserDefaults 设置（过滤掉无法JSON序列化的类型）
            var settingsDict: [String: Any] = [:]
            if let bundleID = Bundle.main.bundleIdentifier {
                let defaults = UserDefaults.standard
                if let dict = defaults.persistentDomain(forName: bundleID) {
                    for (key, value) in dict {
                        if value is String || value is Int || value is Double || value is Bool || value is [String: Any] || value is [Any] {
                            settingsDict[key] = value
                        } else if let data = value as? Data {
                            settingsDict[key] = data.base64EncodedString()
                        }
                    }
                }
            }

            // 2. 导出收藏歌单歌曲
            let playlistData = try JSONEncoder().encode(localStore.tracks)
            let playlistArray = try JSONSerialization.jsonObject(with: playlistData) as? [[String: Any]] ?? []

            // 3. 组装备份数据
            let backup: [String: Any] = [
                "version": 1,
                "timestamp": Date().timeIntervalSince1970,
                "settings": settingsDict,
                "favoritePlaylist": playlistArray
            ]

            // 4. 序列化为 JSON
            let jsonData = try JSONSerialization.data(withJSONObject: backup, options: [.prettyPrinted])

            // 5. 保存到临时文件
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
            let filename = "Kumone_backup_\(dateFormatter.string(from: Date())).json"
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            try jsonData.write(to: tempURL)

            backupFileURL = tempURL
            statusMessage = "备份已生成：\(filename)（\(localStore.count) 首歌曲）"
            showShareSheet = true
        } catch {
            alertTitle = "备份失败"
            alertMessage = error.localizedDescription
            showAlert = true
        }
    }

    // MARK: - 恢复（两步：先解析确认，再执行恢复）

    private func handlePickedFile(_ url: URL) {
        DebugLogger.shared.log("数据备份", "选择文件: \(url.lastPathComponent)")

        do {
            // 第一步：读取并解析备份文件
            let data = try Data(contentsOf: url)
            DebugLogger.shared.log("数据备份", "文件大小: \(data.count) 字节")
            guard let backup = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "Backup", code: -1, userInfo: [NSLocalizedDescriptionKey: "文件格式错误，不是有效的 JSON 备份文件"])
            }
            DebugLogger.shared.log("数据备份", "备份文件键: \(Array(backup.keys))")

            // 验证备份文件有效性
            guard backup["version"] != nil || backup["settings"] != nil || backup["favoritePlaylist"] != nil else {
                throw NSError(domain: "Backup", code: -2, userInfo: [NSLocalizedDescriptionKey: "这不是 Kumone 的备份文件"])
            }

            // 显示确认对话框
            pendingBackup = backup
            pendingFileName = url.lastPathComponent
            showConfirmAlert = true
            DebugLogger.shared.log("数据备份", "解析成功，等待用户确认恢复")
        } catch {
            DebugLogger.shared.log("数据备份", "解析备份文件失败: \(error.localizedDescription)", level: .error)
            alertTitle = "导入失败"
            alertMessage = "\(error.localizedDescription)\n\n请确认选择的是 Kumone_backup_ 开头的 JSON 备份文件"
            showAlert = true
        }
    }

    private func performRestore(backup: [String: Any], fileName: String) {
        DebugLogger.shared.log("数据备份", "用户确认恢复，开始执行恢复")
        DebugLogger.shared.log("数据备份", "恢复前歌单数量: \(localStore.count)")

        var restoredSettings = 0
        var restoredTracks = 0

        // 1. 恢复收藏歌单（兼容旧键名localPlaylist）
        let playlistArray = (backup["favoritePlaylist"] as? [[String: Any]]) ?? (backup["localPlaylist"] as? [[String: Any]])
        if let playlistArray = playlistArray {
            DebugLogger.shared.log("数据备份", "备份中歌单数据条数: \(playlistArray.count)")
            do {
                let playlistData = try JSONSerialization.data(withJSONObject: playlistArray)
                let tracks = try JSONDecoder().decode([Track].self, from: playlistData)
                localStore.replaceAll(tracks)
                restoredTracks = tracks.count
                DebugLogger.shared.log("数据备份", "恢复收藏歌单: \(restoredTracks) 首，恢复后数量: \(localStore.count)", level: .success)
            } catch {
                DebugLogger.shared.log("数据备份", "恢复收藏歌单失败: \(error.localizedDescription)", level: .error)
            }
        } else {
            DebugLogger.shared.log("数据备份", "备份中无收藏歌单数据", level: .warning)
        }

        // 2. 逐个 key 恢复设置（参考 WellMusic，不用 setPersistentDomain 整体覆盖）
        if let settings = backup["settings"] as? [String: Any] {
            DebugLogger.shared.log("数据备份", "备份中设置条数: \(settings.count)")
            let defaults = UserDefaults.standard
            for (key, value) in settings {
                defaults.set(value, forKey: key)
                restoredSettings += 1
            }
            DebugLogger.shared.log("数据备份", "逐个key恢复设置: \(restoredSettings) 项", level: .success)
            // 恢复设置后重新保存歌单（因为设置中可能包含 localPlaylist.tracks，会被覆盖）
            localStore.save()
            DebugLogger.shared.log("数据备份", "恢复设置后重新保存歌单，数量: \(localStore.count)")
        } else {
            DebugLogger.shared.log("数据备份", "备份中无设置数据", level: .warning)
        }

        alertTitle = "恢复成功"
        alertMessage = "已恢复 \(restoredSettings) 项设置和 \(restoredTracks) 首收藏歌曲。\n\n设置需重启应用后生效，收藏歌单已立即更新。"
        showAlert = true
        statusMessage = "已从 \(fileName) 恢复：\(restoredSettings) 项设置，\(restoredTracks) 首歌曲"
        DebugLogger.shared.log("数据备份", "恢复完成: 设置=\(restoredSettings) 歌曲=\(restoredTracks) 最终歌单=\(localStore.count)", level: .success)
    }
}

// MARK: - 文件选择器（UIDocumentPickerViewController + asCopy:true）

/// 用 UIKit 的 UIDocumentPickerViewController 以复制模式打开文件。
/// asCopy:true 时系统自动把文件复制到临时目录，返回的 URL 可直接读取，
/// 不需要 startAccessingSecurityScopedResource()，与音源导入保持一致。
private struct BackupDocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.json, .plainText, .item],
            asCopy: true
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: BackupDocumentPicker
        init(_ parent: BackupDocumentPicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            parent.onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}

// MARK: - UIActivityViewController 封装

struct ActivityViewController: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
}

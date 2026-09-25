import SwiftUI
import UniformTypeIdentifiers

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
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result: result)
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
            // 1. 导出所有 UserDefaults 设置（过滤掉NSData等无法JSON序列化的类型）
            var settingsDict: [String: Any] = [:]
            if let bundleID = Bundle.main.bundleIdentifier {
                let defaults = UserDefaults.standard
                if let dict = defaults.persistentDomain(forName: bundleID) {
                    for (key, value) in dict {
                        // 只保留可以JSON序列化的类型
                        if value is String || value is Int || value is Double || value is Bool || value is [String: Any] || value is [Any] {
                            settingsDict[key] = value
                        } else if let data = value as? Data {
                            // NSData转为base64字符串
                            settingsDict[key] = data.base64EncodedString()
                        }
                        // 其他类型（如Date、URL等）跳过
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

    // MARK: - 恢复

    private func handleFileImport(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            restoreBackup(from: url)
        case .failure(let error):
            alertTitle = "导入失败"
            alertMessage = error.localizedDescription
            showAlert = true
        }
    }

    private func restoreBackup(from url: URL) {
        do {
            // 读取文件
            let data = try Data(contentsOf: url)
            guard let backup = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "Backup", code: -1, userInfo: [NSLocalizedDescriptionKey: "文件格式错误"])
            }

            // 1. 恢复设置
            if let settings = backup["settings"] as? [String: Any],
               let bundleID = Bundle.main.bundleIdentifier {
                UserDefaults.standard.setPersistentDomain(settings, forName: bundleID)
            }

            // 2. 恢复收藏歌单
            if let playlistArray = backup["favoritePlaylist"] as? [[String: Any]] {
                let playlistData = try JSONSerialization.data(withJSONObject: playlistArray)
                let tracks = try JSONDecoder().decode([Track].self, from: playlistData)
                localStore.replaceAll(tracks)
            }

            alertTitle = "恢复成功"
            alertMessage = "数据已恢复，重启应用后生效"
            showAlert = true
            statusMessage = "已从 \(url.lastPathComponent) 恢复数据"
        } catch {
            alertTitle = "恢复失败"
            alertMessage = error.localizedDescription
            showAlert = true
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

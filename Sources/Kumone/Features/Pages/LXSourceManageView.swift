import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// LX 自定义音源管理：导入（URL / 粘贴脚本 / 文件）、激活、自动换源、音源测试。
struct LXSourceManageView: View {
    @ObservedObject private var store = LXSourceStore.shared
    @State private var urlInput = ""
    @State private var showScriptSheet = false
    @State private var scriptInput = ""
    @State private var importing = false
    @State private var showFilePicker = false
    @State private var importError: String?
    @State private var testingIDs = Set<String>()

    var body: some View {
        Form {
            // MARK: 当前状态
            Section {
                HStack {
                    Label("当前音源", systemImage: "music.note")
                    Spacer()
                    if store.isInitializing {
                        ProgressView()
                    } else if let activeID = store.activeSourceID,
                              let active = store.sources.first(where: { $0.id == activeID }) {
                        Text(active.name).foregroundStyle(.secondary)
                    } else {
                        Text("未启用").foregroundStyle(.secondary)
                    }
                }
                if let error = store.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("播放网易云歌曲遇到 VIP / 无版权时，自动使用已启用音源获取播放地址并自动换源。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // MARK: 导入
            Section("导入音源") {
                HStack {
                    TextField("粘贴音源链接（raw .js / GitHub 链接）", text: $urlInput)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button {
                        Task { await importFromURL() }
                    } label: {
                        if importing { ProgressView() } else { Text("导入") }
                    }
                    .disabled(urlInput.trimmingCharacters(in: .whitespaces).isEmpty || importing)
                }
                Button {
                    scriptInput = ""
                    showScriptSheet = true
                } label: {
                    Label("粘贴脚本文本导入", systemImage: "doc.on.clipboard")
                }
                Button {
                    showFilePicker = true
                } label: {
                    Label("从文件导入（.js）", systemImage: "folder")
                }
                if let importError = importError {
                    Text(importError).font(.caption).foregroundStyle(.red)
                }
            }

            // MARK: 音源列表
            Section("已导入音源（\(store.sources.count)）") {
                if store.sources.isEmpty {
                    Text("还没有导入任何音源").foregroundStyle(.secondary)
                }
                ForEach(store.sources) { source in
                    SourceRow(
                        source: source,
                        isActive: source.id == store.activeSourceID,
                        isTesting: testingIDs.contains(source.id),
                        onToggle: {
                            Task {
                                if source.id == store.activeSourceID {
                                    await store.deactivate()
                                } else {
                                    await store.activate(source)
                                }
                            }
                        },
                        onTest: {
                            Task {
                                testingIDs.insert(source.id)
                                _ = await store.test(source)
                                testingIDs.remove(source.id)
                            }
                        }
                    )
                }
                .onDelete { store.remove(at: $0) }
            }
        }
        .navigationTitle("自定义音源")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { store.loadPersistedList() }
        .fullScreenCover(isPresented: $showFilePicker) {
            SourceDocumentPicker(
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
        .sheet(isPresented: $showScriptSheet) {
            ScriptInputSheet(script: $scriptInput) {
                Task { await importFromScript() }
            }
        }
    }

    // MARK: 导入动作

    private func importFromURL() async {
        importing = true
        importError = nil
        do {
            try await store.importFromURL(urlInput)
            urlInput = ""
        } catch {
            importError = error.localizedDescription
        }
        importing = false
    }

    private func importFromScript() async {
        importError = nil
        do {
            try await store.importScript(scriptInput)
            showScriptSheet = false
        } catch {
            importError = error.localizedDescription
        }
    }

    private func handlePickedFile(_ url: URL) {
        // asCopy:true 时系统已复制到临时目录，可直接读取，无需 security-scoped
        do {
            let script = try String(contentsOf: url, encoding: .utf8)
            guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                importError = "文件内容为空"
                return
            }
            importError = nil
            Task {
                do {
                    try await store.importScript(script)
                } catch {
                    importError = "导入失败：\(error.localizedDescription)"
                }
            }
        } catch {
            importError = "无法读取文件：\(error.localizedDescription)"
        }
    }
}

// MARK: - 文件选择器（UIDocumentPickerViewController + asCopy:true）

/// 用 UIKit 的 UIDocumentPickerViewController 以复制模式打开文件。
/// asCopy:true 时系统自动把文件复制到临时目录，返回的 URL 可直接读取，
/// 不需要 startAccessingSecurityScopedResource()，这是 .js 文件能成功导入的关键。
private struct SourceDocumentPicker: UIViewControllerRepresentable {
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
        let parent: SourceDocumentPicker
        init(_ parent: SourceDocumentPicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            parent.onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}

// MARK: - 音源行

private struct SourceRow: View {
    let source: LXSourceInfo
    let isActive: Bool
    let isTesting: Bool
    let onToggle: () -> Void
    let onTest: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.name).font(.body)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                testBadge
            }
            HStack(spacing: 12) {
                Button(isActive ? "停用" : "启用", action: onToggle)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button {
                    onTest()
                } label: {
                    if isTesting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("测试", systemImage: "stethoscope")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var parts: [String] = []
        if !source.version.isEmpty { parts.append("v\(source.version)") }
        if !source.author.isEmpty { parts.append(source.author) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var testBadge: some View {
        switch source.testStatus {
        case .working:
            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.seal.fill").foregroundStyle(.red)
        default:
            EmptyView()
        }
    }
}

// MARK: - 粘贴脚本 Sheet

private struct ScriptInputSheet: View {
    @Binding var script: String
    let onImport: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TextEditor(text: $script)
                .font(.system(.footnote, design: .monospaced))
                .padding(8)
                .navigationTitle("粘贴音源脚本")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("导入", action: onImport)
                            .disabled(script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
    }
}

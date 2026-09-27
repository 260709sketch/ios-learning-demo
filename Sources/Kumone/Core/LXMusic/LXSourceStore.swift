import Foundation
import SwiftUI

// MARK: - 请求日志

/// 一次 LX 音源请求的记录，用于音源状态查看。
struct LXRequestLog: Identifiable, Hashable {
    let id = UUID()
    let date: Date
    let trackName: String
    let trackArtist: String
    let requestedQuality: String
    let actualQuality: String?
    let url: String?
    let duration: TimeInterval
    let success: Bool
    let errorMessage: String?

    var durationText: String {
        String(format: "%.1fs", duration)
    }
}

/// 音源存储与管理：导入、持久化、切换、自动换源、音源测试。
@MainActor
final class LXSourceStore: ObservableObject {
    static let shared = LXSourceStore()

    @Published var sources: [LXSourceInfo] = []
    @Published var activeSourceID: String? {
        didSet { persistActiveSourceID() }
    }
    @Published var isInitializing = false
    @Published var lastError: String?
    /// 最近的音源请求日志（最多保留 50 条）。
    @Published private(set) var requestLogs: [LXRequestLog] = []

    private let engine = LXMusicEngine.shared
    private let activeSourceKey = "lxmusic.activeSourceID"

    private init() {
        // 应用启动时立即恢复音源列表和激活状态
        loadPersistedList()
    }

    private func persistActiveSourceID() {
        UserDefaults.standard.set(activeSourceID, forKey: activeSourceKey)
    }

    /// 记录一次音源请求。
    func addRequestLog(_ log: LXRequestLog) {
        requestLogs.insert(log, at: 0)
        if requestLogs.count > 50 {
            requestLogs.removeLast()
        }
    }

    /// 清空请求日志。
    func clearRequestLogs() {
        requestLogs.removeAll()
    }

    // MARK: 路径

    private var lxDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("LXMusic", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private var scriptsDirectory: URL {
        let dir = lxDirectory.appendingPathComponent("scripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private var listURL: URL { lxDirectory.appendingPathComponent("sources.json") }

    private func scriptURL(_ id: String) -> URL {
        scriptsDirectory.appendingPathComponent("\(id).js")
    }

    // MARK: 启动加载

    func loadPersistedList() {
        guard let data = try? Data(contentsOf: listURL),
              let list = try? JSONDecoder().decode([LXSourceInfo].self, from: data) else {
            sources = []
            return
        }
        sources = list

        // 恢复上次激活的音源并自动重新加载
        // 使用最高优先级，确保应用启动后音源最快可用
        let savedID = UserDefaults.standard.string(forKey: activeSourceKey)
        if let savedID, let source = sources.first(where: { $0.id == savedID }) {
            activeSourceID = savedID
            Task(priority: .userInitiated) { await activate(source) }
        } else if let firstSource = sources.first {
            // 兜底：没有保存的激活音源但列表不为空，自动激活第一个
            activeSourceID = firstSource.id
            Task(priority: .userInitiated) { await activate(firstSource) }
        }
    }

    /// 等待音源初始化完成。播放时调用，确保引擎已加载完毕。
    func waitForInitialization() async {
        // 每 50ms 检查一次，最多等 5 秒
        var waited = 0
        while isInitializing && waited < 5000 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            waited += 50
        }
    }

    private func persistList() {
        guard let data = try? JSONEncoder().encode(sources) else { return }
        try? data.write(to: listURL)
    }

    func script(for id: String) -> String? {
        try? String(contentsOf: scriptURL(id), encoding: .utf8)
    }

    // MARK: 备份/恢复

    /// 导出所有音源（列表+脚本）用于备份
    func exportForBackup() -> (sources: [[String: Any]], scripts: [String: String]) {
        var sourceDicts: [[String: Any]] = []
        var scriptDict: [String: String] = [:]
        DebugLogger.shared.log("音源", "开始导出备份，当前音源\(sources.count)个")
        for source in sources {
            if let data = try? JSONEncoder().encode(source),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                sourceDicts.append(dict)
            } else {
                DebugLogger.shared.log("音源", "音源编码失败: \(source.name)", level: .error)
            }
            if let script = script(for: source.id) {
                scriptDict[source.id] = script
            } else {
                DebugLogger.shared.log("音源", "音源脚本不存在: \(source.name) id=\(source.id)", level: .warning)
            }
        }
        DebugLogger.shared.log("音源", "导出完成: 列表\(sourceDicts.count)个，脚本\(scriptDict.count)个")
        return (sourceDicts, scriptDict)
    }

    /// 从备份恢复音源（列表+脚本），直接更新内存并持久化
    func importFromBackup(sources: [[String: Any]], scripts: [String: String]) {
        DebugLogger.shared.log("音源", "开始从备份恢复，列表\(sources.count)个，脚本\(scripts.count)个")

        // 1. 解码音源列表
        guard let data = try? JSONSerialization.data(withJSONObject: sources),
              let list = try? JSONDecoder().decode([LXSourceInfo].self, from: data) else {
            DebugLogger.shared.log("音源", "音源列表解码失败", level: .error)
            return
        }
        DebugLogger.shared.log("音源", "解码成功，\(list.count)个音源: \(list.map { $0.name })")

        // 2. 写入脚本文件
        var scriptCount = 0
        for (id, script) in scripts {
            do {
                try script.write(to: scriptURL(id), atomically: true, encoding: .utf8)
                scriptCount += 1
            } catch {
                DebugLogger.shared.log("音源", "写入脚本失败 \(id): \(error.localizedDescription)", level: .error)
            }
        }
        DebugLogger.shared.log("音源", "写入脚本\(scriptCount)个")

        // 3. 直接更新内存中的音源列表（UI立即刷新）
        self.sources = list
        DebugLogger.shared.log("音源", "内存音源列表已更新，当前\(self.sources.count)个")

        // 4. 持久化音源列表
        persistList()
        DebugLogger.shared.log("音源", "持久化完成")

        // 5. 恢复激活的音源
        let savedID = UserDefaults.standard.string(forKey: activeSourceKey)
        if let savedID, let source = list.first(where: { $0.id == savedID }) {
            activeSourceID = savedID
            Task { await activate(source) }
            DebugLogger.shared.log("音源", "恢复激活音源: \(source.name)")
        } else if let firstSource = list.first {
            activeSourceID = firstSource.id
            Task { await activate(firstSource) }
            DebugLogger.shared.log("音源", "激活第一个音源: \(firstSource.name)")
        }
    }

    // MARK: 导入

    /// 从脚本文本导入音源。导入后如果当前没有激活的音源，自动激活。
    @discardableResult
    func importScript(_ script: String) async throws -> LXSourceInfo {
        let meta = parseMeta(script)
        let info = LXSourceInfo(
            id: "user_api_\(Int.random(in: 100...999))_\(Int(Date().timeIntervalSince1970 * 1000))",
            name: meta.name,
            sourceDescription: meta.description,
            version: meta.version,
            author: meta.author,
            homepage: meta.homepage,
            importDate: Date(),
            testStatus: .untested
        )
        try script.write(to: scriptURL(info.id), atomically: true, encoding: .utf8)
        sources.append(info)
        persistList()

        // 导入后自动激活（设为优先音源）
        await activate(info)

        return info
    }

    /// 从网络 URL 下载音源脚本并导入。
    @discardableResult
    func importFromURL(_ urlString: String) async throws -> LXSourceInfo {
        guard var url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw LXEngineError.initFailed("无效的链接")
        }
        // 支持 GitHub 页面链接自动转 raw
        if url.host == "github.com" {
            let parts = url.path.components(separatedBy: "/").filter { !$0.isEmpty }
            if parts.count >= 5 && parts[2] == "blob" {
                let user = parts[0], repo = parts[1], branch = parts[3]
                let filePath = parts[4...].joined(separator: "/")
                let raw = "https://raw.githubusercontent.com/\(user)/\(repo)/\(branch)/\(filePath)"
                url = URL(string: raw)!
            }
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw LXEngineError.initFailed("下载失败")
            }
            guard let script = String(data: data, encoding: .utf8) else {
                throw LXEngineError.initFailed("脚本编码无效（需 UTF-8）")
            }
            return try await importScript(script)
        } catch let error as LXEngineError {
            throw error
        } catch {
            throw LXEngineError.initFailed(error.localizedDescription)
        }
    }

    // MARK: 删除

    func remove(at offsets: IndexSet) {
        for index in offsets {
            let info = sources[index]
            try? FileManager.default.removeItem(at: scriptURL(info.id))
            if info.id == activeSourceID {
                Task { await deactivate() }
            }
        }
        sources.remove(atOffsets: offsets)
        persistList()
    }

    func remove(id: String) {
        if let index = sources.firstIndex(where: { $0.id == id }) {
            remove(at: IndexSet(integer: index))
        }
    }

    // MARK: 激活 / 停用

    /// 加载并激活音源。
    func activate(_ source: LXSourceInfo) async {
        guard let script = script(for: source.id) else {
            lastError = "音源脚本不存在"
            return
        }
        isInitializing = true
        lastError = nil
        do {
            let caps = try await engine.load(source: source, script: script)
            if caps.isEmpty {
                lastError = "音源未声明任何可用平台"
            } else {
                activeSourceID = source.id
            }
        } catch {
            lastError = error.localizedDescription
        }
        isInitializing = false
    }

    func deactivate() async {
        await engine.unload()
        activeSourceID = nil
    }

    /// 当前音源是否支持网易云 musicUrl。
    var supportsNeteasePlay: Bool {
        engine.capabilities.contains { $0.platform == "wy" && $0.actions.contains("musicUrl") }
    }

    // MARK: 音源测试

    /// 测试音源：加载后实际发起 musicUrl 请求，同时测试网易云和QQ音乐两个平台。
    /// 测试完成后恢复之前激活的音源。
    func test(_ source: LXSourceInfo) async -> LXSourceInfo.TestStatus {
        setTestStatus(id: source.id, status: .testing)
        setPlatformTestResult(id: source.id, platform: "wy", result: nil)
        setPlatformTestResult(id: source.id, platform: "tx", result: nil)
        guard let script = script(for: source.id) else {
            setTestStatus(id: source.id, status: .failed)
            return .failed
        }
        let previousActiveID = activeSourceID
        do {
            let caps = try await engine.load(source: source, script: script)
            let hasMusicURL = caps.contains { $0.actions.contains("musicUrl") }
            guard hasMusicURL else {
                setTestStatus(id: source.id, status: .failed)
                return .failed
            }
            // 同时测试网易云和QQ音乐两个平台
            async let wyResult = engine.testMusicURL(platform: "wy")
            async let txResult = engine.testMusicURL(platform: "tx")
            let canPlayWY = await wyResult
            let canPlayTX = await txResult
            setPlatformTestResult(id: source.id, platform: "wy", result: canPlayWY)
            setPlatformTestResult(id: source.id, platform: "tx", result: canPlayTX)
            // 任一平台可用即为 working
            let status: LXSourceInfo.TestStatus = (canPlayWY || canPlayTX) ? .working : .failed
            setTestStatus(id: source.id, status: status)
        } catch {
            setTestStatus(id: source.id, status: .failed)
        }

        // 恢复之前的音源
        if previousActiveID != source.id {
            if let prev = sources.first(where: { $0.id == previousActiveID }) {
                await activate(prev)
            } else {
                await deactivate()
            }
        }
        return sources.first { $0.id == source.id }?.testStatus ?? .failed
    }

    private func setTestStatus(id: String, status: LXSourceInfo.TestStatus) {
        if let index = sources.firstIndex(where: { $0.id == id }) {
            sources[index].testStatus = status
            persistList()
        }
    }

    private func setPlatformTestResult(id: String, platform: String, result: Bool?) {
        if let index = sources.firstIndex(where: { $0.id == id }) {
            if let result {
                sources[index].platformTestResults[platform] = result
            } else {
                sources[index].platformTestResults.removeValue(forKey: platform)
            }
        }
    }

    // MARK: 脚本元信息解析

    fileprivate struct Meta {
        var name = "", description = "", version = "", author = "", homepage = ""
    }
    fileprivate func parseMeta(_ script: String) -> Meta {
        var meta = Meta()
        // 找到第一个块注释 /* ... */
        guard let start = script.range(of: "/*") else {
            meta.name = "user_api_\(Int(Date().timeIntervalSince1970))"
            return meta
        }
        guard let end = script[start.lowerBound...].range(of: "*/") else {
            meta.name = "user_api_\(Int(Date().timeIntervalSince1970))"
            return meta
        }
        let comment = String(script[start.lowerBound..<end.upperBound])

        // 按行解析，匹配 * @key value 格式
        for rawLine in comment.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // 跳过 /* 和 */ 以及空行
            guard line.hasPrefix("*") else { continue }
            let content = line.dropFirst() // 去掉 *
                .trimmingCharacters(in: .whitespaces)
            guard content.hasPrefix("@") else { continue }
            // 解析 @key value
            let afterAt = content.dropFirst() // 去掉 @
            guard let spaceIndex = afterAt.firstIndex(of: " ") else { continue }
            let key = String(afterAt[..<spaceIndex])
            let value = String(afterAt[afterAt.index(after: spaceIndex)...])
                .trimmingCharacters(in: .whitespaces)

            switch key {
            case "name":
                meta.name = String(value.prefix(24))
            case "description":
                meta.description = String(value.prefix(36))
            case "author":
                meta.author = String(value.prefix(56))
            case "homepage":
                meta.homepage = String(value.prefix(1024))
            case "version":
                meta.version = String(value.prefix(36))
            default: break
            }
        }
        if meta.name.isEmpty {
            meta.name = "user_api_\(Int(Date().timeIntervalSince1970))"
        }
        return meta
    }
}

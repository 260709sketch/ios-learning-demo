import Foundation
import JavaScriptCore
import CryptoKit
import Security
#if canImport(CommonCrypto)
import CommonCrypto
#endif

// MARK: - 音源信息模型

/// 一条已导入的自定义音源（LX Music 音源脚本）。
struct LXSourceInfo: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var sourceDescription: String
    var version: String
    var author: String
    var homepage: String
    var importDate: Date
    /// 音源测试结果（不持久化，运行时刷新）。
    var testStatus: TestStatus? = nil
    /// 各平台测试结果（wy=网易云，tx=QQ音乐），nil=未测试
    var platformTestResults: [String: Bool] = [:]

    enum TestStatus: String, Codable {
        case untested
        case testing
        case working
        case failed
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case sourceDescription = "description"
        case version, author, homepage, importDate
    }
}

/// 音源初始化后声明的能力（支持哪些平台/操作/音质）。
struct LXSourceCapability: Hashable {
    let platform: String
    let name: String
    let actions: [String]
    let qualities: [String]
}

// MARK: - 错误

enum LXEngineError: LocalizedError {
    case notLoaded
    case initFailed(String)
    case requestFailed(String)
    case timeout
    case invalidResponse
    case unsupported

    var errorDescription: String? {
        switch self {
        case .notLoaded: return "音源未加载"
        case .initFailed(let m): return "音源初始化失败：\(m)"
        case .requestFailed(let m): return "音源请求失败：\(m)"
        case .timeout: return "音源请求超时"
        case .invalidResponse: return "音源返回无效"
        case .unsupported: return "音源不支持该操作"
        }
    }
}

// MARK: - 引擎

/// 基于 JavaScriptCore 的 LX Music 音源引擎。
/// 架构与官方 lx-music-mobile 一致：
/// 1. 创建 JSContext，注入原生函数（__lx_native_call__ 等）
/// 2. evaluate(preload.js)
/// 3. 调用 lx_setup(...)
/// 4. 在全局作用域 evaluate(音源脚本)
final class LXMusicEngine: NSObject {
    static let shared = LXMusicEngine()

    private var context: JSContext?
    private let jsQueue = DispatchQueue(label: "im.missuo.kumone.lxmusic")

    /// 每次音源环境的校验 key。
    private var currentKey = UUID().uuidString
    /// 当前已加载音源。
    private(set) var currentSource: LXSourceInfo?
    /// 当前音源能力。
    private(set) var capabilities: [LXSourceCapability] = []

    // init 续体与超时
    private var initContinuation: CheckedContinuation<[LXSourceCapability], Error>?
    private var initTimeoutWork: DispatchWorkItem?

    // musicUrl/lyric/pic 请求续体（requestKey 以 "request__" 开头）
    private var pendingRequests: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var requestTimeoutWorks: [String: DispatchWorkItem] = [:]

    // HTTP 任务（requestKey 以 "script_request_" 开头）
    private var httpTasks: [String: URLSessionDataTask] = [:]
    // JS setTimeout
    private var timeoutTasks: [Int: DispatchWorkItem] = [:]

    private override init() {
        super.init()
    }

    // MARK: - 加载音源

    /// 加载并初始化一条音源脚本。返回该音源声明的能力。
    func load(source: LXSourceInfo, script: String) async throws -> [LXSourceCapability] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[LXSourceCapability], Error>) in
            jsQueue.async {
                self.cleanupLocked()
                // 关键：必须在 createJSEnv 之前设置 initContinuation，
                // 因为音源脚本在 evaluateScript 时会同步触发 init 事件，
                // 此时 handleInit 需要 resume continuation，设置晚了会导致 init 丢失、15秒超时
                self.initContinuation = cont
                self.createJSEnv(source: source, script: script)

                // init 超时
                let work = DispatchWorkItem { [weak self] in
                    guard let self, let c = self.initContinuation else { return }
                    self.initContinuation = nil
                    self.initTimeoutWork = nil
                    c.resume(throwing: LXEngineError.timeout)
                }
                self.initTimeoutWork = work
                self.jsQueue.asyncAfter(deadline: .now() + 15, execute: work)
            }
        }
    }

    /// 卸载音源。
    func unload() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            jsQueue.async {
                self.cleanupLocked()
                cont.resume()
            }
        }
    }

    // MARK: - 创建 JS 环境（匹配官方 QuickJS.createJSEnv）

    private func createJSEnv(source: LXSourceInfo, script: String) {
        currentKey = UUID().uuidString
        currentSource = source
        capabilities = []

        guard let ctx = JSContext() else {
            failInit(LXEngineError.initFailed("JSContext 创建失败"))
            return
        }
        ctx.name = "KumoneLXMusic"
        ctx.exceptionHandler = { _, exception in
            print("[LXMusic][JS Exception] \(exception?.toString() ?? "unknown")")
        }

        injectNativeFunctions(into: ctx)

        // evaluate preload.js
        guard let preloadURL = Bundle.module.url(forResource: "LXMusicPreload", withExtension: "js"),
              let preload = try? String(contentsOf: preloadURL, encoding: .utf8) else {
            print("[LXMusic] preload.js not found in Bundle.module")
            failInit(LXEngineError.initFailed("preload.js 缺失"))
            return
        }
        ctx.evaluateScript(preload)

        // 调用 lx_setup(key, id, name, description, version, author, homepage, rawScript)
        guard let lxSetup = ctx.objectForKeyedSubscript("lx_setup") else {
            failInit(LXEngineError.initFailed("lx_setup 不存在"))
            return
        }
        lxSetup.call(withArguments: [
            currentKey, source.id, source.name, source.sourceDescription,
            source.version, source.author, source.homepage, script
        ])

        // 在全局作用域执行音源脚本（关键：不用 new Function 包裹）
        ctx.evaluateScript(script)

        context = ctx
    }

    /// 注入官方 preload 期望的全部原生函数。
    private func injectNativeFunctions(into ctx: JSContext) {
        // __lx_native_call__(key, action, dataJsonString) —— 主通信
        let nativeCall: @convention(block) (String, String, String) -> Any? = { [weak self] key, action, data in
            guard let self, key == self.currentKey else { return nil }
            self.handleNativeCall(action: action, dataJSON: data)
            return nil
        }
        ctx.setObject(nativeCall, forKeyedSubscript: "__lx_native_call__" as NSString)

        // set_timeout(id, timeoutMS)
        let setTimeout: @convention(block) (Int, Int) -> Any? = { [weak self] id, ms in
            self?.scheduleJSTimeout(id: id, ms: ms)
            return nil
        }
        ctx.setObject(setTimeout, forKeyedSubscript: "__lx_native_call__set_timeout" as NSString)

        // utils_str2b64(str) -> base64
        let str2b64: @convention(block) (String) -> String = { str in
            Data(str.utf8).base64EncodedString()
        }
        ctx.setObject(str2b64, forKeyedSubscript: "__lx_native_call__utils_str2b64" as NSString)

        // utils_b642buf(b64) -> 字节数组 JSON 字符串 "[1,2,3]"
        let b642buf: @convention(block) (String) -> String = { b64 in
            guard let data = Data(base64Encoded: b64) else { return "[]" }
            let arr = Array(data).map(String.init).joined(separator: ",")
            return "[\(arr)]"
        }
        ctx.setObject(b642buf, forKeyedSubscript: "__lx_native_call__utils_b642buf" as NSString)

        // utils_str2md5(encodeURIComponent(str)) -> md5 hex（先 URL decode）
        let str2md5: @convention(block) (String) -> String = { encoded in
            let decoded = encoded.removingPercentEncoding ?? encoded
            return Crypto.md5(decoded)
        }
        ctx.setObject(str2md5, forKeyedSubscript: "__lx_native_call__utils_str2md5" as NSString)

        // utils_aes_encrypt(data_b64, key_b64, iv_b64, mode) -> base64
        let aesEncrypt: @convention(block) (String, String, String, String) -> String = { dataB64, keyB64, ivB64, mode in
            guard let data = Data(base64Encoded: dataB64),
                  let key = Data(base64Encoded: keyB64) else { return "" }
            if mode == "AES" {
                // ECB NoPadding
                return Crypto.aesECBNoPaddingEncrypt(data: data, key: key)?.base64EncodedString() ?? ""
            } else {
                // CBC PKCS7Padding
                let iv = Data(base64Encoded: ivB64) ?? Data()
                return Crypto.aesCBCEncrypt(data: data, key: key, iv: iv)?.base64EncodedString() ?? ""
            }
        }
        ctx.setObject(aesEncrypt, forKeyedSubscript: "__lx_native_call__utils_aes_encrypt" as NSString)

        // utils_rsa_encrypt(data_b64, keyBase64, mode) -> base64（RSA/ECB/NoPadding）
        let rsaEncrypt: @convention(block) (String, String, String) -> String = { dataB64, keyB64, _ in
            guard let data = Data(base64Encoded: dataB64) else { return "" }
            return Crypto.rsaRawEncrypt(data: data, publicKeyBase64: keyB64)?.base64EncodedString() ?? ""
        }
        ctx.setObject(rsaEncrypt, forKeyedSubscript: "__lx_native_call__utils_rsa_encrypt" as NSString)
    }

    // MARK: - JS -> Swift 分发

    private func handleNativeCall(action: String, dataJSON: String) {
        guard let data = dataJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        switch action {
        case "init":
            handleInit(dict)
        case "response":
            // musicUrl/lyric/pic 的结果（requestKey = request__）
            handleAPIResponse(dict)
        case "request":
            // 音源脚本发起的 HTTP 请求（requestKey = script_request_）
            handleHTTPRequest(dict)
        case "cancelRequest":
            handleCancelHTTP(dict)
        case "showUpdateAlert":
            // 已移除更新提示，忽略
            break
        default:
            break
        }
    }

    /// 音源初始化结果。
    private func handleInit(_ dict: [String: Any]) {
        initTimeoutWork?.cancel()
        initTimeoutWork = nil

        guard let status = dict["status"] as? Bool, status,
              let info = dict["info"] as? [String: Any],
              let sources = info["sources"] as? [String: Any] else {
            let msg = dict["errorMessage"] as? String ?? "初始化失败"
            failInit(LXEngineError.initFailed(msg))
            return
        }

        var caps: [LXSourceCapability] = []
        for (platform, value) in sources {
            guard let s = value as? [String: Any] else { continue }
            caps.append(LXSourceCapability(
                platform: platform,
                name: platform,
                actions: (s["actions"] as? [String]) ?? [],
                qualities: (s["qualitys"] as? [String]) ?? []
            ))
        }
        capabilities = caps
        if let cont = initContinuation {
            initContinuation = nil
            cont.resume(returning: caps)
        }
    }

    private func failInit(_ error: Error) {
        initTimeoutWork?.cancel()
        initTimeoutWork = nil
        if let cont = initContinuation {
            initContinuation = nil
            cont.resume(throwing: error)
        }
    }

    /// musicUrl/lyric/pic 请求的结果（JS 回调）。
    private func handleAPIResponse(_ dict: [String: Any]) {
        guard let key = dict["requestKey"] as? String else { return }
        requestTimeoutWorks[key]?.cancel()
        requestTimeoutWorks[key] = nil
        guard let cont = pendingRequests[key] else { return }
        pendingRequests[key] = nil

        if let status = dict["status"] as? Bool, status {
            cont.resume(returning: dict["result"] as? [String: Any] ?? [:])
        } else {
            let msg = (dict["error"] as? String)
                ?? (dict["errorMessage"] as? String) ?? "failed"
            cont.resume(throwing: LXEngineError.requestFailed(msg))
        }
    }

    // MARK: - Swift -> JS 请求（musicUrl 等）

    /// 获取播放 URL。
    /// - Parameters:
    ///   - track: 歌曲（网易云）
    ///   - quality: LX 音质标识（128k/320k/flac/flac24bit）
    func musicURL(for track: Track, quality: String) async throws -> (url: String, quality: String) {
        let musicInfo = lxMusicInfo(from: track)
        let source = track.sourcePlatform ?? "wy"
        let payload: [String: Any] = [
            "requestKey": "",
            "data": [
                "source": source,
                "action": "musicUrl",
                "info": ["type": quality, "musicInfo": musicInfo]
            ]
        ]
        let result = try await sendJSRequest(payload: payload, timeout: 20)
        guard let data = result["data"] as? [String: Any],
              let url = data["url"] as? String else {
            throw LXEngineError.invalidResponse
        }
        let actualQuality = (data["type"] as? String) ?? quality
        return (url, actualQuality)
    }

    /// 测试音源是否能真正获取播放链接（用固定测试歌曲实际请求 musicUrl）
    /// - Parameter platform: 测试平台，"wy"=网易云，"tx"=QQ音乐
    func testMusicURL(platform: String = "wy") async -> Bool {
        // 不同平台用不同的测试歌曲信息
        let testInfo: [String: Any]
        if platform == "tx" {
            // QQ音乐测试歌曲：晴天（周杰伦）
            testInfo = [
                "name": "晴天",
                "singer": "周杰伦",
                "source": "tx",
                "songmid": "001fXNtB2b58tO",
                "interval": "04:29",
                "albumName": "叶惠美",
                "img": "",
                "typeUrl": [:] as [String: String],
                "albumId": 0,
                "types": [["type": "128k", "size": ""]],
                "_types": ["128k": ["size": ""]],
                "id": "001fXNtB2b58tO",
                "songId": "001fXNtB2b58tO",
                "pic": "",
                "album": "叶惠美",
                "hash": "",
                "rid": ""
            ]
        } else {
            // 网易云测试歌曲：thank u, next
            testInfo = [
                "name": "thank u, next",
                "singer": "Ariana Grande",
                "source": "wy",
                "songmid": "1330348068",
                "interval": "03:27",
                "albumName": "thank u, next",
                "img": "",
                "typeUrl": [:] as [String: String],
                "albumId": 0,
                "types": [["type": "128k", "size": ""]],
                "_types": ["128k": ["size": ""]],
                "id": "1330348068",
                "songId": "1330348068",
                "pic": "",
                "album": "thank u, next",
                "hash": "",
                "rid": ""
            ]
        }
        let payload: [String: Any] = [
            "requestKey": "",
            "data": [
                "source": platform,
                "action": "musicUrl",
                "info": ["type": "128k", "musicInfo": testInfo]
            ]
        ]
        do {
            let result = try await sendJSRequest(payload: payload, timeout: 15)
            guard let data = result["data"] as? [String: Any],
                  let url = data["url"] as? String,
                  !url.isEmpty else {
                return false
            }
            return true
        } catch {
            return false
        }
    }

    private func sendJSRequest(payload: [String: Any], timeout seconds: TimeInterval) async throws -> [String: Any] {
        let requestKey = "request__\(UUID().uuidString)"
        var payload = payload
        payload["requestKey"] = requestKey

        return try await withCheckedThrowingContinuation { cont in
            jsQueue.async {
                self.pendingRequests[requestKey] = cont
                guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
                      let json = String(data: jsonData, encoding: .utf8) else {
                    self.pendingRequests[requestKey] = nil
                    cont.resume(throwing: LXEngineError.invalidResponse)
                    return
                }
                self.callJSNative(action: "request", json: json)

                let work = DispatchWorkItem { [weak self] in
                    guard let self, let c = self.pendingRequests[requestKey] else { return }
                    self.pendingRequests[requestKey] = nil
                    self.requestTimeoutWorks[requestKey] = nil
                    c.resume(throwing: LXEngineError.timeout)
                }
                self.requestTimeoutWorks[requestKey] = work
                self.jsQueue.asyncAfter(deadline: .now() + seconds, execute: work)
            }
        }
    }

    /// 调用 preload 暴露的 __lx_native__(key, action, json)。
    private func callJSNative(action: String, json: String) {
        guard let fn = context?.objectForKeyedSubscript("__lx_native__") else { return }
        fn.call(withArguments: [currentKey, action, json])
    }

    // MARK: - JS setTimeout

    private func scheduleJSTimeout(id: Int, ms: Int) {
        let work = DispatchWorkItem { [weak self] in
            self?.timeoutTasks[id] = nil
            guard let fn = self?.context?.objectForKeyedSubscript("__lx_native__"),
                  let key = self?.currentKey else { return }
            fn.call(withArguments: [key, "__set_timeout__", String(id)])
        }
        timeoutTasks[id] = work
        jsQueue.asyncAfter(deadline: .now() + .milliseconds(max(ms, 0)), execute: work)
    }

    // MARK: - HTTP 请求（音源脚本内部 lx.request）

    private func handleHTTPRequest(_ dict: [String: Any]) {
        guard let key = dict["requestKey"] as? String,
              let urlString = dict["url"] as? String,
              let options = dict["options"] as? [String: Any] else { return }

        guard let url = URL(string: urlString) else {
            deliverHTTPResponse(key: key, error: "Invalid URL", response: nil)
            return
        }

        var request = URLRequest(url: url)
        let method = ((options["method"] as? String) ?? "get").uppercased()
        request.httpMethod = method

        if let headers = options["headers"] as? [String: Any] {
            for (k, v) in headers { request.setValue("\(v)", forHTTPHeaderField: k) }
        }
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36",
                forHTTPHeaderField: "User-Agent"
            )
        }

        let binary = (options["binary"] as? Bool) ?? false
        let timeoutMS = (options["timeout"] as? NSNumber)?.doubleValue ?? 15000
        request.timeoutInterval = max(timeoutMS, 1000) / 1000

        if ["POST", "PUT", "PATCH"].contains(method) {
            applyBody(to: &request, options: options)
        }

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            self?.jsQueue.async {
                if let error = error {
                    self?.deliverHTTPResponse(key: key, error: error.localizedDescription, response: nil)
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    self?.deliverHTTPResponse(key: key, error: "Invalid response", response: nil)
                    return
                }
                var headers: [String: String] = [:]
                for (k, v) in http.allHeaderFields {
                    headers["\(k)".lowercased()] = "\(v)"
                }
                let payload = data ?? Data()
                let body: Any
                if binary {
                    body = Array(payload)
                } else if let json = try? JSONSerialization.jsonObject(with: payload) {
                    body = json
                } else {
                    body = String(data: payload, encoding: .utf8) ?? ""
                }
                let resp: [String: Any] = [
                    "statusCode": http.statusCode,
                    "statusMessage": "",
                    "headers": headers,
                    "body": body
                ]
                self?.deliverHTTPResponse(key: key, error: nil, response: resp)
            }
        }
        httpTasks[key] = task
        task.resume()
    }

    private func handleCancelHTTP(_ dict: [String: Any]) {
        guard let key = dict["requestKey"] as? String else { return }
        httpTasks[key]?.cancel()
        httpTasks.removeValue(forKey: key)
    }

    private func deliverHTTPResponse(key: String, error: String?, response: [String: Any]?) {
        httpTasks.removeValue(forKey: key)
        let payload: [String: Any] = [
            "requestKey": key,
            "error": error ?? NSNull(),
            "response": response ?? NSNull()
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: jsonData, encoding: .utf8) else { return }
        callJSNative(action: "response", json: json)
    }

    // MARK: - 请求体

    private func applyBody(to request: inout URLRequest, options: [String: Any]) {
        // form
        if let form = options["form"] as? [String: Any], !form.isEmpty {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var parts: [String] = []
            for (k, v) in form {
                let ek = k.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? k
                let ev = "\(v)".addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "\(v)"
                parts.append("\(ek)=\(ev)")
            }
            request.httpBody = parts.joined(separator: "&").data(using: .utf8)
            return
        }
        let body = options["body"]
        if let s = body as? String {
            request.httpBody = s.data(using: .utf8)
        } else if let obj = body, !(body is NSNull) {
            let ct = request.value(forHTTPHeaderField: "Content-Type") ?? ""
            if ct.contains("application/x-www-form-urlencoded") {
                if let dict = obj as? [String: Any] {
                    var parts: [String] = []
                    for (k, v) in dict {
                        let ek = k.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? k
                        let ev = "\(v)".addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "\(v)"
                        parts.append("\(ek)=\(ev)")
                    }
                    request.httpBody = parts.joined(separator: "&").data(using: .utf8)
                }
            } else if JSONSerialization.isValidJSONObject(obj),
                      let data = try? JSONSerialization.data(withJSONObject: obj) {
                if !ct.contains("application/json") {
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }
                request.httpBody = data
            }
        }
    }

    // MARK: Track -> LX MusicInfo

    func lxQuality(from quality: AudioQuality) -> String {
        switch quality {
        case .standard, .higher: return "128k"
        case .exhigh: return "320k"
        case .lossless: return "flac"
        case .hires: return "flac24bit"
        }
    }

    private func lxMusicInfo(from track: Track) -> [String: Any] {
        // 根据来源平台选择正确的 source 和 songmid
        let source = track.sourcePlatform ?? "wy"
        let songmid = track.platformSongId ?? String(track.id)
        let pic = track.album.picUrl ?? ""
        // LX 音源标准：多歌手用"、"分隔
        let singer = track.artists.map { $0.name }.joined(separator: "、")
        // 官方 LX Mobile toOldMusicInfo() 标准格式：interval 为 mm:ss
        let durationSec = Int(track.duration)
        let interval = String(format: "%02d:%02d", durationSec / 60, durationSec % 60)
        // 标准音质列表（官方格式 types / _types）
        let qualityInfo: [[String: Any]] = [
            ["type": "128k", "size": ""],
            ["type": "320k", "size": ""],
            ["type": "flac", "size": ""]
        ]
        let qualityMap: [String: [String: String]] = [
            "128k": ["size": ""],
            "320k": ["size": ""],
            "flac": ["size": ""]
        ]
        var info: [String: Any] = [
            // 官方 LX Mobile 标准字段
            "name": track.name,
            "singer": singer,
            "source": source,
            "songmid": songmid,
            "interval": interval,
            "albumName": track.album.name,
            "img": pic,
            "typeUrl": [:] as [String: String],
            "albumId": track.album.id,
            "types": qualityInfo,
            "_types": qualityMap,
            // 兼容字段：部分音源使用这些名称
            "id": songmid,
            "songId": songmid,
            "strMediaMid": songmid,
            "pic": pic,
            "album": track.album.name,
            "hash": "",
            "rid": "",
            // meta 保留旧格式兼容
            "meta": [
                "songId": songmid,
                "songmid": songmid,
                "albumId": track.album.id,
                "albumName": track.album.name,
                "picUrl": pic,
                "img": pic,
                "fee": track.fee,
                "qualitys": qualityInfo,
                "_qualitys": qualityMap
            ]
        ]
        return info
    }

    // MARK: - 清理

    private func cleanupLocked() {
        for (_, t) in httpTasks { t.cancel() }
        httpTasks.removeAll()
        for (_, w) in timeoutTasks { w.cancel() }
        timeoutTasks.removeAll()
        for (_, w) in requestTimeoutWorks { w.cancel() }
        requestTimeoutWorks.removeAll()
        initTimeoutWork?.cancel()
        initTimeoutWork = nil

        initContinuation?.resume(throwing: LXEngineError.notLoaded)
        initContinuation = nil
        for (_, cont) in pendingRequests {
            cont.resume(throwing: LXEngineError.notLoaded)
        }
        pendingRequests.removeAll()

        context = nil
        currentSource = nil
        capabilities = []
    }
}

// MARK: - 加密工具

enum Crypto {
    static func md5(_ string: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func aesCBCEncrypt(data: Data, key: Data, iv: Data) -> Data? {
        crypt(operation: CCOperation(kCCEncrypt), algorithm: CCAlgorithm(kCCAlgorithmAES),
              options: CCOptions(kCCOptionPKCS7Padding), key: key, iv: iv, data: data)
    }

    static func aesECBNoPaddingEncrypt(data: Data, key: Data) -> Data? {
        crypt(operation: CCOperation(kCCEncrypt), algorithm: CCAlgorithm(kCCAlgorithmAES),
              options: CCOptions(kCCOptionECBMode), key: key, iv: Data(), data: data)
    }

    private static func crypt(
        operation: CCOperation, algorithm: CCAlgorithm, options: CCOptions,
        key: Data, iv: Data, data: Data
    ) -> Data? {
        let bufferSize = data.count + kCCBlockSizeAES128
        var buffer = Data(count: bufferSize)
        var numBytes = 0
        let status = buffer.withUnsafeMutableBytes { bufferRaw -> CCCryptorStatus in
            data.withUnsafeBytes { dataRaw in
                key.withUnsafeBytes { keyRaw in
                    iv.withUnsafeBytes { ivRaw in
                        CCCrypt(
                            operation, algorithm, options,
                            keyRaw.baseAddress, key.count,
                            ivRaw.baseAddress,
                            dataRaw.baseAddress, data.count,
                            bufferRaw.baseAddress, bufferSize, &numBytes
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        buffer.count = numBytes
        return buffer
    }

    static func rsaRawEncrypt(data: Data, publicKeyBase64: String) -> Data? {
        guard let keyData = Data(base64Encoded: publicKeyBase64) else { return nil }
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic
        ]
        var secKey: SecKey?
        if let k = SecKeyCreateWithData(keyData as CFData, attrs as CFDictionary, nil) {
            secKey = k
        } else if let pkcs1 = extractPKCS1(from: keyData),
                  let k = SecKeyCreateWithData(pkcs1 as CFData, attrs as CFDictionary, nil) {
            secKey = k
        }
        guard let key = secKey else { return nil }

        // RSA/ECB/NoPadding 要求输入长度等于密钥块大小，不足时在前面补零（与官方 lx-music 一致）
        let blockSize = SecKeyGetBlockSize(key)
        guard data.count <= blockSize else { return nil }
        var padded = Data(count: blockSize)
        if data.count > 0 {
            padded.replaceSubrange((blockSize - data.count)..<blockSize, with: data)
        }

        var error: Unmanaged<CFError>?
        guard let encrypted = SecKeyCreateEncryptedData(
            key, SecKeyAlgorithm.rsaEncryptionRaw, padded as CFData, &error
        ) else { return nil }
        return encrypted as Data
    }

    /// 从 X.509 SubjectPublicKeyInfo 中提取 PKCS#1 RSAPublicKey。
    private static func extractPKCS1(from spki: Data) -> Data? {
        let bytes = [UInt8](spki)
        func parse(_ offset: Int) -> (contentStart: Int, contentEnd: Int, next: Int)? {
            var o = offset
            guard o < bytes.count else { return nil }
            o += 1 // tag
            var len = Int(bytes[o]); o += 1
            if len & 0x80 != 0 {
                let n = len & 0x7f
                len = 0
                for _ in 0..<n { len = (len << 8) | Int(bytes[o]); o += 1 }
            }
            return (o, o + len, o + len)
        }
        guard let outer = parse(0),
              let alg = parse(outer.contentStart),
              let bitString = parse(alg.next) else { return nil }
        // BIT STRING 第一个字节是 unused bits 数
        let start = bitString.contentStart + 1
        guard start < bitString.contentEnd else { return nil }
        return Data(bytes[start..<bitString.contentEnd])
    }
}

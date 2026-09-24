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
    var testStatus: TestStatus?

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
/// 加载并执行 LX 音源脚本，桥接网络请求、加密、定时器。
final class LXMusicEngine: NSObject {
    static let shared = LXMusicEngine()

    private var context: JSContext!
    private let jsQueue = DispatchQueue(label: "im.missuo.kumone.lxmusic")
    private var didSetup = false

    /// 当前已加载音源。
    private(set) var currentSource: LXSourceInfo?
    /// 当前音源能力。
    private(set) var capabilities: [LXSourceCapability] = []

    // 续体
    private var initContinuation: CheckedContinuation<[LXSourceCapability], Error>?
    private var pendingAPIRequests: [String: CheckedContinuation<[String: Any], Error>] = [:]

    // HTTP 任务与定时器
    private var httpTasks: [String: URLSessionDataTask] = [:]
    private var timerItems: [Int: DispatchWorkItem] = [:]   // Swift 内部超时
    private var jsTimerItems: [Int: DispatchWorkItem] = [:] // JS setTimeout
    private var timerSeq = 1

    private override init() {
        super.init()
    }

    // MARK: 初始化 JSContext

    private func ensureSetup() {
        guard !didSetup else { return }
        didSetup = true

        let ctx = JSContext()
        ctx.name = "KumoneLXMusic"
        ctx.exceptionHandler = { _, exception in
            let msg = exception?.toString() ?? "unknown"
            print("[LXMusic][JS Exception] \(msg)")
        }

        // 注入统一桥接
        let nativeBlock: @convention(block) (String, Any?) -> Any? = { [weak self] action, data in
            self?.handleNative(action: action, data: data)
        }
        ctx.setObject(nativeBlock, forKeyedSubscript: "__lx_native" as NSString)

        // 加载 preload
        guard let url = Bundle.module.url(forResource: "LXMusicPreload", withExtension: "js"),
              let preload = try? String(contentsOf: url, encoding: .utf8) else {
            print("[LXMusic] preload.js not found in Bundle.module")
            return
        }
        ctx.evaluateScript(preload)
        context = ctx
    }

    /// 确保引擎已就绪（异步）。
    private func setupIfNeeded() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            jsQueue.async {
                self.ensureSetup()
                cont.resume()
            }
        }
    }

    // MARK: 加载音源

    /// 加载并初始化一条音源脚本。返回该音源声明的能力。
    func load(source: LXSourceInfo, script: String) async throws -> [LXSourceCapability] {
        await setupIfNeeded()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[LXSourceCapability], Error>) in
            jsQueue.async {
                self.ensureSetup()
                guard self.context != nil else {
                    cont.resume(throwing: LXEngineError.initFailed("引擎初始化失败"))
                    return
                }
                self.initContinuation = cont
                self.currentSource = source
                self.capabilities = []

                let scriptInfo: [String: Any] = [
                    "id": source.id,
                    "name": source.name,
                    "description": source.sourceDescription,
                    "version": source.version,
                    "author": source.author,
                    "homepage": source.homepage,
                    "script": script
                ]
                self.callJS("__lx_load", with: [scriptInfo])

                // 初始化超时
                let work = DispatchWorkItem { [weak self] in
                    guard let self, let c = self.initContinuation else { return }
                    self.initContinuation = nil
                    c.resume(throwing: LXEngineError.timeout)
                }
                self.jsQueue.asyncAfter(deadline: .now() + 15, execute: work)
                self.timerItems[self.timerSeq] = work
                self.timerSeq += 1
            }
        }
    }

    /// 卸载音源。
    func unload() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            jsQueue.async {
                self.callJS("__lx_destroy", with: [])
                self.currentSource = nil
                self.capabilities = []
                for (_, task) in self.httpTasks { task.cancel() }
                self.httpTasks.removeAll()
                for (_, item) in self.timerItems { item.cancel() }
                self.timerItems.removeAll()
                for (_, item) in self.jsTimerItems { item.cancel() }
                self.jsTimerItems.removeAll()
                cont.resume()
            }
        }
    }

    // MARK: 音源查询

    /// 获取播放 URL。
    /// - Parameters:
    ///   - track: 歌曲（网易云）
    ///   - quality: LX 音质标识（128k/320k/flac/flac24bit）
    func musicURL(for track: Track, quality: String) async throws -> (url: String, quality: String) {
        let musicInfo = lxMusicInfo(from: track)
        let params: [String: Any] = [
            "source": "wy",
            "action": "musicUrl",
            "info": ["type": quality, "musicInfo": musicInfo]
        ]
        let result = try await startAPIRequest(params: params, timeout: 20)
        guard let data = result["data"] as? [String: Any],
              let url = data["url"] as? String else {
            throw LXEngineError.invalidResponse
        }
        let actualQuality = (data["type"] as? String) ?? quality
        return (url, actualQuality)
    }

    /// 获取歌词。
    func lyric(for track: Track) async throws -> [String: Any] {
        let musicInfo = lxMusicInfo(from: track)
        let params: [String: Any] = [
            "source": "wy",
            "action": "lyric",
            "info": ["type": "320k", "musicInfo": musicInfo]
        ]
        let result = try await startAPIRequest(params: params, timeout: 15)
        guard let data = result["data"] as? [String: Any] else {
            throw LXEngineError.invalidResponse
        }
        return data
    }

    /// 获取封面 URL。
    func pic(for track: Track) async throws -> String {
        let musicInfo = lxMusicInfo(from: track)
        let params: [String: Any] = [
            "source": "wy",
            "action": "pic",
            "info": ["type": "320k", "musicInfo": musicInfo]
        ]
        let result = try await startAPIRequest(params: params, timeout: 15)
        guard let data = result["data"] as? String else {
            throw LXEngineError.invalidResponse
        }
        return data
    }

    /// 统一发起音源请求并等待结果。
    private func startAPIRequest(params: [String: Any], timeout seconds: TimeInterval) async throws -> [String: Any] {
        let key = "api_\(UUID().uuidString)"
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: Any], Error>) in
            jsQueue.async {
                self.pendingAPIRequests[key] = cont
                self.callJS("__lx_start_api_request", with: [key, params])

                let work = DispatchWorkItem { [weak self] in
                    self?.failAPIRequest(key: key, error: LXEngineError.timeout)
                }
                self.jsQueue.asyncAfter(deadline: .now() + seconds, execute: work)
                self.timerItems[self.timerSeq] = work
                self.timerSeq += 1
            }
        }
    }

    private func succeedAPIRequest(key: String, result: [String: Any]) {
        guard let cont = pendingAPIRequests[key] else { return }
        pendingAPIRequests.removeValue(forKey: key)
        cont.resume(returning: result)
    }

    private func failAPIRequest(key: String, error: Error) {
        guard let cont = pendingAPIRequests[key] else { return }
        pendingAPIRequests.removeValue(forKey: key)
        cont.resume(throwing: error)
    }

    // MARK: JS 调用

    private func callJS(_ function: String, with args: [Any]) {
        guard let fn = context.objectForKeyedSubscript(function) else { return }
        fn.call(withArguments: args)
    }

    // MARK: 原生桥接处理（在 jsQueue 上执行）

    private func handleNative(action: String, data: Any?) -> Any? {
        switch action {
        case "inited":
            handleInited(data)
        case "requestResult":
            handleRequestResult(data)
        case "http":
            handleHTTP(data)
        case "cancelHttp":
            handleCancelHTTP(data)
        case "setTimeout":
            handleSetTimeout(data)
        case "log":
            handleLog(data)
        case "updateAlert":
            handleUpdateAlert(data)
        case "md5":
            guard let str = data as? String else { return nil }
            return Crypto.md5(str)
        case "aes":
            guard let dict = data as? [String: Any] else { return nil }
            return handleAES(dict)
        case "rsa":
            guard let dict = data as? [String: Any] else { return nil }
            return handleRSA(dict)
        default:
            return nil
        }
        return nil
    }

    private func handleInited(_ data: Any?) {
        guard let dict = data as? [String: Any],
              let status = dict["status"] as? Bool else {
            initContinuation?.resume(throwing: LXEngineError.initFailed("无效的初始化响应"))
            initContinuation = nil
            return
        }
        if status {
            var caps: [LXSourceCapability] = []
            if let info = dict["info"] as? [String: Any],
               let sources = info["sources"] as? [String: Any] {
                for (platform, value) in sources {
                    guard let s = value as? [String: Any] else { continue }
                    caps.append(LXSourceCapability(
                        platform: platform,
                        name: (s["name"] as? String) ?? platform,
                        actions: (s["actions"] as? [String]) ?? [],
                        qualities: (s["qualitys"] as? [String]) ?? []
                    ))
                }
            }
            capabilities = caps
            initContinuation?.resume(returning: caps)
        } else {
            let error = (dict["error"] as? String) ?? "未知错误"
            initContinuation?.resume(throwing: LXEngineError.initFailed(error))
        }
        initContinuation = nil
    }

    private func handleRequestResult(_ data: Any?) {
        guard let dict = data as? [String: Any],
              let key = dict["requestKey"] as? String else { return }
        if let status = dict["status"] as? Bool, status {
            if let result = dict["result"] as? [String: Any] {
                succeedAPIRequest(key: key, result: result)
            } else {
                failAPIRequest(key: key, error: LXEngineError.invalidResponse)
            }
        } else {
            let msg = (dict["error"] as? String) ?? "failed"
            failAPIRequest(key: key, error: LXEngineError.requestFailed(msg))
        }
    }

    private func handleLog(_ data: Any?) {
        guard let dict = data as? [String: Any],
              let type = dict["type"] as? String,
              let msg = dict["msg"] as? String else { return }
        print("[LXMusic][\(type)] \(msg)")
    }

    private func handleUpdateAlert(_ data: Any?) {
        guard let dict = data as? [String: Any] else { return }
        let log = dict["log"] as? String ?? ""
        print("[LXMusic][updateAlert] \(log)")
    }

    // MARK: 定时器桥接

    private func handleSetTimeout(_ data: Any?) {
        guard let dict = data as? [String: Any],
              let idNum = dict["id"] as? NSNumber,
              let timeout = dict["timeout"] as? NSNumber else { return }
        let id = idNum.intValue
        let work = DispatchWorkItem { [weak self] in
            self?.jsQueue.async {
                self?.callJS("__lx_fire_timer", with: [idNum])
            }
        }
        jsTimerItems[id] = work
        jsQueue.asyncAfter(deadline: .now() + .milliseconds(timeout.intValue), execute: work)
    }

    // MARK: HTTP 桥接

    private func handleHTTP(_ data: Any?) {
        guard let dict = data as? [String: Any],
              let key = dict["requestKey"] as? String,
              let urlString = dict["url"] as? String,
              let options = dict["options"] as? [String: Any] else { return }

        guard let url = URL(string: urlString) else {
            deliverHTTPError(key: key, message: "Invalid URL")
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
        let timeout = (options["timeout"] as? NSNumber)?.doubleValue ?? 15
        request.timeoutInterval = timeout / 1000

        // 请求体
        if method == "POST" || method == "PUT" || method == "PATCH" {
            applyBody(to: &request, options: options)
        }

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            self?.jsQueue.async {
                if let error = error {
                    self?.deliverHTTPError(key: key, message: error.localizedDescription)
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    self?.deliverHTTPError(key: key, message: "Invalid response")
                    return
                }
                var headers: [String: String] = [:]
                for (k, v) in http.allHeaderFields {
                    headers["\(k)".lowercased()] = "\(v)"
                }
                let payload = data ?? Data()

                if binary {
                    self?.deliverHTTP(
                        key: key,
                        statusCode: http.statusCode,
                        statusMessage: "",
                        headers: headers,
                        body: payload.base64EncodedString(),
                        bodyEncoding: "base64"
                    )
                } else {
                    // 尝试 JSON，否则字符串
                    if let json = try? JSONSerialization.jsonObject(with: payload) as Any {
                        self?.deliverHTTP(
                            key: key, statusCode: http.statusCode, statusMessage: "",
                            headers: headers, body: json, bodyEncoding: nil
                        )
                    } else {
                        let text = String(data: payload, encoding: .utf8) ?? ""
                        self?.deliverHTTP(
                            key: key, statusCode: http.statusCode, statusMessage: "",
                            headers: headers, body: text, bodyEncoding: nil
                        )
                    }
                }
            }
        }
        httpTasks[key] = task
        task.resume()
    }

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

    private func handleCancelHTTP(_ data: Any?) {
        guard let dict = data as? [String: Any], let key = dict["requestKey"] as? String else { return }
        httpTasks[key]?.cancel()
        httpTasks.removeValue(forKey: key)
    }

    private func deliverHTTP(
        key: String,
        statusCode: Int,
        statusMessage: String,
        headers: [String: String],
        body: Any,
        bodyEncoding: String?
    ) {
        httpTasks.removeValue(forKey: key)
        var response: [String: Any] = [
            "statusCode": statusCode,
            "statusMessage": statusMessage,
            "headers": headers,
            "body": body
        ]
        if let bodyEncoding = bodyEncoding { response["bodyEncoding"] = bodyEncoding }
        callJS("__lx_http_response", with: [["requestKey": key, "error": NSNull(), "response": response]])
    }

    private func deliverHTTPError(key: String, message: String) {
        httpTasks.removeValue(forKey: key)
        callJS("__lx_http_response", with: [["requestKey": key, "error": message, "response": NSNull()]])
    }

    // MARK: AES / RSA 桥接

    private func handleAES(_ dict: [String: Any]) -> String? {
        guard let b64data = dict["data"] as? String,
              let b64key = dict["key"] as? String,
              let mode = dict["mode"] as? String,
              let data = Data(base64Encoded: b64data),
              let key = Data(base64Encoded: b64key) else { return nil }
        let iv = (dict["iv"] as? String).flatMap { Data(base64Encoded: $0) }
        let result: Data?
        if mode == "aes-128-ecb" {
            result = Crypto.aesECBEncrypt(data: data, key: key)
        } else {
            result = Crypto.aesCBCEncrypt(data: data, key: key, iv: iv ?? Data())
        }
        return result?.base64EncodedString()
    }

    private func handleRSA(_ dict: [String: Any]) -> String? {
        guard let b64data = dict["data"] as? String,
              let keyB64 = dict["key"] as? String,
              let data = Data(base64Encoded: b64data) else { return nil }
        return Crypto.rsaRawEncrypt(data: data, publicKeyBase64: keyB64)?.base64EncodedString()
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
        let id = String(track.id)
        let pic = track.album.picUrl ?? ""
        return [
            "id": id,
            "name": track.name,
            "singer": track.artistNames,
            "source": "wy",
            "interval": String(Int(track.duration)),
            "albumId": track.album.id,
            "albumName": track.album.name,
            "pic": pic,
            "meta": [
                "songId": id,
                "songmid": id,
                "albumId": track.album.id,
                "albumName": track.album.name,
                "picUrl": pic,
                "fee": track.fee,
                "qualitys": [
                    ["type": "128k", "size": NSNull()],
                    ["type": "320k", "size": NSNull()],
                    ["type": "flac", "size": NSNull()]
                ],
                "_qualitys": [
                    "128k": ["size": NSNull()],
                    "320k": ["size": NSNull()],
                    "flac": ["size": NSNull()]
                ]
            ]
        ]
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

    static func aesECBEncrypt(data: Data, key: Data) -> Data? {
        crypt(operation: CCOperation(kCCEncrypt), algorithm: CCAlgorithm(kCCAlgorithmAES),
              options: CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding), key: key, iv: Data(), data: data)
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
        var error: Unmanaged<CFError>?
        guard let encrypted = SecKeyCreateEncryptedData(
            key, SecKeyAlgorithm.rsaEncryptionRaw, data as CFData, &error
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

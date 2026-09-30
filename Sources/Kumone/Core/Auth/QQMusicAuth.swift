import Foundation

enum QQLoginError: LocalizedError {
    case network
    case unknown(String)
    var errorDescription: String? {
        switch self {
        case .network: return "网络错误"
        case .unknown(let msg): return msg
        }
    }
}

final class QQMusicAuth: ObservableObject {
    static let shared = QQMusicAuth()

    @Published private(set) var isLoggedIn = false
    @Published private(set) var nickname = ""
    @Published private(set) var vipBadge: String?

    private var cookies: [String: String] = [:]
    private var qrsig = ""

    private let defaults = UserDefaults.standard
    private let cookieKey = "wellmusic.qqmusic.cookie.v1"
    private let nickKey = "wellmusic.qqmusic.nickname.v1"
    private let vipKey = "wellmusic.qqmusic.vip.v1"
    private let session: URLSession
    private let redirectBlocker = NoRedirectDelegate()

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        session = URLSession(configuration: config, delegate: redirectBlocker, delegateQueue: nil)
        if let saved = defaults.dictionary(forKey: cookieKey) as? [String: String], !saved.isEmpty {
            cookies = saved
            let savedNickname = defaults.string(forKey: nickKey) ?? ""
            let savedVIPBadge = defaults.string(forKey: vipKey)
            updatePublishedState {
                self.isLoggedIn = true
                self.nickname = savedNickname
                self.vipBadge = savedVIPBadge
            }
        }
    }

    var uin: String {
        Self.normalizedUIN(Self.accountID(from: cookies))
    }

    var rawUin: String {
        Self.accountID(from: cookies)
    }

    var isWeChatLogin: Bool {
        Self.hasUsableAccountID(cookies["wxuin"]) || !(cookies["wxopenid"] ?? "").isEmpty
    }

    var playlistUin: String {
        if isWeChatLogin,
           !Self.hasUsableAccountID(cookies["p_uin"]),
           !Self.hasUsableAccountID(cookies["pt2gguin"]) {
            return Self.normalizedUIN(cookies["wxuin"] ?? "0")
        }
        for key in ["uin", "p_uin", "pt2gguin"] {
            guard let value = cookies[key],
                  Self.hasUsableAccountID(value) else { continue }
            return Self.normalizedUIN(value)
        }
        return "0"
    }

    var gtk: Int {
        let key = cookies["qqmusic_key"]
            ?? cookies["qm_keyst"]
            ?? cookies["wxskey"]
            ?? cookies["p_skey"]
            ?? cookies["skey"]
            ?? ""
        return key.isEmpty ? 5381 : Self.hash5381(key)
    }

    var loginKey: String {
        cookies["qm_keyst"] ?? cookies["qqmusic_key"] ?? cookies["music_key"]
            ?? cookies["wxskey"] ?? cookies["musickey"] ?? cookies["p_skey"] ?? ""
    }

    var cookieHeader: String {
        makeCookieHeader(includeCompatibilityUIN: true)
    }

    var playlistCookieHeader: String {
        makeCookieHeader(includeCompatibilityUIN: false)
    }

    private func makeCookieHeader(includeCompatibilityUIN: Bool) -> String {
        let order = [
            "uin", "wxuin", "p_uin", "wxopenid",
            "qm_keyst", "qqmusic_key", "music_key", "wxskey", "wx_skey",
            "musickey", "p_skey", "skey", "pt4_token"
        ]
        var pairs: [String] = order.compactMap { key in
            guard let value = cookies[key], !value.isEmpty else { return nil }
            return "\(key)=\(value)"
        }
        if includeCompatibilityUIN,
           !Self.hasUsableAccountID(cookies["uin"]),
           let wxuin = cookies["wxuin"],
           !wxuin.isEmpty {
            pairs.insert("uin=\(wxuin)", at: 0)
        }
        return pairs.joined(separator: "; ")
    }

    func logout() {
        cookies = [:]
        qrsig = ""
        defaults.removeObject(forKey: cookieKey)
        defaults.removeObject(forKey: nickKey)
        defaults.removeObject(forKey: vipKey)
        updatePublishedState {
            self.isLoggedIn = false
            self.nickname = ""
            self.vipBadge = nil
        }
    }

    func importCookies(_ dict: [String: String], nickname: String?) {
        guard !dict.isEmpty else { return }
        cookies = dict
        let resolvedNickname = nickname ?? Self.fallbackNickname(dict)
        updatePublishedState {
            self.isLoggedIn = true
            self.nickname = resolvedNickname
        }
        defaults.set(cookies, forKey: cookieKey)
        defaults.set(resolvedNickname, forKey: nickKey)
        Task { await self.fetchVIPStatus() }
        Task { await self.fetchProfile() }
    }

    static let webCookieNames: Set<String> = [
        "uin", "wxuin", "p_uin", "wxopenid", "skey", "p_skey",
        "qqmusic_key", "qm_keyst", "music_key", "wxskey", "wx_skey",
        "musickey", "pt4_token", "pt2gguin", "pt_login_sig", "pt4_aid",
        "qmusic_s", "pgv_pvid", "pgv_info", "ptnick", "nick", "nickname",
    ]

    static func parseCookieHeader(_ header: String) -> [String: String] {
        var dict: [String: String] = [:]
        for part in header.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { continue }
            let key = kv[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = kv[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, !value.isEmpty {
                dict[key] = value
            }
        }
        return dict
    }

    static func fallbackNickname(_ dict: [String: String]) -> String {
        if let key = dict.keys.first(where: { $0.hasPrefix("ptnick") }),
           let raw = dict[key], !raw.isEmpty {
            return raw.removingPercentEncoding ?? raw
        }
        if let nick = dict["nick"], !nick.isEmpty { return nick }
        let clean = normalizedUIN(accountID(from: dict))
        return clean.isEmpty ? "QQ音乐用户" : "QQ音乐用户 \(clean)"
    }

    private static func accountID(from cookies: [String: String]) -> String {
        for key in ["uin", "wxuin", "pt2gguin"] {
            guard let value = cookies[key],
                  hasUsableAccountID(value) else { continue }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "0"
    }

    private static func hasUsableAccountID(_ raw: String?) -> Bool {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return false }
        return value != "0" && value != "o0"
    }

    private static func normalizedUIN(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        return value.hasPrefix("o") ? String(value.dropFirst()) : value
    }

    enum ScanState: Equatable {
        case waiting
        case scanned
        case success(String)
        case expired
        case error(String)
    }

    func fetchQRCode() async throws -> Data {
        qrsig = ""
        var comps = URLComponents(string: "https://ssl.ptlogin2.qq.com/ptqrshow")!
        comps.queryItems = [
            URLQueryItem(name: "appid", value: "716027609"),
            URLQueryItem(name: "e", value: "2"),
            URLQueryItem(name: "l", value: "M"),
            URLQueryItem(name: "s", value: "3"),
            URLQueryItem(name: "d", value: "72"),
            URLQueryItem(name: "v", value: "4"),
            URLQueryItem(name: "t", value: String(format: "%.6f", Double.random(in: 0...1))),
            URLQueryItem(name: "daid", value: "383"),
            URLQueryItem(name: "pt_3rd_aid", value: "100497308"),
        ]
        var request = URLRequest(url: comps.url!)
        request.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        request.setValue("https://xui.ptlogin2.qq.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        collectCookies(from: response)
        guard let qr = cookies["qrsig"], !qr.isEmpty else {
            throw QQLoginError.unknown("获取 QQ 二维码失败，请检查网络后重试")
        }
        qrsig = qr
        return data
    }

    func poll() async throws -> ScanState {
        guard !qrsig.isEmpty else { return .expired }
        var comps = URLComponents(string: "https://ssl.ptlogin2.qq.com/ptqrlogin")!
        comps.queryItems = [
            URLQueryItem(name: "u1", value: "https://graph.qq.com/oauth2.0/login_jump"),
            URLQueryItem(name: "ptqrtoken", value: "\(Self.hash33(qrsig))"),
            URLQueryItem(name: "ptredirect", value: "0"),
            URLQueryItem(name: "h", value: "1"),
            URLQueryItem(name: "t", value: "1"),
            URLQueryItem(name: "g", value: "1"),
            URLQueryItem(name: "from_ui", value: "1"),
            URLQueryItem(name: "ptlang", value: "2052"),
            URLQueryItem(name: "action", value: "0-0-\\(Int(Date().timeIntervalSince1970 * 1000))"),
            URLQueryItem(name: "js_ver", value: "22080914"),
            URLQueryItem(name: "js_type", value: "1"),
            URLQueryItem(name: "login_sig", value: ""),
            URLQueryItem(name: "pt_uistyle", value: "40"),
            URLQueryItem(name: "aid", value: "716027609"),
            URLQueryItem(name: "daid", value: "383"),
            URLQueryItem(name: "pt_3rd_aid", value: "100497308"),
            URLQueryItem(name: "o1vId", value: "49283d5cbb01a744d46314da4608d929"),
        ]
        var request = URLRequest(url: comps.url!)
        request.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        request.setValue("https://xui.ptlogin2.qq.com/", forHTTPHeaderField: "Referer")
        request.setValue("qrsig=\(qrsig)", forHTTPHeaderField: "Cookie")
        let (data, response) = try await session.data(for: request)
        collectCookies(from: response)
        guard let text = String(data: data, encoding: .utf8),
              let parsed = Self.parsePTUI(text) else {
            return .error("QQ 登录接口异常，请重试")
        }
        switch parsed.code {
        case "0":
            guard let url = parsed.url else { return .error("登录成功但凭证获取失败") }
            do {
                try await completeOAuth(redirectURL: url)
            } catch {
                return .error(error.localizedDescription)
            }
            let resolvedNickname = parsed.nickname
            updatePublishedState {
                self.nickname = resolvedNickname
                self.isLoggedIn = true
            }
            defaults.set(cookies, forKey: cookieKey)
            defaults.set(resolvedNickname, forKey: nickKey)
            Task { await self.fetchVIPStatus() }
            Task { await self.fetchProfile() }
            return .success(resolvedNickname)
        case "65", "68":
            return .expired
        case "67":
            return .scanned
        case "66":
            return .waiting
        default:
            return .waiting
        }
    }

    private func completeOAuth(redirectURL: String) async throws {
        var loginCookie = cookieHeader
        if !qrsig.isEmpty {
            loginCookie = "qrsig=\(qrsig)" + (loginCookie.isEmpty ? "" : "; " + loginCookie)
        }
        var current = redirectURL
        for _ in 0..<6 {
            guard let url = URL(string: current) else { break }
            var request = URLRequest(url: url)
            request.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
            request.setValue("https://xui.ptlogin2.qq.com/", forHTTPHeaderField: "Referer")
            request.setValue(loginCookie, forHTTPHeaderField: "Cookie")
            let (_, response) = try await session.data(for: request)
            collectCookies(from: response)
            loginCookie = cookieHeader
            if !qrsig.isEmpty {
                loginCookie = "qrsig=\(qrsig)" + (loginCookie.isEmpty ? "" : "; " + loginCookie)
            }
            guard let http = response as? HTTPURLResponse,
                  (300...399).contains(http.statusCode),
                  let location = http.value(forHTTPHeaderField: "Location"),
                  !location.isEmpty else { break }
            if let locURL = URL(string: location), locURL.scheme != nil {
                current = location
            } else if let base = URL(string: current),
                      let resolved = URL(string: location, relativeTo: base) {
                current = resolved.absoluteString
            } else {
                break
            }
        }

        loginCookie = cookieHeader
        let gtk = Self.hash5381(cookies["qqmusic_key"] ?? cookies["p_skey"] ?? cookies["skey"] ?? "")
        let fields: [String: String] = [
            "response_type": "code",
            "client_id": "100497308",
            "redirect_uri": "https://y.qq.com/portal/wx_redirect.html?login_type=1&surl=https://y.qq.com/",
            "scope": "all",
            "state": "state",
            "switch": "",
            "from_ptlogin": "1",
            "src": "1",
            "update_auth": "1",
            "openapi": "80901010_1030",
            "g_tk": "\(gtk)",
            "auth_time": "\(Int(Date().timeIntervalSince1970 * 1000))",
            "ui": "DFEC5395-9E69-4D3E-96A6-300BB770874D",
        ]
        var authRequest = URLRequest(url: URL(string: "https://graph.qq.com/oauth2.0/authorize")!)
        authRequest.httpMethod = "POST"
        authRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        authRequest.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        authRequest.setValue("https://graph.qq.com/", forHTTPHeaderField: "Referer")
        authRequest.setValue(loginCookie, forHTTPHeaderField: "Cookie")
        authRequest.httpBody = Self.formEncode(fields).data(using: .utf8)
        let (_, authResponse) = try await session.data(for: authRequest)
        collectCookies(from: authResponse)
        guard let http = authResponse as? HTTPURLResponse,
              let location = http.value(forHTTPHeaderField: "Location"),
              let code = Self.extractCode(from: location) else {
            throw QQLoginError.unknown("QQ 授权失败，请重新扫码")
        }

        loginCookie = cookieHeader
        let body = "{\"comm\":{\"g_tk\":5381,\"platform\":\"yqq\",\"ct\":24,\"cv\":0},\"req\":{\"module\":\"QQConnectLogin.LoginServer\",\"method\":\"QQLogin\",\"param\":{\"code\":\"\(code)\"}}}"
        var loginRequest = URLRequest(url: URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!)
        loginRequest.httpMethod = "POST"
        loginRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        loginRequest.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        loginRequest.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        loginRequest.setValue(loginCookie, forHTTPHeaderField: "Cookie")
        loginRequest.httpBody = body.data(using: .utf8)
        let (loginData, loginResponse) = try await session.data(for: loginRequest)
        collectCookies(from: loginResponse)
        if let json = try? JSONSerialization.jsonObject(with: loginData) as? [String: Any],
           let req = json["req"] as? [String: Any],
           let data = req["data"] as? [String: Any] {
            if let musicKey = data["musickey"] as? String, !musicKey.isEmpty {
                cookies["musickey"] = musicKey
                cookies["qm_keyst"] = musicKey
                cookies["qqmusic_key"] = musicKey
            }
            if let musicID = data["musicid"] as? Int, musicID > 0 {
                cookies["uin"] = "\(musicID)"
            } else if let musicID = data["musicid"] as? String, !musicID.isEmpty {
                cookies["uin"] = musicID
            }
        }
    }

    @MainActor
    func fetchVIPStatus() async {
        guard isLoggedIn, !uin.isEmpty, uin != "0" else {
            if vipBadge != nil {
                vipBadge = nil
                defaults.removeObject(forKey: vipKey)
            }
            return
        }
        do {
            let payload: [String: Any] = [
                "comm": ["ct": 24, "cv": 0, "uin": uin],
                "req_0": [
                    "module": "music.member.getVipInfo",
                    "method": "get_vip_info",
                    "param": ["uin": uin]
                ]
            ]
            let json = try await musicu(payload)
            let badge = Self.parseVIPBadge(json)
            if badge != vipBadge {
                vipBadge = badge
                defaults.set(badge ?? "", forKey: vipKey)
            }
        } catch {}
    }

    private static func parseVIPBadge(_ json: [String: Any]) -> String? {
        var vipLevel = 0
        var svipFlag = false
        func walk(_ value: Any) {
            if let dict = value as? [String: Any] {
                for (key, v) in dict {
                    let lower = key.lowercased()
                    if lower.contains("svip") {
                        if let n = v as? Int, n > 0 { svipFlag = true }
                        if let b = v as? Bool, b { svipFlag = true }
                    } else if lower == "viptype" || lower == "vip_type" {
                        if let n = v as? Int, n > 0 { vipLevel = max(vipLevel, n) }
                    }
                    walk(v)
                }
            } else if let arr = value as? [Any] {
                arr.forEach(walk)
            }
        }
        walk(json)
        if svipFlag || vipLevel >= 11 { return "SVIP" }
        if vipLevel > 0 { return "VIP" }
        return nil
    }

    @MainActor
    func fetchProfile() async {
        guard isLoggedIn, !uin.isEmpty, uin != "0" else { return }
        do {
            let urlString = "https://c.y.qq.com/rsc/fcgi-bin/fcg_get_profile_homepage.fcg?cid=205360838&userid=\(uin)&reqfrom=1&g_tk=5381&loginUin=\(uin)&hostUin=0&format=json&inCharset=utf8&outCharset=utf-8&notice=0&platform=yqq.json&needNewCode=0"
            guard let url = URL(string: urlString) else { return }
            var request = URLRequest(url: url)
            request.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
            request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let code = obj["code"] as? Int ?? -1
            guard code == 0 || code == 1000 else { return }
            if let nick = Self.extractNickname(obj), !nick.isEmpty, nick != nickname {
                nickname = nick
                defaults.set(nick, forKey: nickKey)
                return
            }
            if let key = cookies.keys.first(where: { $0.hasPrefix("ptnick") }),
               let raw = cookies[key], !raw.isEmpty {
                let nick = raw.removingPercentEncoding ?? raw
                if nick != nickname {
                    nickname = nick
                    defaults.set(nick, forKey: nickKey)
                }
            }
        } catch {}
    }

    private static func extractNickname(_ json: [String: Any]) -> String? {
        if let data = json["data"] as? [String: Any],
           let mymusic = data["mymusic"] as? [String: Any],
           let info = mymusic["info"] as? [String: Any],
           let nick = info["nick"] as? String, !nick.isEmpty {
            return nick
        }
        var found: String?
        func walk(_ value: Any) {
            if found != nil { return }
            if let dict = value as? [String: Any] {
                if let nick = dict["nick"] as? String, !nick.isEmpty, !nick.contains("QQ音乐用户") { found = nick; return }
                if let nick = dict["nickname"] as? String, !nick.isEmpty, !nick.contains("QQ音乐用户") { found = nick; return }
                for (_, v) in dict { walk(v) }
            } else if let arr = value as? [Any] {
                for v in arr { walk(v) }
            }
        }
        walk(json)
        return found
    }

    private func musicu(_ payload: [String: Any]) async throws -> [String: Any] {
        guard let body = try? JSONSerialization.data(withJSONObject: payload),
              let url = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg") else {
            throw QQLoginError.unknown("请求参数错误")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QQLoginError.network
        }
        return obj
    }

    private static let ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

    private func collectCookies(from response: URLResponse) {
        guard let http = response as? HTTPURLResponse,
              let headers = http.allHeaderFields as? [String: String] else { return }
        let setCookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: http.url!)
        for cookie in setCookies where !cookie.name.isEmpty {
            cookies[cookie.name] = cookie.value
        }
    }

    private static func parsePTUI(_ text: String) -> (code: String, url: String?, nickname: String)? {
        guard let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")") else { return nil }
        let inner = text[text.index(after: open)..<close]
        let parts = inner.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))
        }
        guard parts.count >= 5 else { return nil }
        let url: String
        if parts[1].hasPrefix("http") {
            url = parts[1]
        } else {
            url = parts.count > 2 ? parts[2] : ""
        }
        return (parts[0], url.isEmpty ? nil : url, parts[4])
    }

    private static func extractCode(from urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems,
              let code = items.first(where: { $0.name == "code" })?.value else { return nil }
        return code
    }

    private static func formEncode(_ fields: [String: String]) -> String {
        fields.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }

    static func hash33(_ t: String) -> Int {
        var e: Double = 0
        for unit in t.utf16 {
            e = e + Double(Self.toInt32Shift(e)) + Double(unit)
        }
        return Int(Self.toInt32(e) & 0x7FFF_FFFF)
    }

    static func hash5381(_ t: String) -> Int {
        var e: Double = 5381
        for unit in t.utf16 {
            e = e + Double(Self.toInt32Shift(e)) + Double(unit)
        }
        return Int(Self.toInt32(e) & 0x7FFF_FFFF)
    }

    private static func toInt32Shift(_ d: Double) -> Int32 {
        let u = Self.toUInt32(d)
        return Int32(bitPattern: u &* 32)
    }

    private static func toInt32(_ d: Double) -> Int32 {
        Int32(bitPattern: Self.toUInt32(d))
    }

    private static func toUInt32(_ d: Double) -> UInt32 {
        var r = d.truncatingRemainder(dividingBy: 4294967296.0)
        if r < 0 { r += 4294967296.0 }
        return UInt32(r)
    }

    private func updatePublishedState(_ update: @escaping () -> Void) {
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.sync(execute: update)
        }
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

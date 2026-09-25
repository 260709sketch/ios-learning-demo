import Foundation

// MARK: - QQ 音乐搜索 API
// 参考 Well Music xiaoqiu.js 实现，每个模块接口不同：
// - 歌曲：search_for_qq_cp (t=0)
// - 歌手：musicu.fcg (search_type=1) → fallback smartbox_new
// - 专辑：musicu.fcg (search_type=2) → fallback client_search_cp (t=8)

enum QQMusicAPI {
    static let pageSize = 20

    // MARK: - 搜索结果
    struct SearchResult {
        let songs: [Track]
        let artists: [ArtistSummary]
        let albums: [AlbumSummary]
        let hasMore: Bool
    }

    // MARK: - 通用请求头
    private static let headers: [String: String] = [
        "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 QQMusic/9.0.5",
        "Referer": "https://y.qq.com/",
        "Cookie": "uin=0; qqmusic_fromtag=66",
    ]

    // MARK: - 对象构造辅助（这些 struct 有自定义 init(from:)，无成员初始化器，用 JSON 解码构造）
    private static func makeTrack(id: Int, name: String, artists: [ArtistRef], album: AlbumRef, durationMS: Int, sourcePlatform: String, platformSongId: String, isExplicit: Bool = false) -> Track? {
        // QQ音乐脏标歌曲名后加 (Explicit) 后缀
        let displayName = isExplicit ? "\(name) (Explicit)" : name
        let dict: [String: Any] = [
            "id": id, "name": displayName,
            "ar": artists.map { ["id": $0.id, "name": $0.name, "singerMid": $0.singerMid ?? ""] },
            "al": ["id": album.id, "name": album.name, "picUrl": album.picUrl ?? "", "albumMid": album.albumMid ?? ""],
            "dt": durationMS, "alia": [], "tns": [], "fee": 0, "mv": 0, "no": 0,
            "sourcePlatform": sourcePlatform,
            "platformSongId": platformSongId
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(Track.self, from: data)
    }

    private static func makeArtist(id: Int, name: String, picUrl: String?, musicSize: Int, singerMid: String) -> ArtistSummary? {
        var dict: [String: Any] = ["id": id, "name": name, "albumSize": 0, "musicSize": musicSize, "followed": false, "alias": [], "sourcePlatform": "tx", "singerMid": singerMid]
        if let picUrl, !picUrl.isEmpty { dict["picUrl"] = picUrl }
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(ArtistSummary.self, from: data)
    }

    private static func makeAlbum(id: Int, name: String, picUrl: String?, artistName: String, publishTime: Int, albumMid: String = "", size: Int = 0, subType: String? = nil) -> AlbumSummary? {
        var dict: [String: Any] = ["id": id, "name": name, "artist": ["name": artistName], "publishTime": publishTime, "size": size, "alias": [], "sourcePlatform": "tx"]
        if !albumMid.isEmpty { dict["albumMid"] = albumMid }
        if let picUrl, !picUrl.isEmpty { dict["picUrl"] = picUrl }
        if let subType, !subType.isEmpty { dict["subType"] = subType }
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(AlbumSummary.self, from: data)
    }

    // MARK: - 搜索歌曲
    static func searchSongs(_ query: String, page: Int = 1, limit: Int = 20) async throws -> [Track] {
        let urlStr = "https://c.y.qq.com/soso/fcgi-bin/search_for_qq_cp?format=json&w=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&n=\(limit)&p=\(page)&t=0"
        guard let url = URL(string: urlStr) else { return [] }

        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = headers
        request.timeoutInterval = 12

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["code"] as? Int, code == 0,
              let dataDict = json["data"] as? [String: Any],
              let songDict = dataDict["song"] as? [String: Any],
              let list = songDict["list"] as? [[String: Any]] else {
            return []
        }

        return list.compactMap { item -> Track? in
            guard let songmid = item["songmid"] as? String, !songmid.isEmpty else { return nil }
            let songid = (item["songid"] as? Int) ?? abs(songmid.hashValue)
            let name = (item["songname"] as? String) ?? (item["title"] as? String) ?? ""
            let interval = (item["interval"] as? Int) ?? 0

            // 歌手
            var artists: [ArtistRef] = []
            if let singerList = item["singer"] as? [[String: Any]] {
                artists = singerList.map { s in
                    let sid = (s["id"] as? Int) ?? 0
                    let sname = (s["name"] as? String) ?? ""
                    let smid = (s["mid"] as? String) ?? (s["singerMID"] as? String) ?? ""
                    // QQ音乐部分接口singer无id字段，用mid的hash保证唯一，避免ForEach重复导致跳转错误
                    let artistID = sid > 0 ? sid : abs(smid.hashValue)
                    return ArtistRef(id: artistID, name: sname, singerMid: smid.isEmpty ? nil : smid)
                }
            }

            // 专辑
            let albumName = (item["albumname"] as? String) ?? ""
            let albumMid = (item["albummid"] as? String) ?? ""
            let albumID = (item["albumid"] as? Int) ?? 0
            let picUrl = albumMid.isEmpty ? nil : "https://y.gtimg.cn/music/photo_new/T002R800x800M000\(albumMid).jpg"
            let album = AlbumRef(id: albumID, name: albumName, picUrl: picUrl, albumMid: albumMid)

            // QQ音乐 Explicit 脏标：尝试多个可能的字段和bit位
            let status = (item["status"] as? Int) ?? 0
            let action = (item["action"] as? Int) ?? 0
            let pay = (item["pay"] as? [String: Any]) ?? [:]
            let payPay = (pay["pay"] as? Int) ?? 0
            // 常见脏标位：status bit7(128), bit11(2048); action bit; pay.pay bit
            let isExplicit = (status & 128) != 0 || (status & 2048) != 0 || (action & 128) != 0 || (payPay & 128) != 0
            // 调试日志：输出前3首歌的状态字段，帮助确定脏标在哪个位
            if songmid == list.first?["songmid"] as? String || songmid == (list.count > 1 ? list[1]["songmid"] as? String : nil) {
                DebugLogger.shared.log("QQ脏标", "歌曲=\(name) status=\(status)(0b\(String(status, radix: 2))) action=\(action) pay.pay=\(payPay) isExplicit=\(isExplicit)")
            }

            return makeTrack(id: songid, name: name, artists: artists, album: album, durationMS: interval * 1000, sourcePlatform: "tx", platformSongId: songmid, isExplicit: isExplicit)
        }
    }

    // MARK: - 搜索歌手
    static func searchArtists(_ query: String, page: Int = 1, limit: Int = 20) async throws -> [ArtistSummary] {
        // 主接口：musicu.fcg search_type=1
        if let artists = try? await searchArtistsMusicu(query, page: page, limit: limit), !artists.isEmpty {
            return artists
        }
        // fallback：smartbox_new
        return await searchArtistsSmartbox(query, limit: limit)
    }

    private static func searchArtistsMusicu(_ query: String, page: Int, limit: Int) async throws -> [ArtistSummary] {
        guard let url = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg") else { return [] }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = headers.merging(["Content-Type": "application/json"]) { _, new in new }
        request.timeoutInterval = 12

        let body: [String: Any] = [
            "comm": ["ct": 19, "cv": 1859, "uin": "0", "format": "json"],
            "req_1": [
                "module": "music.search.SearchCgiService",
                "method": "DoSearchForQQMusicDesktop",
                "param": [
                    "query": query,
                    "num_per_page": limit,
                    "page_num": page,
                    "search_type": 1,
                    "grp": 1,
                ],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let req1 = json["req_1"] as? [String: Any],
              let code = req1["code"] as? Int, code == 0,
              let reqData = req1["data"] as? [String: Any],
              let bodyDict = reqData["body"] as? [String: Any],
              let singerDict = bodyDict["singer"] as? [String: Any],
              let list = singerDict["list"] as? [[String: Any]] else {
            return []
        }

        return list.compactMap { item -> ArtistSummary? in
            let singerID = (item["singerID"] as? Int) ?? (item["id"] as? Int) ?? 0
            let singerName = (item["singerName"] as? String) ?? (item["name"] as? String) ?? ""
            guard !singerName.isEmpty else { return nil }
            let singerPic = (item["singerPic"] as? String) ?? (item["pic"] as? String) ?? ""
            let songNum = (item["songNum"] as? Int) ?? 0
            let singerMid = (item["singerMID"] as? String) ?? (item["mid"] as? String) ?? ""
            let picUrl = singerPic.isEmpty ? nil : singerPic.replacingOccurrences(of: "http://", with: "https://")
            return makeArtist(id: singerID, name: singerName, picUrl: picUrl, musicSize: songNum, singerMid: singerMid)
        }
    }

    private static func searchArtistsSmartbox(_ query: String, limit: Int) async -> [ArtistSummary] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlStr = "https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg?format=json&s_from=pc_header&type=1&key=\(encoded)"
        guard let url = URL(string: urlStr) else { return [] }
        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = headers
        request.timeoutInterval = 10

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataDict = json["data"] as? [String: Any],
              let singerDict = dataDict["singer"] as? [String: Any],
              let list = singerDict["itemlist"] as? [[String: Any]] else {
            return []
        }

        return list.prefix(limit).compactMap { item -> ArtistSummary? in
            let singerID = (item["id"] as? Int) ?? 0
            let singerName = (item["name"] as? String) ?? ""
            guard !singerName.isEmpty else { return nil }
            let singerPic = (item["pic"] as? String) ?? ""
            let singerMid = (item["mid"] as? String) ?? (item["singerMID"] as? String) ?? ""
            return makeArtist(id: singerID, name: singerName, picUrl: singerPic.isEmpty ? nil : singerPic, musicSize: 0, singerMid: singerMid)
        }
    }

    // MARK: - 搜索专辑
    static func searchAlbums(_ query: String, page: Int = 1, limit: Int = 20) async throws -> [AlbumSummary] {
        // 主接口：musicu.fcg search_type=2
        if let albums = try? await searchAlbumsMusicu(query, page: page, limit: limit), !albums.isEmpty {
            return albums
        }
        // fallback：client_search_cp t=8
        return await searchAlbumsClientCp(query, page: page, limit: limit)
    }

    private static func searchAlbumsMusicu(_ query: String, page: Int, limit: Int) async throws -> [AlbumSummary] {
        guard let url = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg") else { return [] }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = headers.merging(["Content-Type": "application/json"]) { _, new in new }
        request.timeoutInterval = 12

        let body: [String: Any] = [
            "comm": ["ct": 19, "cv": 1859, "uin": "0", "format": "json"],
            "req_1": [
                "module": "music.search.SearchCgiService",
                "method": "DoSearchForQQMusicDesktop",
                "param": [
                    "query": query,
                    "num_per_page": limit,
                    "page_num": page,
                    "search_type": 2,
                    "grp": 1,
                ],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let req1 = json["req_1"] as? [String: Any],
              let code = req1["code"] as? Int, code == 0,
              let reqData = req1["data"] as? [String: Any],
              let bodyDict = reqData["body"] as? [String: Any],
              let albumDict = bodyDict["album"] as? [String: Any],
              let list = albumDict["list"] as? [[String: Any]] else {
            return []
        }

        return list.compactMap { item -> AlbumSummary? in
            let albumID = (item["albumID"] as? Int) ?? (item["albumid"] as? Int) ?? (item["id"] as? Int) ?? 0
            let albumName = (item["albumName"] as? String) ?? (item["albumname"] as? String) ?? (item["name"] as? String) ?? ""
            guard !albumName.isEmpty else { return nil }
            let albumMID = (item["albumMID"] as? String) ?? (item["albummid"] as? String) ?? (item["mid"] as? String) ?? ""
            let albumPic = (item["albumPic"] as? String) ?? (item["albumpic"] as? String) ?? (item["pic"] as? String) ?? ""
            let picUrl = albumPic.isEmpty ? (albumMID.isEmpty ? nil : "https://y.gtimg.cn/music/photo_new/T002R800x800M000\(albumMID).jpg") : albumPic.replacingOccurrences(of: "http://", with: "https://")

            // 歌手名
            var singerName = (item["singerName"] as? String) ?? (item["singername"] as? String) ?? ""
            if singerName.isEmpty, let singerList = item["singer"] as? [[String: Any]] {
                singerName = singerList.compactMap { $0["name"] as? String }.joined(separator: " / ")
            }

            // 发布时间（QQ音乐返回的是秒级时间戳或日期字符串）
            var publishTime = 0
            if let pubTime = item["publicTime"] as? Int {
                publishTime = pubTime * 1000
            } else if let pubTimeStr = item["publicTime"] as? String, !pubTimeStr.isEmpty {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                if let date = formatter.date(from: pubTimeStr) {
                    publishTime = Int(date.timeIntervalSince1970 * 1000)
                }
            }

            return makeAlbum(id: albumID, name: albumName, picUrl: picUrl, artistName: singerName, publishTime: publishTime, albumMid: albumMID)
        }
    }

    private static func searchAlbumsClientCp(_ query: String, page: Int, limit: Int) async -> [AlbumSummary] {
        let urlStr = "https://c.y.qq.com/soso/fcgi-bin/client_search_cp?format=json&w=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&n=\(limit)&p=\(page)&t=8"
        guard let url = URL(string: urlStr) else { return [] }
        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = headers
        request.timeoutInterval = 12

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["code"] as? Int, code == 0,
              let dataDict = json["data"] as? [String: Any],
              let albumDict = dataDict["album"] as? [String: Any],
              let list = albumDict["list"] as? [[String: Any]] else {
            return []
        }

        return list.compactMap { item -> AlbumSummary? in
            let albumID = (item["albumID"] as? Int) ?? (item["albumid"] as? Int) ?? (item["id"] as? Int) ?? 0
            let albumName = (item["albumName"] as? String) ?? (item["albumname"] as? String) ?? (item["name"] as? String) ?? ""
            guard !albumName.isEmpty else { return nil }
            let albumMID = (item["albumMID"] as? String) ?? (item["albummid"] as? String) ?? (item["mid"] as? String) ?? ""
            let albumPic = (item["albumPic"] as? String) ?? (item["albumpic"] as? String) ?? (item["pic"] as? String) ?? ""
            let picUrl = albumPic.isEmpty ? (albumMID.isEmpty ? nil : "https://y.gtimg.cn/music/photo_new/T002R800x800M000\(albumMID).jpg") : albumPic.replacingOccurrences(of: "http://", with: "https://")

            var singerName = (item["singerName"] as? String) ?? (item["singername"] as? String) ?? ""
            if singerName.isEmpty, let singerList = item["singer_list"] as? [[String: Any]] {
                singerName = singerList.compactMap { $0["name"] as? String }.joined(separator: " / ")
            }

            return makeAlbum(id: albumID, name: albumName, picUrl: picUrl, artistName: singerName, publishTime: 0, albumMid: albumMID)
        }
    }

    // MARK: - 歌词（参考 Well Music src/components/utils/musicSdk/tx/lyric.js）
    static func lyric(songmid: String) async throws -> LyricResponse {
        let urlStr = "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?songmid=\(songmid)&g_tk=5381&loginUin=0&hostUin=0&format=json&inCharset=utf8&outCharset=utf-8&platform=yqq"
        guard let url = URL(string: urlStr) else { throw NSError(domain: "QQMusicAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]) }

        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = headers.merging(["Referer": "https://y.qq.com/portal/player.html"]) { _, new in new }
        request.timeoutInterval = 12

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["code"] as? Int, code == 0 else {
            throw NSError(domain: "QQMusicAPI", code: -2, userInfo: [NSLocalizedDescriptionKey: "Lyric API error"])
        }

        // lyric 和 trans 都是 base64 编码
        let lyricB64 = (json["lyric"] as? String) ?? ""
        let transB64 = (json["trans"] as? String) ?? ""

        let lyricText = decodeBase64(lyricB64)
        let transText = decodeBase64(transB64)

        // 构造 LyricResponse
        let lrcBody = LyricResponse.LyricBody(lyric: lyricText.isEmpty ? nil : lyricText)
        let tlyricBody = LyricResponse.LyricBody(lyric: transText.isEmpty ? nil : transText)

        return LyricResponse(
            lrc: lrcBody,
            tlyric: tlyricBody,
            romalrc: nil,
            yrc: nil,
            ytlrc: nil,
            yromalrc: nil,
            lyricUser: nil,
            transUser: nil,
            nolyric: lyricText.isEmpty,
            uncollected: nil
        )
    }

    private static func decodeBase64(_ b64: String) -> String {
        guard !b64.isEmpty,
              let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text
    }

    // MARK: - musicu.fcg 通用 GET 请求（参考 Well Music，data 放 URL 参数）
    private static func musicuGET(_ body: [String: Any]) async throws -> [String: Any] {
        let jsonStr = (try? JSONSerialization.data(withJSONObject: body)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let encoded = jsonStr.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlStr = "https://u.y.qq.com/cgi-bin/musicu.fcg?data=\(encoded)"
        guard let url = URL(string: urlStr) else { return [:] }
        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = headers
        request.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: request)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: - 歌手详情（参考 Well Music：GetSingerSongList 接口）
    static func artistSongs(singerMid: String, page: Int = 1, limit: Int = 20) async throws -> (tracks: [Track], total: Int) {
        DebugLogger.shared.log("QQ歌手", "artistSongs 请求 mid=\(singerMid) page=\(page) limit=\(limit)")
        let body: [String: Any] = [
            "comm": ["ct": 24, "cv": 0],
            "req": [
                "module": "musichall.song_list_server",
                "method": "GetSingerSongList",
                "param": [
                    "singerMid": singerMid,
                    "begin": (page - 1) * limit,
                    "num": limit,
                    "order": 1
                ]
            ]
        ]
        let json = try await musicuGET(body)
        guard let req = json["req"] as? [String: Any],
              let reqData = req["data"] as? [String: Any],
              let songList = reqData["songList"] as? [[String: Any]] else {
            DebugLogger.shared.log("QQ歌手", "artistSongs 响应格式错误 mid=\(singerMid) jsonKeys=\(json.keys)", level: .error)
            return ([], 0)
        }
        // 真实总数
        let total = (reqData["totalNum"] as? Int) ?? songList.count
        DebugLogger.shared.log("QQ歌手", "artistSongs 返回 \(songList.count) 首 总数=\(total) mid=\(singerMid)", level: .success)

        var isFirstSong = true
        let tracks = songList.compactMap { item -> Track? in
            // GetSingerSongList 接口返回字段：songInfo 子对象或直接字段
            let songInfo = item["songInfo"] as? [String: Any] ?? item
            guard let songmid = (songInfo["mid"] as? String) ?? (item["mid"] as? String), !songmid.isEmpty else { return nil }
            let songid = (songInfo["id"] as? Int) ?? (item["id"] as? Int) ?? abs(songmid.hashValue)
            let name = (songInfo["name"] as? String) ?? (songInfo["title"] as? String) ?? (songInfo["songname"] as? String) ?? (item["name"] as? String) ?? ""
            let interval = (songInfo["interval"] as? Int) ?? (item["interval"] as? Int) ?? 0

            var artists: [ArtistRef] = []
            if let singerList = (songInfo["singer"] as? [[String: Any]]) ?? (item["singer"] as? [[String: Any]]) {
                artists = singerList.map { s in
                    let sid = (s["id"] as? Int) ?? 0
                    let sname = (s["name"] as? String) ?? ""
                    let smid = (s["mid"] as? String) ?? (s["singerMID"] as? String) ?? ""
                    let artistID = sid > 0 ? sid : abs(smid.hashValue)
                    return ArtistRef(id: artistID, name: sname, singerMid: smid.isEmpty ? nil : smid)
                }
            }

            // 专辑信息在 album 对象中
            let albumDict = (songInfo["album"] as? [String: Any]) ?? (item["album"] as? [String: Any]) ?? [:]
            let albumName = (albumDict["name"] as? String) ?? (albumDict["title"] as? String) ?? ""
            let albumMid = (albumDict["mid"] as? String) ?? ""
            let albumID = (albumDict["id"] as? Int) ?? 0
            let picUrl = albumMid.isEmpty ? nil : "https://y.gtimg.cn/music/photo_new/T002R800x800M000\(albumMid).jpg"
            let album = AlbumRef(id: albumID, name: albumName, picUrl: picUrl, albumMid: albumMid)

            // QQ音乐 Explicit 脏标：全面检查 item 和 songInfo 层面的所有可能字段
            let status = (item["status"] as? Int) ?? (songInfo["status"] as? Int) ?? 0
            let action = (item["action"] as? Int) ?? (songInfo["action"] as? Int) ?? 0
            let payDict = (item["pay"] as? [String: Any]) ?? (songInfo["pay"] as? [String: Any]) ?? [:]
            let payPay = (payDict["pay"] as? Int) ?? 0
            let switchDict = (item["switch"] as? [String: Any]) ?? (songInfo["switch"] as? [String: Any]) ?? [:]
            let msgDict = (item["msg"] as? [String: Any]) ?? (songInfo["msg"] as? [String: Any]) ?? [:]
            // 脏标可能在多个bit位：bit7(128)=付费专辑, bit11(2048)=脏标, 还有其他可能
            let isExplicit = (status & 128) != 0 || (status & 2048) != 0 ||
                             (action & 128) != 0 || (action & 2048) != 0 ||
                             (payPay & 128) != 0 || (payPay & 2048) != 0 ||
                             (switchDict["flag"] as? Int ?? 0) & 2048 != 0 ||
                             (msgDict["explicit"] as? Int ?? 0) != 0 ||
                             (songInfo["isExplicit"] as? Int ?? 0) != 0 ||
                             (item["isExplicit"] as? Int ?? 0) != 0

            // 调试：打印第一首歌的完整JSON，帮助定位脏标
            if isFirstSong {
                if let jsonData = try? JSONSerialization.data(withJSONObject: item, options: [.prettyPrinted]),
                   let jsonStr = String(data: jsonData, encoding: .utf8) {
                    DebugLogger.shared.log("QQ脏标", "歌曲[\(name)] 完整JSON: \(jsonStr.prefix(2000))")
                }
                DebugLogger.shared.log("QQ脏标", "歌曲[\(name)] item.keys=\(Array(item.keys)) songInfo.keys=\(Array(songInfo.keys)) status=\(status) action=\(action) payPay=\(payPay) isExplicit=\(isExplicit)")
                isFirstSong = false
            }

            return makeTrack(id: songid, name: name, artists: artists, album: album, durationMS: interval * 1000, sourcePlatform: "tx", platformSongId: songmid, isExplicit: isExplicit)
        }
        return (tracks, total)
    }

    static func artistAlbums(singerMid: String, page: Int = 1, limit: Int = 20) async throws -> (albums: [AlbumSummary], total: Int) {
        DebugLogger.shared.log("QQ歌手", "artistAlbums 请求 mid=\(singerMid) page=\(page) limit=\(limit)")
        let body: [String: Any] = [
            "comm": ["ct": 24, "cv": 0],
            "singerAlbum": [
                "method": "get_singer_album",
                "param": [
                    "singermid": singerMid,
                    "order": "time",
                    "begin": (page - 1) * limit,
                    "num": limit,
                    "exstatus": 1
                ],
                "module": "music.web_singer_info_svr"
            ]
        ]
        let json = try await musicuGET(body)
        guard let singerAlbum = json["singerAlbum"] as? [String: Any],
              let albumData = singerAlbum["data"] as? [String: Any],
              let list = albumData["list"] as? [[String: Any]] else {
            DebugLogger.shared.log("QQ歌手", "artistAlbums 响应格式错误 mid=\(singerMid) jsonKeys=\(json.keys)", level: .error)
            return ([], 0)
        }
        // 真实总数：total 或 totalNum
        let total = (albumData["total"] as? Int) ?? (albumData["totalNum"] as? Int) ?? list.count
        DebugLogger.shared.log("QQ歌手", "artistAlbums 返回 \(list.count) 张 总数=\(total) mid=\(singerMid)", level: .success)

        let albums = list.compactMap { item -> AlbumSummary? in
            // get_singer_album 接口返回字段：albumid/album_mid/album_name/singer_name/pub_time/albumtype/song_count/ftype
            let albumID = (item["albumid"] as? Int) ?? (item["albumID"] as? Int) ?? (item["id"] as? Int) ?? 0
            let albumName = (item["album_name"] as? String) ?? (item["albumName"] as? String) ?? (item["name"] as? String) ?? ""
            guard !albumName.isEmpty else { return nil }
            let albumMID = (item["album_mid"] as? String) ?? (item["albumMID"] as? String) ?? (item["mid"] as? String) ?? ""
            let picUrl = albumMID.isEmpty ? nil : "https://y.gtimg.cn/music/photo_new/T002R800x800M000\(albumMID).jpg"
            let singerName = (item["singer_name"] as? String) ?? (item["singerName"] as? String) ?? ""
            let publishTime = (item["pub_time"] as? Int) ?? (item["publishTime"] as? Int) ?? 0
            // 参考 Well Music 逻辑：根据 albumType 和歌曲数量区分专辑/EP/单曲
            let albumType = (item["albumtype"] as? String) ?? (item["album_type"] as? String) ?? (item["albumType"] as? String) ?? ""
            let songCount = (item["song_count"] as? Int) ?? (item["songCount"] as? Int) ?? (item["songcount"] as? Int) ?? (item["total"] as? Int) ?? (item["count"] as? Int) ?? (item["size"] as? Int) ?? 0
            let ftype = (item["ftype"] as? Int) ?? 0
            var subType = "专辑"
            if albumType.contains("EP") || albumType.contains("单曲") || ftype == 10 {
                subType = songCount <= 1 ? "单曲" : "EP"
            } else if songCount == 1 {
                subType = "单曲"
            } else if songCount > 1 && songCount <= 5 {
                subType = "EP"
            }
            return makeAlbum(id: albumID, name: albumName, picUrl: picUrl, artistName: singerName, publishTime: publishTime, albumMid: albumMID, size: songCount, subType: subType)
        }
        return (albums, total)
    }

    // MARK: - 专辑详情（参考 Well Music：fcg_v8_album_info_cp.fcg 接口）
    static func albumInfo(albumMid: String) async throws -> [Track] {
        let urlStr = "https://i.y.qq.com/v8/fcg-bin/fcg_v8_album_info_cp.fcg?platform=h5page&albummid=\(albumMid)&g_tk=938407465&uin=0&format=json&inCharset=utf-8&outCharset=utf-8&notice=0&platform=h5&needNewCode=1"
        guard let url = URL(string: urlStr) else { return [] }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataDict = json["data"] as? [String: Any],
              let songList = dataDict["list"] as? [[String: Any]] else {
            return []
        }

        var isFirstAlbumSong = true
        return songList.compactMap { item -> Track? in
            // fcg_v8_album_info_cp 接口返回字段：songname, songmid, songid, singer[], albumname, albummid, interval, status, action
            guard let songmid = item["songmid"] as? String, !songmid.isEmpty else { return nil }
            let songid = (item["songid"] as? Int) ?? abs(songmid.hashValue)
            let name = (item["songname"] as? String) ?? (item["name"] as? String) ?? (item["title"] as? String) ?? ""
            let interval = (item["interval"] as? Int) ?? 0

            var artists: [ArtistRef] = []
            if let singerList = item["singer"] as? [[String: Any]] {
                artists = singerList.map { s in
                    let sid = (s["id"] as? Int) ?? 0
                    let sname = (s["name"] as? String) ?? ""
                    let smid = (s["mid"] as? String) ?? (s["singerMID"] as? String) ?? ""
                    let artistID = sid > 0 ? sid : abs(smid.hashValue)
                    return ArtistRef(id: artistID, name: sname, singerMid: smid.isEmpty ? nil : smid)
                }
            }

            // 专辑信息
            let albumName = (item["albumname"] as? String) ?? (dataDict["name"] as? String) ?? ""
            let albumID = (dataDict["albumid"] as? Int) ?? 0
            let picUrl = "https://y.gtimg.cn/music/photo_new/T002R800x800M000\(albumMid).jpg"
            let album = AlbumRef(id: albumID, name: albumName, picUrl: picUrl, albumMid: albumMid)

            // QQ音乐 Explicit 脏标：全面检查所有可能字段
            let status = (item["status"] as? Int) ?? 0
            let action = (item["action"] as? Int) ?? 0
            let payDict = item["pay"] as? [String: Any] ?? [:]
            let payPay = (payDict["pay"] as? Int) ?? 0
            let switchDict = item["switch"] as? [String: Any] ?? [:]
            let msgDict = item["msg"] as? [String: Any] ?? [:]
            let isExplicit = (status & 128) != 0 || (status & 2048) != 0 ||
                             (action & 128) != 0 || (action & 2048) != 0 ||
                             (payPay & 128) != 0 || (payPay & 2048) != 0 ||
                             (switchDict["flag"] as? Int ?? 0) & 2048 != 0 ||
                             (msgDict["explicit"] as? Int ?? 0) != 0 ||
                             (item["isExplicit"] as? Int ?? 0) != 0

            // 调试：打印第一首歌的所有字段
            if isFirstAlbumSong {
                DebugLogger.shared.log("QQ脏标", "专辑歌曲[\(name)] keys=\(Array(item.keys)) status=\(status) action=\(action) payPay=\(payPay) isExplicit=\(isExplicit)")
                isFirstAlbumSong = false
            }

            return makeTrack(id: songid, name: name, artists: artists, album: album, durationMS: interval * 1000, sourcePlatform: "tx", platformSongId: songmid, isExplicit: isExplicit)
        }
    }

    // MARK: - QQ音乐逐字歌词（QRC）
    /// 获取 QQ 音乐逐字歌词（QRC），返回解析后的 LyricLine 数组；失败返回 nil
    static func wordLyric(songmid: String) async -> [LyricLine]? {
        DebugLogger.shared.log("QRC", "开始获取逐字歌词 songmid=\(songmid)")
        let body: [String: Any] = [
            "comm": ["uin": 0, "format": 1, "ct": 19, "cv": 0],
            "detail": [
                "module": "music.musichallSong.PlayLyricInfo",
                "method": "GetPlayLyricInfo",
                "param": [
                    "qrc": 1, "qrc_t": 0, "roma": 1, "guoke": 1,
                    "type": -1, "licenseID": "", "cp": 0, "cv": 0, "ct": 19,
                    "songmid": songmid
                ]
            ]
        ]
        guard let url = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = [
            "User-Agent": "QQMusic 14090508(android 12)",
            "Content-Type": "application/json",
            "Referer": "https://y.qq.com/"
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
            DebugLogger.shared.log("QRC", "HTTP状态=\(httpStatus) 数据长度=\(data.count)")
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let detail = json["detail"] as? [String: Any],
                  let detailData = detail["data"] as? [String: Any],
                  let qrcFlag = detailData["qrc"] as? Int, qrcFlag == 1,
                  let encryptedLyric = detailData["lyric"] as? String,
                  !encryptedLyric.isEmpty else {
                DebugLogger.shared.log("QRC", "响应解析失败或无qrc字段", level: .error)
                return nil
            }
            DebugLogger.shared.log("QRC", "加密歌词长度=\(encryptedLyric.count) 前20字符=\(String(encryptedLyric.prefix(20)))")
            guard let decrypted = QQQrcDecoder.decrypt(encryptedLyric) else {
                DebugLogger.shared.log("QRC", "解密失败", level: .error)
                return nil
            }
            DebugLogger.shared.log("QRC", "解密成功 长度=\(decrypted.count) 前50字符=\(String(decrypted.prefix(50)))")
            let parsed = parseQrc(decrypted)
            DebugLogger.shared.log("QRC", parsed != nil ? "解析成功 行数=\(parsed!.count)" : "解析失败", level: parsed != nil ? .success : .error)
            return parsed
        } catch {
            DebugLogger.shared.log("QRC", "请求异常: \(error.localizedDescription)", level: .error)
            return nil
        }
    }

    /// 解析 QQ QRC 文本：[行开始ms,行时长ms]字(绝对开始ms,字时长ms)字...
    private static func parseQrc(_ text: String) -> [LyricLine]? {
        var lines: [LyricLine] = []
        let lineRegex = try? NSRegularExpression(pattern: "\\[(-?\\d+),-?\\d+\\]([^\\r\\n]*)")
        let wordRegex = try? NSRegularExpression(pattern: "([^()\\r\\n]*?)\\((-?\\d+),(-?\\d+)\\)")
        guard let lineRegex = lineRegex, let wordRegex = wordRegex else { return nil }

        let nsText = text as NSString
        let lineMatches = lineRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        var idx = 0
        for lm in lineMatches {
            guard lm.numberOfRanges >= 3 else { continue }
            let lineStart = max(0, Int(nsText.substring(with: lm.range(at: 1))) ?? 0)
            let body = nsText.substring(with: lm.range(at: 2))
            let nsBody = body as NSString
            let wordMatches = wordRegex.matches(in: body, range: NSRange(location: 0, length: nsBody.length))
            var words: [LyricWord] = []
            for wm in wordMatches {
                guard wm.numberOfRanges >= 4 else { continue }
                let t = nsBody.substring(with: wm.range(at: 1))
                let abs = Int(nsBody.substring(with: wm.range(at: 2))) ?? 0
                let dur = Int(nsBody.substring(with: wm.range(at: 3))) ?? 0
                let start = TimeInterval(max(0, abs)) / 1000
                let end = start + TimeInterval(max(0, dur)) / 1000
                words.append(LyricWord(text: t, start: start, duration: max(end - start, 0.02)))
            }
            let lrc = words.map { $0.text }.joined().trimmingCharacters(in: .whitespaces)
            guard !lrc.isEmpty, !words.isEmpty else { continue }
            lines.append(LyricLine(id: idx, time: TimeInterval(lineStart) / 1000, text: lrc, words: words))
            idx += 1
        }
        return lines.isEmpty ? nil : lines
    }
}

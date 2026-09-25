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
    private static func makeTrack(id: Int, name: String, artists: [ArtistRef], album: AlbumRef, durationMS: Int, sourcePlatform: String, platformSongId: String) -> Track? {
        let dict: [String: Any] = [
            "id": id, "name": name,
            "ar": artists.map { ["id": $0.id, "name": $0.name] },
            "al": ["id": album.id, "name": album.name, "picUrl": album.picUrl ?? ""],
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

    private static func makeAlbum(id: Int, name: String, picUrl: String?, artistName: String, publishTime: Int, albumMid: String = "") -> AlbumSummary? {
        var dict: [String: Any] = ["id": id, "name": name, "artist": ["name": artistName], "publishTime": publishTime, "size": 0, "alias": [], "sourcePlatform": "tx"]
        if !albumMid.isEmpty { dict["albumMid"] = albumMid }
        if let picUrl, !picUrl.isEmpty { dict["picUrl"] = picUrl }
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
                    let smid = (s["mid"] as? String) ?? (s["singerMID"] as? String)
                    return ArtistRef(id: sid, name: sname, singerMid: smid)
                }
            }

            // 专辑
            let albumName = (item["albumname"] as? String) ?? ""
            let albumMid = (item["albummid"] as? String) ?? ""
            let albumID = (item["albumid"] as? Int) ?? 0
            let picUrl = albumMid.isEmpty ? nil : "https://y.gtimg.cn/music/photo_new/T002R800x800M000\(albumMid).jpg"
            let album = AlbumRef(id: albumID, name: albumName, picUrl: picUrl)

            return makeTrack(id: songid, name: name, artists: artists, album: album, durationMS: interval * 1000, sourcePlatform: "tx", platformSongId: songmid)
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

    // MARK: - 歌手详情（参考 Well Music xiaoqiu.js getArtistSongs/getArtistAlbums）
    static func artistSongs(singerMid: String, page: Int = 1, limit: Int = 20) async throws -> [Track] {
        let body: [String: Any] = [
            "comm": ["ct": 24, "cv": 0],
            "singer": [
                "method": "get_singer_detail_info",
                "param": [
                    "sort": 5,
                    "singermid": singerMid,
                    "sin": (page - 1) * limit,
                    "num": limit
                ],
                "module": "music.web_singer_info_svr"
            ]
        ]
        let json = try await musicuGET(body)
        guard let singer = json["singer"] as? [String: Any],
              let singerData = singer["data"] as? [String: Any],
              let songlist = singerData["songlist"] as? [[String: Any]] else {
            return []
        }

        return songlist.compactMap { item -> Track? in
            // get_singer_detail_info 接口返回字段：name/title, mid, id, singer[], album{}
            guard let songmid = item["mid"] as? String, !songmid.isEmpty else { return nil }
            let songid = (item["id"] as? Int) ?? abs(songmid.hashValue)
            let name = (item["name"] as? String) ?? (item["title"] as? String) ?? ""
            let interval = (item["interval"] as? Int) ?? 0

            var artists: [ArtistRef] = []
            if let singerList = item["singer"] as? [[String: Any]] {
                artists = singerList.map { s in
                    let sid = (s["id"] as? Int) ?? 0
                    let sname = (s["name"] as? String) ?? ""
                    let smid = (s["mid"] as? String) ?? (s["singerMID"] as? String)
                    return ArtistRef(id: sid, name: sname, singerMid: smid)
                }
            }

            // 专辑信息在 album 对象中
            let albumDict = item["album"] as? [String: Any] ?? [:]
            let albumName = (albumDict["name"] as? String) ?? (albumDict["title"] as? String) ?? ""
            let albumMid = (albumDict["mid"] as? String) ?? ""
            let albumID = (albumDict["id"] as? Int) ?? 0
            let picUrl = albumMid.isEmpty ? nil : "https://y.gtimg.cn/music/photo_new/T002R800x800M000\(albumMid).jpg"
            let album = AlbumRef(id: albumID, name: albumName, picUrl: picUrl)

            return makeTrack(id: songid, name: name, artists: artists, album: album, durationMS: interval * 1000, sourcePlatform: "tx", platformSongId: songmid)
        }
    }

    static func artistAlbums(singerMid: String, page: Int = 1, limit: Int = 20) async throws -> [AlbumSummary] {
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
            return []
        }

        return list.compactMap { item -> AlbumSummary? in
            let albumID = (item["albumID"] as? Int) ?? (item["id"] as? Int) ?? 0
            let albumName = (item["albumName"] as? String) ?? (item["name"] as? String) ?? ""
            guard !albumName.isEmpty else { return nil }
            let albumMID = (item["albumMID"] as? String) ?? (item["mid"] as? String) ?? ""
            let albumPic = (item["albumPic"] as? String) ?? (item["pic"] as? String) ?? ""
            let picUrl = albumPic.isEmpty ? (albumMID.isEmpty ? nil : "https://y.gtimg.cn/music/photo_new/T002R800x800M000\(albumMID).jpg") : albumPic.replacingOccurrences(of: "http://", with: "https://")
            let singerName = (item["singerName"] as? String) ?? ""
            let publishTime = (item["publishTime"] as? Int) ?? 0
            return makeAlbum(id: albumID, name: albumName, picUrl: picUrl, artistName: singerName, publishTime: publishTime, albumMid: albumMID)
        }
    }

    // MARK: - 专辑详情（参考 Well Music xiaoqiu.js getAlbumInfo）
    static func albumInfo(albumMid: String) async throws -> [Track] {
        let body: [String: Any] = [
            "comm": ["ct": 24, "cv": 10000],
            "albumSonglist": [
                "method": "GetAlbumSongList",
                "param": [
                    "albumMid": albumMid,
                    "albumID": 0,
                    "begin": 0,
                    "num": 999,
                    "order": 2
                ],
                "module": "music.musichallAlbum.AlbumSongList"
            ]
        ]
        let json = try await musicuGET(body)
        guard let albumSonglist = json["albumSonglist"] as? [String: Any],
              let albumData = albumSonglist["data"] as? [String: Any],
              let songList = albumData["songList"] as? [[String: Any]] else {
            return []
        }

        return songList.compactMap { item -> Track? in
            guard let songInfo = item["songInfo"] as? [String: Any] else { return nil }
            // GetAlbumSongList 接口返回字段：name/title, mid, id, singer[], album{}
            guard let songmid = songInfo["mid"] as? String, !songmid.isEmpty else { return nil }
            let songid = (songInfo["id"] as? Int) ?? abs(songmid.hashValue)
            let name = (songInfo["name"] as? String) ?? (songInfo["title"] as? String) ?? ""
            let interval = (songInfo["interval"] as? Int) ?? 0

            var artists: [ArtistRef] = []
            if let singerList = songInfo["singer"] as? [[String: Any]] {
                artists = singerList.map { s in
                    let sid = (s["id"] as? Int) ?? 0
                    let sname = (s["name"] as? String) ?? ""
                    let smid = (s["mid"] as? String) ?? (s["singerMID"] as? String)
                    return ArtistRef(id: sid, name: sname, singerMid: smid)
                }
            }

            // 专辑信息在 album 对象中
            let albumDict = songInfo["album"] as? [String: Any] ?? [:]
            let albumName = (albumDict["name"] as? String) ?? (albumDict["title"] as? String) ?? ""
            let albumMid2 = (albumDict["mid"] as? String) ?? ""
            let albumID = (albumDict["id"] as? Int) ?? 0
            let picUrl = albumMid2.isEmpty ? nil : "https://y.gtimg.cn/music/photo_new/T002R800x800M000\(albumMid2).jpg"
            let album = AlbumRef(id: albumID, name: albumName, picUrl: picUrl)

            return makeTrack(id: songid, name: name, artists: artists, album: album, durationMS: interval * 1000, sourcePlatform: "tx", platformSongId: songmid)
        }
    }
}

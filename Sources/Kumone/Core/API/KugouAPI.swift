import Foundation

// MARK: - 酷狗音乐搜索 API
// 参考 Beans Music (XIaodou0416/Beans-Music) 和 wellmusic 实现
// 接口（来自 wellmusic src/helpers/userApi/kugou-music-api.js）：
// - 歌曲搜索：songsearch.kugou.com/song_search_v2
// - 歌手详情：mobilecdn.kugou.com/api/v3/singer/info
// - 歌手歌曲：mobilecdn.kugou.com/api/v3/singer/song
// - 歌手专辑：mobilecdn.kugou.com/api/v3/singer/album
// - 专辑详情：mobilecdn.kugou.com/api/v3/album/info
// - 专辑歌曲：mobilecdn.kugou.com/api/v3/album/song
// - 歌词：lyrics.kugou.com/search + download
// - 播放：走 LX 音源（platformSongId = hash）
// 注意：mobilecdn API 必须用 http + PC User-Agent，https 会返回空

enum KugouAPI {
    static let pageSize = 20

    // MARK: - 通用请求头
    private static let headers: [String: String] = [
        "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
        "Referer": "https://www.kugou.com/",
    ]

    private static let browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    // MARK: - 歌手名分割（酷狗多歌手用 / 、 , & 等分隔）
    private static func splitArtists(_ singerName: String, singerID: Int = 0) -> [ArtistRef] {
        let trimmed = singerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // 按常见分隔符分割
        let separators = CharacterSet(charactersIn: "/、,&，")
        let parts = trimmed.components(separatedBy: separators).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        if parts.count <= 1 {
            return [ArtistRef(id: singerID, name: trimmed, singerMid: singerID > 0 ? String(singerID) : nil)]
        }
        // 多歌手：只有第一个用真正的 singerID，其他 singerMid 为 nil（避免跳转错误歌手）
        return parts.enumerated().map { idx, name in
            if idx == 0 && singerID > 0 {
                return ArtistRef(id: singerID, name: name, singerMid: String(singerID))
            }
            return ArtistRef(id: abs(name.hashValue), name: name, singerMid: nil)
        }
    }

    /// 只分割歌手名，返回字符串数组
    private static func splitArtistsNames(_ singerName: String) -> [String] {
        let trimmed = singerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let separators = CharacterSet(charactersIn: "/、,&，")
        let parts = trimmed.components(separatedBy: separators).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        return parts.isEmpty ? [trimmed] : parts
    }

    // MARK: - 对象构造辅助
    private static func makeTrack(id: Int, name: String, artists: [ArtistRef], album: AlbumRef, durationMS: Int, hash: String, isExplicit: Bool = false) -> Track? {
        let displayName = isExplicit ? "\(name) (Explicit)" : name
        let dict: [String: Any] = [
            "id": id, "name": displayName,
            "ar": artists.map { ["id": $0.id, "name": $0.name, "singerMid": $0.singerMid ?? ""] },
            "al": ["id": album.id, "name": album.name, "picUrl": album.picUrl ?? "", "albumMid": album.albumMid ?? ""],
            "dt": durationMS, "alia": [], "tns": [], "fee": 0, "mv": 0, "no": 0,
            "sourcePlatform": "kg",
            "platformSongId": hash
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(Track.self, from: data)
    }

    private static func makeArtist(id: Int, name: String, picUrl: String?, authorID: String) -> ArtistSummary? {
        var dict: [String: Any] = ["id": id, "name": name, "albumSize": 0, "musicSize": 0, "followed": false, "alias": [], "sourcePlatform": "kg", "singerMid": authorID]
        if let picUrl, !picUrl.isEmpty { dict["picUrl"] = picUrl }
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(ArtistSummary.self, from: data)
    }

    // 来自 wellmusic (src/helpers/userApi/kugou-music-api.js)
    private static func makeAlbum(id: Int, name: String, picUrl: String?, artistName: String, albumID: String, subType: String = "") -> AlbumSummary? {
        var dict: [String: Any] = ["id": id, "name": name, "artist": ["name": artistName], "publishTime": 0, "size": 0, "alias": [], "sourcePlatform": "kg", "albumMid": albumID]
        if let picUrl, !picUrl.isEmpty { dict["picUrl"] = picUrl }
        if !subType.isEmpty { dict["subType"] = subType }
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(AlbumSummary.self, from: data)
    }

    // MARK: - 通用 GET 请求
    private static func getJSON(_ url: URL, headers: [String: String] = [:]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        if headers.isEmpty { request.allHTTPHeaderFields = self.headers }
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    // MARK: - 搜索歌曲
    static func searchSongs(_ query: String, page: Int = 1, limit: Int = 20) async throws -> [Track] {
        // 主接口：songsearch_v2（lx-music 同款，返回结果多，支持 Grp 展开）
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlStr = "https://songsearch.kugou.com/song_search_v2?platform=AndroidFilter&iscorrection=1&keyword=\(encoded)&hifiquality=0&pagesize=\(limit)&PrivilegeFilter=0&page=\(page)"
        guard let url = URL(string: urlStr) else { return [] }

        guard let json = try? await getJSON(url, headers: ["User-Agent": browserUA, "Referer": "https://www.kugou.com/"]),
              let data = json["data"] as? [String: Any],
              let lists = data["lists"] as? [[String: Any]] else {
            return []
        }

        // 不展开 Grp（其他版本），避免同一首歌重复显示
        let allItems = lists

        return allItems.compactMap { item -> Track? in
            let hash = (item["FileHash"] as? String) ?? ""
            guard !hash.isEmpty else { return nil }

            let name = (item["OriSongName"] as? String) ?? (item["SongName"] as? String) ?? ""
            let duration = (item["Duration"] as? Int) ?? 0
            let songID = (item["Audioid"] as? Int) ?? (item["SongID"] as? Int) ?? abs(hash.hashValue)

            // 歌手：优先 SingerId 数组（真实ID），然后 Singers 数组，兜底 SingerName 字符串
            var artists: [ArtistRef] = []
            if let singerIds = item["SingerId"] as? [Int], !singerIds.isEmpty,
               let singerName = item["SingerName"] as? String {
                let names = singerName.components(separatedBy: "、").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                for (idx, sid) in singerIds.enumerated() {
                    let sname = idx < names.count ? names[idx] : singerName
                    artists.append(ArtistRef(id: sid, name: sname, singerMid: String(sid)))
                }
            } else if let singers = item["Singers"] as? [[String: Any]] {
                artists = singers.compactMap { s in
                    let sname = (s["name"] as? String) ?? ""
                    guard !sname.isEmpty else { return nil }
                    let sid = (s["id"] as? Int) ?? abs(sname.hashValue)
                    return ArtistRef(id: sid, name: sname, singerMid: String(sid))
                }
            }
            if artists.isEmpty {
                let singerName = (item["SingerName"] as? String) ?? ""
                artists = splitArtists(singerName, singerID: abs(singerName.hashValue))
            }

            let albumName = (item["AlbumName"] as? String) ?? ""
            let albumID = (item["AlbumID"] as? String) ?? ""
            let albumAudioId = (item["MixSongID"] as? String) ?? ""
            var picUrl: String? = nil
            let transParam = item["trans_param"] as? [String: Any]
            let imgCandidates = [
                item["Image"] as? String,
                item["image"] as? String,
                item["AlbumImage"] as? String,
                item["Img"] as? String,
                item["img"] as? String,
                item["imgurl"] as? String,
                transParam?["union_cover"] as? String
            ]
            for candidate in imgCandidates {
                if let img = candidate, !img.isEmpty {
                    var normalized = img.replacingOccurrences(of: "{size}", with: "400")
                    if normalized.hasPrefix("//") { normalized = "https:" + normalized }
                    normalized = normalized.replacingOccurrences(of: "http://", with: "https://")
                    picUrl = normalized
                    break
                }
            }
            if picUrl == nil, !albumID.isEmpty {
                picUrl = "https://imge.kugou.com/stdmusic/400/album/\(albumID).jpg"
            }
            let albumMid = albumID
            let album = AlbumRef(id: abs(albumID.hashValue), name: albumName, picUrl: picUrl, albumMid: albumMid)

            return makeTrack(id: songID, name: name, artists: artists, album: album, durationMS: duration * 1000, hash: hash)
        }
    }


    // MARK: - 搜索歌手（来自 wellmusic: searchKugouArtist）
    static func searchArtists(_ query: String, page: Int = 1, limit: Int = 20) async throws -> [ArtistSummary] {
        // 方式1：专门的歌手搜索 API
        if let artists = try? await searchSingersAPI(keyword: query, page: page, limit: limit), !artists.isEmpty {
            return artists
        }
        // 方式2：从歌曲搜索结果提取歌手（逐个获取真实头像，不用专辑封面）
        let songs = try await searchSongs(query, page: page, limit: 50)
        var result: [ArtistSummary] = []
        var seen = Set<String>()
        for song in songs {
            for artist in song.artists {
                let key = artist.name
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                let authorID = artist.singerMid ?? String(artist.id)
                // 调用 singer/info 获取歌手真实头像，不用专辑封面
                var avatar: String? = nil
                if let detail = try? await artistDetail(authorID: authorID) {
                    avatar = detail.avatar
                }
                if let artistSummary = makeArtist(id: artist.id, name: artist.name, picUrl: avatar, authorID: authorID) {
                    result.append(artistSummary)
                }
                if result.count >= limit { break }
            }
            if result.count >= limit { break }
        }
        return result
    }

    // 专门的歌手搜索 API（来自 wellmusic）
    private static func searchSingersAPI(keyword: String, page: Int = 1, limit: Int = 20) async throws -> [ArtistSummary] {
        guard let url = URL(string: "http://mobilecdn.kugou.com/api/v3/search/singer?format=json&keyword=\(keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword)&page=\(page)&pagesize=\(limit)") else { return [] }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.kugou.com/", forHTTPHeaderField: "Referer")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        // data 可能是数组或包含 info 的字典
        var singerList: [[String: Any]] = []
        if let dataArr = json["data"] as? [[String: Any]] {
            singerList = dataArr
        } else if let dataDict = json["data"] as? [String: Any],
                  let info = dataDict["info"] as? [[String: Any]] {
            singerList = info
        }

        var result: [ArtistSummary] = []
        // 批量补全前10个歌手的头像
        let fillCount = min(singerList.count, 10)
        for (index, item) in singerList.enumerated() {
            let singerID = (item["singerid"] as? Int).map { String($0) } ?? (item["singerid"] as? String) ?? ""
            let singerName = (item["singername"] as? String) ?? ""
            guard !singerID.isEmpty, !singerName.isEmpty else { continue }
            var avatar: String? = nil
            // 前10个调用 singer/info 获取真实头像
            if index < fillCount {
                if let detail = try? await artistDetail(authorID: singerID) {
                    avatar = detail.avatar
                }
            }
            if let artist = makeArtist(id: abs(singerID.hashValue), name: singerName, picUrl: avatar, authorID: singerID) {
                result.append(artist)
            }
            if result.count >= limit { break }
        }
        return result
    }

    // MARK: - 搜索专辑（来自 wellmusic: searchKugouAlbum，用专门的 search/album API）
    static func searchAlbums(_ query: String, page: Int = 1, limit: Int = 20) async throws -> [AlbumSummary] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "http://mobilecdn.kugou.com/api/v3/search/album?format=json&keyword=\(encoded)&page=\(page)&pagesize=\(limit)") else { return [] }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataDict = json["data"] as? [String: Any],
              let list = dataDict["info"] as? [[String: Any]] else {
            return []
        }

        return list.compactMap { item -> AlbumSummary? in
            let albumID = (item["albumid"] as? String) ?? (item["album_id"] as? String) ?? (item["albumid"] as? Int).map { String($0) } ?? (item["album_id"] as? Int).map { String($0) } ?? ""
            let albumName = (item["albumname"] as? String) ?? (item["album_name"] as? String) ?? ""
            let singerName = (item["singername"] as? String) ?? ""
            guard !albumName.isEmpty, !albumID.isEmpty else { return nil }
            var picUrl: String? = nil
            if let img = item["imgurl"] as? String, !img.isEmpty {
                picUrl = img.replacingOccurrences(of: "{size}", with: "400").replacingOccurrences(of: "http://", with: "https://")
            }
            if picUrl == nil {
                picUrl = "https://imge.kugou.com/stdmusic/400/album/\(albumID).jpg"
            }
            return makeAlbum(id: abs(albumID.hashValue), name: albumName, picUrl: picUrl, artistName: singerName, albumID: albumID)
        }
    }

    // MARK: - 歌词
    static func lyric(hash: String, duration: TimeInterval) async -> String {
        guard !hash.isEmpty else { return "" }

        // 搜索歌词
        let searchURLStr = "http://lyrics.kugou.com/search?ver=1&man=yes&client=pc&hash=\(hash.uppercased())&duration=\(Int(duration * 1000))"
        guard let searchURL = URL(string: searchURLStr) else { return "" }

        guard let sjson = try? await getJSON(searchURL, headers: ["User-Agent": browserUA]),
              let candidates = sjson["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let id = first["id"],
              let accessKey = first["accesskey"] else { return "" }

        // 下载歌词
        let downloadURLStr = "http://lyrics.kugou.com/download?ver=1&client=pc&id=\(id)&accesskey=\(accessKey)&fmt=lrc&charset=utf8"
        guard let downloadURL = URL(string: downloadURLStr) else { return "" }

        guard let djson = try? await getJSON(downloadURL, headers: ["User-Agent": browserUA]),
              let content = djson["content"] as? String,
              let data = Data(base64Encoded: content.replacingOccurrences(of: "\n", with: "")) else { return "" }

        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - 歌手详情（头像、歌曲数、专辑数）
    static func artistDetail(authorID: String) async throws -> (name: String, avatar: String?, songCount: Int, albumCount: Int)? {
        let id = authorID.replacingOccurrences(of: "kugou_", with: "")
        guard let url = URL(string: "http://mobilecdn.kugou.com/api/v3/singer/info?singerid=\(id)") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = json["data"] as? [String: Any] else { return nil }
        let name = (info["singername"] as? String) ?? ""
        var avatar: String? = nil
        if let img = info["imgurl"] as? String, !img.isEmpty {
            avatar = img.replacingOccurrences(of: "{size}", with: "400").replacingOccurrences(of: "http://", with: "https://")
        }
        let songCount = (info["songcount"] as? Int) ?? 0
        let albumCount = (info["albumcount"] as? Int) ?? 0
        return (name, avatar, songCount, albumCount)
    }

    // MARK: - 歌手歌曲
    static func artistSongs(authorID: String, page: Int = 1, limit: Int = 20) async throws -> (tracks: [Track], total: Int) {
        let id = authorID.replacingOccurrences(of: "kugou_", with: "")
        // 先获取歌手名
        let detail = try? await artistDetail(authorID: authorID)
        let singerName = detail?.name ?? ""

        guard let url = URL(string: "http://mobilecdn.kugou.com/api/v3/singer/song?singerid=\(id)&page=\(page)&pagesize=\(min(limit, 100))") else { return ([], 0) }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataDict = json["data"] as? [String: Any],
              let list = dataDict["info"] as? [[String: Any]] else {
            return ([], 0)
        }
        let total = (dataDict["total"] as? Int) ?? list.count

        let tracks = list.compactMap { item -> Track? in
            guard let hash = item["hash"] as? String, !hash.isEmpty else { return nil }
            let filename = (item["filename"] as? String) ?? ""
            // 从 filename 解析歌曲名和歌手名，格式 "歌手 - 歌名"
            var songName = ""
            var artistName = singerName
            if !filename.isEmpty {
                let parts = filename.components(separatedBy: " - ")
                if parts.count >= 2 {
                    artistName = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    songName = parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    songName = filename
                }
            }
            if songName.isEmpty { return nil }
            let duration = (item["duration"] as? Int) ?? 0
            let songID = abs(hash.hashValue)
            let albumName = (item["album_name"] as? String) ?? ""
            let albumID = (item["album_id"] as? String) ?? (item["album_id"] as? Int).map { String($0) } ?? ""
            let albumAudioID = (item["album_audio_id"] as? String) ?? (item["album_audio_id"] as? Int).map { String($0) } ?? ""
            // 封面：优先用 trans_param.union_cover，然后 album_id
            var picUrl: String? = nil
            if let trans = item["trans_param"] as? [String: Any], let unionCover = trans["union_cover"] as? String, !unionCover.isEmpty {
                picUrl = unionCover.replacingOccurrences(of: "{size}", with: "400").replacingOccurrences(of: "http://", with: "https://")
            }
            if picUrl == nil, !albumID.isEmpty {
                picUrl = "https://imge.kugou.com/stdmusic/400/album/\(albumID).jpg"
            }
            let artists = splitArtists(artistName, singerID: Int(id) ?? abs(artistName.hashValue))
            let album = AlbumRef(id: abs(albumID.hashValue), name: albumName, picUrl: picUrl, albumMid: albumID)
            return makeTrack(id: songID, name: songName, artists: artists, album: album, durationMS: duration * 1000, hash: hash)
        }
        return (Array(tracks.prefix(limit)), total)
    }

    // MARK: - 歌手专辑
    static func artistAlbums(authorID: String, page: Int = 1, limit: Int = 20) async throws -> (albums: [AlbumSummary], total: Int) {
        let id = authorID.replacingOccurrences(of: "kugou_", with: "")
        let singerName = (try? await artistDetail(authorID: authorID))?.name ?? ""

        // 循环请求所有页，一次性获取全部专辑（对齐 WellMusic 的懒加载效果）
        var allAlbums: [AlbumSummary] = []
        var currentPage = 1
        var total = 0
        let pageSize = 100 // 每页最大100

        while true {
            guard let url = URL(string: "http://mobilecdn.kugou.com/api/v3/singer/album?singerid=\(id)&page=\(currentPage)&pagesize=\(pageSize)") else { break }
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataDict = json["data"] as? [String: Any],
                  let list = dataDict["info"] as? [[String: Any]] else {
                break
            }
            if total == 0 {
                total = (dataDict["total"] as? Int) ?? list.count
            }
            let pageAlbums = list.compactMap { item -> AlbumSummary? in
                let albumID = (item["albumid"] as? String) ?? (item["album_id"] as? String) ?? (item["albumid"] as? Int).map { String($0) } ?? (item["album_id"] as? Int).map { String($0) } ?? ""
                let albumName = (item["albumname"] as? String) ?? (item["album_name"] as? String) ?? ""
                guard !albumName.isEmpty, !albumID.isEmpty else { return nil }
                var picUrl: String? = nil
                if let img = item["imgurl"] as? String, !img.isEmpty {
                    picUrl = img.replacingOccurrences(of: "{size}", with: "400").replacingOccurrences(of: "http://", with: "https://")
                }
                if picUrl == nil, !albumID.isEmpty {
                    picUrl = "https://imge.kugou.com/stdmusic/400/album/\(albumID).jpg"
                }
                // 专辑类型：优先用 album_type，其次按歌曲数量判断（对齐 WellMusic）
                var subType = "专辑"
                if let type = item["album_type"] as? Int, type > 0 {
                    if type == 1 { subType = "单曲" }
                    else if type == 2 { subType = "EP" }
                } else if let songCount = item["songcount"] as? Int {
                    if songCount == 1 { subType = "单曲" }
                    else if songCount > 1 && songCount <= 5 { subType = "EP" }
                }
                return makeAlbum(id: abs(albumID.hashValue), name: albumName, picUrl: picUrl, artistName: singerName, albumID: albumID, subType: subType)
            }
            allAlbums.append(contentsOf: pageAlbums)
            // 本页不足100张，说明是最后一页
            if list.count < pageSize { break }
            currentPage += 1
            // 安全上限，防止无限循环
            if currentPage > 20 { break }
        }

        return (allAlbums, total)
    }

    // MARK: - 专辑歌曲（来自 wellmusic: getKugouAlbumSongs）
    static func albumInfo(albumID: String, albumName: String = "", artistName: String = "") async throws -> [Track] {
        let id = albumID.replacingOccurrences(of: "kugou_album_", with: "").replacingOccurrences(of: "kugou_", with: "")
        // 获取专辑信息（专辑名、封面、歌手）
        var singerName = artistName
        var albumCover: String? = nil
        if let infoUrl = URL(string: "http://mobilecdn.kugou.com/api/v3/album/info?albumid=\(id)") {
            var infoRequest = URLRequest(url: infoUrl)
            infoRequest.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
            if let (infoData, _) = try? await URLSession.shared.data(for: infoRequest),
               let infoJson = try? JSONSerialization.jsonObject(with: infoData) as? [String: Any],
               let infoDict = infoJson["data"] as? [String: Any] {
                if let name = infoDict["albumname"] as? String, !name.isEmpty {
                    singerName = infoDict["singername"] as? String ?? singerName
                    if let img = infoDict["imgurl"] as? String, !img.isEmpty {
                        albumCover = img.replacingOccurrences(of: "{size}", with: "400").replacingOccurrences(of: "http://", with: "https://")
                    }
                }
            }
        }

        // 获取专辑歌曲
        guard let songUrl = URL(string: "http://mobilecdn.kugou.com/api/v3/album/song?albumid=\(id)&page=1&pagesize=100") else { return [] }
        var songRequest = URLRequest(url: songUrl)
        songRequest.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        let (songData, _) = try await URLSession.shared.data(for: songRequest)
        guard let songJson = try? JSONSerialization.jsonObject(with: songData) as? [String: Any],
              let dataDict = songJson["data"] as? [String: Any],
              let list = dataDict["info"] as? [[String: Any]] else {
            return []
        }

        return list.compactMap { item -> Track? in
            guard let hash = item["hash"] as? String, !hash.isEmpty else { return nil }
            let filename = (item["filename"] as? String) ?? ""
            // 从 filename 解析歌曲名和歌手名，格式 "歌手 - 歌名"
            var songName = ""
            var artistNameParsed = singerName
            if !filename.isEmpty {
                let parts = filename.components(separatedBy: " - ")
                if parts.count >= 2 {
                    artistNameParsed = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    songName = parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    songName = filename
                }
            }
            if songName.isEmpty { return nil }
            let duration = (item["duration"] as? Int) ?? 0
            let songID = abs(hash.hashValue)
            let albumNameParsed = (item["album_name"] as? String) ?? albumName
            // 封面：优先用专辑封面，然后 trans_param.union_cover，最后 album_id
            var picUrl = albumCover
            if picUrl == nil, let trans = item["trans_param"] as? [String: Any], let unionCover = trans["union_cover"] as? String, !unionCover.isEmpty {
                picUrl = unionCover.replacingOccurrences(of: "{size}", with: "400").replacingOccurrences(of: "http://", with: "https://")
            }
            if picUrl == nil, !id.isEmpty {
                picUrl = "https://imge.kugou.com/stdmusic/400/album/\(id).jpg"
            }
            let artists = splitArtists(artistNameParsed, singerID: abs(artistNameParsed.hashValue))
            let album = AlbumRef(id: abs(id.hashValue), name: albumNameParsed, picUrl: picUrl, albumMid: id)
            return makeTrack(id: songID, name: songName, artists: artists, album: album, durationMS: duration * 1000, hash: hash)
        }
    }

    // MARK: - 评论

    struct KugouCommentPage {
        let comments: [SongComment]
        let hotComments: [SongComment]
        let total: Int
    }

    /// 通过 hash 获取评论用的 audio_id
    private static func commentAudioID(hash: String) async throws -> String? {
        guard !hash.isEmpty else { return nil }
        var components = URLComponents(string: "https://wwwapi.kugou.com/yy/index.php")!
        components.queryItems = [
            URLQueryItem(name: "r", value: "play/getdata"),
            URLQueryItem(name: "hash", value: hash.uppercased()),
            URLQueryItem(name: "appid", value: "1014"),
            URLQueryItem(name: "platid", value: "4"),
        ]
        guard let url = components.url else { return nil }
        let json = try await getJSON(url)
        let data = (json["data"] as? [String: Any]) ?? json
        if let audioID = data["audio_id"] as? Int {
            return "\(audioID)"
        }
        if let audioID = data["audio_id"] as? String, !audioID.isEmpty {
            return audioID
        }
        return nil
    }

    /// 酷狗评论（热门评论从 weightList 提取，最新评论从 list 提取）
    static func comments(hash: String, page: Int = 1, limit: Int = 30) async throws -> KugouCommentPage {
        let cleanHash = hash.replacingOccurrences(of: "kugou_", with: "").replacingOccurrences(of: "kg_", with: "")
        let urlString = "https://mcomment.kugou.com/index.php?r=commentsv2/getCommentWithLike&code=fc4be23b4e972707f36b8a828a93ba8a&extdata=\(cleanHash)&p=\(max(page, 1))&pagesize=\(min(max(limit, 1), 30))"
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "KugouAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "URL 无效"])
        }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return KugouCommentPage(comments: [], hotComments: [], total: 0)
        }
        return parseComments(json: json, page: page)
    }

    private static func parseComments(json: [String: Any], page: Int) -> KugouCommentPage {
        // 最新评论：list
        let rows: [[String: Any]]
        if let list = json["list"] as? [[String: Any]] {
            rows = list
        } else if let data = json["data"] as? [String: Any],
                  let list = data["list"] as? [[String: Any]] {
            rows = list
        } else if let comments = json["comments"] as? [[String: Any]] {
            rows = comments
        } else {
            rows = []
        }
        // 热门评论：weightList（酷狗的精选/热门评论）
        let hotRows: [[String: Any]]
        if let weight = json["weightList"] as? [[String: Any]] {
            hotRows = weight
        } else if let data = json["data"] as? [String: Any],
                  let weight = data["weightList"] as? [[String: Any]] {
            hotRows = weight
        } else {
            hotRows = []
        }

        let comments = parseCommentRows(rows, isHot: false)
        // 热门评论优先用 weightList，没有则用前几条最新评论兜底
        let hotComments = hotRows.isEmpty ? Array(comments.prefix(5)) : parseCommentRows(hotRows, isHot: true)

        let total = (json["count"] as? Int) ?? (json["total"] as? Int) ?? ((json["data"] as? [String: Any])?["total"] as? Int) ?? comments.count
        return KugouCommentPage(comments: comments, hotComments: hotComments, total: total)
    }

    private static func parseCommentRows(_ rows: [[String: Any]], isHot: Bool) -> [SongComment] {
        var seen = Set<Int>()
        return rows.compactMap { raw -> SongComment? in
            let rawID = (raw["commentid"] as? String) ?? (raw["comment_id"] as? String) ?? ((raw["id"] as? Int).map { "\($0)" }) ?? ""
            let content = (raw["content"] as? String) ?? (raw["comment_content"] as? String) ?? ""
            guard !content.isEmpty else { return nil }
            let nickname = (raw["user_name"] as? String) ?? (raw["nick"] as? String) ?? (raw["nickname"] as? String) ?? (raw["username"] as? String) ?? "酷狗用户"
            let avatar = (raw["user_pic"] as? String) ?? (raw["avatarurl"] as? String) ?? (raw["avatar_url"] as? String) ?? (raw["avatar"] as? String) ?? ""
            var timestamp: Double = 0
            if let addtime = raw["addtime"] as? Double {
                timestamp = addtime
            } else if let addtime = raw["addtime"] as? Int {
                timestamp = Double(addtime)
            } else if let addtimeStr = raw["addtime"] as? String {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                if let date = formatter.date(from: addtimeStr) {
                    timestamp = date.timeIntervalSince1970
                }
            } else if let time = raw["time"] as? Double {
                timestamp = time
            }
            let seconds = timestamp > 10_000_000_000 ? timestamp / 1000 : timestamp
            let id = rawID.isEmpty ? abs(content.hashValue) : abs(rawID.hashValue)
            guard seen.insert(id).inserted else { return nil }
            var likedCount = (raw["praisenum"] as? Int) ?? (raw["like_count"] as? Int) ?? 0
            if likedCount == 0, let like = raw["like"] as? [String: Any], let likenum = like["likenum"] as? Int {
                likedCount = likenum
            }
            return SongComment(
                id: id,
                content: content,
                nickname: nickname.isEmpty ? "酷狗用户" : nickname,
                avatarURL: avatar.isEmpty ? nil : avatar,
                time: seconds > 0 ? Date(timeIntervalSince1970: seconds) : Date(),
                likedCount: likedCount,
                isHot: isHot
            )
        }
    }
}

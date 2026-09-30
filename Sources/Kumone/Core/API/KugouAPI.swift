import Foundation

// MARK: - 酷狗音乐搜索 API
// 参考 Beans Music (XIaodou0416/Beans-Music) 实现
// 接口：
// - 歌曲：mobilecdn.kugou.com/api/v3/search/song
// - 歌手：mobilecdn.kugou.com/api/v1/search/author
// - 专辑：从歌曲搜索结果提取
// - 歌词：lyrics.kugou.com/search + download
// - 播放：走 LX 音源（platformSongId = hash）

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
            return [ArtistRef(id: singerID, name: trimmed, singerMid: String(singerID))]
        }
        // 多歌手：第一个用真正的 singerID，其他用歌手名作为 singerMid（用于搜索）
        return parts.enumerated().map { idx, name in
            if idx == 0 && singerID > 0 {
                return ArtistRef(id: singerID, name: name, singerMid: String(singerID))
            }
            return ArtistRef(id: abs(name.hashValue), name: name, singerMid: name)
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

    private static func makeAlbum(id: Int, name: String, picUrl: String?, artistName: String, albumID: String) -> AlbumSummary? {
        var dict: [String: Any] = ["id": id, "name": name, "artist": ["name": artistName], "publishTime": 0, "size": 0, "alias": [], "sourcePlatform": "kg", "albumMid": albumID]
        if let picUrl, !picUrl.isEmpty { dict["picUrl"] = picUrl }
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

        // 展开 Grp（其他版本），去重
        var seen = Set<String>()
        var allItems: [[String: Any]] = []
        for item in lists {
            let hash = (item["FileHash"] as? String) ?? ""
            if !hash.isEmpty, seen.insert(hash).inserted {
                allItems.append(item)
            }
            if let grp = item["Grp"] as? [[String: Any]] {
                for child in grp {
                    let childHash = (child["FileHash"] as? String) ?? ""
                    if !childHash.isEmpty, seen.insert(childHash).inserted {
                        allItems.append(child)
                    }
                }
            }
        }

        return allItems.compactMap { item -> Track? in
            let hash = (item["FileHash"] as? String) ?? ""
            guard !hash.isEmpty else { return nil }

            let name = (item["OriSongName"] as? String) ?? (item["SongName"] as? String) ?? ""
            let duration = (item["Duration"] as? Int) ?? 0
            let songID = (item["Audioid"] as? Int) ?? (item["SongID"] as? Int) ?? abs(hash.hashValue)

            // 歌手：Singers 数组（lx-music 格式），兜底 SingerName 字符串
            var artists: [ArtistRef] = []
            if let singers = item["Singers"] as? [[String: Any]] {
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
            if picUrl == nil, !hash.isEmpty {
                picUrl = "https://imgessl.kugou.com/stdmusic/400/\(hash).jpg"
            }
            let albumMid = albumAudioId.isEmpty ? albumID : albumAudioId
            let album = AlbumRef(id: abs(albumID.hashValue), name: albumName, picUrl: picUrl, albumMid: albumMid)

            return makeTrack(id: songID, name: name, artists: artists, album: album, durationMS: duration * 1000, hash: hash)
        }
    }


    // MARK: - 搜索歌手（从歌曲搜索结果提取，和Beans Music一致）
    static func searchArtists(_ query: String, page: Int = 1, limit: Int = 20) async throws -> [ArtistSummary] {
        let songs = try await searchSongs(query, page: page, limit: 50)
        var result: [ArtistSummary] = []
        var seen = Set<String>()
        for song in songs {
            for artist in song.artists {
                let key = artist.name
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                let authorID = artist.singerMid ?? String(artist.id)
                result.append(makeArtist(id: artist.id, name: artist.name, picUrl: song.album.picUrl, authorID: authorID)!)
                if result.count >= limit { break }
            }
            if result.count >= limit { break }
        }
        return result
    }

    // MARK: - 搜索专辑（从歌曲搜索结果提取）
    static func searchAlbums(_ query: String, page: Int = 1, limit: Int = 20) async throws -> [AlbumSummary] {
        let songs = try await searchSongs(query, page: page, limit: 50)
        var result: [AlbumSummary] = []
        var seen = Set<String>()
        for song in songs {
            let albumName = song.album.name
            guard !albumName.isEmpty else { continue }
            let artistName = song.artists.first?.name ?? ""
            let key = "\(albumName)|\(artistName)"
            guard seen.insert(key).inserted else { continue }
            let albumID = song.album.albumMid ?? String(song.album.id)
            result.append(makeAlbum(id: song.album.id, name: albumName, picUrl: song.album.picUrl, artistName: artistName, albumID: albumID)!)
            if result.count >= limit { break }
        }
        return result
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

    // MARK: - 歌手歌曲
    static func artistSongs(authorID: String, page: Int = 1, limit: Int = 20) async throws -> (tracks: [Track], total: Int) {
        // 非数字 authorID（歌手名）：用搜索方式获取该歌手的歌曲
        if Int(authorID) == nil {
            let allSongs = try await searchSongs(authorID, page: 1, limit: 50)
            let filtered = allSongs.filter { track in
                track.artists.contains { $0.name.lowercased() == authorID.lowercased() }
            }
            let result = filtered.isEmpty ? allSongs : filtered
            return (Array(result.prefix(limit)), result.count)
        }
        // mobilecdn API 已失效，改用移动端网页解析
        let urlStr = "https://m.kugou.com/singer/info/\(authorID)/"
        guard let url = URL(string: urlStr) else { return ([], 0) }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let html = String(data: data, encoding: .utf8) else { return ([], 0) }

        // 提取 songs: {...}
        guard let songsRange = html.range(of: "songs: {") else { return ([], 0) }
        let jsonStart = html[songsRange.upperBound...].firstIndex(of: "{") ?? songsRange.upperBound
        var depth = 0
        var jsonEnd = jsonStart
        for idx in jsonStart..<html.endIndex {
            let char = html[idx]
            if char == "{" { depth += 1 }
            else if char == "}" {
                depth -= 1
                if depth == 0 {
                    jsonEnd = html.index(after: idx)
                    break
                }
            }
        }
        let jsonStr = String(html[jsonStart..<jsonEnd])
        guard let jsonData = jsonStr.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let list = json["list"] as? [[String: Any]] else {
            return ([], 0)
        }
        let total = (json["total"] as? Int) ?? list.count

        let tracks = list.compactMap { item -> Track? in
            // hash 在 mvdata[0].hash
            guard let mvdata = item["mvdata"] as? [[String: Any]],
                  let firstMv = mvdata.first,
                  let hash = firstMv["hash"] as? String, !hash.isEmpty else { return nil }
            let name = (item["audio_name"] as? String) ?? ""
            let duration = (item["duration"] as? Int) ?? 0
            let songID = abs(hash.hashValue)
            // 歌手：authors[].base.author_name
            var singerNames: [String] = []
            if let authors = item["authors"] as? [[String: Any]] {
                for author in authors {
                    if let base = author["base"] as? [String: Any],
                       let aname = base["author_name"] as? String, !aname.isEmpty {
                        singerNames.append(aname)
                    }
                }
            }
            if singerNames.isEmpty, let aname = item["author_name"] as? String {
                singerNames = splitArtistsNames(aname)
            }
            let artists = singerNames.enumerated().map { (idx, name) -> ArtistRef in
                let aid = (idx == 0) ? (Int(authorID) ?? abs(name.hashValue)) : abs(name.hashValue)
                return ArtistRef(id: aid, name: name, singerMid: String(aid))
            }
            let albumName = (item["album_name"] as? String) ?? ""
            let albumID = (item["album_id"] as? Int) ?? 0
            let albumAblumID = (item["album_audio_id"] as? String) ?? ""
            // 封面
            var picUrl: String? = nil
            if let cover = item["cover"] as? String, !cover.isEmpty {
                var normalized = cover.replacingOccurrences(of: "{size}", with: "400")
                if normalized.hasPrefix("//") { normalized = "https:" + normalized }
                normalized = normalized.replacingOccurrences(of: "http://", with: "https://")
                picUrl = normalized
            }
            if picUrl == nil, !albumAblumID.isEmpty {
                picUrl = "https://imgessl.kugou.com/ymm/400/\(albumAblumID).jpg"
            }
            if picUrl == nil {
                picUrl = "https://imgessl.kugou.com/stdmusic/400/\(hash).jpg"
            }
            let album = AlbumRef(id: albumID, name: albumName, picUrl: picUrl, albumMid: albumAblumID)
            return makeTrack(id: songID, name: name, artists: artists, album: album, durationMS: duration, hash: hash)
        }
        return (Array(tracks.prefix(limit)), total)
    }

    // MARK: - 歌手专辑
    static func artistAlbums(authorID: String, page: Int = 1, limit: Int = 20) async throws -> (albums: [AlbumSummary], total: Int) {
        // 非数字 authorID（歌手名）：用搜索方式获取该歌手的专辑
        if Int(authorID) == nil {
            let allSongs = try await searchSongs(authorID, page: 1, limit: 50)
            let filtered = allSongs.filter { track in
                track.artists.contains { $0.name.lowercased() == authorID.lowercased() }
            }
            let songs = filtered.isEmpty ? allSongs : filtered
            var seen = Set<String>()
            var albums: [AlbumSummary] = []
            for song in songs {
                let key = song.album.name
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                if let album = makeAlbum(id: song.album.id, name: song.album.name, picUrl: song.album.picUrl, artistName: authorID, albumID: song.album.albumMid ?? String(song.album.id)) {
                    albums.append(album)
                }
                if albums.count >= limit { break }
            }
            return (albums, albums.count)
        }
        // mobilecdn API 已失效，从歌手页面歌曲数据中提取专辑
        let (tracks, _) = try await artistSongs(authorID: authorID, page: 1, limit: 50)
        var seen = Set<String>()
        var albums: [AlbumSummary] = []
        for song in tracks {
            let key = song.album.name
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            if let album = makeAlbum(id: song.album.id, name: song.album.name, picUrl: song.album.picUrl, artistName: "", albumID: song.album.albumMid ?? String(song.album.id)) {
                albums.append(album)
            }
            if albums.count >= limit { break }
        }
        return (albums, albums.count)
    }

    // MARK: - 专辑歌曲
    static func albumInfo(albumID: String) async throws -> [Track] {
        let urlStr = "https://mobilecdn.kugou.com/api/v3/album/song?format=json&albumid=\(albumID)&page=1&pagesize=100"
        guard let url = URL(string: urlStr) else { return [] }

        let json = try await getJSON(url)
        guard let data = json["data"] as? [String: Any],
              let info = data["info"] as? [[String: Any]] else {
            return []
        }

        return info.compactMap { item -> Track? in
            let hash = (item["hash"] as? String) ?? ""
            guard !hash.isEmpty else { return nil }
            let name = (item["songname"] as? String) ?? ""
            let duration = (item["duration"] as? Int) ?? 0
            let songID = (item["songid"] as? Int) ?? abs(hash.hashValue)
            let singerName = (item["singername"] as? String) ?? ""
            let singerID = (item["singerid"] as? Int) ?? 0
            let artists = splitArtists(singerName, singerID: singerID)
            let albumName = (item["album_name"] as? String) ?? ""
            let albumAblumID = (item["album_audio_id"] as? String) ?? albumID
            // 封面：多级 fallback
            var picUrl: String? = nil
            let transParam = item["trans_param"] as? [String: Any]
            let imgCandidates = [
                item["Image"] as? String,
                item["image"] as? String,
                item["AlbumImage"] as? String,
                item["img"] as? String,
                item["imgurl"] as? String,
                transParam?["union_cover"] as? String,
                item["album_img"] as? String
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
            if picUrl == nil, !albumAblumID.isEmpty {
                picUrl = "https://imgessl.kugou.com/ymm/400/\(albumAblumID).jpg"
            }
            if picUrl == nil, !hash.isEmpty {
                picUrl = "https://imgessl.kugou.com/stdmusic/400/\(hash).jpg"
            }
            let album = AlbumRef(id: abs(albumID.hashValue), name: albumName, picUrl: picUrl, albumMid: albumAblumID)
            return makeTrack(id: songID, name: name, artists: artists, album: album, durationMS: duration * 1000, hash: hash)
        }
    }

    // MARK: - 评论

    struct KugouCommentPage {
        let comments: [SongComment]
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

    /// 酷狗评论（legacy 接口，无需签名）
    static func comments(hash: String, page: Int = 1, limit: Int = 30) async throws -> KugouCommentPage {
        let childrenID: String
        if let audioID = try await commentAudioID(hash: hash) {
            childrenID = audioID
        } else {
            childrenID = "\(abs(hash.hashValue))"
        }
        var components = URLComponents(string: "http://m.comment.service.kugou.com/index.php")!
        components.queryItems = [
            URLQueryItem(name: "r", value: "commentsv2/getCommentWithLike"),
            URLQueryItem(name: "childrenid", value: childrenID),
            URLQueryItem(name: "code", value: "fc4be23b4e972707f36b8a828a93ba8a"),
            URLQueryItem(name: "extdata", value: "0"),
            URLQueryItem(name: "p", value: "\(max(page, 1))"),
            URLQueryItem(name: "pagesize", value: "\(min(max(limit, 1), 30))"),
        ]
        guard let url = components.url else {
            throw NSError(domain: "KugouAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "URL 无效"])
        }
        let json = try await getJSON(url)
        return parseComments(json: json, page: page)
    }

    private static func parseComments(json: [String: Any], page: Int) -> KugouCommentPage {
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
        var seen = Set<Int>()
        let comments = rows.compactMap { raw -> SongComment? in
            let rawID = (raw["commentid"] as? String) ?? (raw["comment_id"] as? String) ?? ((raw["id"] as? Int).map { "\($0)" }) ?? ""
            let content = (raw["content"] as? String) ?? (raw["comment_content"] as? String) ?? ""
            guard !content.isEmpty else { return nil }
            let nickname = (raw["nick"] as? String) ?? (raw["nickname"] as? String) ?? (raw["username"] as? String) ?? "酷狗用户"
            let avatar = (raw["avatarurl"] as? String) ?? (raw["avatar_url"] as? String) ?? (raw["avatar"] as? String) ?? ""
            let timestamp: Double
            if let addtime = raw["addtime"] as? Double {
                timestamp = addtime
            } else if let addtime = raw["addtime"] as? Int {
                timestamp = Double(addtime)
            } else if let time = raw["time"] as? Double {
                timestamp = time
            } else {
                timestamp = 0
            }
            let seconds = timestamp > 10_000_000_000 ? timestamp / 1000 : timestamp
            let id = rawID.isEmpty ? abs(content.hashValue) : abs(rawID.hashValue)
            guard seen.insert(id).inserted else { return nil }
            let likedCount = (raw["praisenum"] as? Int) ?? (raw["like_count"] as? Int) ?? 0
            return SongComment(
                id: id,
                content: content,
                nickname: nickname.isEmpty ? "酷狗用户" : nickname,
                avatarURL: avatar.isEmpty ? nil : avatar,
                time: seconds > 0 ? Date(timeIntervalSince1970: seconds) : Date(),
                likedCount: likedCount,
                isHot: page == 1
            )
        }
        let total = (json["total"] as? Int) ?? ((json["data"] as? [String: Any])?["total"] as? Int) ?? comments.count
        return KugouCommentPage(comments: comments, total: total)
    }
}

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
        // 主接口：mobilecdn v3 search
        if let songs = try? await searchSongsV3(query, page: page, limit: limit), !songs.isEmpty {
            return songs
        }
        // 兜底：songsearch_v2
        return await searchSongsLegacy(query, page: page, limit: limit)
    }

    private static func searchSongsV3(_ query: String, page: Int, limit: Int) async throws -> [Track] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlStr = "https://mobilecdn.kugou.com/api/v3/search/song?format=json&keyword=\(encoded)&page=\(page)&pagesize=\(limit)&showtype=1"
        guard let url = URL(string: urlStr) else { return [] }

        let json = try await getJSON(url)
        guard let data = json["data"] as? [String: Any],
              let info = data["info"] as? [[String: Any]] else {
            return []
        }

        return info.compactMap { item -> Track? in
            let hash = (item["hash"] as? String) ?? ""
            guard !hash.isEmpty else { return nil }

            let name = (item["songname"] as? String) ?? (item["SongName"] as? String) ?? ""
            let duration = (item["duration"] as? Int) ?? 0
            let songID = (item["songid"] as? Int) ?? abs(hash.hashValue)

            // 歌手
            let singerName = (item["singername"] as? String) ?? (item["SingerName"] as? String) ?? ""
            let singerID = (item["singerid"] as? Int) ?? 0
            let artists: [ArtistRef] = singerName.isEmpty ? [] : [ArtistRef(id: singerID, name: singerName, singerMid: String(singerID))]

            // 专辑
            let albumName = (item["album_name"] as? String) ?? (item["AlbumName"] as? String) ?? ""
            let albumID = (item["album_id"] as? Int) ?? 0
            let albumAblumID = (item["album_audio_id"] as? String) ?? ""
            // 酷狗封面：用 album_id 构造，或从 img 字段
            var picUrl: String? = nil
            if let img = item["img"] as? String, !img.isEmpty {
                picUrl = img.replacingOccurrences(of: "{size}", with: "400")
            } else if albumID > 0 {
                picUrl = "https://imgessl.kugou.com/ymm/\(albumID).jpg"
            }
            let album = AlbumRef(id: albumID, name: albumName, picUrl: picUrl, albumMid: albumAblumID)

            // 脏标
            let isExplicit = (item["is_copyright"] as? Int) == 1 || (item["remark"] as? String)?.contains("explicit") == true

            return makeTrack(id: songID, name: name, artists: artists, album: album, durationMS: duration * 1000, hash: hash, isExplicit: isExplicit)
        }
    }

    private static func searchSongsLegacy(_ query: String, page: Int, limit: Int) async -> [Track] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlStr = "https://songsearch.kugou.com/song_search_v2?keyword=\(encoded)&page=\(page)&pagesize=\(limit)&platform=WebFilter"
        guard let url = URL(string: urlStr) else { return [] }

        guard let json = try? await getJSON(url, headers: ["User-Agent": browserUA, "Referer": "https://www.kugou.com/"]),
              let data = json["data"] as? [String: Any],
              let lists = data["lists"] as? [[String: Any]] else {
            return []
        }

        return lists.compactMap { item -> Track? in
            let hash = (item["FileHash"] as? String) ?? ""
            guard !hash.isEmpty else { return nil }

            let name = (item["SongName"] as? String) ?? ""
            let duration = (item["Duration"] as? Int) ?? 0
            let songID = (item["SongID"] as? Int) ?? abs(hash.hashValue)

            let singerName = (item["SingerName"] as? String) ?? ""
            let artists: [ArtistRef] = singerName.isEmpty ? [] : [ArtistRef(id: abs(singerName.hashValue), name: singerName, singerMid: nil)]

            let albumName = (item["AlbumName"] as? String) ?? ""
            let albumID = (item["AlbumID"] as? String) ?? ""
            let picUrl = (item["Img"] as? String)?.replacingOccurrences(of: "{size}", with: "400")
            let album = AlbumRef(id: abs(albumID.hashValue), name: albumName, picUrl: picUrl, albumMid: albumID)

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
        let urlStr = "https://mobilecdn.kugou.com/api/v3/singer/song?format=json&singerid=\(authorID)&page=\(page)&pagesize=\(limit)"
        guard let url = URL(string: urlStr) else { return ([], 0) }

        let json = try await getJSON(url)
        guard let data = json["data"] as? [String: Any],
              let info = data["info"] as? [[String: Any]] else {
            return ([], 0)
        }

        let total = (data["total"] as? Int) ?? info.count
        let tracks = info.compactMap { item -> Track? in
            let hash = (item["hash"] as? String) ?? ""
            guard !hash.isEmpty else { return nil }
            let name = (item["songname"] as? String) ?? ""
            let duration = (item["duration"] as? Int) ?? 0
            let songID = (item["songid"] as? Int) ?? abs(hash.hashValue)
            let singerName = (item["singername"] as? String) ?? ""
            let artists: [ArtistRef] = singerName.isEmpty ? [] : [ArtistRef(id: abs(singerName.hashValue), name: singerName, singerMid: authorID)]
            let albumName = (item["album_name"] as? String) ?? ""
            let albumID = (item["album_id"] as? Int) ?? 0
            let album = AlbumRef(id: albumID, name: albumName, picUrl: nil, albumMid: nil)
            return makeTrack(id: songID, name: name, artists: artists, album: album, durationMS: duration * 1000, hash: hash)
        }
        return (tracks, total)
    }

    // MARK: - 歌手专辑
    static func artistAlbums(authorID: String, page: Int = 1, limit: Int = 20) async throws -> (albums: [AlbumSummary], total: Int) {
        let urlStr = "https://mobilecdn.kugou.com/api/v3/singer/album?format=json&singerid=\(authorID)&page=\(page)&pagesize=\(limit)"
        guard let url = URL(string: urlStr) else { return ([], 0) }

        let json = try await getJSON(url)
        guard let data = json["data"] as? [String: Any],
              let info = data["info"] as? [[String: Any]] else {
            return ([], 0)
        }

        let total = (data["total"] as? Int) ?? info.count
        let albums = info.compactMap { item -> AlbumSummary? in
            let albumID = (item["album_id"] as? String) ?? (item["albumid"] as? String) ?? ""
            let name = (item["album_name"] as? String) ?? ""
            guard !name.isEmpty else { return nil }
            let picUrl = (item["img"] as? String)?.replacingOccurrences(of: "{size}", with: "400")
            let id = abs(albumID.hashValue)
            return makeAlbum(id: id, name: name, picUrl: picUrl, artistName: "", albumID: albumID)
        }
        return (albums, total)
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
            let artists: [ArtistRef] = singerName.isEmpty ? [] : [ArtistRef(id: abs(singerName.hashValue), name: singerName, singerMid: nil)]
            let albumName = (item["album_name"] as? String) ?? ""
            let album = AlbumRef(id: abs(albumID.hashValue), name: albumName, picUrl: nil, albumMid: albumID)
            return makeTrack(id: songID, name: name, artists: artists, album: album, durationMS: duration * 1000, hash: hash)
        }
    }
}

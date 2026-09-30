import SwiftUI

struct PlaylistImportView: View {
    enum Platform: String, CaseIterable, Identifiable {
        case netease = "网易云"
        case qq = "QQ音乐"
        case kugou = "酷狗"
        var id: String { rawValue }
    }

    @State private var platform: Platform = .netease
    @State private var playlistURL = ""
    @State private var isLoading = false
    @State private var importedTracks: [Track] = []
    @State private var playlistName = ""
    @State private var errorMessage = ""
    @State private var showSuccess = false

    var body: some View {
        Form {
            Section("选择平台") {
                Picker("平台", selection: $platform) {
                    ForEach(Platform.allCases) { p in
                        Text(p.rawValue).tag(p)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("歌单链接") {
                TextField("粘贴歌单链接或输入歌单ID", text: $playlistURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    Task { await importPlaylist() }
                } label: {
                    HStack {
                        Spacer()
                        if isLoading {
                            ProgressView()
                        } else {
                            Text("解析并导入")
                                .foregroundStyle(.blue)
                        }
                        Spacer()
                    }
                }
                .disabled(playlistURL.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)
            }

            if !errorMessage.isEmpty {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            if !importedTracks.isEmpty {
                Section("已导入 \(importedTracks.count) 首到外部歌单") {
                    ForEach(Array(importedTracks.prefix(20).enumerated()), id: \.element.id) { idx, track in
                        HStack(spacing: 10) {
                            Text("\(idx + 1)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.name)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Text(track.artists.map { $0.name }.joined(separator: " / "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    if importedTracks.count > 20 {
                        Text("... 还有 \(importedTracks.count - 20) 首")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("说明") {
                Text("支持网易云、QQ音乐、酷狗歌单链接或ID。导入的歌曲会保存到本地收藏歌单，不依赖平台登录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("歌单导入")
        .alert("导入成功", isPresented: $showSuccess) {
            Button("好的", role: .cancel) {}
        } message: {
            Text("已成功导入 \(importedTracks.count) 首歌曲到收藏歌单")
        }
    }

    private func importPlaylist() async {
        isLoading = true
        errorMessage = ""
        importedTracks = []

        let input = playlistURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            errorMessage = "请输入歌单链接或ID"
            isLoading = false
            return
        }

        // 从链接中提取ID
        let playlistID = extractPlaylistID(from: input)

        do {
            switch platform {
            case .netease:
                try await importNeteasePlaylist(id: playlistID)
            case .qq:
                try await importQQPlaylist(id: playlistID)
            case .kugou:
                try await importKugouPlaylist(id: playlistID)
            }
        } catch {
            errorMessage = "导入失败：\(error.localizedDescription)"
        }

        isLoading = false
    }

    private func extractPlaylistID(from input: String) -> String {
        // 网易云：https://music.163.com/#/playlist?id=123456
        // QQ音乐：https://y.qq.com/n/ryqq/playlist/123456
        // 酷狗PC：https://www.kugou.com/yy/special/single/123456.html
        // 酷狗移动端：https://m.kugou.com/songlist/gcid_3z1a6y44pz2z0bd/
        let patterns = [
            "[?&]id=(\\d+)",
            "playlist/(\\d+)",
            "single/(\\d+)",
            "(gcid_[a-zA-Z0-9]+)"
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
               let range = Range(match.range(at: 1), in: input) {
                return String(input[range])
            }
        }
        // 纯数字ID
        if input.allSatisfy({ $0.isNumber }) {
            return input
        }
        // gcid 格式
        if input.hasPrefix("gcid_") {
            return input
        }
        return input
    }

    // MARK: - 网易云歌单导入
    private func importNeteasePlaylist(id: String) async throws {
        guard let playlistID = Int(id) else {
            errorMessage = "无效的网易云歌单ID"
            return
        }

        // 获取歌单详情（包含前部分歌曲）
        let response = try await NeteaseAPI.playlistDetail(id: playlistID)
        playlistName = response.playlist.name
        var tracks = response.playlist.tracks

        // 加载剩余歌曲
        let trackIds = response.playlist.trackIds.map { $0.id }
        if tracks.count < trackIds.count {
            let remaining = Array(trackIds.dropFirst(tracks.count))
            for chunk in stride(from: 0, to: remaining.count, by: 500) {
                let ids = Array(remaining.dropFirst(chunk).prefix(500))
                if let detail = try? await NeteaseAPI.songDetails(ids: ids) {
                    tracks += detail.songs
                }
            }
        }

        await MainActor.run {
            let coverURL = tracks.first?.album.picUrl
            _ = ExternalPlaylistStore.shared.addPlaylist(
                name: playlistName.isEmpty ? "导入的歌单" : playlistName,
                sourcePlatform: "wy",
                coverURL: coverURL,
                tracks: tracks
            )
            importedTracks = tracks
            showSuccess = true
        }
    }

    // MARK: - QQ音乐歌单导入
    private func importQQPlaylist(id: String) async throws {
        // QQ音乐歌单详情API
        let urlStr = "https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg?type=1&json=1&utf8=1&onlysong=0&disstid=\(id)&format=json"
        guard let url = URL(string: urlStr) else {
            errorMessage = "无效的QQ音乐歌单ID"
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cdlist = json["cdlist"] as? [[String: Any]],
              let cd = cdlist.first,
              let songList = cd["songlist"] as? [[String: Any]] else {
            errorMessage = "解析QQ音乐歌单失败"
            return
        }

        playlistName = (cd["dissname"] as? String) ?? ""

        var tracks: [Track] = []
        for item in songList.prefix(500) {
            guard let songmid = item["songmid"] as? String, !songmid.isEmpty else { continue }
            let songid = (item["songid"] as? Int) ?? abs(songmid.hashValue)
            let name = (item["songname"] as? String) ?? ""
            let interval = (item["interval"] as? Int) ?? 0

            var artists: [ArtistRef] = []
            if let singerList = item["singer"] as? [[String: Any]] {
                artists = singerList.map { s in
                    let sid = (s["id"] as? Int) ?? 0
                    let sname = (s["name"] as? String) ?? ""
                    let smid = (s["mid"] as? String) ?? ""
                    return ArtistRef(id: sid > 0 ? sid : abs(smid.hashValue), name: sname, singerMid: smid.isEmpty ? nil : smid)
                }
            }

            let albumName = (item["albumname"] as? String) ?? ""
            let albumMid = (item["albummid"] as? String) ?? ""
            let albumID = (item["albumid"] as? Int) ?? 0
            let picUrl = albumMid.isEmpty ? nil : "https://y.gtimg.cn/music/photo_new/T002R800x800M000\(albumMid).jpg"
            let album = AlbumRef(id: albumID, name: albumName, picUrl: picUrl, albumMid: albumMid)

            let dict: [String: Any] = [
                "id": songid, "name": name,
                "ar": artists.map { ["id": $0.id, "name": $0.name, "singerMid": $0.singerMid ?? ""] },
                "al": ["id": album.id, "name": album.name, "picUrl": album.picUrl ?? "", "albumMid": album.albumMid ?? ""],
                "dt": interval * 1000, "alia": [], "tns": [], "fee": 0, "mv": 0, "no": 0,
                "sourcePlatform": "tx", "platformSongId": songmid
            ]
            if let data = try? JSONSerialization.data(withJSONObject: dict),
               let track = try? JSONDecoder().decode(Track.self, from: data) {
                tracks.append(track)
            }
        }

        await MainActor.run {
            let coverURL = tracks.first?.album.picUrl
            _ = ExternalPlaylistStore.shared.addPlaylist(
                name: playlistName.isEmpty ? "导入的QQ音乐歌单" : playlistName,
                sourcePlatform: "tx",
                coverURL: coverURL,
                tracks: tracks
            )
            importedTracks = tracks
            showSuccess = true
        }
    }

    // MARK: - 酷狗歌单导入
    private func importKugouPlaylist(id: String) async throws {
        var tracks: [Track] = []
        var name = ""
        var coverURL: String?

        if id.hasPrefix("gcid_") {
            // 酷狗移动端歌单：解析网页内嵌的 window.$output JSON
            let urlStr = "https://m.kugou.com/songlist/\(id)/"
            guard let url = URL(string: urlStr) else {
                errorMessage = "无效的酷狗歌单链接"
                return
            }
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let html = String(data: data, encoding: .utf8) else {
                errorMessage = "解析酷狗歌单失败"
                return
            }
            // 提取 window.$output = {...};
            guard let startRange = html.range(of: "window.$output = ") else {
                errorMessage = "解析酷狗歌单失败"
                return
            }
            // 从第一个 { 开始，用括号匹配找到对应的 }
            let jsonStart = html[startRange.upperBound...].firstIndex(of: "{") ?? startRange.upperBound
            var depth = 0
            var jsonEnd = jsonStart
            var idx = jsonStart
            while idx < html.endIndex {
                let char = html[idx]
                if char == "{" { depth += 1 }
                else if char == "}" {
                    depth -= 1
                    if depth == 0 {
                        jsonEnd = html.index(after: idx)
                        break
                    }
                }
                idx = html.index(after: idx)
            }
            let jsonStr = String(html[jsonStart..<jsonEnd])
            guard let jsonData = jsonStr.data(using: .utf8),
                  let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let info = json["info"] as? [String: Any],
                  let listinfo = info["listinfo"] as? [String: Any],
                  let songs = json["songs"] as? [[String: Any]] else {
                errorMessage = "解析酷狗歌单失败"
                return
            }
            name = (listinfo["name"] as? String) ?? ""
            if let pic = listinfo["pic"] as? String {
                coverURL = pic.replacingOccurrences(of: "{size}", with: "400")
            }
            for item in songs {
                let hash = (item["hash"] as? String) ?? ""
                guard !hash.isEmpty else { continue }
                let songName = (item["name"] as? String) ?? ""
                let duration = ((item["timelen"] as? Int) ?? 0) / 1000
                let songID = (item["audio_id"] as? Int) ?? abs(hash.hashValue)

                var singerNames: [String] = []
                if let singerinfo = item["singerinfo"] as? [[String: Any]] {
                    singerNames = singerinfo.compactMap { $0["name"] as? String }
                }
                let singerName = singerNames.joined(separator: "、")
                let artists: [ArtistRef] = singerNames.isEmpty ? [] : singerNames.enumerated().map { idx, name in
                    ArtistRef(id: abs(name.hashValue) + idx, name: name, singerMid: idx == 0 ? nil : name)
                }

                let albumName = ((item["albuminfo"] as? [String: Any])?["name"] as? String) ?? ""
                let albumID = ((item["albuminfo"] as? [String: Any])?["id"] as? Int) ?? 0
                var albumPic: String?
                if let cover = item["cover"] as? String {
                    albumPic = cover.replacingOccurrences(of: "{size}", with: "400")
                }
                let album = AlbumRef(id: albumID, name: albumName, picUrl: albumPic, albumMid: nil)

                let dict: [String: Any] = [
                    "id": songID, "name": songName,
                    "ar": artists.map { ["id": $0.id, "name": $0.name, "singerMid": $0.singerMid ?? ""] },
                    "al": ["id": album.id, "name": album.name, "picUrl": album.picUrl ?? "", "albumMid": ""],
                    "dt": duration * 1000, "alia": [], "tns": [], "fee": 0, "mv": 0, "no": 0,
                    "sourcePlatform": "kg", "platformSongId": hash
                ]
                if let data = try? JSONSerialization.data(withJSONObject: dict),
                   let track = try? JSONDecoder().decode(Track.self, from: data) {
                    tracks.append(track)
                }
            }
        } else {
            // 酷狗PC歌单：数字 specialid
            let urlStr = "https://mobilecdn.kugou.com/api/v3/special/song?format=json&specialid=\(id)&page=1&pagesize=500"
            guard let url = URL(string: urlStr) else {
                errorMessage = "无效的酷狗歌单ID"
                return
            }
            let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url))
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any],
                  let list = result["list"] as? [[String: Any]] else {
                errorMessage = "解析酷狗歌单失败"
                return
            }
            for item in list {
                let hash = (item["hash"] as? String) ?? ""
                guard !hash.isEmpty else { continue }
                let songName = (item["songname"] as? String) ?? ""
                let duration = (item["duration"] as? Int) ?? 0
                let songID = (item["songid"] as? Int) ?? abs(hash.hashValue)
                let singerName = (item["singername"] as? String) ?? ""
                let artists: [ArtistRef] = singerName.isEmpty ? [] : [ArtistRef(id: abs(singerName.hashValue), name: singerName, singerMid: nil)]
                let albumName = (item["album_name"] as? String) ?? ""
                let albumID = (item["album_id"] as? Int) ?? 0
                let album = AlbumRef(id: albumID, name: albumName, picUrl: nil, albumMid: nil)
                let dict: [String: Any] = [
                    "id": songID, "name": songName,
                    "ar": artists.map { ["id": $0.id, "name": $0.name, "singerMid": $0.singerMid ?? ""] },
                    "al": ["id": album.id, "name": album.name, "picUrl": "", "albumMid": ""],
                    "dt": duration * 1000, "alia": [], "tns": [], "fee": 0, "mv": 0, "no": 0,
                    "sourcePlatform": "kg", "platformSongId": hash
                ]
                if let data = try? JSONSerialization.data(withJSONObject: dict),
                   let track = try? JSONDecoder().decode(Track.self, from: data) {
                    tracks.append(track)
                }
            }
        }

        await MainActor.run {
            _ = ExternalPlaylistStore.shared.addPlaylist(
                name: name.isEmpty ? "导入的酷狗歌单" : name,
                sourcePlatform: "kg",
                coverURL: coverURL,
                tracks: tracks
            )
            importedTracks = tracks
            showSuccess = true
        }
    }
}

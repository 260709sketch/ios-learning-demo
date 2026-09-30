import SwiftUI

// MARK: - 日期格式化

private func commentDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
}

private func formattedCount(_ count: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.groupingSeparator = ","
    return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
}

// MARK: - 评论区（Beans Music 风格半屏 sheet）

struct CommentsView: View {
    let track: Track

    @Environment(\.dismiss) private var dismiss

    @State private var hotComments: [SongComment] = []
    @State private var latestComments: [SongComment] = []
    @State private var total = 0
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var selectedSegment = 0 // 0=热门, 1=最新
    @State private var latestPage = 1

    private let limit = 30

    private var isQQ: Bool { track.sourcePlatform == "tx" }
    private var isKugou: Bool { track.sourcePlatform == "kg" }

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Spacer()
                Text("评论")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.black)
                Spacer()
            }
            .overlay(alignment: .trailing) {
                Button("完成") {
                    dismiss()
                }
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(.blue)
                .padding(.trailing, 16)
            }
            .padding(.top, 12)
            .padding(.bottom, 12)

            // 分段控制
            Picker("", selection: $selectedSegment) {
                Text("热门评论").tag(0)
                Text("最新评论").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            // 评论列表
            Group {
                if loading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    VStack(spacing: 12) {
                        Text(errorMessage)
                            .foregroundStyle(.secondary)
                        Button("重试") {
                            Task { await load() }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    let list = selectedSegment == 0 ? hotComments : latestComments
                    if list.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "bubble.left")
                                .font(.system(size: 40))
                                .foregroundStyle(.secondary)
                            Text("暂无评论")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(list) { comment in
                                    CommentRow(comment: comment)
                                    Divider()
                                        .padding(.leading, 16)
                                }
                                if selectedSegment == 1 && latestComments.count >= limit {
                                    Button("加载更多") {
                                        Task { await loadMoreLatest() }
                                    }
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.blue)
                                    .padding(.vertical, 16)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.white)
        .task { await load() }
    }

    private func load() async {
        loading = true
        errorMessage = nil
        latestPage = 1
        do {
            if isKugou, let hash = track.platformSongId {
                let result = try await KugouAPI.comments(hash: hash, page: 1, limit: limit)
                hotComments = result.comments
                latestComments = result.comments
                total = result.total
            } else if isQQ {
                let result = try await QQMusicAPI.comments(songID: track.id, limit: limit, pagenum: 0)
                hotComments = result.comments
                latestComments = result.comments
                total = result.total
            } else {
                let result = try await NeteaseAPI.songComments(id: track.id, limit: limit, offset: 0)
                hotComments = result.hotComments ?? []
                latestComments = result.comments ?? []
                total = result.total
            }
            loading = false
        } catch {
            errorMessage = error.localizedDescription
            loading = false
        }
    }

    private func loadMoreLatest() async {
        latestPage += 1
        do {
            if isKugou, let hash = track.platformSongId {
                let result = try await KugouAPI.comments(hash: hash, page: latestPage, limit: limit)
                latestComments.append(contentsOf: result.comments)
            } else if isQQ {
                let result = try await QQMusicAPI.comments(songID: track.id, limit: limit, pagenum: latestPage - 1)
                latestComments.append(contentsOf: result.comments)
            } else {
                let result = try await NeteaseAPI.songComments(id: track.id, limit: limit, offset: (latestPage - 1) * limit)
                latestComments.append(contentsOf: result.comments ?? [])
            }
        } catch {
            // 静默失败
        }
    }
}

// MARK: - 评论行（Beans 风格：无头像，用户名+日期+赞数同一行）

struct CommentRow: View {
    let comment: SongComment

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // 头像
            Group {
                if let avatarURL = comment.avatarURL, let url = URL(string: avatarURL) {
                    AsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Circle().fill(Color.gray.opacity(0.2))
                    }
                    .frame(width: 36, height: 36)
                    .clipShape(Circle())
                } else {
                    Circle()
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 36, height: 36)
                        .overlay {
                            Image(systemName: "person.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.gray)
                        }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(comment.nickname)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.black)
                        .lineLimit(1)
                    Text(commentDate(comment.time))
                        .font(.system(size: 12))
                        .foregroundStyle(.gray)
                    Spacer()
                    Text("\(formattedCount(comment.likedCount)) 赞")
                        .font(.system(size: 12))
                        .foregroundStyle(.gray)
                }
                Text(comment.content)
                    .font(.system(size: 15))
                    .foregroundStyle(.black)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

import SwiftUI

// MARK: - 相对时间

func relativeTime(_ date: Date) -> String {
    let interval = Date().timeIntervalSince(date)
    if interval < 60 { return "刚刚" }
    if interval < 3600 { return "\(Int(interval / 60)) 分钟前" }
    if interval < 86400 { return "\(Int(interval / 3600)) 小时前" }
    if interval < 86400 * 30 { return "\(Int(interval / 86400)) 天前" }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

// MARK: - 评论区（Beans Music 风格半屏 sheet）

struct CommentsView: View {
    let track: Track

    @State private var neteasePage: NeteaseAPI.SongCommentResponse?
    @State private var qqComments: [SongComment] = []
    @State private var qqTotal = 0
    @State private var qqPageNum = 0
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var offset = 0

    private let limit = 30
    private let qqPageSize = 25

    var body: some View {
        ZStack {
            // 毛玻璃背景（不是透明）
            LinearGradient(
                colors: [Color(red: 0.12, green: 0.12, blue: 0.14), Color(red: 0.08, green: 0.08, blue: 0.10)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            NavigationStack {
                Group {
                    if loading {
                        ProgressView("加载评论中...")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let errorMessage {
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 40))
                                .foregroundStyle(.secondary)
                            Text(errorMessage)
                                .foregroundStyle(.secondary)
                            Button("重试") {
                                Task { await load(reset: true) }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if track.sourcePlatform == "tx" {
                        qqCommentList
                    } else if let page = neteasePage {
                        if (page.hotComments ?? []).isEmpty && (page.comments ?? []).isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "bubble.left")
                                    .font(.system(size: 40))
                                    .foregroundStyle(.secondary)
                                Text("暂无评论")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            neteaseCommentList(page)
                        }
                    }
                }
                .navigationTitle("评论")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task { await load(reset: true) }
    }

    private func neteaseCommentList(_ page: NeteaseAPI.SongCommentResponse) -> some View {
        List {
            Section {
                Text("《\(track.name)》 · 共 \(page.total) 条评论")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)

            if let hot = page.hotComments, !hot.isEmpty {
                Section("精彩评论") {
                    ForEach(hot) { comment in
                        CommentRow(comment: comment)
                            .listRowBackground(Color.clear)
                    }
                }
            }

            if let comments = page.comments, !comments.isEmpty {
                Section("最新评论") {
                    ForEach(comments) { comment in
                        CommentRow(comment: comment)
                            .listRowBackground(Color.clear)
                    }
                }
            }

            if (page.comments ?? []).count >= limit {
                Section {
                    Button {
                        Task { await loadMore() }
                    } label: {
                        Text("加载更多")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity)
                    }
                }
                .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var qqCommentList: some View {
        Group {
            if qqComments.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("暂无评论")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        Text("《\(track.name)》 · QQ音乐 \(qqTotal > 0 ? qqTotal : qqComments.count) 条评论")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color.clear)

                    Section("评论") {
                        ForEach(qqComments) { comment in
                            CommentRow(comment: comment)
                                .listRowBackground(Color.clear)
                        }
                    }

                    if qqTotal <= 0 || qqComments.count < qqTotal {
                        Section {
                            Button {
                                Task { await loadQQMore() }
                            } label: {
                                Text("加载更多")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.orange)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .listRowBackground(Color.clear)
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func load(reset: Bool) async {
        if reset {
            offset = 0
            neteasePage = nil
            qqComments = []
            qqTotal = 0
            qqPageNum = 0
            loading = true
        }
        errorMessage = nil
        do {
            if track.sourcePlatform == "tx", let songmid = track.platformSongId {
                let result = try await QQMusicAPI.comments(songID: songmid, limit: qqPageSize, pagenum: qqPageNum)
                if reset {
                    qqComments = result.comments
                } else {
                    qqComments.append(contentsOf: result.comments)
                }
                qqTotal = result.total
            } else {
                let result = try await NeteaseAPI.songComments(id: track.id, limit: limit, offset: offset)
                if reset {
                    neteasePage = result
                } else if var current = neteasePage {
                    current.comments?.append(contentsOf: result.comments ?? [])
                    neteasePage = current
                }
            }
            loading = false
        } catch {
            errorMessage = error.localizedDescription
            loading = false
        }
    }

    private func loadMore() async {
        offset += limit
        await load(reset: false)
    }

    private func loadQQMore() async {
        qqPageNum += 1
        await load(reset: false)
    }
}

// MARK: - 评论行

struct CommentRow: View {
    let comment: SongComment

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: comment.avatarURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(comment.nickname)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if comment.isHot {
                        Text("热评")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(LinearGradient(colors: [.orange, .red], startPoint: .leading, endPoint: .trailing), in: Capsule())
                    }
                    Spacer()
                    Text(relativeTime(comment.time))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary.opacity(0.8))
                }
                Text(comment.content)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Label("\(comment.likedCount)", systemImage: "heart")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .labelStyle(.trailingIcon)
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }
}

// 图标在文字后面
extension LabelStyle where Self == TrailingIconLabelStyle {
    static var trailingIcon: TrailingIconLabelStyle { TrailingIconLabelStyle() }
}

struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon
        }
    }
}

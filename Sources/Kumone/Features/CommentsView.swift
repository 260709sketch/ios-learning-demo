import SwiftUI

/// 歌曲评论页面（Beans Music / Apple Music 播放器风格半屏 sheet）。
/// 调用方通过 `.sheet(isPresented:)` 展示，并设置
/// `.presentationDetents([.medium, .large])` 与 `.presentationBackground(.clear)`。
struct CommentsView: View {
    let track: Track

    /// 评论数据源平台
    enum CommentSource: String, CaseIterable {
        case netease
        case qq

        var title: String {
            switch self {
            case .netease: return "网易云"
            case .qq: return "QQ音乐"
            }
        }
    }

    @State private var source: CommentSource
    @State private var hotComments: [SongComment] = []
    @State private var comments: [SongComment] = []
    @State private var total: Int = 0
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var hasMore = false
    @State private var errorMessage: String?
    /// 网易云分页偏移
    @State private var offset = 0
    /// QQ 音乐分页页码
    @State private var page = 0

    private let neteaseLimit = 30
    private let qqLimit = 25

    init(track: Track) {
        self.track = track
        // 默认选中与曲目来源一致的平台
        let isQQ = track.sourcePlatform == "tx"
        _source = State(initialValue: isQQ ? .qq : .netease)
    }

    /// 展示用评论：网易云热评置顶并打上热评标记；QQ 接口已合并好顺序。
    private var displayedComments: [SongComment] {
        let hot = hotComments.map { c in
            SongComment(id: c.id, content: c.content, nickname: c.nickname,
                        avatarURL: c.avatarURL, time: c.time,
                        likedCount: c.likedCount, isHot: true)
        }
        return hot + comments
    }

    private var currentLimit: Int {
        switch source {
        case .netease: return neteaseLimit
        case .qq: return qqLimit
        }
    }

    var body: some View {
        ZStack {
            // 毛玻璃背景（调用方已将 sheet 背景设为 clear）
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                grabber
                header
                content
            }
        }
        .task(id: source) { await load(reset: true) }
    }

    // MARK: - 顶部拖动指示条

    private var grabber: some View {
        Capsule()
            .fill(Color.white.opacity(0.38))
            .frame(width: 44, height: 5)
            .padding(.top, 8)
            .padding(.bottom, 6)
    }

    // MARK: - 标题栏 + 平台切换

    private var header: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("评论")
                    .font(.system(size: 17, weight: .bold))
                if total > 0 {
                    Text("\(total)")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Picker("平台", selection: $source) {
                ForEach(CommentSource.allCases, id: \.self) { s in
                    Text(s.title).tag(s)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    // MARK: - 内容区

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            errorView(message: errorMessage)
        } else if displayedComments.isEmpty {
            emptyView
        } else {
            commentList
        }
    }

    private var commentList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(displayedComments) { comment in
                    CommentRow(comment: comment)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }

                if hasMore {
                    Button {
                        Task { await loadMore() }
                    } label: {
                        HStack(spacing: 6) {
                            if isLoadingMore {
                                ProgressView()
                            } else {
                                Text("加载更多")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoadingMore)
                }
            }
            .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("暂无评论")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await load(reset: true) }
            } label: {
                Text("重试")
                    .font(.system(size: 14, weight: .medium))
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 数据加载

    private func load(reset: Bool) async {
        if reset {
            offset = 0
            page = 0
            hasMore = false
        }
        isLoading = reset
        isLoadingMore = !reset
        errorMessage = nil

        do {
            let batch: [SongComment]
            let newTotal: Int
            let newHot: [SongComment]?
            switch source {
            case .netease:
                let resp = try await NeteaseAPI.songComments(id: track.id,
                                                             limit: neteaseLimit,
                                                             offset: offset)
                batch = resp.comments ?? []
                newTotal = resp.total
                newHot = resp.hotComments
            case .qq:
                let resp = try await QQMusicAPI.comments(songID: track.id,
                                                         limit: qqLimit,
                                                         pagenum: page)
                batch = resp.comments
                newTotal = resp.total
                newHot = nil
            }
            await MainActor.run {
                total = newTotal
                if reset {
                    comments = batch
                    hotComments = newHot ?? []
                } else {
                    comments.append(contentsOf: batch)
                }
                hasMore = batch.count >= currentLimit
                isLoading = false
                isLoadingMore = false
            }
        } catch is CancellationError {
            // 切换平台时旧任务被取消，不更新 UI（新任务会重置）
        } catch {
            // URLSession 在任务取消时会抛 URLError.cancelled，同样忽略
            if Task.isCancelled { return }
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
                isLoadingMore = false
            }
        }
    }

    private func loadMore() async {
        switch source {
        case .netease: offset += neteaseLimit
        case .qq: page += 1
        }
        await load(reset: false)
    }
}

// MARK: - 评论行

struct CommentRow: View {
    let comment: SongComment

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            avatar

            VStack(alignment: .leading, spacing: 4) {
                // 第一行：用户名 + 热评标签 + 时间
                HStack(spacing: 6) {
                    Text(comment.nickname)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if comment.isHot {
                        Text("热评")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Theme.accentGradient, in: Capsule())
                    }

                    Spacer(minLength: 8)

                    Text(relativeTime(comment.time))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                // 第二行：评论内容
                Text(comment.content)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // 第三行：点赞数
                HStack {
                    Spacer()
                    HStack(spacing: 3) {
                        Text("\(comment.likedCount)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Image(systemName: "heart")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private var avatar: some View {
        if let raw = comment.avatarURL, let url = raw.resizedImageURL(72) {
            CachedAsyncImage(url: url, animated: false) {
                placeholderAvatar
            }
            .frame(width: 36, height: 36)
            .clipShape(Circle())
        } else {
            placeholderAvatar
                .frame(width: 36, height: 36)
        }
    }

    private var placeholderAvatar: some View {
        Image(systemName: "person.circle.fill")
            .font(.system(size: 36))
            .foregroundStyle(.tertiary)
    }

    private func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "刚刚" }
        if interval < 3600 { return "\(Int(interval / 60)) 分钟前" }
        if interval < 86400 { return "\(Int(interval / 3600)) 小时前" }
        if interval < 86400 * 30 { return "\(Int(interval / 86400)) 天前" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

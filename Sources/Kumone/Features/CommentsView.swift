import SwiftUI

/// 歌曲评论页面
struct CommentsView: View {
    let track: Track
    @State private var response: NeteaseAPI.SongCommentResponse?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var offset = 0
    @State private var isLoadingMore = false
    private let limit = 30

    var body: some View {
        Group {
            if isLoading {
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
            } else if let response {
                if (response.hotComments ?? []).isEmpty && (response.comments ?? []).isEmpty {
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
                            Text("《\(track.name)》 · 共 \(response.total) 条评论")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .listRowBackground(Color.clear)

                        if let hot = response.hotComments, !hot.isEmpty {
                            Section("精彩评论") {
                                ForEach(hot) { comment in
                                    CommentRow(comment: comment)
                                        .listRowBackground(Color.clear)
                                }
                            }
                        }

                        if let comments = response.comments, !comments.isEmpty {
                            Section("最新评论") {
                                ForEach(comments) { comment in
                                    CommentRow(comment: comment)
                                        .listRowBackground(Color.clear)
                                }
                            }

                            if comments.count >= limit {
                                Section {
                                    Button {
                                        Task { await loadMore() }
                                    } label: {
                                        HStack {
                                            Spacer()
                                            if isLoadingMore {
                                                ProgressView()
                                            } else {
                                                Text("加载更多")
                                                    .foregroundStyle(.blue)
                                            }
                                            Spacer()
                                        }
                                    }
                                    .disabled(isLoadingMore)
                                }
                                .listRowBackground(Color.clear)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
        }
        .navigationTitle("评论")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load(reset: true) }
    }

    private func load(reset: Bool) async {
        if reset {
            offset = 0
            response = nil
        }
        isLoading = reset
        isLoadingMore = !reset
        errorMessage = nil
        do {
            let newResponse = try await NeteaseAPI.songComments(id: track.id, limit: limit, offset: offset)
            await MainActor.run {
                if reset {
                    response = newResponse
                } else if var current = response {
                    var merged = current.comments ?? []
                    merged.append(contentsOf: newResponse.comments ?? [])
                    response = NeteaseAPI.SongCommentResponse(
                        total: newResponse.total,
                        hotComments: current.hotComments,
                        comments: merged
                    )
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
        isLoadingMore = false
    }

    private func loadMore() async {
        offset += limit
        await load(reset: false)
    }
}

// MARK: - 评论行

struct CommentRow: View {
    let comment: SongComment

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let avatar = comment.avatarURL, let url = URL(string: avatar) {
                CachedAsyncImage(url: url, animated: false) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 36, height: 36)
                .clipShape(Circle())
            } else {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(comment.nickname)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if comment.isHot {
                        Text("热评")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Theme.accentGradient, in: Capsule())
                    }
                    Spacer()
                    Text(relativeTime(comment.time))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary.opacity(0.8))
                }
                Text(comment.content)
                    .font(.system(size: 14))
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    HStack(spacing: 4) {
                        Text("\(comment.likedCount)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Image(systemName: "heart")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
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

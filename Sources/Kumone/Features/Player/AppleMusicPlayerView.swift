import SwiftUI

/// Apple Music 风格播放器：封面模糊背景 + 大封面 + 歌词页 + 底部控制栏
struct AppleMusicPlayerView: View {
    let onOpenDestination: (Destination) -> Void
    let onDismiss: () -> Void

    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var settings: SettingsManager
    @Environment(\.colorScheme) private var colorScheme

    @State private var showLyrics = false
    @State private var showQueue = false
    @State private var showMore = false
    @State private var isDraggingProgress = false
    @State private var dragProgress: Double = 0
    @State private var loadedArtwork: PlatformImage?

    private var currentTrack: Track? { player.currentTrack }
    private var isPlaying: Bool { player.isPlaying }
    private var currentTime: TimeInterval { player.progress }
    private var duration: TimeInterval { player.duration }
    private var lyrics: [LyricLine] { player.lyrics?.lines ?? [] }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // 背景：封面模糊
                background
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    // 顶部栏
                    topBar
                        .padding(.horizontal, 20)
                        .padding(.top, 16)

                    Spacer(minLength: 0)

                    // 封面 / 歌词
                    ZStack {
                        if showLyrics {
                            lyricsView
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        } else {
                            coverView(size: geo.size)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .animation(.easeInOut(duration: 0.25), value: showLyrics)

                    Spacer(minLength: 0)

                    // 底部控制
                    bottomControls(bottomInset: geo.safeAreaInsets.bottom)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear { loadArtwork() }
        .onChange(of: currentTrack?.id) { _ in loadArtwork() }
        .sheet(isPresented: $showQueue) {
            if #available(iOS 16.0, *) {
                QueueView()
                    .environmentObject(player)
                    .presentationDetents([.medium, .large])
            } else {
                QueueView().environmentObject(player)
            }
        }
    }

    // MARK: - 背景
    @ViewBuilder
    private var background: some View {
        ZStack {
            Color.black

            if let img = loadedArtwork {
                Image(platformImage: img)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 60)
                    .opacity(0.7)
            } else if let url = currentTrack?.album.picUrl, let imageURL = URL(string: url) {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill().blur(radius: 60).opacity(0.7)
                    default:
                        Color.black
                    }
                }
            }

            // 暗色遮罩
            LinearGradient(
                colors: [.black.opacity(0.3), .black.opacity(0.5), .black.opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private func loadArtwork() {
        guard let urlStr = currentTrack?.album.picUrl, let url = URL(string: urlStr) else {
            loadedArtwork = nil
            return
        }
        Task {
            if let (data, _) = try? await URLSession.shared.data(from: url),
               let img = PlatformImage(data: data) {
                await MainActor.run { loadedArtwork = img }
            }
        }
    }

    // MARK: - 顶部栏
    private var topBar: some View {
        HStack {
            Button {
                onDismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.15), in: Circle())
            }
            .buttonStyle(.pressable)

            Spacer()

            VStack(spacing: 2) {
                Text("正在播放")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                Text(currentTrack?.name ?? "未播放")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
            }

            Spacer()

            Button {
                showMore.toggle()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.15), in: Circle())
            }
            .buttonStyle(.pressable)
            .confirmationDialog("更多操作", isPresented: $showMore, titleVisibility: .visible) {
                Button("播放队列") { showQueue = true }
                Button("收藏歌曲") {
                    if let track = currentTrack {
                        Task { await AccountStore.shared.toggleLike(trackID: track.id, track: track) }
                    }
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    // MARK: - 封面
    private func coverView(size: CGSize) -> some View {
        VStack(spacing: 20) {
            let coverSize = min(size.width - 80, size.height * 0.42)
            ZStack {
                if let img = loadedArtwork {
                    Image(platformImage: img)
                        .resizable()
                        .scaledToFill()
                } else if let url = currentTrack?.album.picUrl, let imageURL = URL(string: url) {
                    AsyncImage(url: imageURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            Rectangle().fill(Color.gray.opacity(0.3))
                        }
                    }
                } else {
                    Rectangle().fill(Color.gray.opacity(0.3))
                }
            }
            .frame(width: coverSize, height: coverSize)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 10)

            VStack(spacing: 6) {
                Text(currentTrack?.name ?? "")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .multilineTextAlignment(.center)

                Text(currentTrack?.artists.map { $0.name }.joined(separator: " / ") ?? "")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 30)
        }
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.25)) {
                showLyrics = true
            }
        }
    }

    // MARK: - 歌词
    private var lyricsView: some View {
        VStack {
            if lyrics.isEmpty {
                Text("暂无歌词")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 24) {
                            ForEach(Array(lyrics.enumerated()), id: \.element.id) { index, line in
                                let isActive = player.lyricsCursor.activeIndex == index
                                Text(line.text)
                                    .font(.system(size: isActive ? 20 : 17, weight: isActive ? .bold : .medium))
                                    .foregroundStyle(isActive ? .white : .white.opacity(0.45))
                                    .multilineTextAlignment(.center)
                                    .id(line.id)
                                    .onTapGesture {
                                        player.seek(to: line.time)
                                    }
                            }
                        }
                        .padding(.horizontal, 30)
                        .padding(.top, 40)
                        .padding(.bottom, 40)
                    }
                    .onChange(of: player.lyricsCursor.activeIndex) { newIndex in
                        guard let idx = newIndex, idx >= 0, idx < lyrics.count else { return }
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(lyrics[idx].id, anchor: .center)
                        }
                    }
                }
            }
        }
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.25)) {
                showLyrics = false
            }
        }
    }

    // MARK: - 底部控制
    private func bottomControls(bottomInset: CGFloat) -> some View {
        VStack(spacing: 14) {
            // 进度条
            progressBar

            // 时间
            HStack {
                Text(formatTime(currentTime))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Text("-\(formatTime(max(0, duration - currentTime)))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }

            // 播放控制
            HStack(spacing: 40) {
                Button {
                    player.previous()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 28, weight: .regular))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.pressable)

                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 36, weight: .regular))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.pressable)

                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 28, weight: .regular))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.pressable)
            }

            // 音量 + 队列
            HStack(spacing: 20) {
                Image(systemName: "speaker.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))

                Slider(value: Binding(
                    get: { Double(player.volume) },
                    set: { player.volume = Float($0) }
                ), in: 0...1)
                .tint(.white.opacity(0.8))

                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))

                Button {
                    showQueue = true
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.pressable)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, bottomInset + 16)
    }

    // MARK: - 进度条
    private var progressBar: some View {
        GeometryReader { geo in
            let progress = duration > 0 ? min(1, max(0, currentTime / duration)) : 0
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.25))
                    .frame(height: 5)

                Capsule()
                    .fill(.white)
                    .frame(width: geo.size.width * progress, height: 5)

                Circle()
                    .fill(.white)
                    .frame(width: 14, height: 14)
                    .offset(x: geo.size.width * progress - 7)
                    .shadow(color: .black.opacity(0.3), radius: 4)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDraggingProgress = true
                        let p = min(1, max(0, Double(value.location.x / geo.size.width)))
                        dragProgress = p
                    }
                    .onEnded { value in
                        let p = min(1, max(0, Double(value.location.x / geo.size.width)))
                        player.seek(to: p * duration)
                        isDraggingProgress = false
                    }
            )
        }
        .frame(height: 20)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let m = Int(time) / 60
        let s = Int(time) % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - QueueView
private struct QueueView: View {
    @EnvironmentObject private var player: PlayerService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(player.queue.enumerated()), id: \.element.id) { index, track in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.name)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(index == player.currentIndex ? Theme.accent : .primary)
                            Text(track.artists.map { $0.name }.joined(separator: " / "))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if index == player.currentIndex {
                            Image(systemName: "speaker.wave.2.fill")
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        player.play(tracks: player.queue, source: .none, startAt: track)
                        dismiss()
                    }
                }
            }
            .navigationTitle("播放队列")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

import SwiftUI
import MediaPlayer
import UIKit

private struct ReferenceLyricCenterKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]

    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private struct ReferencePlaybackPresentationMetrics {
    static let headerTopSpacing: CGFloat = 20
}

/// Apple Music 风格全屏播放页：封面模糊背景 + 大封面/歌词页切换 + 底部控制栏。
/// 移植自 Beans Music 的 ReferencePlaybackView，数据接入当前项目的 PlayerService / Track / AccountStore。
struct AppleMusicPlayerView: View {
    let onOpenDestination: (Destination) -> Void
    let onDismiss: () -> Void

    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var settings: SettingsManager
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var account = AccountStore.shared
    @ObservedObject private var clock = PlayerService.shared.clock
    @ObservedObject private var appleLayout = AppleMusicLayoutStore.shared

    @State private var showLyrics = false
    @State private var showQueue = false
    @State private var showComments = false
    @State private var showAddToPlaylist = false
    @State private var showPlayerSettings = false
    @State private var layoutMode = false
    @State private var appleLayoutPart: AppleMusicLayoutPart = .cover
    @AppStorage("wellmusic.lyricOffset") private var lyricOffset = 0.0
    @AppStorage("wellmusic.appleMusic.showVolume") private var showVolumeControl = false
    @AppStorage("wellmusic.appleMusic.primaryHex") private var primaryHex = ""
    @AppStorage("wellmusic.appleMusic.secondaryHex") private var secondaryHex = ""
    @AppStorage("wellmusic.appleMusic.accentHex") private var accentHex = ""
    @AppStorage("wellmusic.appleMusic.volumeHex") private var volumeHex = ""
    @AppStorage("wellmusic.showSongVIPBadge") private var showSongVIPBadge = true
    @AppStorage("wellmusic.appleMusic.showLyricPreview") private var showLyricPreview = true
    @AppStorage("wellmusic.player.autoSkipOnFailure") private var autoSkipOnFailure = true
    @AppStorage("wellmusic.player.swipeSwitchSong") private var swipeSwitchSong = true
    @AppStorage("wellmusic.player.breath") private var breath = 0.6
    @AppStorage("wellmusic.player.progressBarStyle") private var progressBarStyle = 0
    @AppStorage("wellmusic.lyric.fontSize") private var lyricFontSize = 17.0
    @AppStorage("wellmusic.lyric.lineSpacing") private var lyricLineSpacing = 24.0
    @AppStorage("wellmusic.lyric.translation") private var lyricTranslation = true
    @AppStorage("wellmusic.lyric.glowLevel") private var lyricGlowLevel = 1
    @AppStorage("wellmusic.player.controlsUseCoverColor") private var controlsUseCoverColor = true

    @State private var lyricCenters: [Int: CGFloat] = [:]
    @State private var focusedLyricID: Int?
    @State private var lyricsViewportHeight: CGFloat = 0
    @State private var isDraggingLyrics = false
    @State private var resumeTask: Task<Void, Never>?

    private var track: Track? { player.currentTrack }
    private var lyrics: [LyricLine] { player.lyrics?.lines ?? [] }
    private var coverURL: URL? {
        guard let pic = track?.album.picUrl else { return nil }
        return URL(string: pic)
    }

    private func layoutEntry(_ part: AppleMusicLayoutPart) -> PlayerLayoutEntry {
        appleLayout.entry(for: part)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                playerBackground

                VStack(spacing: 0) {
                    Color.clear.frame(height: ReferencePlaybackPresentationMetrics.headerTopSpacing)

                    ZStack {
                        if showLyrics {
                            lyricsPage
                                .transition(.asymmetric(
                                    insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .move(edge: .top).combined(with: .opacity)
                                ))
                        } else {
                            coverPage(size: geometry.size)
                                .transition(.asymmetric(
                                    insertion: .move(edge: .top).combined(with: .opacity),
                                    removal: .move(edge: .top).combined(with: .opacity)
                                ))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .animation(.easeInOut(duration: 0.22), value: showLyrics)

                    playbackControls(bottomInset: geometry.safeAreaInsets.bottom)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .onDisappear { resumeTask?.cancel() }
        .sheet(isPresented: $showQueue) {
            Group {
                if #available(iOS 16.4, *) {
                    QueueView()
                        .environmentObject(player)
                        .presentationDetents([.medium, .large])
                        .presentationBackground(.ultraThinMaterial)
                } else if #available(iOS 16.0, *) {
                    QueueView()
                        .environmentObject(player)
                        .presentationDetents([.medium, .large])
                } else {
                    QueueView()
                        .environmentObject(player)
                }
            }
        }
        .sheet(isPresented: $showComments) {
            Group {
                if let t = track {
                    CommentsView(track: t)
                }
            }
            .modifier(CommentsSheetDetents())
        }
        .sheet(isPresented: $showAddToPlaylist) {
            if let t = track {
                AddToPlaylistSheet(track: t)
            }
        }
        .sheet(isPresented: $showPlayerSettings) {
            playerSettingsSheet
        }
    }

    // MARK: - 三点菜单

    @ViewBuilder
    private var moreMenu: some View {
        Menu {
            // 评论
            Button {
                showComments = true
            } label: {
                Label("评论", systemImage: "bubble.left")
            }

            // 下一首播放
            Button {
                if let t = track {
                    player.addToPlayNext(t)
                    ToastCenter.shared.show("已添加到下一首播放")
                }
            } label: {
                Label("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward")
            }

            // 加入歌单
            Button {
                showAddToPlaylist = true
            } label: {
                Label("加入歌单…", systemImage: "music.note.list")
            }

            Divider()

            // 睡眠定时（用独立组件，避免嵌套Menu自动关闭）
            SleepTimerMenu(player: player)

            Divider()

            // 复制链接
            Button {
                if let t = track {
                    let link: String
                    switch t.sourcePlatform {
                    case "tx":
                        link = "https://y.qq.com/n/ryqq/songDetail/\(t.platformSongId ?? "")"
                    case "kg":
                        link = "https://www.kugou.com/song/#hash=\(t.platformSongId ?? "")"
                    default:
                        link = "https://music.163.com/#/song?id=\(t.id)"
                    }
                    Platform.copyToPasteboard(string: link)
                    ToastCenter.shared.show("链接已复制")
                }
            } label: {
                Label("复制链接", systemImage: "link")
            }

            Button {
                WellHaptics.tap()
                showPlayerSettings = true
            } label: {
                Label("播放器设置", systemImage: "gearshape")
            }
        } label: {
            compactActionButton(icon: "ellipsis") {}
        }
    }

    @ViewBuilder
    private var playerSettingsSheet: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    playingSettingsCard
                    appleMusicSettingsCard
                    lyricDisplaySettingsCard
                    coverSettingsCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("播放器设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        showPlayerSettings = false
                    }
                    .foregroundStyle(.blue)
                }
            }
        }
        .presentationDetentsSafe()
    }

    private var playingSettingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("播放")
                .font(.system(size: 17, weight: .semibold))
            Toggle("播放失败自动下一首", isOn: $autoSkipOnFailure)
                .font(.system(size: 15))
            Divider().opacity(0.5)
            Toggle("左右滑动切歌", isOn: $swipeSwitchSong)
                .font(.system(size: 15))
            Divider().opacity(0.5)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("背景光晕强度")
                        .font(.system(size: 15))
                    Spacer()
                    Text("\(Int((breath * 100).rounded()))%")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $breath, in: 0...1, step: 0.05)
            }
            Divider().opacity(0.5)
            progressStyleGrid
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.systemGray6))
        }
    }

    private var progressStyleGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("进度条样式")
                .font(.system(size: 15))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach([(0, "流光", "rays"), (1, "辉光", "sun.max"), (2, "极光", "sparkles"), (3, "波浪", "waveform")], id: \.0) { idx, name, icon in
                    Button {
                        progressBarStyle = idx
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: icon)
                                .font(.system(size: 15, weight: .medium))
                            Text(name)
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(progressBarStyle == idx ? Color.accentColor : Color.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            (progressBarStyle == idx ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05)),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var appleMusicSettingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Apple Music 样式")
                .font(.system(size: 17, weight: .semibold))
            Toggle("显示封面页歌词预览", isOn: $showLyricPreview)
                .font(.system(size: 15))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.systemGray6))
        }
    }

    private var lyricDisplaySettingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("歌词显示")
                .font(.system(size: 17, weight: .semibold))
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("歌词字号")
                        .font(.system(size: 15))
                    Spacer()
                    Text("\(Int(lyricFontSize))")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $lyricFontSize, in: 12...28, step: 1)
            }
            Divider().opacity(0.5)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("歌词行距")
                        .font(.system(size: 15))
                    Spacer()
                    Text("\(Int(lyricLineSpacing))")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $lyricLineSpacing, in: 14...40, step: 1)
            }
            Divider().opacity(0.5)
            Toggle("显示翻译", isOn: $lyricTranslation)
                .font(.system(size: 15))
            Divider().opacity(0.5)
            Picker("歌词发光", selection: $lyricGlowLevel) {
                Text("关闭").tag(0)
                Text("弱").tag(1)
                Text("中").tag(2)
                Text("强").tag(3)
            }
            .pickerStyle(.segmented)
            Divider().opacity(0.5)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("歌词偏移")
                        .font(.system(size: 15))
                    Spacer()
                    Text(lyricOffsetText)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $lyricOffset, in: -5...5, step: 0.1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.systemGray6))
        }
    }

    private var lyricOffsetText: String {
        if lyricOffset == 0 { return "同步" }
        return lyricOffset > 0 ? "提前 \(String(format: "%.1f", lyricOffset))s" : "延后 \(String(format: "%.1f", -lyricOffset))s"
    }

    private var coverSettingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("封面")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
            }
            Text("播放器风格")
                .font(.system(size: 15))
            playerStyleOption(icon: "square", title: "经典封面", subtitle: "封面、歌名和预览歌词分层显示", mode: .classic)
            playerStyleOption(icon: "music.note", title: "Apple Music", subtitle: "大封面、细进度条和简洁播放控制", mode: .appleMusic)
            playerStyleOption(icon: "circle.circle", title: "唱片模式", subtitle: "参考唱片界面、歌词、队列和播放控制", mode: .vinyl)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.systemGray6))
        }
    }

    private func playerStyleOption(icon: String, title: String, subtitle: String, mode: NowPlayingMode) -> some View {
        Button {
            settings.nowPlayingMode = mode
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(settings.nowPlayingMode == mode ? Color.red.opacity(0.15) : Color(.systemGray5))
                        .frame(width: 40, height: 40)
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(settings.nowPlayingMode == mode ? .red : .primary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if settings.nowPlayingMode == mode {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(settings.nowPlayingMode == mode ? Color.red.opacity(0.08) : Color(.systemGray5))
            }
            .overlay {
                if settings.nowPlayingMode == mode {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.red.opacity(0.5), lineWidth: 1)
                }
            }
        }
    }

    private func layoutSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, format: String, display: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                Spacer()
                Text(display(value.wrappedValue))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
            }
            Slider(value: value, in: range, step: step)
                .tint(.red)
        }
    }

    private func layoutSliderInt(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, suffix: String = "") -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(Int(value.wrappedValue))\(suffix)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
            }
            Slider(value: value, in: range, step: step)
                .tint(.red)
        }
    }

    private var playbackModeText: String {
        if player.shuffleEnabled { return "随机播放" }
        switch player.repeatMode {
        case .one: return "单曲循环"
        case .all: return "列表循环"
        case .off: return "顺序播放"
        }
    }

    // MARK: - 背景

    @ViewBuilder
    private var playerBackground: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            CoverBlurBackground(url: coverURL, scheme: colorScheme)
                .overlay(Color.black.opacity(colorScheme == .dark ? 0.48 : 0.14))
                .ignoresSafeArea()
        }
    }

    // MARK: - 封面页

    private func coverPage(size: CGSize) -> some View {
        let contentWidth = max(size.width - 64, 0)
        let artworkSize = min(contentWidth, min(size.height * 0.50, 390))

        return VStack(spacing: 0) {
            Spacer(minLength: 8)

            CoverImage(
                url: coverURL,
                size: artworkSize,
                cornerRadius: 18,
                emptyHint: player.isBuffering ? "等待开始播放…" : nil
            )
            .frame(width: artworkSize, height: artworkSize)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.46), radius: 36, y: 18)
            .scaleEffect(player.isPlaying ? 1 : 0.965)
            .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.cover)))
            .animation(.spring(response: 0.36, dampingFraction: 0.84), value: player.isPlaying)

            if showLyricPreview {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 9) {
                            Text(track?.name ?? "未在播放")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(primaryColor)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        Group {
                            if let t = track {
                                NowPlayingTrackDestinationLinks(
                                    track: t,
                                    font: .system(size: 13.5, weight: .medium),
                                    color: secondaryColor,
                                    onOpenDestination: onOpenDestination
                                )
                            } else {
                                Text(subtitle)
                                    .font(.system(size: 13.5, weight: .medium))
                                    .foregroundStyle(secondaryColor)
                            }
                        }
                        .lineLimit(1)
                        .truncationMode(.tail)
                    }
                    Spacer(minLength: 8)
                    compactActionButton(
                        icon: isLiked ? "heart.fill" : "heart",
                        active: isLiked
                    ) { onFavorite() }
                    moreMenu
                }
                .frame(maxWidth: 420)
                .padding(.top, 22)
                .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.title)))

                MiniLyricsPreview {
                    guard !lyrics.isEmpty else { return }
                    WellHaptics.tap()
                    showLyrics = true
                }
                .padding(.top, 18)
                .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.previewLyric)))
            } else {
                compactTrackHeader
                    .padding(.top, 22)
            }

            Spacer(minLength: 0).frame(height: 24)
        }
        .padding(.horizontal, 32)
    }

    private var compactTrackHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(track?.name ?? "未在播放")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(primaryColor)
                    .lineLimit(1)
                Group {
                    if let t = track {
                        NowPlayingTrackDestinationLinks(
                            track: t,
                            font: .system(size: 12, weight: .medium),
                            color: secondaryColor,
                            onOpenDestination: onOpenDestination
                        )
                    } else {
                        Text(subtitle)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(secondaryColor)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
            compactActionButton(
                icon: isLiked ? "heart.fill" : "heart",
                active: isLiked
            ) { onFavorite() }
            moreMenu
        }
        .frame(maxWidth: 420)
    }

    // MARK: - 歌词页

    private var lyricsPage: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 60)

            lyricsHeader
                .padding(.horizontal, 24)
                .padding(.bottom, 10)

            if lyrics.isEmpty {
                emptyLyricsView
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 26) {
                            Color.clear.frame(height: max(88, lyricsViewportHeight * 0.30))
                            ForEach(lyrics) { line in
                                lyricLine(line, isFocused: line.id == currentVisualLyricID)
                                    .id(line.id)
                                    .background {
                                        GeometryReader { rowGeometry in
                                            Color.clear.preference(
                                                key: ReferenceLyricCenterKey.self,
                                                value: [line.id: rowGeometry.frame(in: .named("referenceLyricsViewport")).midY]
                                            )
                                        }
                                    }
                            }
                            Color.clear.frame(height: max(110, lyricsViewportHeight * 0.34))
                        }
                        .padding(.horizontal, 28)
                    }
                    .coordinateSpace(name: "referenceLyricsViewport")
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.0),
                                .init(color: .black, location: 0.12),
                                .init(color: .black, location: 0.84),
                                .init(color: .clear, location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .background {
                        GeometryReader { viewport in
                            Color.clear
                                .onAppear { lyricsViewportHeight = viewport.size.height }
                                .onChange(of: viewport.size.height) { lyricsViewportHeight = $0 }
                        }
                    }
                    .onPreferenceChange(ReferenceLyricCenterKey.self) { centers in
                        lyricCenters = centers
                        updateFocusedLyric(from: centers)
                    }
                    .simultaneousGesture(lyricsDragGesture(proxy: proxy))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                            scrollToPlaybackLyric(proxy: proxy, animated: false)
                        }
                    }
                    .onChange(of: currentPlaybackLyricID) { _ in
                        guard !isDraggingLyrics else { return }
                        scrollToPlaybackLyric(proxy: proxy, animated: true)
                    }
                }
            }
        }
    }

    private var lyricsHeader: some View {
        HStack(spacing: 12) {
            Button {
                WellHaptics.tap()
                showLyrics = false
            } label: {
                CoverImage(url: coverURL, size: 48, cornerRadius: 10)
                    .shadow(color: .black.opacity(0.26), radius: 9, y: 4)
            }
            .buttonStyle(GlassPressButtonStyle(scale: 0.94))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(track?.name ?? "未在播放")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(primaryColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Group {
                    if let t = track {
                        NowPlayingTrackDestinationLinks(
                            track: t,
                            font: .system(size: 12, weight: .medium),
                            color: secondaryColor,
                            onOpenDestination: onOpenDestination
                        )
                    } else {
                        Text(subtitle)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(secondaryColor)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            Spacer(minLength: 0)
            compactActionButton(
                icon: isLiked ? "heart.fill" : "heart",
                active: isLiked
            ) { onFavorite() }
            moreMenu
        }
    }

    // MARK: - 播放控制栏

    private func playbackControls(bottomInset: CGFloat) -> some View {
        VStack(spacing: 15) {
            ReferenceScrubber()
                .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.progress)))

            HStack(spacing: 28) {
                Button {
                    WellHaptics.tap()
                    player.previous()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 25, weight: .semibold))
                }
                .buttonStyle(.plain)
                .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.previous)))

                Button {
                    WellHaptics.tap()
                    player.togglePlayPause()
                } label: {
                    PlayPauseMorphIcon(isPlaying: player.isPlaying, size: 24)
                        .frame(width: 66, height: 66)
                        .foregroundStyle(primaryColor)
                }
                .buttonStyle(GlassPressButtonStyle(scale: 0.92))
                .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.play)))

                Button {
                    WellHaptics.tap()
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 25, weight: .semibold))
                }
                .buttonStyle(.plain)
                .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.next)))
            }
            .foregroundStyle(primaryColor)
            .frame(maxWidth: 320)

            if showVolumeControl {
                ReferenceVolumeControl(accent: volumeColor, secondary: secondaryColor)
                    .frame(maxWidth: 420)
                    .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.volume)))
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            HStack(spacing: 48) {
                referenceActionButton(icon: "quote.bubble", active: showLyrics) {
                    guard !lyrics.isEmpty else { return }
                    showLyrics.toggle()
                }
                referenceActionButton(icon: playbackModeIcon, active: player.shuffleEnabled) {
                    player.cyclePlaybackMode()
                }
                referenceActionButton(icon: "list.bullet") {
                    showQueue = true
                }
            }
            .frame(maxWidth: 420)
            .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.actions)))
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 70)
        .gesture(commentsGesture)
    }

    private func referenceActionButton(icon: String, active: Bool = false, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button {
            WellHaptics.tap()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(active ? accentColor : primaryColor.opacity(0.78))
                .frame(width: 58, height: 58)
                .background { Circle().fill(.ultraThinMaterial) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func compactActionButton(icon: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            WellHaptics.tap()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(active ? accentColor : primaryColor.opacity(0.78))
                .frame(width: 38, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyLyricsView: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "quote.bubble")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.white.opacity(0.42))
            Text("暂无歌词")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.86))
            Text("点击封面区域返回歌曲页面")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.46))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            WellHaptics.tap()
            showLyrics = false
        }
    }

    // MARK: - 派生数据

    private var isVIP: Bool {
        guard let t = track else { return false }
        return t.fee == 1 || t.fee == 4
    }

    private var isLiked: Bool {
        guard let t = track else { return false }
        return account.isLiked(track: t)
    }

    private func onFavorite() {
        guard let t = track else { return }
        Task { await AccountStore.shared.toggleLike(trackID: t.id, track: t) }
    }

    /// 播放模式图标：当前项目 repeatMode + shuffleEnabled 分离。
    private var playbackModeIcon: String {
        if player.shuffleEnabled { return "shuffle" }
        switch player.repeatMode {
        case .one: return "repeat.1"
        case .all: return "repeat"
        case .off: return "repeat"
        }
    }

    private var currentPlaybackLyricIndex: Int? {
        guard !lyrics.isEmpty else { return nil }
        let progress = LyricTiming.effectiveProgress(clock.progress, userOffset: lyricOffset)
        var low = 0
        var high = lyrics.count - 1
        var answer: Int?
        while low <= high {
            let mid = (low + high) / 2
            if lyrics[mid].time <= progress {
                answer = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return answer
    }

    private var currentPlaybackLyricID: Int? {
        guard let index = currentPlaybackLyricIndex, lyrics.indices.contains(index) else { return nil }
        return lyrics[index].id
    }

    private var currentVisualLyricID: Int? {
        isDraggingLyrics ? focusedLyricID : (focusedLyricID ?? currentPlaybackLyricID)
    }

    private var subtitle: String {
        guard let t = track else { return "" }
        let parts = [t.artistNames, t.album.name].filter { !$0.isEmpty }
        return parts.isEmpty ? "未知歌曲" : parts.joined(separator: " · ")
    }

    private func lyricLine(_ line: LyricLine, isFocused: Bool) -> some View {
        Button {
            WellHaptics.tap()
            player.seek(to: LyricTiming.seekTime(for: line, userOffset: lyricOffset))
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(.system(size: isFocused ? 27 : 23, weight: isFocused ? .bold : .semibold))
                        .foregroundStyle(primaryColor.opacity(isFocused ? 1 : 0.36))
                        .fixedSize(horizontal: false, vertical: true)
                    if isFocused && isDraggingLyrics {
                        Spacer(minLength: 8)
                        Text(beansTimeString(line.time))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(secondaryColor.opacity(0.82))
                    }
                }
                if isFocused, let translation = line.translation, !translation.isEmpty {
                    Text(translation)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(secondaryColor.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .scaleEffect(isFocused ? 1.06 : 0.84, anchor: .leading)
            .blur(radius: isFocused ? 0 : 0.7)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: isFocused)
    }

    private func updateFocusedLyric(from centers: [Int: CGFloat]) {
        guard lyricsViewportHeight > 0, !centers.isEmpty else { return }
        let center = lyricsViewportHeight / 2
        focusedLyricID = centers.min { abs($0.value - center) < abs($1.value - center) }?.key
    }

    private func scrollToPlaybackLyric(proxy: ScrollViewProxy, animated: Bool) {
        guard let id = currentPlaybackLyricID else { return }
        let action = { proxy.scrollTo(id, anchor: .center) }
        if animated {
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.38)) { action() }
        } else {
            action()
        }
    }

    private func lyricsDragGesture(proxy: ScrollViewProxy) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { _ in
                isDraggingLyrics = true
                resumeTask?.cancel()
                updateFocusedLyric(from: lyricCenters)
            }
            .onEnded { _ in
                resumeTask?.cancel()
                if let id = focusedLyricID {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
                resumeTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    guard !Task.isCancelled else { return }
                    isDraggingLyrics = false
                }
            }
    }

    private var commentsGesture: some Gesture {
        DragGesture(minimumDistance: 25)
            .onEnded { value in
                guard value.translation.height < -54, abs(value.translation.height) > abs(value.translation.width) else { return }
                guard track != nil else { return }
                WellHaptics.medium()
                showComments = true
            }
    }

    // MARK: - 颜色

    private var primaryColor: Color {
        if primaryHex.hasPrefix("#"), let color = Color(hex: primaryHex) { return color }
        return .white
    }

    private var secondaryColor: Color {
        if secondaryHex.hasPrefix("#"), let color = Color(hex: secondaryHex) { return color }
        return .white.opacity(0.58)
    }

    private var accentColor: Color {
        if accentHex.hasPrefix("#"), let color = Color(hex: accentHex) { return color }
        return Color(red: 1.0, green: 0.28, blue: 0.36)
    }

    private var volumeColor: Color {
        if volumeHex.hasPrefix("#"), let color = Color(hex: volumeHex) { return color }
        return primaryColor
    }
}

// MARK: - 进度条

private struct ReferenceScrubber: View {
    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var clock = PlayerService.shared.clock
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let total = max(max(player.duration, player.currentTrack?.duration ?? 0), 1)
                let progress = min(max((scrubbing ? scrubValue : clock.progress) / total, 0), 1)
                let width = geometry.size.width

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.18))
                        .frame(height: 4)
                    Capsule()
                        .fill(.white.opacity(0.88))
                        .frame(width: width * progress, height: 4)
                    Circle()
                        .fill(.white)
                        .frame(width: scrubbing ? 18 : 12, height: scrubbing ? 18 : 12)
                        .shadow(color: .white.opacity(scrubbing ? 0.55 : 0.28), radius: scrubbing ? 10 : 3)
                        .offset(x: max(0, min(width - (scrubbing ? 18 : 12), width * progress - (scrubbing ? 9 : 6))))
                }
                .frame(height: 30)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !scrubbing {
                                scrubValue = clock.progress
                                WellHaptics.medium()
                            }
                            scrubbing = true
                            scrubValue = min(max(value.location.x / max(width, 1), 0), 1) * total
                        }
                        .onEnded { _ in
                            player.seek(to: scrubValue)
                            scrubbing = false
                            WellHaptics.tap()
                        }
                )
                .overlay(alignment: .topLeading) {
                    if scrubbing {
                        Text(beansTimeString(scrubValue))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(.black.opacity(0.44), in: Capsule())
                            .offset(x: max(0, min(width - 62, width * progress - 31)), y: -28)
                            .transition(.scale(scale: 0.92).combined(with: .opacity))
                    }
                }
            }
            .frame(height: 30)

            HStack {
                Text(beansTimeString(scrubbing ? scrubValue : clock.progress))
                Spacer()
                Text(beansTimeString(max(player.duration, player.currentTrack?.duration ?? 0)))
            }
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .foregroundStyle(.white.opacity(0.52))
        }
        .frame(maxWidth: 420)
        .animation(.spring(response: 0.24, dampingFraction: 0.82), value: scrubbing)
    }
}

// MARK: - 音量

private struct ReferenceVolumeControl: View {
    let accent: Color
    let secondary: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(secondary.opacity(0.84))
            ReferenceSystemVolumeView(accent: accent, secondary: secondary)
                .frame(height: 32)
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(secondary.opacity(0.84))
        }
        .frame(height: 34)
    }
}

private struct ReferenceSystemVolumeView: UIViewRepresentable {
    let accent: Color
    let secondary: Color

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsRouteButton = false
        styleVolumeSlider(in: view)
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        styleVolumeSlider(in: uiView)
    }

    private func styleVolumeSlider(in view: MPVolumeView) {
        let applyStyle = {
            let sliders = allSubviews(in: view).compactMap { $0 as? UISlider }
            sliders.forEach { slider in
                slider.minimumTrackTintColor = UIColor(accent.opacity(0.88))
                slider.maximumTrackTintColor = UIColor(secondary.opacity(0.32))
                slider.thumbTintColor = UIColor(accent)
            }
        }

        applyStyle()
        DispatchQueue.main.async {
            applyStyle()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                applyStyle()
            }
        }
    }

    private func allSubviews(in view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap { allSubviews(in: $0) }
    }
}

// MARK: - 迷你歌词预览（沉浸模式样式）

private struct MiniLyricsPreview: View {
    let action: () -> Void

    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var lyricsCursor = PlayerService.shared.lyricsCursor

    private var currentLines: (previous: LyricLine?, current: LyricLine?, next: LyricLine?) {
        guard let lyrics = player.lyrics, !lyrics.isEmpty else { return (nil, nil, nil) }
        guard let index = lyricsCursor.activeIndex else {
            return (nil, nil, lyrics.lines.first)
        }
        let all = lyrics.lines
        return (
            index > 0 ? all[index - 1] : nil,
            all[index],
            index + 1 < all.count ? all[index + 1] : nil
        )
    }

    var body: some View {
        let (_, current, next) = currentLines
        Button(action: action) {
            VStack(spacing: 8) {
                if current == nil && next == nil {
                    Text("暂无歌词")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.54))
                } else {
                    line(current, emphasized: true)
                    line(next, emphasized: false)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 70)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: current?.id)
    }

    @ViewBuilder
    private func line(_ line: LyricLine?, emphasized: Bool) -> some View {
        Text(line?.text.isEmpty == false ? line!.text : " ")
            .font(.system(size: emphasized ? 17 : 14, weight: emphasized ? .bold : .medium))
            .foregroundStyle(.white.opacity(emphasized ? 1 : 0.45))
            .lineLimit(1)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 28)
            .id(line?.id)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

// MARK: - QueueView

private struct QueueView: View {
    @EnvironmentObject private var player: PlayerService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // 拖动指示条
            Capsule()
                .fill(.secondary.opacity(0.45))
                .frame(width: 36, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 8)

            // 标题栏：标题 + 数量 + 清空
            HStack(spacing: 8) {
                Text("播放队列")
                    .font(.system(size: 17, weight: .bold))
                Text("\(player.queue.count) 首")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(role: .destructive) {
                    player.clearQueue()
                } label: {
                    Text("清空")
                        .font(.system(size: 15, weight: .medium))
                }
                .disabled(player.queue.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            if player.queue.isEmpty {
                Spacer()
                EmptyStateView(icon: "music.note.list", title: "播放队列为空")
                Spacer()
            } else {
                List {
                    ForEach(Array(player.queue.enumerated()), id: \.element.id) { index, track in
                        row(track, index: index)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                    }
                    .onDelete { offsets in
                        // 从大到小删除，避免索引漂移
                        for index in offsets.sorted(by: >) where player.queue.indices.contains(index) {
                            player.removeFromQueue(at: index)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .listStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func row(_ track: Track, index: Int) -> some View {
        let isCurrent = index == player.currentIndex
        HStack(spacing: 12) {
            CoverImage(url: URL(string: track.album.picUrl ?? ""), size: 46, cornerRadius: 9)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.name)
                    .font(.system(size: 15, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Theme.accent : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(track.artistNames)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if isCurrent {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.accent)
            } else {
                Text(Formatters.duration(track.duration))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            player.play(tracks: player.queue, source: .none, startAt: track)
            dismiss()
        }
    }
}

// MARK: - Sheet 辅助修饰器

/// 评论区 sheet：iOS 16.4+ 使用半屏 detents + 透明背景（CommentsView 自绘背景）。
private struct CommentsSheetDetents: ViewModifier {
    func body(content: Content) -> some View {
        Group {
            if #available(iOS 16.4, *) {
                content
                    .presentationDetents([.medium, .large])
                    .presentationBackground(.white)
            } else if #available(iOS 16.0, *) {
                content
                    .presentationDetents([.medium, .large])
            } else {
                content
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func presentationDetentsSafe() -> some View {
        if #available(iOS 16.0, *) {
            self.presentationDetents([.medium])
        } else {
            self
        }
    }
}

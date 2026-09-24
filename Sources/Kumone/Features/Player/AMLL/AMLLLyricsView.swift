import SwiftUI
import WebKit
import Combine

// MARK: - AMLLLyricsView

/// 基于 WKWebView 嵌入 AMLL（Apple Music Like Lyrics）的歌词 + 流动背景组件。
///
/// 使用参考项目 well-music 的完整内联版 AMLL HTML（455KB，不依赖 CDN），
/// 包含 MeshGradientRenderer 流动背景 + LyricPlayer 逐字扫光歌词。
///
/// API（时间单位均为**秒**）：
/// - setLyrics(LyricLineData[])
/// - setTime(seconds, isSeek)
/// - setPlaying(Bool)
/// - setAlbum(urlString)
/// - setAlignPosition(0-1)
/// - setFontStyle(fontSize, inactiveFontSize, fontWeight, lineMargin)
struct AMLLLyricsView: View {
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var settings: SettingsManager

    /// 歌词点击/seek 回调（时间，秒）
    var onSeek: ((TimeInterval) -> Void)?
    /// 是否显示歌词（大封面状态下隐藏）
    var showLyrics: Bool = true

    var body: some View {
        AMLLWebViewRepresentable(
            player: player,
            lyricTop: settings.amllLyricTop,
            lyricBottom: settings.amllLyricBottom,
            fontSize: settings.amllFontSize,
            fontWeight: settings.amllFontWeight,
            showLyrics: showLyrics,
            onSeek: onSeek
        )
        .ignoresSafeArea()
    }
}

// MARK: - WebView Representable

private struct AMLLWebViewRepresentable: PlatformViewRepresentable {
    let player: PlayerService
    let lyricTop: Int
    let lyricBottom: Int
    let fontSize: Int
    let fontWeight: Int
    let showLyrics: Bool
    let onSeek: ((TimeInterval) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(player: player, onSeek: onSeek)
    }

    #if os(iOS)
    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.createWebView()
    }
    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.applyLayout(
            top: lyricTop, bottom: lyricBottom,
            fontSize: fontSize, fontWeight: fontWeight,
            showLyrics: showLyrics
        )
    }
    #elseif os(macOS)
    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.createWebView()
    }
    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.applyLayout(
            top: lyricTop, bottom: lyricBottom,
            fontSize: fontSize, fontWeight: fontWeight,
            showLyrics: showLyrics
        )
    }
    #endif

    #if os(iOS)
    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.cleanup()
    }
    #elseif os(macOS)
    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.cleanup()
    }
    #endif
}

// MARK: - Coordinator

@MainActor
private final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {

    private let player: PlayerService
    private let onSeek: ((TimeInterval) -> Void)?

    private weak var webView: WKWebView?
    private var isReady = false
    private var pendingCalls: [() -> Void] = []

    private var cancellables: Set<AnyCancellable> = []
    private var timeSyncTimer: Timer?
    private var seekDetectionTimer: Timer?
    private var lastAlbumTrackId: Int?

    // 当前 AMLL 歌词数据（用于 line-click 时查准确时间）
    private var currentAMLLLines: [[String: Any]] = []
    // 上一次同步的播放进度（用于判断是否需要 seek 同步）
    private var lastSyncedProgress: TimeInterval = 0

    // 最后一次布局参数
    private var layoutTop = 170
    private var layoutBottom = 230
    private var layoutFontSize = 22
    private var layoutFontWeight = 700
    private var layoutShowLyrics = true

    init(player: PlayerService, onSeek: ((TimeInterval) -> Void)?) {
        self.player = player
        self.onSeek = onSeek
        super.init()
    }

    /// 应用歌词布局（位置、字号、字重、显示/隐藏）
    func applyLayout(top: Int, bottom: Int, fontSize: Int, fontWeight: Int, showLyrics: Bool) {
        // 记录切换前的状态，用于检测"从隐藏切到显示"
        let wasHidden = !layoutShowLyrics
        layoutTop = top
        layoutBottom = bottom
        layoutFontSize = fontSize
        layoutFontWeight = fontWeight
        layoutShowLyrics = showLyrics

        // 通过 JS 直接操作 DOM 设置歌词容器位置和显示状态
        let displayValue = showLyrics ? "block" : "none"
        let js = """
        (function() {
            var el = document.getElementById('lyrics');
            if (el) {
                el.style.top = '\(top)px';
                el.style.bottom = '\(bottom)px';
                el.style.display = '\(displayValue)';
            }
        })();
        true;
        """
        callJSRaw(js)

        // 字体样式
        callJS("setFontStyle", args: [fontSize, max(Int(Double(fontSize) * 0.7), 12), fontWeight, 16])

        // 关键修复：从隐藏切换到显示时，立即强制同步当前播放时间和播放状态
        // 否则 AMLL 会停在隐藏前的歌词位置（卡在第一句），不会跟随当前播放进度
        if wasHidden && showLyrics && isReady {
            let time = player.livePlaybackTime
            callJS("setTime", args: [time, true])  // isSeek=true 强制跳转到当前时间
            lastSyncedProgress = time
            callJS("setPlaying", args: [player.isPlaying])
        }
    }

    // MARK: - 创建 WebView

    func createWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptEnabled = true
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        if #available(iOS 14.0, macOS 11.0, *) {
            config.defaultWebpagePreferences.allowsContentJavaScript = true
        }

        // 注册 JS → Swift 消息通道
        let userContent = WKUserContentController()
        userContent.add(self, name: "amllEvent")
        config.userContentController = userContent

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        #if os(iOS)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        // 禁用 WebView 滚动手势，防止拦截原生进度条拖动
        webView.scrollView.panGestureRecognizer.isEnabled = false
        #elseif os(macOS)
        webView.setValue(false, forKey: "drawsBackground")
        #endif
        self.webView = webView

        // 加载本地 HTML（SPM 资源在 Bundle.module 中）
        if let htmlURL = Bundle.module.url(forResource: "AMLLLyrics", withExtension: "html") {
            webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        } else {
            NSLog("[AMLL] 警告：未在 bundle 中找到 AMLLLyrics.html")
        }

        return webView
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 页面加载完成，等待 JS 侧发 ready 事件
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.syncInitialState()
        }
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "amllEvent",
              let body = message.body as? [String: Any],
              let eventName = body["name"] as? String
        else { return }

        switch eventName {
        case "ready":
            isReady = true
            flushPendingCalls()
            syncInitialState()
            startTimeSync()
        case "seek":
            if let data = body["data"] as? [String: Any],
               let time = data["time"] as? TimeInterval {
                onSeek?(time)
            }
        case "line-click":
            if let data = body["data"] as? [String: Any],
               let index = data["index"] as? Int,
               index >= 0, index < currentAMLLLines.count,
               let time = currentAMLLLines[index]["time"] as? TimeInterval {
                // 用 AMLL 自己的歌词时间，避免和 Kumone 歌词索引不对应
                onSeek?(time)
            }
        case "error":
            if let data = body["data"] as? [String: Any],
               let msg = data["message"] as? String {
                NSLog("[AMLL] JS 错误: \(msg)")
            }
        default:
            break
        }
    }

    // MARK: - 状态同步

    private func syncInitialState() {
        guard isReady else { return }

        // 同步歌词
        if let lyrics = player.lyrics {
            updateLyrics(lyrics)
        } else {
            callJS("setLyrics", args: [[]])
        }

        // 同步播放状态
        callJS("setPlaying", args: [player.isPlaying])

        // 同步当前时间（秒）
        callJS("setTime", args: [player.livePlaybackTime, true])
        lastSyncedProgress = player.livePlaybackTime

        // 同步封面
        updateAlbumArt()

        // 歌词居中对齐
        callJS("setAlignPosition", args: [0.5])

        // 应用自定义布局（位置、字号、字重、显示状态）
        applyLayout(
            top: layoutTop, bottom: layoutBottom,
            fontSize: layoutFontSize, fontWeight: layoutFontWeight,
            showLyrics: layoutShowLyrics
        )

        // 监听 PlayerService 变化
        setupObservers()
    }

    private func setupObservers() {
        guard cancellables.isEmpty else { return }

        // 歌词变化
        player.$lyrics
            .receive(on: DispatchQueue.main)
            .sink { [weak self] lyrics in
                guard let self, let lyrics else {
                    self?.callJS("setLyrics", args: [[]])
                    return
                }
                self.updateLyrics(lyrics)
            }
            .store(in: &cancellables)

        // 播放状态变化
        player.$isPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isPlaying in
                self?.callJS("setPlaying", args: [isPlaying])
                if isPlaying {
                    // 恢复播放时用真实当前时间重置 AMLL 时钟
                    let time = self?.player.livePlaybackTime ?? 0
                    self?.callJS("setTime", args: [time, true])
                    self?.lastSyncedProgress = time
                }
            }
            .store(in: &cancellables)

        // 曲目变化 → 更新封面
        player.$currentTrack
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateAlbumArt()
            }
            .store(in: &cancellables)
    }

    private func updateLyrics(_ lyrics: ParsedLyrics) {
        let amllLines = AMLLDataConverter.convert(lyrics)
        currentAMLLLines = amllLines
        callJS("setLyrics", args: [amllLines])
    }

    private func updateAlbumArt() {
        guard let track = player.currentTrack,
              let picUrl = track.album.picUrl,
              let url = picUrl.resizedImageURL(512)
        else {
            callJS("setAlbum", args: [""])
            return
        }

        let trackId = track.id
        guard trackId != lastAlbumTrackId else { return }
        lastAlbumTrackId = trackId

        // 从 Kumone 的 ImageCache 获取图片，转 base64 传给 WebView
        Task { @MainActor in
            if let image = await ImageCache.shared.image(for: url) {
                if let dataURL = image.amllJPEGDataURL() {
                    callJS("setAlbum", args: [dataURL])
                }
            }
        }
    }

    // MARK: - 时间校准（保留我们的策略：每 0.5 秒校准）

    private func startTimeSync() {
        timeSyncTimer?.invalidate()
        seekDetectionTimer?.invalidate()

        // 播放时每0.5秒平滑同步时间
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.player.isPlaying else { return }
            let time = self.player.livePlaybackTime
            self.callJS("setTime", args: [time])
            self.lastSyncedProgress = time
        }
        RunLoop.main.add(timer, forMode: .common)
        timeSyncTimer = timer

        // 每0.2秒检测进度突变（拖动进度条/seek），超过2秒立即用 isSeek=true 同步
        // 不依赖 isPlaying，暂停状态拖动也能检测到
        let seekTimer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let currentTime = self.player.livePlaybackTime
            let delta = abs(currentTime - self.lastSyncedProgress)
            if delta > 2.0 {
                self.callJS("setTime", args: [currentTime, true])
                self.lastSyncedProgress = currentTime
            }
        }
        RunLoop.main.add(seekTimer, forMode: .common)
        seekDetectionTimer = seekTimer
    }

    // MARK: - JS 调用封装

    /// 调用 `window.amll.<method>(<args...>)`。
    /// 参数会被序列化为 JSON。未 ready 时的调用会排队。
    private func callJS(_ method: String, args: [Any] = []) {
        let block = { [weak self] in
            guard let webView = self?.webView else { return }
            let jsonArgs: [String] = args.map { arg in
                if let s = arg as? String {
                    let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\"", with: "\\\"")
                        .replacingOccurrences(of: "\n", with: "\\n")
                    return "\"\(escaped)\""
                }
                if let arr = arg as? [Any] {
                    if let data = try? JSONSerialization.data(withJSONObject: arr),
                       let str = String(data: data, encoding: .utf8) {
                        return str
                    }
                    return "[]"
                }
                return "\(arg)"
            }
            let script = "window.amll.\(method)(\(jsonArgs.joined(separator: ",")))"
            webView.evaluateJavaScript(script) { _, error in
                if let error {
                    NSLog("[AMLL] JS 调用失败 (\(method)): \(error.localizedDescription)")
                }
            }
        }

        if isReady {
            block()
        } else {
            pendingCalls.append(block)
        }
    }

    private func flushPendingCalls() {
        let calls = pendingCalls
        pendingCalls.removeAll()
        calls.forEach { $0() }
    }

    /// 直接执行任意 JS 字符串（用于 DOM 操作）。未 ready 时排队。
    private func callJSRaw(_ script: String) {
        let block = { [weak self] in
            guard let webView = self?.webView else { return }
            webView.evaluateJavaScript(script) { _, error in
                if let error {
                    NSLog("[AMLL] JS 执行失败: \(error.localizedDescription)")
                }
            }
        }
        if isReady {
            block()
        } else {
            pendingCalls.append(block)
        }
    }

    // MARK: - 清理

    func cleanup() {
        timeSyncTimer?.invalidate()
        timeSyncTimer = nil
        seekDetectionTimer?.invalidate()
        seekDetectionTimer = nil
        cancellables.removeAll()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "amllEvent")
        webView?.stopLoading()
        webView = nil
    }
}

import SwiftUI
import WebKit
import Combine

// MARK: - AMLLLyricsView

/// 基于 WKWebView 嵌入 AMLL（Apple Music Like Lyrics）的歌词 + 流动背景组件。
///
/// 功能：
/// - AMLL MeshGradientRenderer 流动背景（WebGL，基于专辑封面）
/// - AMLL LyricPlayer 逐字歌词（扫光/卡拉OK效果，支持翻译/罗马音）
/// - 与 Kumone PlayerService 自动同步播放状态、歌词、封面、播放进度
///
/// 使用：
/// ```swift
/// AMLLLyricsView()
///     .environmentObject(PlayerService.shared)
/// ```
struct AMLLLyricsView: View {
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var settings: SettingsManager

    /// 背景流动速度（默认 1.5）
    var flowSpeed: Double = 1.5
    /// 背景渲染缩放，0.3-1.0，越低越省性能（默认 0.6）
    var renderScale: Double = 0.6
    /// 歌词点击回调（行索引）
    var onLineClick: ((Int) -> Void)?

    var body: some View {
        AMLLWebViewRepresentable(
            player: player,
            flowSpeed: flowSpeed,
            renderScale: renderScale,
            onLineClick: onLineClick
        )
        .ignoresSafeArea()
    }
}

// MARK: - WebView Representable

private struct AMLLWebViewRepresentable: PlatformViewRepresentable {
    let player: PlayerService
    let flowSpeed: Double
    let renderScale: Double
    let onLineClick: ((Int) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(player: player, flowSpeed: flowSpeed, renderScale: renderScale, onLineClick: onLineClick)
    }

    #if os(iOS)
    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.createWebView()
    }
    func updateUIView(_ webView: WKWebView, context: Context) {}
    #elseif os(macOS)
    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.createWebView()
    }
    func updateNSView(_ webView: WKWebView, context: Context) {}
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
    private let flowSpeed: Double
    private let renderScale: Double
    private let onLineClick: ((Int) -> Void)?

    private weak var webView: WKWebView?
    private var isReady = false
    private var pendingCalls: [() -> Void] = []

    private var cancellables: Set<AnyCancellable> = []
    private var timeSyncTimer: Timer?
    private var lastAlbumTrackId: Int?

    init(player: PlayerService, flowSpeed: Double, renderScale: Double, onLineClick: ((Int) -> Void)?) {
        self.player = player
        self.flowSpeed = flowSpeed
        self.renderScale = renderScale
        self.onLineClick = onLineClick
        super.init()
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
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        #if os(iOS)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        #endif
        self.webView = webView

        // 加载本地 HTML
        if let htmlURL = Bundle.main.url(forResource: "AMLLLyrics", withExtension: "html") {
            webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        } else {
            // 兜底：如果 bundle 中找不到，尝试从资源目录加载
            loadFallbackHTML()
        }

        return webView
    }

    private func loadFallbackHTML() {
        // 在开发阶段，如果 HTML 未加入 bundle，可以用内嵌的方式加载
        // 正式使用时请将 AMLLLyrics.html 加入 Copy Bundle Resources
        NSLog("[AMLL] 警告：未在 bundle 中找到 AMLLLyrics.html，请将其加入 Copy Bundle Resources")
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 页面加载完成，等待 JS 侧发 ready 事件
        // 同时做一次初始状态同步
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
        case "line-click":
            if let data = body["data"] as? [String: Any],
               let index = data["index"] as? Int {
                onLineClick?(index)
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
        }

        // 同步播放状态
        callJS("setPlaying", args: [player.isPlaying])

        // 同步当前时间
        callJS("setTime", args: [player.livePlaybackTime])

        // 同步封面
        updateAlbumArt()

        // 配置参数
        callJS("setFlowSpeed", args: [flowSpeed])
        callJS("setRenderScale", args: [renderScale])
        callJS("setHasLyric", args: [player.lyrics?.isEmpty == false])

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
                    self?.callJS("setHasLyric", args: [false])
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
                    self?.callJS("setTime", args: [self?.player.livePlaybackTime ?? 0])
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
        callJS("setLyrics", args: [amllLines])
        callJS("setHasLyric", args: [!lyrics.isEmpty])
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

    // MARK: - 时间校准

    private func startTimeSync() {
        timeSyncTimer?.invalidate()
        // 每 0.5 秒校准一次播放时间，防止 JS 侧时间漂移
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.player.isPlaying else { return }
            self.callJS("setTime", args: [self.player.livePlaybackTime])
        }
        RunLoop.main.add(timer, forMode: .common)
        timeSyncTimer = timer
    }

    // MARK: - JS 调用封装

    /// 调用 `window.amll.<method>(<args...>)`。
    /// 参数会被序列化为 JSON。未 ready 时的调用会排队。
    private func callJS(_ method: String, args: [Any] = []) {
        let block = { [weak self] in
            guard let webView = self?.webView else { return }
            let jsonArgs: [String] = args.map { arg in
                if let s = arg as? String {
                    // 字符串需要转义后加引号
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

    // MARK: - 清理

    func cleanup() {
        timeSyncTimer?.invalidate()
        timeSyncTimer = nil
        cancellables.removeAll()
        callJS("dispose")
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "amllEvent")
        webView?.stopLoading()
        webView = nil
    }
}

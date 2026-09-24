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

    /// 歌词点击/seek 回调（时间，秒）
    var onSeek: ((TimeInterval) -> Void)?

    var body: some View {
        AMLLWebViewRepresentable(
            player: player,
            onSeek: onSeek
        )
        .ignoresSafeArea()
    }
}

// MARK: - WebView Representable

private struct AMLLWebViewRepresentable: PlatformViewRepresentable {
    let player: PlayerService
    let onSeek: ((TimeInterval) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(player: player, onSeek: onSeek)
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
    private let onSeek: ((TimeInterval) -> Void)?

    private weak var webView: WKWebView?
    private var isReady = false
    private var pendingCalls: [() -> Void] = []

    private var cancellables: Set<AnyCancellable> = []
    private var timeSyncTimer: Timer?
    private var lastAlbumTrackId: Int?

    init(player: PlayerService, onSeek: ((TimeInterval) -> Void)?) {
        self.player = player
        self.onSeek = onSeek
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
        #if os(iOS)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
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
               let index = data["index"] as? Int {
                // 兼容旧版 line-click 事件
                if let lyrics = player.lyrics,
                   index >= 0, index < lyrics.lines.count {
                    onSeek?(lyrics.lines[index].time)
                }
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

        // 同步封面
        updateAlbumArt()

        // 歌词居中对齐
        callJS("setAlignPosition", args: [0.5])

        // 字体样式：fontSize=22, inactiveFontSize=16, fontWeight=700, lineMargin=16
        callJS("setFontStyle", args: [22, 16, 700, 16])

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
                    self?.callJS("setTime", args: [self?.player.livePlaybackTime ?? 0, true])
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
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "amllEvent")
        webView?.stopLoading()
        webView = nil
    }
}

import SwiftUI
import WebKit

// MARK: - QQ 音乐网页登录（应用内网页登录 y.qq.com，登录后直接读取 Cookie）

struct QQWebLoginView: View {
    @State private var pageLoaded = false
    @State private var syncing = false
    @State private var message = ""
    let onSuccess: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text("在下方网页右上角点「登录」，完成后手动点击下方「同步登录状态」")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            ZStack {
                QQWebViewRepresentable(onLoaded: { pageLoaded = true })
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .padding(.horizontal, 20)

                if !pageLoaded {
                    ProgressView("正在加载 QQ 音乐…")
                        .tint(.accentColor)
                }
            }
            .frame(maxHeight: .infinity)

            if !message.isEmpty {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(message.hasPrefix("✓") ? Color.green : Color.red.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }

            Button {
                syncNow()
            } label: {
                HStack(spacing: 6) {
                    if syncing {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Text(syncing ? "正在读取登录状态…" : "同步登录状态")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.accentColor, in: Capsule())
            }
            .disabled(syncing)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .navigationTitle("QQ 音乐登录")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func syncNow() {
        syncing = true
        message = ""
        readCookies { dict in
            syncing = false
            let auth = QQMusicAuth.shared
            if let issue = QQMusicAuth.loginValidationMessage(dict) {
                message = issue
            } else {
                auth.importCookies(dict, nickname: nil)
                message = "✓ QQ 音乐登录成功"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    onSuccess()
                }
            }
        }
    }

    private func readCookies(_ completion: @escaping ([String: String]) -> Void) {
        let wanted = QQMusicAuth.webCookieNames
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            var dict: [String: String] = [:]
            for cookie in cookies where wanted.contains(cookie.name) || cookie.name.hasPrefix("ptnick") {
                dict[cookie.name] = cookie.value
            }
            if QQMusicAuth.loginValidationMessage(dict) != nil {
                for cookie in cookies where cookie.domain.lowercased().hasSuffix("qq.com") {
                    dict[cookie.name] = cookie.value
                }
            }
            DispatchQueue.main.async {
                completion(dict)
            }
        }
    }
}

// MARK: - WKWebView 封装

struct QQWebViewRepresentable: UIViewRepresentable {
    let onLoaded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onLoaded: onLoaded)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        webView.navigationDelegate = context.coordinator
        if let url = URL(string: "https://y.qq.com/") {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onLoaded: () -> Void

        init(onLoaded: @escaping () -> Void) {
            self.onLoaded = onLoaded
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.onLoaded()
            }
        }
    }
}

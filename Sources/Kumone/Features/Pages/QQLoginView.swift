import SwiftUI

struct QQLoginView: View {
    @ObservedObject private var auth = QQMusicAuth.shared
    @Environment(\.dismiss) private var dismiss
    @State private var qrImage: UIImage?
    @State private var scanState: QQMusicAuth.ScanState = .waiting
    @State private var isLoading = false
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        List {
            if auth.isLoggedIn {
                Section {
                    HStack {
                        Image(systemName: "person.circle.fill")
                            .font(.largeTitle)
                            .foregroundColor(.accentColor)
                        VStack(alignment: .leading) {
                            Text(auth.nickname)
                                .font(.headline)
                            if let vip = auth.vipBadge {
                                Text(vip)
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                            Text("QQ: \(auth.uin)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                }

                Section {
                    Button(role: .destructive) {
                        auth.logout()
                    } label: {
                        Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            } else {
                Section {
                    VStack(spacing: 16) {
                        if isLoading {
                            ProgressView("加载二维码...")
                                .frame(height: 200)
                        } else if let qrImage {
                            Image(uiImage: qrImage)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 200, height: 200)

                            Text(stateText)
                                .font(.subheadline)
                                .foregroundColor(.secondary)

                            if scanState == .expired {
                                Button {
                                    loadQRCode()
                                } label: {
                                    Label("刷新二维码", systemImage: "arrow.clockwise")
                                }
                            }
                        } else {
                            ProgressView()
                                .frame(height: 200)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                } header: {
                    Text("扫码登录 QQ 音乐")
                } footer: {
                    Text("使用 QQ 音乐 APP 扫码登录，登录后可播放 VIP 歌曲")
                }
            }
        }
        .navigationTitle("QQ 音乐登录")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !auth.isLoggedIn {
                loadQRCode()
            }
        }
        .onDisappear {
            pollTask?.cancel()
        }
    }

    private var stateText: String {
        switch scanState {
        case .waiting: return "请使用 QQ 音乐 APP 扫码"
        case .scanned: return "已扫描，请在手机上确认"
        case .expired: return "二维码已过期"
        case .success: return "登录成功"
        case .error(let msg): return msg
        }
    }

    private func loadQRCode() {
        isLoading = true
        scanState = .waiting
        pollTask?.cancel()

        Task {
            do {
                let data = try await auth.fetchQRCode()
                if let image = UIImage(data: data) {
                    await MainActor.run {
                        qrImage = image
                        isLoading = false
                        startPolling()
                    }
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    scanState = .error(error.localizedDescription)
                }
            }
        }
    }

    private func startPolling() {
        pollTask = Task {
            while !Task.isCancelled {
                do {
                    let state = try await auth.poll()
                    await MainActor.run {
                        scanState = state
                    }
                    if case .success = state {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        await MainActor.run { dismiss() }
                        break
                    }
                    if state == .expired { break }
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                } catch {
                    break
                }
            }
        }
    }
}

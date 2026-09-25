import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsManager
    @EnvironmentObject private var account: AccountStore
    @State private var audioCacheUsage: String = String(localized: "计算中…")
    @State private var imageCacheUsage: String = String(localized: "计算中…")
    @State private var cacheError: String?

    var body: some View {
        Form {
            Section("播放") {
                Picker("音质", selection: $settings.audioQuality) {
                    ForEach(AudioQuality.allCases) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
                Toggle("预加载下一首", isOn: $settings.preloadNextTrack)
                Text("播放5秒后自动预加载下一首歌，切换时秒开不卡顿")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                NavigationLink {
                    LXSourceManageView()
                } label: {
                    Label("自定义音源", systemImage: "antenna.radiowaves.left.and.right")
                }
                NavigationLink {
                    LXSourceStatusView()
                } label: {
                    Label("音源状态", systemImage: "list.bullet.clipboard")
                }
            }

            Section("外观") {
                Picker("主题", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.displayName).tag(appearance)
                    }
                }
                #if os(macOS)
                // macOS only renders two now-playing layouts — 黑胶 and the
                // regular page; the iOS 沉浸/简洁 options all fall back to the
                // regular page here, so offering four was misleading (#105).
                // Map any non-vinyl value onto 经典模式 so a stored default (e.g.
                // 沉浸模式) still shows a valid selection.
                Picker("播放页模式", selection: Binding(
                    get: { settings.nowPlayingMode == .vinyl ? .vinyl : .classic },
                    set: { settings.nowPlayingMode = $0 }
                )) {
                    Text(NowPlayingMode.vinyl.displayName).tag(NowPlayingMode.vinyl)
                    Text(NowPlayingMode.classic.displayName).tag(NowPlayingMode.classic)
                }
                #else
                Picker("播放页模式", selection: $settings.nowPlayingMode) {
                    ForEach(NowPlayingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                #endif
                Toggle("显示歌词翻译", isOn: $settings.showLyricsTranslation)
                Toggle("显示 VIP 歌曲标识", isOn: $settings.showVIPBadge)
                Toggle("逐字歌词（卡拉OK）", isOn: $settings.verbatimLyrics)
                Toggle("AMLL 沉浸式歌词（流动背景+扫光）", isOn: $settings.useAMLLImmersive)
                if settings.useAMLLImmersive {
                    Text("通过 WKWebView 嵌入开源 AMLL 组件；播放页将切换为 AMLL 流动背景和逐字扫光歌词")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // 歌词顶部位置
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("歌词顶部位置")
                            Spacer()
                            Text("\(settings.amllLyricTop)px")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(
                            get: { Double(settings.amllLyricTop) },
                            set: { settings.amllLyricTop = Int($0) }
                        ), in: 50...400, step: 5)
                    }
                    .padding(.top, 4)

                    // 歌词底部位置
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("歌词底部位置")
                            Spacer()
                            Text("\(settings.amllLyricBottom)px")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(
                            get: { Double(settings.amllLyricBottom) },
                            set: { settings.amllLyricBottom = Int($0) }
                        ), in: 100...500, step: 5)
                    }

                    // 歌词左右位置
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("歌词左右位置")
                            Spacer()
                            Text(settings.amllLyricHorizontal > 0 ? "+\(settings.amllLyricHorizontal)" : "\(settings.amllLyricHorizontal)")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(
                            get: { Double(settings.amllLyricHorizontal) },
                            set: { settings.amllLyricHorizontal = Int($0) }
                        ), in: -200...200, step: 5)
                    }

                    // 歌词字号
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("歌词字号")
                            Spacer()
                            Text("\(settings.amllFontSize)pt")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(
                            get: { Double(settings.amllFontSize) },
                            set: { settings.amllFontSize = Int($0) }
                        ), in: 14...40, step: 1)
                    }

                    // 歌词字重
                    Picker("歌词字重", selection: Binding(
                        get: { settings.amllFontWeight },
                        set: { settings.amllFontWeight = $0 }
                    )) {
                        Text("常规").tag(400)
                        Text("中等").tag(500)
                        Text("半粗").tag(600)
                        Text("粗体").tag(700)
                        Text("特粗").tag(800)
                        Text("超粗").tag(900)
                    }

                    // 歌词字体
                    Picker("歌词字体", selection: Binding(
                        get: { settings.amllFontFamily },
                        set: { settings.amllFontFamily = $0 }
                    )) {
                        Text("系统默认").tag("")
                        Text("黑体").tag("PingFang SC")
                        Text("SF粗体").tag("SF Pro Display")
                        if !settings.amllFontFamily.isEmpty,
                           settings.amllFontFamily != "PingFang SC",
                           settings.amllFontFamily != "SF Pro Display" {
                            Text("自定义").tag(settings.amllFontFamily)
                        }
                    }

                    // 导入自定义字体
                    FontImportButton()

                    // MARK: 播放器组件位置调整
                    Divider()
                    Text("播放器组件位置调整")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    // 大封面顶部偏移
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("大封面上下位置")
                            Spacer()
                            Text(settings.playerArtworkTopOffset > 0 ? "+\(settings.playerArtworkTopOffset)" : "\(settings.playerArtworkTopOffset)")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(
                            get: { Double(settings.playerArtworkTopOffset) },
                            set: { settings.playerArtworkTopOffset = Int($0) }
                        ), in: -300...300, step: 5)
                    }

                    // 大封面尺寸
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("大封面尺寸")
                            Spacer()
                            Text(String(format: "%.0f%%", settings.playerArtworkScale * 100))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(
                            get: { settings.playerArtworkScale },
                            set: { settings.playerArtworkScale = $0 }
                        ), in: 0.7...1.3, step: 0.05)
                    }

                    // 歌曲信息与封面间距
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("歌曲信息与封面间距")
                            Spacer()
                            Text("\(settings.playerTrackInfoSpacing)px")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(
                            get: { Double(settings.playerTrackInfoSpacing) },
                            set: { settings.playerTrackInfoSpacing = Int($0) }
                        ), in: 0...60, step: 2)
                    }

                    // 控制区域底部偏移
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("控制条上下位置")
                            Spacer()
                            Text(settings.playerControlsBottomOffset > 0 ? "+\(settings.playerControlsBottomOffset)" : "\(settings.playerControlsBottomOffset)")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(
                            get: { Double(settings.playerControlsBottomOffset) },
                            set: { settings.playerControlsBottomOffset = Int($0) }
                        ), in: -200...200, step: 5)
                    }

                    // 歌曲信息上下偏移
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("歌曲信息上下位置")
                            Spacer()
                            Text(settings.playerTrackInfoTopOffset > 0 ? "+\(settings.playerTrackInfoTopOffset)" : "\(settings.playerTrackInfoTopOffset)")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(
                            get: { Double(settings.playerTrackInfoTopOffset) },
                            set: { settings.playerTrackInfoTopOffset = Int($0) }
                        ), in: -300...300, step: 5)
                    }

                    // 左侧歌曲信息左右偏移
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("歌曲名/歌手左右位置")
                            Spacer()
                            Text(settings.playerTrackInfoLeftOffset > 0 ? "+\(settings.playerTrackInfoLeftOffset)" : "\(settings.playerTrackInfoLeftOffset)")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(
                            get: { Double(settings.playerTrackInfoLeftOffset) },
                            set: { settings.playerTrackInfoLeftOffset = Int($0) }
                        ), in: -200...200, step: 5)
                    }

                    // 右侧按钮左右偏移
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("爱心/更多按钮左右位置")
                            Spacer()
                            Text(settings.playerTrackInfoRightOffset > 0 ? "+\(settings.playerTrackInfoRightOffset)" : "\(settings.playerTrackInfoRightOffset)")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(
                            get: { Double(settings.playerTrackInfoRightOffset) },
                            set: { settings.playerTrackInfoRightOffset = Int($0) }
                        ), in: -200...200, step: 5)
                    }
                }
                Picker("日文歌词读音", selection: $settings.lyricsAnnotation) {
                    ForEach(LyricsAnnotation.allCases) { annotation in
                        Text(annotation.displayName).tag(annotation)
                    }
                }
                Text("罗马音在歌词上方另起一行，汉字读音把假名标在汉字正上方；缺少官方罗马音时自动生成读音")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("主界面环境色", isOn: $settings.showMainWindowAmbientBackground)
                if settings.showMainWindowAmbientBackground {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("背景色强度")
                            Spacer()
                            Text("\(Int(settings.mainWindowAmbientBackgroundIntensity * 100))%")
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: $settings.mainWindowAmbientBackgroundIntensity,
                            in: SettingsManager.mainWindowAmbientBackgroundIntensityRange,
                            step: 0.1
                        )
                        HStack {
                            Text("50%")
                            Spacer()
                            Text("150%")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                #if os(macOS)
                Toggle("桌面歌词", isOn: $settings.showDesktopLyrics)
                if settings.showDesktopLyrics {
                    Toggle("桌面歌词水平居中", isOn: $settings.desktopLyricsCentered)
                }
                Text("在屏幕上悬浮显示当前歌词，可拖动调整位置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
            }

            Section("底部栏") {
                NavigationLink {
                    BottomBarSettingsView()
                } label: {
                    Label("底部栏页面显示", systemImage: "rectangle.bottomthird.inset.filled")
                }
            }

            Section("存储") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(
                        "歌曲缓存",
                        isOn: Binding(
                            get: { settings.enableAudioCache },
                            set: { enabled in
                                settings.enableAudioCache = enabled
                                if enabled {
                                    Task { await enforceAudioCacheLimit() }
                                }
                            }
                        )
                    )
                    Text("关闭后将不读取或缓存歌曲")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if settings.enableAudioCache {
                        Slider(
                            value: Binding(
                                get: { Double(settings.audioCacheSizeMB) },
                                set: { settings.audioCacheSizeMB = Int($0.rounded()) }
                            ),
                            in: Double(SettingsManager.audioCacheSizeRangeMB.lowerBound)...Double(
                                SettingsManager.audioCacheSizeRangeMB.upperBound
                            ),
                            step: Double(SettingsManager.audioCacheSizeStepMB)
                        )
                        HStack {
                            Text("100 MB")
                            Spacer()
                            Text("1 GB")
                        }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("\(audioCacheUsage) / \(audioCacheLimit)")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("清理") {
                            Task { await clearAudioCache() }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("图片缓存")
                    HStack {
                        HStack(spacing: 4) {
                            Text("已占用")
                            Text(imageCacheUsage)
                        }
                        .foregroundStyle(.secondary)
                        Spacer()
                        Button("清理") {
                            Task { await clearImageCache() }
                        }
                    }
                }
                if let cacheError {
                    Text(cacheError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("账号") {
                if let profile = account.profile {
                    LabeledContent("当前账号", value: profile.nickname)
                    Button("退出登录", role: .destructive) {
                        Task { await AccountStore.shared.logout() }
                    }
                } else {
                    Text("未登录")
                        .foregroundStyle(.secondary)
                }
            }

            Section("关于") {
                LabeledContent("Kumone", value: appVersion)
                Text("网易云音乐第三方客户端 · 数据来自网易云音乐")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(width: 440, height: 600)
        #endif
        .task {
            await refreshCacheUsage()
            await enforceAudioCacheLimit()
        }
        #if os(macOS)
        .onChange(of: settings.audioCacheSizeMB) { _, _ in
            Task { await enforceAudioCacheLimit() }
        }
        #else
        .onChange(of: settings.audioCacheSizeMB) { _ in
            Task { await enforceAudioCacheLimit() }
        }
        #endif
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    private var audioCacheLimit: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(settings.audioCacheSizeMB) * 1_000_000,
            countStyle: .file
        )
    }

    private func refreshCacheUsage() async {
        do {
            audioCacheUsage = (try await AudioCache.shared.usage()).formatted
        } catch {
            cacheError = error.localizedDescription
        }
        do {
            imageCacheUsage = (try await ImageCache.shared.usage()).formatted
        } catch {
            cacheError = error.localizedDescription
        }
    }

    private func enforceAudioCacheLimit() async {
        guard settings.enableAudioCache else { return }
        do {
            try await AudioCache.shared.enforce(maximumSizeMB: settings.audioCacheSizeMB)
            await refreshCacheUsage()
        } catch {
            cacheError = error.localizedDescription
        }
    }

    private func clearAudioCache() async {
        do {
            try await AudioCache.shared.clear()
            ToastCenter.shared.show(String(localized: "歌曲缓存已清除"))
            await refreshCacheUsage()
        } catch {
            cacheError = error.localizedDescription
        }
    }

    private func clearImageCache() async {
        do {
            try await ImageCache.shared.clear()
            ToastCenter.shared.show(String(localized: "图片缓存已清除"))
            await refreshCacheUsage()
        } catch {
            cacheError = error.localizedDescription
        }
    }
}

// MARK: - 底部栏设置

/// 底部栏页面显示设置：可隐藏推荐/精选/漫游/搜索，"我的"强制显示不可隐藏。
struct BottomBarSettingsView: View {
    @EnvironmentObject private var settings: SettingsManager

    var body: some View {
        Form {
            Section {
                Toggle("推荐", isOn: Binding(
                    get: { !settings.hideHomeTab },
                    set: { settings.hideHomeTab = !$0 }
                ))
                Toggle("精选", isOn: Binding(
                    get: { !settings.hideExploreTab },
                    set: { settings.hideExploreTab = !$0 }
                ))
                Toggle("漫游", isOn: Binding(
                    get: { !settings.hideFmTab },
                    set: { settings.hideFmTab = !$0 }
                ))
                Toggle("搜索", isOn: Binding(
                    get: { !settings.hideSearchTab },
                    set: { settings.hideSearchTab = !$0 }
                ))
            } footer: {
                Text("关闭后该页面将从底部栏隐藏。「我的」为固定入口，不可隐藏。若当前所在页面被隐藏，将自动切换到第一个可见页面。")
            }
        }
        .navigationTitle("底部栏页面显示")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 字体导入按钮

/// 导入自定义字体（.ttf/.otf），注册后用于 AMLL 歌词
struct FontImportButton: View {
    @EnvironmentObject private var settings: SettingsManager
    @State private var showPicker = false

    var body: some View {
        Button {
            showPicker = true
        } label: {
            HStack {
                Label("导入自定义字体", systemImage: "textformat")
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showPicker) {
            FontPickerViewController { fontName in
                if let fontName {
                    settings.amllFontFamily = fontName
                    ToastCenter.shared.show("字体已导入：\(fontName)")
                }
                showPicker = false
            }
            .ignoresSafeArea()
        }
    }
}

/// 字体选择器（UIViewControllerRepresentable 封装 UIDocumentPickerViewController）
struct FontPickerViewController: UIViewControllerRepresentable {
    let onPick: (String?) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.font],
            asCopy: true
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (String?) -> Void

        init(onPick: @escaping (String?) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { onPick(nil); return }

            // 复制到 App 沙盒 Fonts 目录
            let fontsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Fonts", isDirectory: true)
            try? FileManager.default.createDirectory(at: fontsDir, withIntermediateDirectories: true)

            let destURL = fontsDir.appendingPathComponent(url.lastPathComponent)
            do {
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.copyItem(at: url, to: destURL)
            } catch {
                DispatchQueue.main.async {
                    ToastCenter.shared.show("字体文件复制失败")
                }
                onPick(nil)
                return
            }

            // 注册字体
            var error: Unmanaged<CFError>?
            CTFontManagerRegisterFontsForURL(destURL as CFURL, .process, &error)
            if let error = error?.takeRetainedValue() {
                DispatchQueue.main.async {
                    ToastCenter.shared.show("字体注册失败")
                }
                onPick(nil)
                return
            }

            // 获取字体名称
            if let fontDescriptors = CTFontManagerCreateFontDescriptorsFromURL(destURL as CFURL) as? [CTFontDescriptor],
               let firstDescriptor = fontDescriptors.first,
               let fontName = CTFontDescriptorCopyAttribute(firstDescriptor, kCTFontNameAttribute) as? String {
                onPick(fontName)
            } else {
                // 用文件名（去掉扩展名）作为字体名
                let fileName = destURL.deletingPathExtension().lastPathComponent
                onPick(fileName)
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onPick(nil)
        }
    }
}

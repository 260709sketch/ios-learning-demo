import SwiftUI

enum AudioQuality: String, CaseIterable, Identifiable {
    case standard
    case higher
    case exhigh
    case lossless
    case hires

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: return String(localized: "标准")
        case .higher: return String(localized: "较高")
        case .exhigh: return String(localized: "极高")
        case .lossless: return String(localized: "无损")
        case .hires: return "Hi-Res"
        }
    }

    var badge: String {
        switch self {
        case .standard: return String(localized: "标准")
        case .higher: return String(localized: "较高")
        case .exhigh: return String(localized: "极高")
        case .lossless: return String(localized: "无损")
        case .hires: return String(localized: "高解析")
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case auto, light, dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return String(localized: "跟随系统")
        case .light: return String(localized: "浅色")
        case .dark: return String(localized: "深色")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .auto: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// What to show above Japanese lyrics.
enum LyricsAnnotation: String, CaseIterable, Identifiable {
    case off
    case romaji
    case furigana

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return String(localized: "关闭")
        case .romaji: return String(localized: "罗马音")
        case .furigana: return String(localized: "汉字读音")
        }
    }
}

public enum NowPlayingMode: String, CaseIterable, Identifiable {
    case vinyl
    case classic
    case immersive
    case minimal

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .vinyl: return String(localized: "黑胶模式")
        case .classic: return String(localized: "经典模式")
        case .immersive: return String(localized: "沉浸模式")
        case .minimal: return String(localized: "简洁模式")
        }
    }
}

@MainActor
final class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    private enum Keys {
        static let quality = "settings.audioQuality"
        static let preloadNextTrack = "settings.preloadNextTrack"
        static let appearance = "settings.appearance"
        static let nowPlayingMode = "settings.nowPlayingMode"
        static let showTranslation = "settings.showLyricsTranslation"
        static let showRomaji = "settings.showLyricsRomaji"  // migrated to `annotation`
        static let annotation = "settings.lyricsAnnotation"
        static let verbatimLyrics = "settings.verbatimLyrics"
        static let useAMLLImmersive = "settings.useAMLLImmersive"
        static let amllBackgroundMode = "settings.amllBackgroundMode"
        static let amllLyricTop = "settings.amllLyricTop"
        static let amllLyricBottom = "settings.amllLyricBottom"
        static let amllLyricHorizontal = "settings.amllLyricHorizontal"
        static let amllFontSize = "settings.amllFontSize"
        static let amllFontWeight = "settings.amllFontWeight"
        static let amllFontFamily = "settings.amllFontFamily"
        static let showVIPBadge = "settings.showVIPBadge"
        // 底部栏隐藏设置（"我的"强制显示，不可隐藏）
        static let hideHomeTab = "settings.hideHomeTab"
        static let hideExploreTab = "settings.hideExploreTab"
        static let hideFmTab = "settings.hideFmTab"
        static let hideSearchTab = "settings.hideSearchTab"
        // 播放器组件位置调整
        static let playerArtworkTopOffset = "settings.playerArtworkTopOffset"
        static let playerArtworkScale = "settings.playerArtworkScale"
        static let playerTrackInfoSpacing = "settings.playerTrackInfoSpacing"
        static let playerControlsBottomOffset = "settings.playerControlsBottomOffset"
        static let playerTrackInfoTopOffset = "settings.playerTrackInfoTopOffset"
        static let playerTrackInfoLeftOffset = "settings.playerTrackInfoLeftOffset"
        static let playerTrackInfoRightOffset = "settings.playerTrackInfoRightOffset"
        static let volume = "settings.volume"
        static let fmMode = "settings.fmMode"
        static let unblock = "settings.enableUnblock"
        static let unblockSources = "settings.enabledUnblockSources"
        static let autoCheckUpdates = "settings.autoCheckUpdates"
        static let desktopLyrics = "settings.showDesktopLyrics"
        static let desktopLyricsCentered = "settings.desktopLyricsCentered"
        static let mainWindowAmbientBackground = "settings.showMainWindowAmbientBackground"
        static let mainWindowAmbientBackgroundIntensity = "settings.mainWindowAmbientBackgroundIntensity"
        static let enableAudioCache = "settings.enableAudioCache"
        static let audioCacheSizeMB = "settings.audioCacheSizeMB"
    }

    @Published var audioQuality: AudioQuality {
        didSet { UserDefaults.standard.set(audioQuality.rawValue, forKey: Keys.quality) }
    }

    /// 预加载下一首歌（播放5秒后预加载下一首，切换时不卡顿）
    @Published var preloadNextTrack: Bool {
        didSet { UserDefaults.standard.set(preloadNextTrack, forKey: Keys.preloadNextTrack) }
    }

    static let audioCacheSizeRangeMB = 100...1_000
    static let audioCacheSizeStepMB = 100

    /// Use locally stored audio files before resolving a remote source and
    /// retain completed remote playback for future requests.
    @Published var enableAudioCache: Bool {
        didSet { UserDefaults.standard.set(enableAudioCache, forKey: Keys.enableAudioCache) }
    }

    static func normalizedAudioCacheSizeMB(_ value: Int) -> Int {
        let boundedValue = min(
            max(value, audioCacheSizeRangeMB.lowerBound),
            audioCacheSizeRangeMB.upperBound
        )
        let distanceFromLowerBound = boundedValue - audioCacheSizeRangeMB.lowerBound
        return audioCacheSizeRangeMB.lowerBound
            + Int((Double(distanceFromLowerBound) / Double(audioCacheSizeStepMB)).rounded())
                * audioCacheSizeStepMB
    }

    @Published var audioCacheSizeMB: Int {
        didSet {
            let normalizedValue = Self.normalizedAudioCacheSizeMB(audioCacheSizeMB)
            guard normalizedValue == audioCacheSizeMB else {
                audioCacheSizeMB = normalizedValue
                return
            }
            UserDefaults.standard.set(audioCacheSizeMB, forKey: Keys.audioCacheSizeMB)
        }
    }

    @Published var appearance: AppAppearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    @Published var nowPlayingMode: NowPlayingMode {
        didSet { UserDefaults.standard.set(nowPlayingMode.rawValue, forKey: Keys.nowPlayingMode) }
    }

    @Published var showLyricsTranslation: Bool {
        didSet { UserDefaults.standard.set(showLyricsTranslation, forKey: Keys.showTranslation) }
    }

    /// Check for updates on launch. When off, no update sheet appears
    /// automatically; the user can still check manually (#42).
    @Published var autoCheckUpdates: Bool {
        didSet {
            UserDefaults.standard.set(autoCheckUpdates, forKey: Keys.autoCheckUpdates)
            #if os(macOS)
            UpdaterManager.shared.setAutomaticChecks(autoCheckUpdates)
            #endif
        }
    }

    /// Reading shown for Japanese lyrics: a romaji line above, furigana over
    /// the kanji, or nothing.
    @Published var lyricsAnnotation: LyricsAnnotation {
        didSet { UserDefaults.standard.set(lyricsAnnotation.rawValue, forKey: Keys.annotation) }
    }

    /// Karaoke-style word-by-word highlighting when the song has verbatim
    /// (yrc) lyrics; falls back to line highlighting when it doesn't.
    @Published var verbatimLyrics: Bool {
        didSet { UserDefaults.standard.set(verbatimLyrics, forKey: Keys.verbatimLyrics) }
    }

    /// Use AMLL (Apple Music Like Lyrics) WebView for immersive now-playing:
    /// flowing mesh-gradient background + sweeping word-by-word lyrics.
    @Published var useAMLLImmersive: Bool {
        didSet { UserDefaults.standard.set(useAMLLImmersive, forKey: Keys.useAMLLImmersive) }
    }

    /// AMLL 背景模式：流动背景 / 静态背景 / 原版背景
    enum AMLLBackgroundMode: String, CaseIterable {
        case flowing = "flowing"    // 流动背景（MeshGradient + 扫光歌词）
        case still = "still"        // 静态背景（隐藏流动背景，纯黑底+歌词）
        case original = "original"  // 原版背景（不使用AMLL，用原版布局）

        var displayName: String {
            switch self {
            case .flowing: return "流动背景"
            case .still: return "静态背景"
            case .original: return "原版背景"
            }
        }
    }

    @Published var amllBackgroundMode: AMLLBackgroundMode {
        didSet {
            UserDefaults.standard.set(amllBackgroundMode.rawValue, forKey: Keys.amllBackgroundMode)
            // 同步 useAMLLImmersive：original 模式关闭 AMLL，其他模式开启
            useAMLLImmersive = (amllBackgroundMode != .original)
        }
    }

    // MARK: AMLL 自定义布局
    @Published var amllLyricTop: Int {
        didSet { UserDefaults.standard.set(amllLyricTop, forKey: Keys.amllLyricTop) }
    }
    @Published var amllLyricBottom: Int {
        didSet { UserDefaults.standard.set(amllLyricBottom, forKey: Keys.amllLyricBottom) }
    }
    /// AMLL 歌词水平偏移（-200 ~ 200，正数右移，负数左移）
    @Published var amllLyricHorizontal: Int {
        didSet { UserDefaults.standard.set(amllLyricHorizontal, forKey: Keys.amllLyricHorizontal) }
    }
    @Published var amllFontSize: Int {
        didSet { UserDefaults.standard.set(amllFontSize, forKey: Keys.amllFontSize) }
    }
    @Published var amllFontWeight: Int {
        didSet { UserDefaults.standard.set(amllFontWeight, forKey: Keys.amllFontWeight) }
    }

    /// AMLL 歌词字体：空=系统默认，"PingFang SC"=黑体，"SF Pro Display"=SF粗体，其他=自定义字体名
    @Published var amllFontFamily: String {
        didSet { UserDefaults.standard.set(amllFontFamily, forKey: Keys.amllFontFamily) }
    }

    /// 搜索/列表中显示 VIP 歌曲标识（默认关闭，隐藏 VIP 标识）
    @Published var showVIPBadge: Bool {
        didSet { UserDefaults.standard.set(showVIPBadge, forKey: Keys.showVIPBadge) }
    }

    // MARK: 底部栏隐藏设置（"我的"强制显示，不可隐藏）
    @Published var hideHomeTab: Bool {
        didSet { UserDefaults.standard.set(hideHomeTab, forKey: Keys.hideHomeTab) }
    }
    @Published var hideExploreTab: Bool {
        didSet { UserDefaults.standard.set(hideExploreTab, forKey: Keys.hideExploreTab) }
    }
    @Published var hideFmTab: Bool {
        didSet { UserDefaults.standard.set(hideFmTab, forKey: Keys.hideFmTab) }
    }
    @Published var hideSearchTab: Bool {
        didSet { UserDefaults.standard.set(hideSearchTab, forKey: Keys.hideSearchTab) }
    }

    // MARK: 播放器组件位置调整
    /// 大封面顶部偏移（-100 ~ 100，正数下移，负数上移）
    @Published var playerArtworkTopOffset: Int {
        didSet { UserDefaults.standard.set(playerArtworkTopOffset, forKey: Keys.playerArtworkTopOffset) }
    }
    /// 大封面尺寸缩放（0.7 ~ 1.3）
    @Published var playerArtworkScale: Double {
        didSet { UserDefaults.standard.set(playerArtworkScale, forKey: Keys.playerArtworkScale) }
    }
    /// 歌曲信息与封面间距（0 ~ 60）
    @Published var playerTrackInfoSpacing: Int {
        didSet { UserDefaults.standard.set(playerTrackInfoSpacing, forKey: Keys.playerTrackInfoSpacing) }
    }
    /// 控制区域底部偏移（-50 ~ 100，正数下移，负数上移）
    @Published var playerControlsBottomOffset: Int {
        didSet { UserDefaults.standard.set(playerControlsBottomOffset, forKey: Keys.playerControlsBottomOffset) }
    }
    /// 歌曲信息上下偏移（-100 ~ 100，正数下移，负数上移）
    @Published var playerTrackInfoTopOffset: Int {
        didSet { UserDefaults.standard.set(playerTrackInfoTopOffset, forKey: Keys.playerTrackInfoTopOffset) }
    }
    /// 左侧歌曲信息（歌曲名+歌手）左右偏移（-50 ~ 50，正数右移，负数左移）
    @Published var playerTrackInfoLeftOffset: Int {
        didSet { UserDefaults.standard.set(playerTrackInfoLeftOffset, forKey: Keys.playerTrackInfoLeftOffset) }
    }
    /// 右侧按钮（爱心+更多）左右偏移（-50 ~ 50，正数右移，负数左移）
    @Published var playerTrackInfoRightOffset: Int {
        didSet { UserDefaults.standard.set(playerTrackInfoRightOffset, forKey: Keys.playerTrackInfoRightOffset) }
    }

    /// Resolve gray tracks from third-party sources (UnblockNeteaseMusic-style).
    @Published var enableUnblock: Bool {
        didSet { UserDefaults.standard.set(enableUnblock, forKey: Keys.unblock) }
    }

    /// Built-in third-party sources eligible for gray-track resolution.
    @Published var enabledAudioSourceIDs: Set<AudioSourceID> {
        didSet {
            UserDefaults.standard.set(
                enabledAudioSourceIDs.map(\.rawValue).sorted(),
                forKey: Keys.unblockSources
            )
        }
    }

    var canResolveUnblockedTracks: Bool {
        enableUnblock && !enabledAudioSourceIDs.isEmpty
    }

    /// Floating desktop lyrics window (LyricsX-style).
    @Published var showDesktopLyrics: Bool {
        didSet { UserDefaults.standard.set(showDesktopLyrics, forKey: Keys.desktopLyrics) }
    }

    /// Lock the desktop-lyrics capsule to the horizontal centre of the screen
    /// instead of the free-drag position (#48).
    @Published var desktopLyricsCentered: Bool {
        didSet { UserDefaults.standard.set(desktopLyricsCentered, forKey: Keys.desktopLyricsCentered) }
    }

    static let mainWindowAmbientBackgroundIntensityRange = 0.5...1.5

    /// Artwork-tinted overlay on the main app interface.
    @Published var showMainWindowAmbientBackground: Bool {
        didSet {
            UserDefaults.standard.set(
                showMainWindowAmbientBackground,
                forKey: Keys.mainWindowAmbientBackground
            )
        }
    }

    /// Multiplier applied to the main interface's artwork tint.
    @Published var mainWindowAmbientBackgroundIntensity: Double {
        didSet {
            UserDefaults.standard.set(
                mainWindowAmbientBackgroundIntensity,
                forKey: Keys.mainWindowAmbientBackgroundIntensity
            )
        }
    }
    private init() {
        let defaults = UserDefaults.standard
        audioQuality = defaults.string(forKey: Keys.quality).flatMap(AudioQuality.init) ?? .exhigh
        preloadNextTrack = defaults.object(forKey: Keys.preloadNextTrack) as? Bool ?? true
        enableAudioCache = defaults.object(forKey: Keys.enableAudioCache) as? Bool ?? true
        let storedAudioCacheSizeMB = defaults.object(forKey: Keys.audioCacheSizeMB) as? Int
            ?? AudioCache.defaultMaximumSizeMB
        let normalizedAudioCacheSizeMB = Self.normalizedAudioCacheSizeMB(storedAudioCacheSizeMB)
        audioCacheSizeMB = normalizedAudioCacheSizeMB
        defaults.set(normalizedAudioCacheSizeMB, forKey: Keys.audioCacheSizeMB)
        appearance = defaults.string(forKey: Keys.appearance).flatMap(AppAppearance.init) ?? .auto
        nowPlayingMode = defaults.string(forKey: Keys.nowPlayingMode).flatMap(NowPlayingMode.init) ?? .immersive
        showLyricsTranslation = defaults.object(forKey: Keys.showTranslation) as? Bool ?? true
        // Carry over the old on/off romaji toggle for anyone who had it on.
        lyricsAnnotation = defaults.string(forKey: Keys.annotation).flatMap(LyricsAnnotation.init)
            ?? (defaults.bool(forKey: Keys.showRomaji) ? .romaji : .off)
        verbatimLyrics = defaults.object(forKey: Keys.verbatimLyrics) as? Bool ?? true
        useAMLLImmersive = defaults.object(forKey: Keys.useAMLLImmersive) as? Bool ?? false
        // 背景模式：优先读取新设置，否则根据旧的 useAMLLImmersive 推导（开启=flowing，关闭=original）
        if let storedMode = defaults.string(forKey: Keys.amllBackgroundMode),
           let mode = AMLLBackgroundMode(rawValue: storedMode) {
            amllBackgroundMode = mode
        } else {
            amllBackgroundMode = useAMLLImmersive ? .flowing : .original
        }
        amllLyricTop = defaults.object(forKey: Keys.amllLyricTop) as? Int ?? 170
        amllLyricBottom = defaults.object(forKey: Keys.amllLyricBottom) as? Int ?? 230
        amllLyricHorizontal = defaults.object(forKey: Keys.amllLyricHorizontal) as? Int ?? 0
        amllFontSize = defaults.object(forKey: Keys.amllFontSize) as? Int ?? 22
        amllFontWeight = defaults.object(forKey: Keys.amllFontWeight) as? Int ?? 700
        amllFontFamily = defaults.string(forKey: Keys.amllFontFamily) ?? ""
        showVIPBadge = defaults.object(forKey: Keys.showVIPBadge) as? Bool ?? false
        hideHomeTab = defaults.object(forKey: Keys.hideHomeTab) as? Bool ?? false
        hideExploreTab = defaults.object(forKey: Keys.hideExploreTab) as? Bool ?? false
        hideFmTab = defaults.object(forKey: Keys.hideFmTab) as? Bool ?? false
        hideSearchTab = defaults.object(forKey: Keys.hideSearchTab) as? Bool ?? false
        playerArtworkTopOffset = defaults.object(forKey: Keys.playerArtworkTopOffset) as? Int ?? 0
        playerArtworkScale = defaults.object(forKey: Keys.playerArtworkScale) as? Double ?? 1.0
        playerTrackInfoSpacing = defaults.object(forKey: Keys.playerTrackInfoSpacing) as? Int ?? 20
        playerControlsBottomOffset = defaults.object(forKey: Keys.playerControlsBottomOffset) as? Int ?? 0
        playerTrackInfoTopOffset = defaults.object(forKey: Keys.playerTrackInfoTopOffset) as? Int ?? 0
        playerTrackInfoLeftOffset = defaults.object(forKey: Keys.playerTrackInfoLeftOffset) as? Int ?? 0
        playerTrackInfoRightOffset = defaults.object(forKey: Keys.playerTrackInfoRightOffset) as? Int ?? 0
        enableUnblock = defaults.object(forKey: Keys.unblock) as? Bool ?? true
        if let rawSourceIDs = defaults.stringArray(forKey: Keys.unblockSources) {
            enabledAudioSourceIDs = Set(rawSourceIDs.compactMap(AudioSourceID.init))
        } else {
            enabledAudioSourceIDs = Set(AudioSourceID.allCases)
        }
        autoCheckUpdates = defaults.object(forKey: Keys.autoCheckUpdates) as? Bool ?? false
        showDesktopLyrics = defaults.object(forKey: Keys.desktopLyrics) as? Bool ?? false
        desktopLyricsCentered = defaults.object(forKey: Keys.desktopLyricsCentered) as? Bool ?? false
        showMainWindowAmbientBackground = defaults.object(
            forKey: Keys.mainWindowAmbientBackground
        ) as? Bool ?? true
        let storedAmbientBackgroundIntensity = defaults.object(
            forKey: Keys.mainWindowAmbientBackgroundIntensity
        ) as? Double ?? 1
        mainWindowAmbientBackgroundIntensity = min(
            max(storedAmbientBackgroundIntensity, Self.mainWindowAmbientBackgroundIntensityRange.lowerBound),
            Self.mainWindowAmbientBackgroundIntensityRange.upperBound
        )
    }
}

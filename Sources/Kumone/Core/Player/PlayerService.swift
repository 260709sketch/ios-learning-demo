import AVFoundation
import Foundation

enum RepeatMode: String, CaseIterable {
    case off, all, one

    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

/// Where the current queue came from — used for scrobbling and UI affordances.
enum PlaySource: Equatable {
    case playlist(Int)
    case album(Int)
    case artist(Int)
    case daily
    case cloud
    case none

    var sourceID: Int {
        switch self {
        case .playlist(let id), .album(let id), .artist(let id): return id
        default: return 0
        }
    }
}

/// Where playback started from — listed under "Recently Played" in the Dock
/// menu, where picking one reloads it and starts playing again.
///
/// This is deliberately separate from `PlaySource`: heartbeat mode plays out
/// of the liked-songs playlist for scrobbling purposes, but as a *place* it is
/// its own thing, and the recents page has no source at all.
struct PlayContext: Codable, Hashable {
    enum Kind: String, Codable {
        /// Reloaded by id.
        case playlist, album, artist
        /// Fixed per-account entry points, each reloaded from its own API.
        case daily, cloud, recents, heartbeat, fm
    }

    let kind: Kind
    /// Zero for the fixed entry points, which have no id of their own.
    let id: Int
    let name: String

    static func playlist(id: Int, name: String) -> PlayContext {
        .init(kind: .playlist, id: id, name: name)
    }

    static func album(id: Int, name: String) -> PlayContext {
        .init(kind: .album, id: id, name: name)
    }

    static func artist(id: Int, name: String) -> PlayContext {
        .init(kind: .artist, id: id, name: name)
    }

    static var daily: PlayContext { .init(kind: .daily, id: 0, name: String(localized: "每日推荐")) }
    static var cloud: PlayContext { .init(kind: .cloud, id: 0, name: String(localized: "音乐云盘")) }
    static var recents: PlayContext { .init(kind: .recents, id: 0, name: String(localized: "最近播放")) }
    static var heartbeat: PlayContext { .init(kind: .heartbeat, id: 0, name: String(localized: "心动模式")) }
    static var fm: PlayContext { .init(kind: .fm, id: 0, name: String(localized: "私人漫游")) }

    /// Identity is the place, not its current title — a renamed playlist is
    /// still the same entry in the recents list.
    static func == (lhs: PlayContext, rhs: PlayContext) -> Bool {
        lhs.kind == rhs.kind && lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(id)
    }
}

enum RightPanel {
    case lyrics, queue
}

/// The playback engine: queue, shuffle/repeat, personal FM, URL resolution,
/// lyrics, scrobbling. Modeled on YesPlayMusic's Player class, backed by AVPlayer.
/// High-frequency playback position, isolated so per-tick updates only
/// re-render the scrubbers/lyrics that observe it — not every view holding
/// the PlayerService.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var progress: TimeInterval = 0
}

/// Which lyric line is current.
///
/// Every lyric view used to derive this itself, which meant observing the clock
/// and re-rendering on every tick just to discover the line hadn't changed —
/// and for the now-playing page, whose body is the whole immersive layout, that
/// was five full re-evaluations a second. Computing it once here and publishing
/// only on a change turns that into one re-render per lyric line.
@MainActor
final class LyricsCursor: ObservableObject {
    @Published var activeIndex: Int?
}

@MainActor
final class PlayerService: ObservableObject {
    static let shared = PlayerService()

    // MARK: - Observable state

    @Published private(set) var queue: [Track] = []
    @Published private(set) var shuffledQueue: [Track] = []
    @Published private(set) var playNextList: [Track] = []
    @Published private(set) var currentIndex = -1
    @Published private(set) var currentTrack: Track?
    @Published private(set) var source: PlaySource = .none
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var servedQuality: String?
    @Published private(set) var unblockSource: String?
    @Published private(set) var isTrial = false
    let clock = PlaybackClock()
    let lyricsCursor = LyricsCursor()
    let sleepTimer = SleepTimer()
    /// Passthrough to the clock so existing `progress` reads/writes keep working.
    var progress: TimeInterval {
        get { clock.progress }
        set { clock.progress = newValue }
    }
    @Published var repeatMode: RepeatMode = .off {
        didSet { UserDefaults.standard.set(repeatMode.rawValue, forKey: "player.repeat") }
    }

    @Published private(set) var shuffleEnabled = false
    @Published var volume: Float = 1 {
        didSet {
            engine.volume = volume
            UserDefaults.standard.set(volume, forKey: "player.volume")
        }
    }

    @Published private(set) var isFMMode = false
    @Published private(set) var fmUpcoming: [Track] = []
    /// Where playback was most recently started from, newest first —
    /// surfaced as "Recently Played" in the Dock menu.
    @Published private(set) var recentContexts: [PlayContext] = []
    @Published private(set) var lyrics: ParsedLyrics?
    @Published var activePanel: RightPanel?
    @Published var showNowPlaying = false

    /// The list the player is walking through (shuffled or ordered).
    var activeQueue: [Track] { shuffleEnabled ? shuffledQueue : queue }

    var upcomingTracks: [Track] {
        guard !activeQueue.isEmpty, currentIndex >= 0 else { return playNextList }
        let rest = activeQueue.suffix(from: min(currentIndex + 1, activeQueue.count))
        return playNextList + Array(rest.prefix(200))
    }

    var hasCurrentTrack: Bool { currentTrack != nil }

    // MARK: - Engine

    private let engine = AVPlayer()

    /// Live playback position straight from the player, for smooth per-frame
    /// karaoke highlighting (the published `progress` is intentionally coarse).
    var livePlaybackTime: TimeInterval {
        let t = engine.currentTime().seconds
        return t.isFinite ? t : progress
    }
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var audioResourceLoader: CachingAudioResourceLoader?
    private var pendingAudioResourceLoader: CachingAudioResourceLoader?
    private var audioCacheLease: UUID?
    private var statusObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var resolveGeneration = 0
    private var consecutiveFailures = 0
    private var attemptedUnblockSources: Set<AudioSourceID> = []
    private var currentUnblockSourceID: AudioSourceID?
    private var scrobbled = false
    private var startScrobbled = false

    // MARK: - 预加载下一首
    /// 预加载的下一首歌 AVPlayerItem（旧机制，已弃用，保留避免编译错误）
    private var preloadedNextItem: AVPlayerItem?
    /// 预加载的下一首歌 ID（旧机制，已弃用）
    private var preloadedNextTrackID: Int?
    /// 当前歌曲是否已触发预加载
    private var hasPreloadedCurrent = false
    /// 当前正在解析「正在播放」请求的数量；>0 时预加载让出单例音源运行时，避免抢占导致切歌卡住
    private var activeCurrentResolveCount = 0
    /// 预加载 URL 内存缓存（key: 平台+id，value: (url, 时间戳, 音源ID)），播放时优先命中实现秒开
    /// key 包含 sourcePlatform 避免不同平台歌曲 id 冲突（QQ音乐id为hashValue，可能与网易云id相同）
    /// 加入过期时间（60秒）和音源ID校验，避免使用过期URL或不同音源返回的URL
    private var preloadedURLs: [String: (url: String, timestamp: Date, sourceID: String)] = [:]
    private let preloadTTL: TimeInterval = 300 // 预加载URL有效期5分钟，正常听歌切歌时仍有效
    private func preloadCacheKey(for track: Track) -> String {
        "\(track.sourcePlatform ?? "wy")_\(track.id)"
    }

    private enum ResolvedURLLoadResult {
        case loaded
        case superseded
    }

    private init() {
        engine.actionAtItemEnd = .pause
        sleepTimer.onDeadlineReached = { [weak self] in
            self?.pause()
        }
        volume = UserDefaults.standard.object(forKey: "player.volume") as? Float ?? 0.8
        engine.volume = volume
        repeatMode = UserDefaults.standard.string(forKey: "player.repeat")
            .flatMap(RepeatMode.init) ?? .off

        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to activate audio session: \(error)")
        }

        // Resume after interruptions (phone calls, WeChat voice messages, …).
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.handleAudioInterruption(note)
            }
        }
        // Pause when the output route disappears (headphones unplugged).
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let reasonValue = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue),
                      reason == .oldDeviceUnavailable, self.isPlaying else { return }
                self.pause()
            }
        }
        #endif

        timeObserver = engine.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing else { return }
                let seconds = time.seconds
                guard seconds.isFinite else { return }

                // Lyrics need this cadence to stay in sync; the cursor itself
                // only publishes when the line actually changes.
                self.updateLyricsCursor(at: seconds)

                // The scrubber does not. Publishing the position every tick
                // re-renders it — and SwiftUI rebuilds the display list for the
                // whole tree each time — to move the thumb a fraction of a
                // pixel. Half a second is still smoother than the eye needs.
                if abs(seconds - self.progress) > 0.45 {
                    self.progress = seconds
                    NowPlayingManager.shared.updateElapsed(seconds, rate: self.isPlaying ? 1 : 0)
                }

                // 播放5秒后预加载下一首歌
                if seconds > 5 && !self.hasPreloadedCurrent {
                    self.hasPreloadedCurrent = true
                    self.preloadNextTrackIfNeeded()
                }
            }
        }

        statusObservation = engine.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                self?.isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            }
        }

        NowPlayingManager.shared.attach(to: self)
        restoreState()
    }

    /// Set while the user drags the seek bar so the time observer doesn't fight the thumb.
    var isScrubbing = false

    #if os(iOS)
    private var wasPlayingBeforeInterruption = false

    private func handleAudioInterruption(_ note: Notification) {
        guard let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        switch type {
        case .began:
            wasPlayingBeforeInterruption = isPlaying
            if isPlaying {
                // The system already silenced us; sync our state and UI.
                isPlaying = false
                NowPlayingManager.shared.updateElapsed(progress, rate: 0)
            }
        case .ended:
            let optionsValue = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            guard wasPlayingBeforeInterruption, options.contains(.shouldResume) else { return }
            wasPlayingBeforeInterruption = false
            try? AVAudioSession.sharedInstance().setActive(true)
            engine.play()
            isPlaying = true
            NowPlayingManager.shared.updateElapsed(progress, rate: 1)
        @unknown default:
            break
        }
    }
    #endif

    // MARK: - Entry points

    /// - Parameter context: the place these tracks came from. Supplying it
    ///   lists that place in the Dock menu's recently played section; callers
    ///   playing an ad-hoc selection (search results, a single track) omit it.
    func play(tracks: [Track], source: PlaySource, startAt track: Track? = nil,
              context: PlayContext? = nil) {
        guard !tracks.isEmpty else { return }
        if let context { recordRecent(context) }
        isFMMode = false
        queue = tracks
        self.source = source
        playNextList.removeAll()
        let startTrack = track ?? tracks[0]
        if shuffleEnabled {
            reshuffle(keeping: startTrack)
            currentIndex = 0
        } else {
            currentIndex = tracks.firstIndex(where: { $0.id == startTrack.id }) ?? 0
        }
        startPlaying(activeQueue[currentIndex])
    }

    func playTrack(_ track: Track) {
        if let idx = activeQueue.firstIndex(where: { $0.id == track.id }) {
            currentIndex = idx
            startPlaying(track)
        } else {
            play(tracks: [track], source: .none)
        }
    }

    /// Insert a track right after the current one.
    func addToPlayNext(_ track: Track, playNow: Bool = false) {
        playNextList.append(track)
        if playNow || currentTrack == nil {
            advanceToNext(userInitiated: true)
        } else {
            ToastCenter.shared.show(String(localized: "已添加到下一首播放"))
        }
    }

    func togglePlayPause() {
        guard let track = currentTrack else { return }
        if isPlaying {
            engine.pause()
            isPlaying = false
            AudioSpectrum.shared.reset()
        } else if engine.currentItem == nil {
            // Restored session: re-resolve the source.
            startPlaying(track, indexUnchanged: true)
            return
        } else {
            engine.play()
            isPlaying = true
            scrobbleStartIfNeeded()
        }
        NowPlayingManager.shared.updateElapsed(progress, rate: isPlaying ? 1 : 0)
    }

    func pause() {
        engine.pause()
        isPlaying = false
        AudioSpectrum.shared.reset()
        NowPlayingManager.shared.updateElapsed(progress, rate: 0)
    }

    func next() {
        advanceToNext(userInitiated: true)
    }

    func previous() {
        if isFMMode { return }
        if progress > 4 || activeQueue.isEmpty {
            seek(to: 0)
            return
        }
        var idx = currentIndex - 1
        if idx < 0 {
            guard repeatMode == .all else {
                seek(to: 0)
                return
            }
            idx = activeQueue.count - 1
        }
        currentIndex = idx
        startPlaying(activeQueue[idx])
    }

    /// Recomputes the current lyric line, publishing only on a change.
    /// The lead makes a line light up just before it is sung.
    private func updateLyricsCursor(at seconds: TimeInterval) {
        let index = lyrics?.activeIndex(at: seconds + 0.2)
        if index != lyricsCursor.activeIndex {
            lyricsCursor.activeIndex = index
        }
    }

    func seek(to seconds: TimeInterval, completion: (@MainActor () -> Void)? = nil) {
        progress = seconds
        updateLyricsCursor(at: seconds)
        engine.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            guard let completion else { return }
            Task { @MainActor in completion() }
        }
        NowPlayingManager.shared.updateElapsed(seconds, rate: isPlaying ? 1 : 0)
    }

    func toggleShuffle() {
        guard !isFMMode else { return }
        shuffleEnabled.toggle()
        guard let current = currentTrack else { return }
        if shuffleEnabled {
            reshuffle(keeping: current)
            currentIndex = 0
        } else {
            currentIndex = queue.firstIndex(where: { $0.id == current.id }) ?? 0
        }
    }

    func cycleRepeatMode() {
        guard !isFMMode else { return }
        repeatMode = repeatMode.next
    }

    /// Single-button mode cycle for the iOS minimal transport row:
    /// sequential → loop all → loop one → shuffle → sequential.
    func cyclePlaybackMode() {
        guard !isFMMode else { return }
        if shuffleEnabled {
            toggleShuffle()
            repeatMode = .off
        } else {
            switch repeatMode {
            case .off:
                repeatMode = .all
            case .all:
                repeatMode = .one
            case .one:
                repeatMode = .off
                toggleShuffle()
            }
        }
    }

    /// Jump to a track in the upcoming list (queue panel click).
    func jumpTo(_ track: Track) {
        if let nextIdx = playNextList.firstIndex(where: { $0.id == track.id }) {
            playNextList.removeSubrange(0...nextIdx)
            startPlaying(track, indexUnchanged: true)
            return
        }
        if let idx = activeQueue.firstIndex(where: { $0.id == track.id }) {
            currentIndex = idx
            startPlaying(track)
        }
    }

    func removeFromUpcoming(_ track: Track) {
        if let idx = playNextList.firstIndex(where: { $0.id == track.id }) {
            playNextList.remove(at: idx)
            return
        }
        if let idx = queue.firstIndex(where: { $0.id == track.id }), idx != currentIndex || shuffleEnabled {
            queue.remove(at: idx)
        }
        if let idx = shuffledQueue.firstIndex(where: { $0.id == track.id }) {
            shuffledQueue.remove(at: idx)
        }
    }

    // MARK: - Personal FM

    func startFM() {
        guard !isFMMode || !isPlaying else { return }
        recordRecent(.fm)
        isFMMode = true
        shuffleEnabled = false
        repeatMode = .off
        queue = []
        shuffledQueue = []
        playNextList = []
        currentIndex = -1
        source = .none
        Task { await fmAdvance() }
    }

    func fmNext() {
        guard isFMMode else { return }
        Task { await fmAdvance() }
    }

    func fmTrash() {
        guard isFMMode, let track = currentTrack else { return }
        Task {
            await fmAdvance()
            try? await NeteaseAPI.fmTrash(id: track.id)
        }
    }

    private func fmAdvance() async {
        if fmUpcoming.isEmpty {
            for attempt in 0..<3 {
                if let tracks = try? await NeteaseAPI.personalFM(), !tracks.isEmpty {
                    fmUpcoming = tracks
                    break
                }
                if attempt == 2 {
                    ToastCenter.shared.show(String(localized: "获取私人漫游数据失败"))
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        guard !fmUpcoming.isEmpty else { return }
        let track = fmUpcoming.removeFirst()
        startPlaying(track, indexUnchanged: true)
        if fmUpcoming.count < 1 {
            if let more = try? await NeteaseAPI.personalFM() {
                fmUpcoming.append(contentsOf: more)
            }
        }
    }

    // MARK: - Advancing

    private func advanceToNext(userInitiated: Bool) {
        if isFMMode {
            Task { await fmAdvance() }
            return
        }
        if !playNextList.isEmpty {
            let track = playNextList.removeFirst()
            startPlaying(track, indexUnchanged: true)
            return
        }
        guard !activeQueue.isEmpty else { return }
        var idx = currentIndex + 1
        if idx >= activeQueue.count {
            guard repeatMode == .all else {
                if userInitiated {
                    ToastCenter.shared.show(String(localized: "已经是最后一首了"))
                } else {
                    isPlaying = false
                    NowPlayingManager.shared.updateElapsed(progress, rate: 0)
                }
                return
            }
            idx = 0
        }
        currentIndex = idx
        startPlaying(activeQueue[idx])
    }

    private func handleItemEnded() {
        scrobbleIfNeeded(completed: true)

        if sleepTimer.consumeEndOfCurrentTrack() {
            progress = duration
            updateLyricsCursor(at: duration)
            pause()
            engine.replaceCurrentItem(with: nil)
            releaseCurrentPlaybackResources()
            return
        }

        guard isPlaying else { return }

        if repeatMode == .one, !isFMMode {
            scrobbled = false
            seek(to: 0)
            engine.play()
            isPlaying = true
            return
        }
        advanceToNext(userInitiated: false)
    }

    // MARK: - Source resolution

    private func startPlaying(_ track: Track, indexUnchanged: Bool = false) {
        pendingAudioResourceLoader?.cancel()
        pendingAudioResourceLoader = nil
        scrobbleIfNeeded(completed: false)
        currentTrack = track
        // 记录到本地最近播放
        RecentPlaysStore.shared.record(track: track)
        progress = 0
        duration = track.duration
        servedQuality = nil
        unblockSource = nil
        currentUnblockSourceID = nil
        attemptedUnblockSources.removeAll()
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        isTrial = false
        lyrics = nil
        scrobbled = false
        startScrobbled = false
        isPlaying = true
        lyricsCursor.activeIndex = nil
        // 重置预加载状态
        hasPreloadedCurrent = false

        // 如果有预加载的 item 且对应当前歌曲，直接使用（跳过 URL 解析，秒开）
        if preloadedNextTrackID == track.id, let preloadedItem = preloadedNextItem {
            preloadedNextItem = nil
            preloadedNextTrackID = nil
            AudioSpectrum.shared.beginPreparing()
            NowPlayingManager.shared.updateMetadata(for: track, duration: track.duration)
            persistState()

            // 复用预加载的 item
            if let old = endObserver { NotificationCenter.default.removeObserver(old) }
            endObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification, object: preloadedItem, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.handleItemEnded() }
            }
            engine.replaceCurrentItem(with: preloadedItem)
            engine.play()
            scrobbleStartIfNeeded()
            Task { await loadLyrics(for: track, generation: resolveGeneration) }
            return
        }
        // Before the URL is even resolved: holds the bars still rather than
        // letting them fall back to the decorative animation for the moment it
        // takes to find out whether this source can be tapped.
        AudioSpectrum.shared.beginPreparing()
        resolveGeneration += 1
        let generation = resolveGeneration

        NowPlayingManager.shared.updateMetadata(for: track, duration: track.duration)
        persistState()

        Task {
            await resolveAndLoad(track, generation: generation)
        }
        Task {
            await loadLyrics(for: track, generation: generation)
        }
    }

    /// 重新解析当前歌曲（切换音源后调用），用新音源获取播放链接并无缝切换
    func reloadCurrentTrack() {
        guard let track = currentTrack else { return }
        AudioSpectrum.shared.beginPreparing()
        resolveGeneration += 1
        let generation = resolveGeneration
        Task {
            await resolveAndLoad(track, generation: generation)
        }
        Task {
            await loadLyrics(for: track, generation: generation)
        }
    }

    private func resolveAndLoad(_ track: Track, generation: Int, preloadOnly: Bool = false) async {
        let quality = SettingsManager.shared.audioQuality.rawValue
        let allowsUnblock = SettingsManager.shared.canResolveUnblockedTracks
        let cacheEnabled = SettingsManager.shared.enableAudioCache
        let hasLXSource = LXSourceStore.shared.activeSourceID != nil
        let useAnySource = allowsUnblock || hasLXSource

        // LX音源激活时跳过AudioCache持久化缓存：
        // 1. LX音源URL有时效性，缓存会导致播放过期链接
        // 2. AudioCache只用track.id做key，QQ音乐(hashValue)与网易云id可能冲突，命中错误缓存
        if cacheEnabled && !hasLXSource {
            do {
                if let cached = try await AudioCache.shared.entry(
                    for: track.id,
                    requestedQuality: quality,
                    allowsUnblock: useAnySource
                ) {
                    guard generation == resolveGeneration else { return }
                    let lease = await AudioCache.shared.retain(cached)
                    guard generation == resolveGeneration else {
                        releaseAudioCacheLease(lease)
                        return
                    }
                    servedQuality = cached.metadata.servedQuality
                    if case .unblock(let source) = cached.metadata.source {
                        unblockSource = source
                    }
                    _ = await installResolvedAsset(
                        AVURLAsset(url: cached.fileURL),
                        for: track,
                        generation: generation,
                        durationMS: nil,
                        cacheLease: lease,
                        preloadOnly: preloadOnly
                    )
                    return
                }
            } catch {
                print("Audio cache lookup failed: \(error)")
            }
        }

        // 有 LX 自定义音源激活时，所有歌曲只向 LX 音源请求播放地址，
        // 音质由设置中的音质选项控制，自动遍历所有音源换源，不 fallback 到网易云官方或内置音源
        if hasLXSource {
            // 优先检查预加载URL缓存，命中则直接用URL播放（秒开，跳过音源请求）
            // 校验：未过期（60秒内）+ 音源ID匹配（当前激活音源）
            if !preloadOnly,
               let cached = preloadedURLs[preloadCacheKey(for: track)],
               Date().timeIntervalSince(cached.timestamp) < preloadTTL,
               cached.sourceID == (LXSourceStore.shared.activeSourceID ?? ""),
               let preloadedURL = URL(string: cached.url) {
                preloadedURLs[preloadCacheKey(for: track)] = nil // 用掉后清除
                DebugLogger.shared.log("预加载", "命中缓存 歌曲=\(track.name) 音源=\(cached.sourceID) 剩余有效期=\(String(format: "%.0f", preloadTTL - Date().timeIntervalSince(cached.timestamp)))s", level: .success)
                _ = await loadResolvedURL(track, url: preloadedURL, durationMS: nil, generation: generation, preloadOnly: false)
                return
            }
            // 缓存未命中，实时向音源请求播放地址，不做 URL 缓存（音源链接有时效性，缓存会导致播放过期链接）
            if await resolveFromLXSource(track, generation: generation, preloadOnly: preloadOnly) { return }
            // 预加载失败静默处理，不影响当前播放、不弹提示、不切歌
            if preloadOnly { return }
            // 所有 LX 音源均失败，提示用户后直接跳下一首
            // 不调用 handleUnplayable，因为它会基于网易云 VIP 判断显示"VIP 专属"，具有误导性
            await MainActor.run {
                ToastCenter.shared.show("所有音源均解析失败，请检查音源网络")
                consecutiveFailures += 1
                if consecutiveFailures < 5 {
                    advanceToNext(userInitiated: false)
                } else {
                    isPlaying = false
                }
            }
            return
        }

        var data = try? await NeteaseAPI.songURL(ids: [track.id], level: quality).first
        if data?.url == nil, quality != AudioQuality.standard.rawValue {
            data = try? await NeteaseAPI.songURL(ids: [track.id], level: AudioQuality.standard.rawValue).first
        }
        guard generation == resolveGeneration else { return }

        // 第三方平台歌曲（如QQ音乐）没有LX音源时，网易云API返回的是错误歌曲，直接提示不可播放
        if track.sourcePlatform != nil && track.sourcePlatform != "wy" && !hasLXSource {
            DebugLogger.shared.log("播放", "第三方平台歌曲(\(track.sourcePlatform ?? ""))无LX音源，跳过网易云通道", level: .warning)
            await MainActor.run {
                ToastCenter.shared.show("无法解析该歌曲，需要导入音源")
            }
            return
        }

        var resolvedURL: URL?
        if let urlString = data?.url {
            resolvedURL = URL(string: urlString.replacingOccurrences(of: "http://", with: "https://"))
        }

        // NetEase refused — try third-party sources (UnblockNeteaseMusic-style)
        if resolvedURL == nil || data?.freeTrialInfo != nil, allowsUnblock {
            if await resolveAndLoadUnblocked(track, generation: generation) { return }
        }
        guard generation == resolveGeneration else { return }

        guard let url = resolvedURL else {
            if cacheEnabled, await loadFallbackCache(
                for: track,
                generation: generation,
                allowsUnblock: allowsUnblock,
                preloadOnly: preloadOnly
            ) {
                return
            }
            handleUnplayable(track)
            return
        }

        servedQuality = data?.level
        if data?.freeTrialInfo != nil {
            isTrial = true
            ToastCenter.shared.show(String(localized: "VIP 歌曲，当前为试听片段"))
        }
        _ = await loadResolvedURL(track, url: url, durationMS: data?.time, generation: generation, preloadOnly: preloadOnly)
    }

    // MARK: - 预加载下一首

    /// 播放5秒后预加载下一首歌的URL，切换时秒开不卡顿
    /// 参考 Well Music RN 版实现：预加载只解析URL存入内存缓存，不创建AVPlayerItem，不碰任何播放全局状态
    private func preloadNextTrackIfNeeded() {
        guard SettingsManager.shared.preloadNextTrack else { return }
        guard let nextTrack = upcomingTracks.first else { return }
        // 已经预加载过同一首且未过期，跳过
        if let cached = preloadedURLs[preloadCacheKey(for: nextTrack)],
           Date().timeIntervalSince(cached.timestamp) < preloadTTL { return }
        Task {
            await preloadResolveURLOnly(nextTrack)
        }
    }

    /// 仅解析下一首歌的URL并存入缓存，不创建AVPlayerItem、不切换音源、不修改任何播放全局状态
    /// 当前正在解析播放歌曲时（activeCurrentResolveCount > 0）直接让出，避免抢占单例音源运行时
    private func preloadResolveURLOnly(_ track: Track) async {
        // 当前正在解析播放歌曲时，让出单例音源运行时，避免抢占导致切歌卡住
        guard activeCurrentResolveCount == 0 else { return }

        let lxEngine = LXMusicEngine.shared
        let lxStore = LXSourceStore.shared
        let targetQuality = lxEngine.lxQuality(from: SettingsManager.shared.audioQuality)

        // 只用当前已加载的音源，不切换音源（unload/load会打断当前播放）
        guard let currentSource = lxEngine.currentSource else { return }
        guard lxStore.sources.contains(where: { $0.id == currentSource.id }) else { return }

        do {
            let result = try await lxEngine.musicURL(for: track, quality: targetQuality)
            guard !result.url.isEmpty else { return }
            guard URL(string: result.url) != nil else { return }
            // 存入预加载缓存（带时间戳和音源ID）
            preloadedURLs[preloadCacheKey(for: track)] = (url: result.url, timestamp: Date(), sourceID: currentSource.id)
            DebugLogger.shared.log("预加载", "成功 歌曲=\(track.name) 音源=\(currentSource.name) URL=\(result.url.prefix(60))...", level: .success)
            // 限制缓存大小，最多存5首，避免内存占用
            if preloadedURLs.count > 5 {
                if let firstKey = preloadedURLs.keys.first {
                    preloadedURLs[firstKey] = nil
                }
            }
        } catch {
            // 预加载失败完全静默，不弹提示、不切歌、不影响当前播放
            DebugLogger.shared.log("预加载", "失败 歌曲=\(track.name) 错误=\(error.localizedDescription)", level: .error)
        }
    }

    private func resolveAndLoadUnblocked(
        _ track: Track,
        generation: Int,
        requiresActivePlayback: Bool = false
    ) async -> Bool {
        let hasLXSource = LXSourceStore.shared.activeSourceID != nil

        guard hasLXSource else { return false }
        guard generation == resolveGeneration,
              !requiresActivePlayback || isPlaying
        else { return false }

        // 只使用 LX 自定义音源（自动换源），已移除内置第三方音源
        return await resolveFromLXSource(track, generation: generation)
    }

    /// 使用已激活的 LX 自定义音源脚本获取播放地址。
    private func resolveFromLXSource(_ track: Track, generation: Int, preloadOnly: Bool = false) async -> Bool {
        // 当前播放解析计数：预加载检查此值，>0 时让出，避免抢占单例音源运行时
        if !preloadOnly { activeCurrentResolveCount += 1 }
        defer { if !preloadOnly { activeCurrentResolveCount -= 1 } }

        let lxStore = LXSourceStore.shared
        let lxEngine = LXMusicEngine.shared
        let targetQuality = lxEngine.lxQuality(from: SettingsManager.shared.audioQuality)
        let platform = track.sourcePlatform ?? "wy"
        DebugLogger.shared.log("LX", "\(preloadOnly ? "[预加载]" : "[播放]") 开始解析 歌曲=\(track.name) 平台=\(platform) songmid=\(track.platformSongId ?? String(track.id)) 请求音质=\(targetQuality)")

        // 构建音源尝试顺序：优先音源排第一，其余按导入顺序
        var sourcesToTry = lxStore.sources
        if let activeID = lxStore.activeSourceID,
           let activeIndex = sourcesToTry.firstIndex(where: { $0.id == activeID }) {
            let activeSource = sourcesToTry.remove(at: activeIndex)
            sourcesToTry.insert(activeSource, at: 0)
        }

        guard !sourcesToTry.isEmpty else { return false }

        for (index, source) in sourcesToTry.enumerated() {
            // 正常播放要求 generation 精确匹配；预加载 generation > resolveGeneration 也允许执行；
            // 旧任务（generation < resolveGeneration）直接丢弃。
            guard generation >= resolveGeneration else { return false }
            let startTime = Date()
            let isPriority = index == 0

            // 预加载时不切换音源——unload/load 会打断当前播放。
            // 只用当前已加载的音源解析下一首；当前音源不匹配则跳过。
            if preloadOnly && lxEngine.currentSource?.id != source.id {
                continue
            }

            do {
                // 切换音源（如果当前加载的不是这个音源）
                if lxEngine.currentSource?.id != source.id {
                    await lxEngine.unload()
                    guard let script = lxStore.script(for: source.id) else { continue }
                    try await lxEngine.load(source: source, script: script)
                }

                let result = try await lxEngine.musicURL(for: track, quality: targetQuality)
                guard generation >= resolveGeneration else { return false }
                DebugLogger.shared.log("LX", "音源[\(source.name)]返回 URL=\(result.url) 实际音质=\(result.quality) 耗时=\(String(format: "%.1f", Date().timeIntervalSince(startTime)))s", level: .success)
                // LX音源返回的URL不做http→https替换——第三方音源服务器很多只支持HTTP，强制替换会导致无法播放
                guard let url = URL(string: result.url) else {
                    DebugLogger.shared.log("LX", "音源[\(source.name)]返回URL无效", level: .error)
                    let log = LXRequestLog(
                        date: Date(), trackName: track.name, trackArtist: track.artistNames,
                        requestedQuality: targetQuality, actualQuality: nil, url: nil,
                        duration: Date().timeIntervalSince(startTime), success: false,
                        errorMessage: "返回 URL 无效"
                    )
                    await MainActor.run { lxStore.addRequestLog(log) }
                    continue
                }

                // 全局状态只在正常播放时修改，预加载不干扰当前播放
                if !preloadOnly {
                    currentUnblockSourceID = nil
                    unblockSource = source.name
                    servedQuality = result.quality
                    isTrial = false
                }

                let loadResult = await loadResolvedURL(
                    track,
                    url: url,
                    durationMS: nil,
                    generation: generation,
                    preloadOnly: preloadOnly
                )
                guard case .loaded = loadResult else {
                    let log = LXRequestLog(
                        date: Date(), trackName: track.name, trackArtist: track.artistNames,
                        requestedQuality: targetQuality, actualQuality: result.quality, url: result.url,
                        duration: Date().timeIntervalSince(startTime), success: false,
                        errorMessage: "音频加载失败"
                    )
                    await MainActor.run { lxStore.addRequestLog(log) }
                    continue
                }

                // 记录成功日志
                let log = LXRequestLog(
                    date: Date(), trackName: track.name, trackArtist: track.artistNames,
                    requestedQuality: targetQuality, actualQuality: result.quality, url: result.url,
                    duration: Date().timeIntervalSince(startTime), success: true, errorMessage: nil
                )
                await MainActor.run { lxStore.addRequestLog(log) }

                // 非优先音源成功时，提示自动换源（预加载不提示）
                if !isPriority && !preloadOnly {
                    await MainActor.run {
                        ToastCenter.shared.show("自动换源：已使用「\(source.name)」播放")
                    }
                }
                return true
            } catch {
                let log = LXRequestLog(
                    date: Date(), trackName: track.name, trackArtist: track.artistNames,
                    requestedQuality: targetQuality, actualQuality: nil, url: nil,
                    duration: Date().timeIntervalSince(startTime), success: false,
                    errorMessage: error.localizedDescription
                )
                await MainActor.run { lxStore.addRequestLog(log) }
                continue
            }
        }

        // 全部音源失败
        return false
    }

    private func handleUnplayable(_ track: Track) {
        consecutiveFailures += 1
        // 有 LX 音源时不显示基于网易云 VIP 判断的 reason（如"VIP 专属"），避免误导
        let hasLX = LXSourceStore.shared.activeSourceID != nil
        let reason = hasLX ? nil : track.playability(privilege: nil,
                                       isLoggedIn: AccountStore.shared.isLoggedIn,
                                       vipType: AccountStore.shared.vipType).reason
        if let reason {
            ToastCenter.shared.show(String(localized: "《\(track.name)》无法播放：\(reason)"))
        } else if !hasLX {
            ToastCenter.shared.show(String(localized: "《\(track.name)》无法播放"))
        }
        guard isPlaying else {
            engine.replaceCurrentItem(with: nil)
            releaseCurrentPlaybackResources()
            return
        }
        if consecutiveFailures < 5 {
            advanceToNext(userInitiated: false)
        } else {
            isPlaying = false
        }
    }

    private func loadResolvedURL(
        _ track: Track,
        url: URL,
        durationMS: Int?,
        generation: Int,
        preloadOnly: Bool = false
    ) async -> ResolvedURLLoadResult {
        // 预加载不重置连续失败计数，不影响当前播放状态
        if !preloadOnly { consecutiveFailures = 0 }

        var asset = AVURLAsset(url: url)
        var resourceLoader: CachingAudioResourceLoader?
        // LX音源返回的URL可能有特殊字符，缓存层处理不了，直接用原始URL播放
        if SettingsManager.shared.enableAudioCache, !isTrial, unblockSource == nil {
            let source: AudioCacheSource = .netease
            do {
                let loader = try CachingAudioResourceLoader(
                    remoteURL: url,
                    trackID: track.id,
                    requestedQuality: SettingsManager.shared.audioQuality.rawValue,
                    servedQuality: servedQuality,
                    source: source,
                    maximumCacheSizeMB: SettingsManager.shared.audioCacheSizeMB
                )
                // 预加载 generation > resolveGeneration 也允许执行；旧任务才丢弃
                guard generation >= resolveGeneration else {
                    loader.cancel()
                    return .superseded
                }
                let cachedAsset = AVURLAsset(url: loader.assetURL)
                loader.attach(to: cachedAsset)
                pendingAudioResourceLoader = loader
                resourceLoader = loader
                asset = cachedAsset
            } catch {
                print("Audio source will play without caching: \(error)")
            }
        }

        return await installResolvedAsset(
            asset,
            for: track,
            generation: generation,
            durationMS: durationMS,
            resourceLoader: resourceLoader,
            preloadOnly: preloadOnly
        )
    }

    private func loadFallbackCache(
        for track: Track,
        generation: Int,
        allowsUnblock: Bool,
        preloadOnly: Bool = false
    ) async -> Bool {
        do {
            guard let cached = try await AudioCache.shared.fallbackEntry(
                for: track.id,
                allowsUnblock: allowsUnblock
            ) else { return false }
            guard generation == resolveGeneration else { return true }
            let lease = await AudioCache.shared.retain(cached)
            guard generation == resolveGeneration else {
                releaseAudioCacheLease(lease)
                return true
            }
            servedQuality = cached.metadata.servedQuality
            if case .unblock(let source) = cached.metadata.source {
                unblockSource = source
            }
            _ = await installResolvedAsset(
                AVURLAsset(url: cached.fileURL),
                for: track,
                generation: generation,
                durationMS: nil,
                cacheLease: lease,
                preloadOnly: preloadOnly
            )
            return true
        } catch {
            print("Audio cache fallback lookup failed: \(error)")
            return false
        }
    }

    private func installResolvedAsset(
        _ asset: AVURLAsset,
        for track: Track,
        generation: Int,
        durationMS: Int?,
        resourceLoader: CachingAudioResourceLoader? = nil,
        cacheLease: UUID? = nil,
        preloadOnly: Bool = false
    ) async -> ResolvedURLLoadResult {
        // Resolve the asset's audio track before the item goes live: an audio mix
        // attached after playback starts is silently ignored, so the spectrum tap
        // has to be spliced in here or not at all. Unsupported sources and iOS
        // cache hits play untapped and use the decorative UI fallback.
        #if os(iOS)
        // Cached files already have a complete local media source. Keeping their
        // playback path free of a MediaToolbox processing tap avoids rebuilding
        // the custom render pipeline on every rapid cache-to-cache switch.
        let assetTrack = asset.url.isFileURL
            ? nil
            : await loadAudioTrack(from: asset, timeout: 2)
        #else
        let assetTrack = await loadAudioTrack(from: asset, timeout: 2)
        #endif
        guard generation == resolveGeneration,
              resourceLoader.map({ pendingAudioResourceLoader === $0 }) ?? true else {
            resourceLoader?.cancel()
            if let cacheLease {
                releaseAudioCacheLease(cacheLease)
            }
            return .superseded
        }

        let item = AVPlayerItem(asset: asset)
        if let assetTrack,
           let mix = AudioSpectrum.shared.makeAudioMix(for: assetTrack) {
            item.audioMix = mix
        } else {
            AudioSpectrum.shared.markUntappable()
        }

        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        // 所有音源都观察 AVPlayerItem status，加载失败时记录日志并处理
        let urlString = asset.url.absoluteString
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let errorDesc = item.error?.localizedDescription ?? "未知错误"
            DebugLogger.shared.log("Player", "AVPlayerItem加载失败: \(errorDesc) URL=\(urlString)", level: .error)
            Task { @MainActor in
                if let sourceID = self?.currentUnblockSourceID {
                    self?.handleUnblockItemFailure(track: track, generation: generation, sourceID: sourceID)
                }
            }
        }

        if let old = endObserver {
            NotificationCenter.default.removeObserver(old)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleItemEnded()
            }
        }
        let previousResourceLoader = audioResourceLoader
        let previousCacheLease = audioCacheLease
        if resourceLoader != nil {
            pendingAudioResourceLoader = nil
        }

        if preloadOnly {
            // 预加载模式：存储 item，不替换当前播放项，提前触发元数据加载
            preloadedNextItem = item
            preloadedNextTrackID = track.id
            item.asset.loadValuesAsynchronously(forKeys: ["playable", "duration"]) {}
            return .loaded
        }

        audioResourceLoader = resourceLoader
        audioCacheLease = cacheLease
        engine.replaceCurrentItem(with: item)
        previousResourceLoader?.cancel()
        if let previousCacheLease {
            releaseAudioCacheLease(previousCacheLease)
        }
        if isPlaying {
            engine.play()
            scrobbleStartIfNeeded()
        }

        if let durationMS, durationMS > 0 {
            duration = TimeInterval(durationMS) / 1000
            NowPlayingManager.shared.updateMetadata(for: track, duration: duration)
        }
        return .loaded
    }

    private func handleUnblockItemFailure(
        track: Track,
        generation: Int,
        sourceID: AudioSourceID
    ) {
        guard generation == resolveGeneration,
              currentTrack?.id == track.id,
              currentUnblockSourceID == sourceID
        else { return }

        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        currentUnblockSourceID = nil
        unblockSource = nil
        engine.replaceCurrentItem(with: nil)
        releaseCurrentPlaybackResources()
        AudioSpectrum.shared.beginPreparing()

        guard isPlaying else {
            return
        }

        Task {
            let loaded = await resolveAndLoadUnblocked(
                track,
                generation: generation,
                requiresActivePlayback: true
            )
            guard isPlaying else { return }
            guard loaded else {
                guard generation == resolveGeneration else { return }
                handleUnplayable(track)
                return
            }
        }
    }

    private func releaseAudioCacheLease(_ leaseID: UUID) {
        Task {
            do {
                try await AudioCache.shared.release(leaseID)
            } catch {
                print("Audio cache could not release its playback lease: \(error)")
            }
        }
    }

    private func releaseCurrentPlaybackResources() {
        let resourceLoader = audioResourceLoader
        let cacheLease = audioCacheLease
        audioResourceLoader = nil
        audioCacheLease = nil
        resourceLoader?.cancel()
        if let cacheLease {
            releaseAudioCacheLease(cacheLease)
        }
    }

    /// Resolves the asset's audio track, giving up after `timeout` so a slow or
    /// uncooperative source delays playback no longer than it would today.
    private func loadAudioTrack(from asset: AVURLAsset, timeout: TimeInterval) async -> AVAssetTrack? {
        await withTaskGroup(of: AVAssetTrack?.self) { group in
            group.addTask {
                try? await asset.loadTracks(withMediaType: .audio).first
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func loadLyrics(for track: Track, generation: Int) async {
        // QQ音乐：优先获取 QRC 逐字歌词，成功则直接使用
        if track.sourcePlatform == "tx", let songmid = track.platformSongId {
            if let qrcLines = await QQMusicAPI.wordLyric(songmid: songmid), !qrcLines.isEmpty {
                guard generation == resolveGeneration else { return }
                var parsed = ParsedLyrics()
                parsed.lines = qrcLines
                lyrics = parsed
                updateLyricsCursor(at: progress)
                // QQ音乐歌曲保底：仅当本身无封面时，向网易云搜索同名同歌手匹配封面
                if (track.album.picUrl ?? "").isEmpty {
                    await matchCoverFromNetEase(for: track, generation: generation)
                }
                return
            }
        }
        // 回退：逐行 LRC 歌词
        let response: LyricResponse?
        if track.sourcePlatform == "tx", let songmid = track.platformSongId {
            response = try? await QQMusicAPI.lyric(songmid: songmid)
        } else {
            response = try? await NeteaseAPI.lyric(id: track.id)
        }
        guard generation == resolveGeneration else { return }
        lyrics = response.map(LyricsParser.parse)
        updateLyricsCursor(at: progress)

        // QQ音乐歌曲保底：仅当本身无封面时，向网易云搜索同名同歌手匹配封面，供 AMLL 背景提取颜色
        if track.sourcePlatform == "tx", (track.album.picUrl ?? "").isEmpty {
            await matchCoverFromNetEase(for: track, generation: generation)
        }
    }

    // MARK: - QQ音乐封面保底（向网易云搜索同名同歌手同专辑匹配）
    private func matchCoverFromNetEase(for track: Track, generation: Int) async {
        // 构造搜索关键词：歌名 + 第一个歌手名
        let artistName = track.artists.first?.name ?? ""
        let keyword = "\(track.name) \(artistName)".trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return }

        // 调用网易云搜索
        guard let searchResult = try? await NeteaseAPI.search(keyword, type: .songs, limit: 10),
              let songs = searchResult.songs, !songs.isEmpty else { return }

        // 精准匹配：歌名相同 + 至少一个歌手名相同
        let targetArtistNames = Set(track.artists.map { $0.name })
        let matched = songs.first { candidate in
            let candidateArtists = Set(candidate.artists.map { $0.name })
            let nameMatch = candidate.name == track.name || candidate.name.contains(track.name) || track.name.contains(candidate.name)
            let artistMatch = !targetArtistNames.isDisjoint(with: candidateArtists)
            return nameMatch && artistMatch
        } ?? songs.first

        guard let matchedTrack = matched,
              let coverURL = matchedTrack.album.picUrl,
              !coverURL.isEmpty else { return }

        // 用匹配到的封面替换当前歌曲的封面（通过 JSON 编码/解码修改 picUrl）
        guard generation == resolveGeneration,
              currentTrack?.id == track.id else { return }

        if let data = try? JSONEncoder().encode(track),
           var dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           var al = dict["al"] as? [String: Any] {
            al["picUrl"] = coverURL
            dict["al"] = al
            if let newData = try? JSONSerialization.data(withJSONObject: dict),
               let newTrack = try? JSONDecoder().decode(Track.self, from: newData) {
                currentTrack = newTrack
            }
        }
    }

    // MARK: - Scrobble

    private func scrobbleStartIfNeeded() {
        guard let track = currentTrack, !startScrobbled else { return }
        startScrobbled = true
        let trackID = track.id
        let sourceID = source.sourceID
        Task.detached {
            await NeteaseAPI.scrobbleStart(trackID: trackID, sourceID: sourceID)
        }
    }

    private func scrobbleIfNeeded(completed: Bool) {
        guard let track = currentTrack, !scrobbled, progress > 1 else { return }
        scrobbled = true
        let seconds = completed ? Int(duration) : Int(progress)
        let sourceID = source.sourceID
        Task.detached {
            await NeteaseAPI.scrobbleFinish(trackID: track.id, sourceID: sourceID, seconds: seconds)
        }
    }

    // MARK: - Shuffle helpers

    private func reshuffle(keeping first: Track) {
        var rest = queue.filter { $0.id != first.id }
        rest.shuffle()
        shuffledQueue = [first] + rest
    }

    // MARK: - Persistence

    private static let recentContextsLimit = 6

    private func recordRecent(_ context: PlayContext) {
        recentContexts.removeAll { $0 == context }
        recentContexts.insert(context, at: 0)
        if recentContexts.count > Self.recentContextsLimit {
            recentContexts.removeLast(recentContexts.count - Self.recentContextsLimit)
        }
    }

    /// Reloads a place from the recents list and starts playing it again.
    func play(context: PlayContext) {
        // Personal FM is a stream, not a fixed list — restart it in place.
        guard context.kind != .fm else { return startFM() }
        Task {
            do {
                guard let resolved = try await resolve(context) else { return }
                play(tracks: resolved.tracks, source: resolved.source, context: context)
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

    func resolve(_ context: PlayContext) async throws -> (tracks: [Track], source: PlaySource)? {
        switch context.kind {
        case .fm:
            return nil
        case .album:
            return (try await NeteaseAPI.album(id: context.id).songs, .album(context.id))
        case .artist:
            return (try await NeteaseAPI.artist(id: context.id).hotSongs, .artist(context.id))
        case .daily:
            return (try await NeteaseAPI.dailyRecommendSongs(), .daily)
        case .cloud:
            let songs = try await NeteaseAPI.cloudSongs().data?.compactMap(\.simpleSong) ?? []
            return (songs, .cloud)
        case .recents:
            guard let uid = AccountStore.shared.profile?.userId else { return nil }
            return (try await NeteaseAPI.playRecords(uid: uid, week: false).map(\.song), .none)
        case .heartbeat:
            // Regenerated from a fresh seed, the same way the Home card does it.
            guard let liked = AccountStore.shared.likedSongsPlaylist,
                  let seed = AccountStore.shared.likedTrackIDs.randomElement() else { return nil }
            let tracks = try await NeteaseAPI.intelligenceList(songID: seed, playlistID: liked.id)
            return (tracks, .playlist(liked.id))
        case .playlist:
            let response = try await NeteaseAPI.playlistDetail(id: context.id)
            var tracks = response.playlist.tracks
            // /v6/playlist/detail only carries the first page of tracks.
            let remaining = response.playlist.trackIds.map(\.id).dropFirst(tracks.count)
            for chunk in stride(from: 0, to: remaining.count, by: 500)
                .map({ Array(remaining.dropFirst($0).prefix(500)) }) {
                guard let more = try? await NeteaseAPI.songDetails(ids: chunk) else { break }
                tracks += more.songs
            }
            return (tracks, .playlist(context.id))
        }
    }

    private struct PersistedState: Codable {
        var queue: [Track]
        var currentID: Int?
        var repeatMode: String
        var shuffle: Bool
        /// Optional so state files written before recents existed still decode.
        var recentContexts: [PlayContext]?
    }

    private func persistState() {
        let state = PersistedState(
            queue: Array(queue.prefix(1000)),
            currentID: currentTrack?.id,
            repeatMode: repeatMode.rawValue,
            shuffle: shuffleEnabled,
            recentContexts: recentContexts
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        let url = Self.stateFileURL
        Task.detached {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func restoreState() {
        guard let data = try? Data(contentsOf: Self.stateFileURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data)
        else { return }
        // Recents outlive the queue: restore them before bailing out on an
        // empty queue, or the next played track persists an empty list over
        // them and the Dock menu loses its history for good.
        recentContexts = Array((state.recentContexts ?? []).prefix(Self.recentContextsLimit))
        guard !state.queue.isEmpty else { return }
        queue = state.queue
        shuffleEnabled = state.shuffle
        if shuffleEnabled {
            shuffledQueue = queue.shuffled()
        }
        if let id = state.currentID,
           let idx = activeQueue.firstIndex(where: { $0.id == id }) {
            currentIndex = idx
            currentTrack = activeQueue[idx]
            duration = activeQueue[idx].duration
            NowPlayingManager.shared.updateMetadata(for: activeQueue[idx], duration: duration)
            Task {
                await loadLyrics(for: activeQueue[idx], generation: resolveGeneration)
            }
        }
    }

    private static var stateFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kumone", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("player-state.json")
    }
}

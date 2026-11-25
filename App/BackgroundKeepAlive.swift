import AVFoundation

/// Keeps CarWithin running after the user leaves the app or locks the phone.
///
/// iOS suspends a backgrounded app about 10 seconds after it stops doing declared background
/// work, which kills the CarPlay session, the browser receiver and every socket. CarPlay audio
/// only runs while the iPhone actually plays sound, and Picture in Picture is not shown on the
/// lock screen. Looping silent audio counts as playback for the `audio` background mode.
///
/// It starts in the foreground before requesting CarPlay and stays active for the session.
/// Waiting for the app to resign active can fail once the virtual CarAudio route is selected.
/// It uses `AVAudioPlayer` rather than a second
/// `AVAudioEngine`: an extra engine that restarted on configuration changes stalled every CarPlay
/// audio stream SETUP for ~8 s and broke the connection. It never changes an audio session
/// category that CarPlay audio or PiP has already chosen.
///
/// The shared audio session is the weak point: when the last CarPlay audio stream ends (a
/// navigation prompt, paused music) `CarPlayAudio` used to deactivate the session, which also
/// stopped this player, and the app was suspended ~10 s later. `CarPlayAudio` now checks
/// `holdsAudioSession` before deactivating, and a watchdog restarts the player if anything
/// else stops it.
final class BackgroundKeepAlive {
    private var player: AVAudioPlayer?
    private var observers: [NSObjectProtocol] = []
    private var watchdog: Timer?
    private var restarts = 0
    private(set) var isRunning = false
    var onLog: ((String) -> Void)?

    private static let lock = NSLock()
    private static var holding = false
    /// True while the keep-alive needs the shared audio session active. Read from any queue.
    static var holdsAudioSession: Bool {
        lock.lock(); defer { lock.unlock() }
        return holding
    }
    private static func setHolding(_ value: Bool) { lock.lock(); holding = value; lock.unlock() }

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        Self.setHolding(true)
        guard play(reason: nil) else { Self.setHolding(false); return false }
        isRunning = true; restarts = 0
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
                // Resume whether or not iOS sets shouldResume: staying silent means being suspended.
                self?.revive(reason: CWL("音频中断结束"))
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
                // Every player is invalid after a media services reset; build a new one.
                self?.player = nil
                self?.revive(reason: CWL("系统媒体服务重置"))
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.isRunning, self.player?.isPlaying != true else { return }
                self.revive(reason: CWL("音频路由变化"))
            }
        ]
        // Catches every other way the player can be stopped (session deactivated, category change).
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.isRunning, self.player?.isPlaying != true else { return }
            self.revive(reason: CWL("检测到静音播放已停止"))
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
        onLog?(CWL("后台保持已开启"))
        return true
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        Self.setHolding(false)
        watchdog?.invalidate(); watchdog = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        player?.stop()
        player = nil
        CarPlayAudio.endMediaSession()
        onLog?(CWL("后台保持已关闭"))
    }

    private func revive(reason: String) {
        guard isRunning else { return }
        restarts += 1
        let ok = play(reason: reason)
        // Log the first few and then every 10th so a flapping session cannot flood the log.
        if restarts <= 3 || restarts % 10 == 0 {
            onLog?(ok ? CWL("后台保持已恢复（{1}，第 {2} 次）", [String(describing: reason), String(describing: restarts)]) : CWL("后台保持恢复失败（{1}）", [String(describing: reason)]))
        }
    }

    private func play(reason: String?) -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            if reason == nil {
                onLog?(CWL("后台保持准备：类别 {1}，模式 {2}，选项 {3}，路由 {4}", [String(describing: session.category.rawValue), String(describing: session.mode.rawValue), String(describing: session.categoryOptions.rawValue), String(describing: session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ","))]))
            }
            if session.category != .playback && session.category != .playAndRecord {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            } else if session.category == .playback && !session.categoryOptions.contains(.mixWithOthers) {
                // CarPlay playback may have selected this category without mixing. Silent
                // keep-alive must not request exclusive audio focus from the source iPhone.
                try session.setCategory(.playback, mode: session.mode,
                                        options: session.categoryOptions.union(.mixWithOthers))
            }
            try session.setActive(true)
            let player = try player ?? AVAudioPlayer(data: Self.silentWAV)
            player.numberOfLoops = -1
            player.volume = 0
            self.player = player
            guard player.play() else {
                self.player = nil
                if reason == nil {
                    onLog?(CWL("后台保持开启失败：系统拒绝播放（类别 {1}，模式 {2}，选项 {3}，路由 {4}）", [String(describing: session.category.rawValue), String(describing: session.mode.rawValue), String(describing: session.categoryOptions.rawValue), String(describing: session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ","))]))
                }
                return false
            }
            return true
        } catch {
            if reason == nil { onLog?(CWL("后台保持开启失败：{1}", [String(describing: error.localizedDescription)])) }
            return false
        }
    }

    /// One second of 8 kHz mono 16-bit silence.
    private static let silentWAV: Data = {
        let rate: UInt32 = 8_000, samples = rate
        let dataBytes = samples * 2
        var wav = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes); wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        wav.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        wav.append(Data(count: Int(dataBytes)))
        return wav
    }()

    deinit { stop() }
}

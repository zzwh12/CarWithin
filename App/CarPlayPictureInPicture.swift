import AVFoundation
import AVKit
import UIKit

/// Coordinates system Picture in Picture for the live CarPlay sample-buffer layer.
/// PiP is intentionally view-only; UIKit cannot receive arbitrary touches inside the system PiP window.
final class CarPlayPictureInPicture: NSObject {
    private let surface: H264Surface
    private var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private var startDeadline: DispatchWorkItem?
    private var waitingForReadiness = false
    private var awaitingSystemStart = false
    private var acceptsStarts = true
    private(set) var isStarting = false
    var isActive: Bool { controller?.isPictureInPictureActive == true }
    var canKeepSessionInBackground: Bool { isStarting || isActive || awaitingSystemStart }
    var onLog: ((String) -> Void)?
    var onFailure: (() -> Void)?
    var onStopped: (() -> Void)?
    var onRestore: (() -> Void)?

    init(surface: H264Surface) {
        self.surface = surface
        super.init()
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: surface.pictureInPictureLayer,
            playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.requiresLinearPlayback = true
        self.controller = controller
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in self?.sourceMayBeReady() }
        }
        if #available(iOS 17.4, *) {
            NotificationCenter.default.addObserver(self, selector: #selector(sourceReadinessChanged),
                name: .AVSampleBufferDisplayLayerReadyForDisplayDidChange, object: surface.pictureInPictureLayer)
        }
    }

    @objc private func sourceReadinessChanged() {
        DispatchQueue.main.async { [weak self] in self?.sourceMayBeReady() }
    }

    func setAutomatic(_ enabled: Bool) {
        if enabled { acceptsStarts = true }
        guard let controller, controller.canStartPictureInPictureAutomaticallyFromInline != enabled else { return }
        if enabled { prepareAudioSession() }
        controller.canStartPictureInPictureAutomaticallyFromInline = enabled
    }

    /// iOS owns the Home gesture transition. Allow its delegate callbacks to arrive before
    /// deciding whether a session without silent audio can survive in the background.
    func awaitAutomaticStart() {
        guard let controller, controller.canStartPictureInPictureAutomaticallyFromInline,
              !isStarting, !isActive, !awaitingSystemStart, surface.isReadyForPictureInPicture else { return }
        waitingForReadiness = false
        awaitingSystemStart = true
        setStartDeadline(after: 4, message: CWL("iOS 未自动开启画中画，请检查系统的自动画中画设置"))
    }

    func returnedToForeground() {
        guard awaitingSystemStart else { return }
        awaitingSystemStart = false
        cancelStartDeadline()
    }

    func cancelPendingStart() {
        guard waitingForReadiness else { return }
        waitingForReadiness = false
        cancelStartDeadline()
    }

    @discardableResult
    func start() -> Bool {
        guard controller != nil else {
            onLog?(CWL("当前设备不支持系统画中画"))
            return false
        }
        guard !isActive, !isStarting, !waitingForReadiness else { return true }
        acceptsStarts = true
        prepareAudioSession()
        waitingForReadiness = true
        setStartDeadline(after: 6, message: CWL("画中画未就绪：系统尚未允许启动或首帧未渲染"))
        sourceMayBeReady()
        return true
    }

    func sourceMayBeReady() {
        guard waitingForReadiness, let controller, surface.isReadyForPictureInPicture,
              controller.isPictureInPicturePossible, UIApplication.shared.applicationState == .active else { return }
        waitingForReadiness = false
        isStarting = true
        setStartDeadline(after: 4, message: CWL("系统画中画 4 秒内没有启动"))
        controller.startPictureInPicture()
    }

    private func prepareAudioSession() {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            if session.category != .playback && session.category != .playAndRecord {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            }
            try session.setActive(true)
        } catch {
            onLog?(CWL("画中画音频会话准备失败：{1}", [String(describing: error.localizedDescription)]))
        }
        #endif
    }

    private func setStartDeadline(after delay: TimeInterval, message: String) {
        cancelStartDeadline()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isActive else { return }
            self.clearStartState()
            self.onLog?(message)
            self.onFailure?()
        }
        startDeadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelStartDeadline() {
        startDeadline?.cancel()
        startDeadline = nil
    }

    private func clearStartState() {
        waitingForReadiness = false
        awaitingSystemStart = false
        isStarting = false
        cancelStartDeadline()
    }

    func stop() {
        acceptsStarts = false
        setAutomatic(false)
        clearStartState()
        if isActive { controller?.stopPictureInPicture() }
    }

}

extension CarPlayPictureInPicture: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard acceptsStarts else { return }
        waitingForReadiness = false
        awaitingSystemStart = false
        isStarting = true
        setStartDeadline(after: 4, message: CWL("系统画中画 4 秒内没有启动"))
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        clearStartState()
        guard acceptsStarts else {
            pictureInPictureController.stopPictureInPicture()
            return
        }
        onLog?(CWL("系统画中画已开启"))
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        clearStartState()
        guard acceptsStarts else { return }
        onLog?(CWL("系统画中画启动失败：{1}", [String(describing: error.localizedDescription)]))
        onFailure?()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        clearStartState()
        guard acceptsStarts else { return }
        onLog?(CWL("系统画中画已关闭"))
        onStopped?()
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        onRestore?()
        completionHandler(true)
    }
}

extension CarPlayPictureInPicture: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    setPlaying playing: Bool) {
        // CarPlay is a live stream and cannot be paused independently.
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        false
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

import UIKit
import AVFoundation

private final class SampleBufferView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
}

/// One touch surface for inline and fullscreen video.
/// H.264 streams arrive as compressed access units; CarbitLink instead publishes the frames
/// it already decoded for re-encoding. Both paths use the same display layer, so Picture in
/// Picture needs neither a second decode nor a separate source layer.
final class H264Surface: UIView {
    private let sampleView = SampleBufferView()
    var usesPreviewFrames: Bool { previewMode }
    private var display: AVSampleBufferDisplayLayer { sampleView.layer as! AVSampleBufferDisplayLayer }
    var pictureInPictureLayer: AVSampleBufferDisplayLayer { display }
    var isReadyForPictureInPicture: Bool {
        guard window != nil, !isHidden, !bounds.isEmpty else { return false }
        if previewMode {
            guard let at = previewFrameAt, ProcessInfo.processInfo.systemUptime - at < 2 else { return false }
            return display.status != .failed
        }
        guard format != nil, !awaitingKeyframe, !rendererNeedsRecovery else { return false }
        if #available(iOS 17.4, *) { return display.isReadyForDisplay }
        return hasEnqueuedFrame
    }
    lazy var touchOwnershipGestureRecognizer: UILongPressGestureRecognizer = {
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(holdTouchOwnership(_:)))
        gesture.minimumPressDuration = 0
        gesture.allowableMovement = 10_000
        gesture.cancelsTouchesInView = false
        return gesture
    }()

    private var format: CMVideoFormatDescription?
    private var parameters: VideoParameterSets?
    private var pending: [(CMSampleBuffer, Int)] = []
    private var pendingBytes = 0
    private var requesting = false
    private var hasEnqueuedFrame = false
    private var awaitingKeyframe = false
    private var suspended = false
    private var previewMode = false
    private var previewFrameSize: CMVideoDimensions?
    private var previewFrameAt: TimeInterval?
    private var lastRecovery = -Double.infinity
    private var checkingDisplaySince: TimeInterval?
    private var rendererNeedsRecovery: Bool { display.requiresFlushToResumeDecoding || display.status == .failed }
    var onLog: ((String) -> Void)?
    /// Every finger currently on the surface, normalized to the video picture (0…1).
    var onTouches: (([TouchPoint]) -> Void)?
    /// Called whenever the renderer discarded frames and can only resume at a new keyframe.
    var onKeyframeNeeded: ((String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        sampleView.isUserInteractionEnabled = false
        sampleView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sampleView.frame = bounds
        addSubview(sampleView)
        display.videoGravity = .resizeAspect
        isUserInteractionEnabled = true
        isMultipleTouchEnabled = true
        addGestureRecognizer(touchOwnershipGestureRecognizer)
        NotificationCenter.default.addObserver(self, selector: #selector(decodeFailed(_:)),
            name: .AVSampleBufferDisplayLayerFailedToDecode, object: display)
        NotificationCenter.default.addObserver(self, selector: #selector(rendererFlushChanged),
            name: .AVSampleBufferDisplayLayerRequiresFlushToResumeDecodingDidChange, object: display)
    }

    @objc private func decodeFailed(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.suspended, self.format != nil, self.rendererNeedsRecovery,
                  ProcessInfo.processInfo.systemUptime - self.lastRecovery >= 0.5 else { return }
            let error = note.userInfo?[AVSampleBufferDisplayLayerFailedToDecodeNotificationErrorKey] as? NSError
            self.recover(reason: CWL("本机解码失败{1}", [String(describing: error.map { "（\($0.code)）" } ?? "")]))
        }
    }

    @objc private func rendererFlushChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.suspended, self.format != nil, self.display.requiresFlushToResumeDecoding,
                  ProcessInfo.processInfo.systemUptime - self.lastRecovery >= 0.5 else { return }
            self.recover(reason: CWL("系统要求恢复视频解码"))
        }
    }

    private func recover(reason: String) {
        guard !suspended else { return }
        display.stopRequestingMediaData(); requesting = false
        pending.removeAll(); pendingBytes = 0
        display.flush()
        hasEnqueuedFrame = false
        checkingDisplaySince = nil
        lastRecovery = ProcessInfo.processInfo.systemUptime
        if !awaitingKeyframe { onLog?(CWL("视频渲染器将在下一个关键帧恢复：{1}", [String(describing: reason)])) }
        awaitingKeyframe = true
        onKeyframeNeeded?(reason)
    }

    required init?(coder: NSCoder) { fatalError(CWL("不支持从 Storyboard 创建 H264Surface")) }

    /// CarbitLink decodes CarPlay once for re-encoding. Its preview reuses those frames at a
    /// low rate, and Picture in Picture takes the same layer that shows them inline.
    func usePreviewFrames(_ enabled: Bool) {
        guard previewMode != enabled else { return }
        previewMode = enabled
        releaseAllTouches()
        display.stopRequestingMediaData(); requesting = false
        pending.removeAll(); pendingBytes = 0
        display.flushAndRemoveImage()
        format = nil; parameters = nil; hasEnqueuedFrame = false
        previewFrameSize = nil; previewFrameAt = nil
        checkingDisplaySince = nil
    }

    /// Shows one already-decoded frame from the CarbitLink preview publisher.
    func showPreviewFrame(_ sample: CMSampleBuffer) {
        guard previewMode, !suspended, let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        if display.status == .failed { display.flush() }
        display.enqueue(sample)
        previewFrameSize = CMVideoDimensions(width: Int32(CVPixelBufferGetWidth(buffer)),
                                             height: Int32(CVPixelBufferGetHeight(buffer)))
        previewFrameAt = ProcessInfo.processInfo.systemUptime
    }

    @objc private func holdTouchOwnership(_ gesture: UILongPressGestureRecognizer) {
        // The recognizer intentionally does no work. It prevents the parent scroll view
        // from cancelling a CarPlay drag while raw touch callbacks keep their HID semantics.
    }

    /// Frames were skipped while the app was in the background: start again at a fresh keyframe.
    func resumeAfterBackground(skippedFrames: Bool) {
        suspended = false
        guard format != nil else { return }
        if skippedFrames || rendererNeedsRecovery {
            recover(reason: CWL("回到前台"))
        } else if awaitingKeyframe {
            onKeyframeNeeded?(CWL("回到前台等待关键帧"))
        }
        if #available(iOS 17.4, *), !display.isReadyForDisplay {
            checkingDisplaySince = ProcessInfo.processInfo.systemUptime
            onKeyframeNeeded?(CWL("回到前台等待显示"))
        }
    }

    func reset() {
        suspended = false
        previewFrameAt = nil; previewFrameSize = nil
        checkingDisplaySince = nil; lastRecovery = -.infinity
        releaseAllTouches()
        display.stopRequestingMediaData(); requesting = false
        pending.removeAll(); pendingBytes = 0; awaitingKeyframe = false
        display.flushAndRemoveImage(); format = nil; parameters = nil; hasEnqueuedFrame = false
    }

    private func makeFormat(_ sets: VideoParameterSets) throws -> CMVideoFormatDescription {
        let units = sets.ordered.map { $0 as NSData }
        let pointers = units.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
        let sizes = units.map(\.length)
        var description: CMVideoFormatDescription?
        let status: OSStatus
        switch sets.codec {
        case .h264:
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                parameterSetCount: pointers.count, parameterSetPointers: pointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: 4, formatDescriptionOut: &description)
        case .h265:
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault,
                parameterSetCount: pointers.count, parameterSetPointers: pointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description)
        }
        guard status == noErr, let description else {
            throw ProtocolError.malformed(CWL("{1} 参数无效（{2}）", [String(describing: sets.codec.displayName), String(describing: status)]))
        }
        return description
    }

    func enqueue(accessUnit: Data, codec: VideoCodec) throws {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !suspended, !previewMode else { return }
        let units = try AnnexB.units(in: accessUnit)
        if parameters?.codec != codec { parameters = VideoParameterSets(codec: codec); format = nil }
        var picture: [Data] = []
        var changed = false
        for unit in units {
            if codec.parameterSet(unit) != nil { if parameters!.absorb(unit) { changed = true } }
            else { picture.append(unit) }
        }
        if changed || format == nil, let sets = parameters, sets.isComplete {
            let newFormat = try makeFormat(sets)
            display.stopRequestingMediaData(); requesting = false
            pending.removeAll(); pendingBytes = 0
            display.flush(); format = newFormat
            onLog?(CWL("本机显示层使用 {1}", [String(describing: codec.displayName)]))
        }
        guard !picture.isEmpty else { return }
        guard let format else {
            // Parameter sets were lost (e.g. after a reset); only a new IDR carries them again.
            if !awaitingKeyframe { awaitingKeyframe = true; onKeyframeNeeded?(CWL("缺少参数集")) }
            return
        }
        let keyframe = picture.contains { codec.isRandomAccess($0) }
        let now = ProcessInfo.processInfo.systemUptime
        if rendererNeedsRecovery {
            // During lock transitions the decoder may stay unavailable for a short time.
            guard now - lastRecovery >= 0.5 else { return }
            recover(reason: CWL("显示层需要恢复：{1}", [String(describing: display.error?.localizedDescription ?? CWL("系统状态变化"))]))
            guard !rendererNeedsRecovery else { return }
        } else if pending.count >= 30 || pendingBytes > 16 * 1024 * 1024 {
            recover(reason: CWL("显示积压 {1} 帧", [String(describing: pending.count)]))
        } else if #available(iOS 17.4, *) {
            if display.isReadyForDisplay {
                checkingDisplaySince = nil
            } else if hasEnqueuedFrame {
                let started = checkingDisplaySince ?? now
                checkingDisplaySince = started
                if now - started >= 1.5, now - lastRecovery >= 1.5 {
                    recover(reason: CWL("收到视频帧后显示层仍未就绪"))
                }
            }
        }
        if awaitingKeyframe {
            guard keyframe else { return }
            awaitingKeyframe = false
        }
        let bytes = try AnnexB.lengthPrefixed(picture)
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: bytes.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { throw ProtocolError.malformed(CWL("无法分配视频缓冲区")) }
        status = bytes.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count) }
        guard status == noErr else { throw ProtocolError.malformed(CWL("无法写入视频缓冲区")) }
        var sample: CMSampleBuffer?
        var size = bytes.count
        var timing = CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw ProtocolError.malformed(CWL("无法创建视频帧")) }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        pending.append((sample, bytes.count)); pendingBytes += bytes.count
        // Retain dependent compressed frames until the decoder is ready. Dropping
        // an arbitrary P-frame corrupts every dependent frame up to the next IDR.
        if !requesting {
            requesting = true
            display.requestMediaDataWhenReady(on: .main) { [weak self] in self?.drain() }
        }
    }

    func suspendForExternalOutput() {
        suspended = true
        display.stopRequestingMediaData(); requesting = false
        pending.removeAll(); pendingBytes = 0
        display.flush()
    }

    private func drain() {
        guard !suspended else { return }
        while display.isReadyForMoreMediaData, !pending.isEmpty {
            let (sample, bytes) = pending.removeFirst(); pendingBytes -= bytes
            display.enqueue(sample)
            hasEnqueuedFrame = true
        }
        if pending.isEmpty {
            display.stopRequestingMediaData(); requesting = false
        }
    }

    // Each UITouch keeps a small id from touchesBegan to touchesEnded, so a finger keeps its HID slot.
    private var fingers: [ObjectIdentifier: (id: Int, touch: UITouch)] = [:]
    private var nextFingerID = 0

    private func normalized(_ touch: UITouch) -> CGPoint? {
        let size: CGSize
        if let previewFrameSize {
            size = CGSize(width: Int(previewFrameSize.width), height: Int(previewFrameSize.height))
        } else if let format {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            size = CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
        } else { return nil }
        let rect = AVMakeRect(aspectRatio: size, insideRect: bounds)
        guard rect.width > 0, rect.height > 0 else { return nil }
        let point = touch.location(in: self)
        return CGPoint(x: min(max((point.x - rect.minX) / rect.width, 0), 1),
                       y: min(max((point.y - rect.minY) / rect.height, 0), 1))
    }

    private func publish() {
        let points = fingers.values.sorted { $0.id < $1.id }.compactMap { finger in
            normalized(finger.touch).map { TouchPoint(id: finger.id, x: $0.x, y: $0.y) }
        }
        onTouches?(points)
    }

    /// Releases every finger, e.g. when the view leaves the screen mid-gesture.
    func releaseAllTouches() {
        guard !fingers.isEmpty else { return }
        fingers.removeAll(); onTouches?([])
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            fingers[ObjectIdentifier(touch)] = (nextFingerID, touch); nextFingerID = (nextFingerID + 1) & 0xff
        }
        publish()
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { publish() }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        touches.forEach { fingers.removeValue(forKey: ObjectIdentifier($0)) }; publish()
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touches.forEach { fingers.removeValue(forKey: ObjectIdentifier($0)) }; publish()
    }
}

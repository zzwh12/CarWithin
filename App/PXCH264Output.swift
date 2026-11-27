import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Keeps encoding and the instrument's TCP frame requests off the CarPlay receive queue.
final class PXCH264Output {
    private let queue = DispatchQueue(label: "CarWithin.pxc.h264", qos: .userInitiated)
    private var session: Session?

    deinit { stop() }

    func start(connection: TailingConnection,
               frameRate: ZeehoFrameRate = .fps25,
               videoMode: ZeehoVideoMode = .transcode, sourceSize: InstrumentFrameSize? = nil,
               onPreview: ((CMSampleBuffer) -> Void)? = nil,
               onState: @escaping (String) -> Void, requestKeyframe: @escaping () -> Void) {
        stop()
        let next = Session(queue: queue, connection: connection, frameRate: frameRate, videoMode: videoMode,
                           sourceSize: sourceSize ?? connection.profile.preferredSize,
                           onPreview: onPreview, onState: onState, requestKeyframe: requestKeyframe)
        session = next
        next.start()
    }

    func append(_ data: Data, codec: VideoCodec, keyframe: Bool) {
        guard codec == .h264 else { return }
        session?.append(data, keyframe: keyframe)
    }

    func requestCarbitTestPicture() {
        session?.requestCarbitTestPicture()
    }

    func setPreviewEnabled(_ enabled: Bool) {
        session?.setPreviewEnabled(enabled)
    }

    /// Wraps a decoded CarPlay frame for the local sample-buffer display. The frame is already
    /// decoded for re-encoding, so the preview and its Picture in Picture source add no decode.
    static func previewSample(_ buffer: CVPixelBuffer) -> CMSampleBuffer? {
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
              imageBuffer: buffer, formatDescriptionOut: &description) == noErr, let description else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
              formatDescription: description, sampleTiming: &timing,
              sampleBufferOut: &sample) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        return sample
    }

    func stop() {
        guard let previous = session else { return }
        session = nil
        previous.cancel()
        queue.async { previous.close() }
    }

    private final class Session: @unchecked Sendable {
        let queue: DispatchQueue
        let onState: (String) -> Void
        let onLog: (String) -> Void
        let onPreview: ((CMSampleBuffer) -> Void)?
        let requestKeyframe: () -> Void
        private let lock = NSLock()
        private var cancelled = false
        private var testRequested = false
        private var previewEnabled = true
        private var previewPending = false
        private var lastPreview = -Double.infinity
        private var acceptingFrames = true
        private var queued = 0
        private var skipping = false
        private var decoded: CVPixelBuffer?
        private var decodeError: Error?
        private var encoded: Result<H264EncodedFrame, Error>?

        private let connection: TailingConnection
        private let profile: TailingDisplayProfile
        private let frameRate: ZeehoFrameRate
        private let sourceSize: InstrumentFrameSize
        private var usesRelay: Bool
        private var isRelaying: Bool { lock.withLock { usesRelay } }
        private let relayCondition = NSCondition()
        private var relayBuffer = ZeehoRelayBuffer()
        private var relayParameters = VideoParameterSets(codec: .h264)
        private var relayValidated = false
        private var relayError: Error?
        private var relayInputFrames = 0
        private var relayKeyframeRequestedAt = -Double.infinity
        private var relayPullTime = 0.0
        private var relayWriteTime = 0.0
        private var decoder: TailingH264Decoder?
        private var encoder: H264Encoder?
        private var encoderSize: InstrumentFrameSize?
        private var parameters = VideoParameterSets(codec: .h264)
        private var waitingForIDR = true
        private var latest: CVPixelBuffer?
        private var decodedPictures: UInt64 = 0
        // iOS can deny GPU submissions when the projection app is in the background.
        private let compositor = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
        private var cachedJPEG: (source: CVPixelBuffer, size: InstrumentFrameSize, data: Data)?
        // The pull worker owns this timer and buffer. The UI only sets testRequested under lock.
        private var testUntil = -Double.infinity
        private var testPicture: (size: InstrumentFrameSize, buffer: CVPixelBuffer)?
        private let origin = ProcessInfo.processInfo.systemUptime
        private var lastFrame = -Double.infinity
        private var lastKeyframe = -Double.infinity
        private var lastCodecFailure = -Double.infinity
        private var lastPixelSample = -Double.infinity
        private var nextHeartbeat = 0.0
        private var counter: UInt32 = 0
        private var lastReply: Double?
        private var sentPicture = false
        private var status = ""

        init(queue: DispatchQueue, connection: TailingConnection, frameRate: ZeehoFrameRate,
             videoMode: ZeehoVideoMode, sourceSize: InstrumentFrameSize, onPreview: ((CMSampleBuffer) -> Void)?,
             onState: @escaping (String) -> Void,
             requestKeyframe: @escaping () -> Void) {
            self.queue = queue
            self.profile = connection.profile
            self.frameRate = frameRate
            self.sourceSize = sourceSize
            self.usesRelay = connection.profile == .zeehoSEPlus && videoMode.effective(for: frameRate) == .relay
            self.connection = connection
            self.onState = onState
            self.onPreview = connection.profile == .carbit ? onPreview : nil
            self.onLog = connection.log
            self.requestKeyframe = requestKeyframe
        }

        func start() {
            report(profile == .carbit ? CWL("正在连接亿连…") : CWL("正在连接极核仪表…"))
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                do {
                    let initialSize = try connection.start()
                    guard active else { return }
                    if profile == .carbit {
                        report(CWL("亿连已协商 {1}，等待车机拉帧", [initialSize.description]))
                    } else {
                        report(CWL("{1}已建立视频通道 · {2}，等待 CarPlay 画面…", [profile.name, initialSize.description]))
                    }
                    if isRelaying, sourceSize != initialSize {
                        lock.withLock { usesRelay = false }
                        onLog("直传尺寸 \(sourceSize) 与仪表 \(initialSize) 不同，本次改用兼容转码")
                        requestKeyframe()
                    }
                    if isRelaying {
                        onLog("极核使用 H.264 原码流直传，不执行手机端解码、缩放或编码；仪表兼容性需实测")
                        try runRelay(size: initialSize)
                    } else {
                        onLog("\(profile.name)使用兼容转码，CarPlay 源画面 \(sourceSize)，输出 \(initialSize)")
                        var first = true
                        var wasTesting = false
                        var waitingForSource = false
                        var nextFrame = ProcessInfo.processInfo.systemUptime
                        while active {
                            try connection.checkHealth()
                            if profile != .carbit && !queue.sync(execute: { latest != nil }) {
                                Thread.sleep(forTimeInterval: 0.05)
                                continue
                            }
                            let remaining = nextFrame - ProcessInfo.processInfo.systemUptime
                            if remaining > 0 { Thread.sleep(forTimeInterval: min(remaining, 0.04)); continue }
                            let (size, format) = try connection.waitForFrameRequest()
                            let now = ProcessInfo.processInfo.systemUptime
                            nextFrame = now + 1.0 / Double(frameRate.rawValue)
                            guard active else { break }
                            let pattern = profile == .carbit ? try testImageForPull(size: size, at: now) : nil
                            guard let image = pattern ?? queue.sync(execute: { latest }) else {
                                guard profile == .carbit else { continue }
                                try connection.sendEmptyCarbitFrame()
                                if !waitingForSource {
                                    onLog(CWL("亿连已拉帧，已回应空帧并请求 CarPlay 关键帧"))
                                    requestKeyframe()
                                }
                                report(CWL("车机已拉帧 · {1} · 等待 CarPlay 画面", [size.description]))
                                waitingForSource = true
                                first = true
                                continue
                            }
                            waitingForSource = false
                            let testing = pattern != nil
                            let frame: Data
                            if format == .jpeg {
                                frame = try queue.sync { try jpeg(image, size: size) }
                            } else {
                                var result = queue.sync {
                                    encode(image, size: size, at: now, forceKeyframe: first || testing != wasTesting)
                                }
                                // A retry still answers the same pull. Keep test pictures separate from live frames.
                                for _ in 0..<20 {
                                    guard result == nil && active else { break }
                                    Thread.sleep(forTimeInterval: 0.05)
                                    result = queue.sync {
                                        encode(pattern ?? latest ?? image, size: size,
                                               at: ProcessInfo.processInfo.systemUptime, forceKeyframe: true)
                                    }
                                }
                                guard active else { break }
                                guard let result else { throw TailingError.timeout(CWL("等待 H.264 编码画面")) }
                                frame = result.data
                            }
                            try connection.sendFrame(frame, format: format)
                            first = format == .jpeg
                            if testing && !wasTesting {
                                onLog(CWL("亿连测试色条已发送 · {1} · {2}", [size.description, format.name]))
                            }
                            wasTesting = testing
                            reportFrameSent(size: size, format: format, testing: testing)
                        }
                    }
                } catch {
                    if active {
                        onLog(CWL("{1}输出失败：{2}", [profile.name, error.localizedDescription]))
                        report(CWL("{1}连接失败：{2}", [profile.name, error.localizedDescription]))
                    }
                }
                connection.close()
                queue.async { [self] in close() }
            }
        }

        private var active: Bool { lock.withLock { !cancelled } }

        func requestCarbitTestPicture() {
            guard profile == .carbit else { return }
            let accepted = lock.withLock {
                guard !cancelled, acceptingFrames else { return false }
                testRequested = true
                return true
            }
            guard accepted else { return }
            onLog(CWL("已请求测试色条，等待亿连车机拉帧"))
        }

        private func testImageForPull(size: InstrumentFrameSize, at now: Double) throws -> CVPixelBuffer? {
            let requested = lock.withLock {
                defer { testRequested = false }
                return testRequested
            }
            if requested { testUntil = now + 5 }
            guard now < testUntil else {
                testPicture = nil
                return nil
            }
            if let testPicture, testPicture.size == size { return testPicture.buffer }

            var storage: CVPixelBuffer?
            let status = CVPixelBufferCreate(nil, size.width, size.height, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &storage)
            guard status == kCVReturnSuccess, let buffer = storage,
                  CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
                throw ConfigurationError(CWL("无法创建测试色条画面"))
            }
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            guard let address = CVPixelBufferGetBaseAddress(buffer),
                  let context = CGContext(data: address, width: size.width, height: size.height,
                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
                throw ConfigurationError(CWL("无法创建测试色条画面"))
            }
            for (index, color) in [CGColor(red: 1, green: 0, blue: 0, alpha: 1),
                                   CGColor(red: 0, green: 1, blue: 0, alpha: 1),
                                   CGColor(red: 0, green: 0, blue: 1, alpha: 1)].enumerated() {
                let left = size.width * index / 3, right = size.width * (index + 1) / 3
                context.setFillColor(color)
                context.fill(CGRect(x: left, y: 0, width: right - left, height: size.height))
            }
            testPicture = (size, buffer)
            return buffer
        }

        func cancel() {
            lock.withLock { cancelled = true }
            relayCondition.lock(); relayCondition.broadcast(); relayCondition.unlock()
            connection.close()
        }

        func append(_ data: Data, keyframe: Bool) {
            if isRelaying {
                guard lock.withLock({ !cancelled && acceptingFrames }) else { return }
                appendRelay(data)
                return
            }
            let (accepted, needsKeyframe) = lock.withLock {
                guard !cancelled, acceptingFrames else { return (false, false) }
                if queued >= 6 {
                    let request = !skipping
                    skipping = true
                    return (false, request)
                }
                guard !skipping || keyframe else { return (false, false) }
                skipping = false
                queued += 1
                return (true, false)
            }
            if needsKeyframe { requestKeyframe() }
            guard accepted else { return }
            queue.async { [self] in
                defer { lock.withLock { queued -= 1 } }
                guard lock.withLock({ !cancelled && acceptingFrames }) else { return }
                decode(data, keyframe: keyframe)
            }
        }

        private func appendRelay(_ data: Data) {
            var needsKeyframe = false
            relayCondition.lock()
            defer {
                relayCondition.signal(); relayCondition.unlock()
                if needsKeyframe { requestRelayKeyframe() }
            }
            do {
                var picture: [Data] = []
                for unit in try AnnexB.units(in: data) {
                    if VideoCodec.h264.parameterSet(unit) != nil {
                        if relayParameters.absorb(unit) {
                            relayBuffer.reset(); relayValidated = false
                        }
                    } else { picture.append(unit) }
                }
                guard relayParameters.isComplete else { needsKeyframe = true; return }
                if !relayValidated {
                    let units = relayParameters.ordered.map { $0 as NSData }
                    let pointers = units.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
                    var description: CMVideoFormatDescription?
                    let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                        parameterSetCount: pointers.count, parameterSetPointers: pointers,
                        parameterSetSizes: units.map(\.length), nalUnitHeaderLength: 4, formatDescriptionOut: &description)
                    guard status == noErr, let description else { throw ConfigurationError("H.264 直传参数无效（\(status)），请改用兼容转码") }
                    let dimensions = CMVideoFormatDescriptionGetPresentationDimensions(description,
                        usePixelAspectRatio: false, useCleanAperture: true)
                    let actual = InstrumentFrameSize(width: Int(dimensions.width.rounded()), height: Int(dimensions.height.rounded()))
                    guard actual == sourceSize else { throw ConfigurationError("H.264 源尺寸 \(actual) 与直传尺寸 \(sourceSize) 不同，请改用兼容转码") }
                    relayValidated = true
                    onLog("极核直传源规格：\(try relayParameters.codecString()) · \(actual)")
                }
                guard picture.contains(where: { [1, 5].contains(Int(VideoCodec.h264.nalType($0) ?? 0)) }) else { return }
                relayInputFrames += 1
                let keyframe = picture.contains { VideoCodec.h264.isRandomAccess($0) }
                var frame = Data()
                for unit in (keyframe ? relayParameters.ordered : []) + picture {
                    frame.append(contentsOf: [0, 0, 0, 1]); frame.append(unit)
                }
                needsKeyframe = relayBuffer.append(frame, keyframe: keyframe)
            } catch {
                relayError = error
            }
        }

        private func requestRelayKeyframe() {
            let now = ProcessInfo.processInfo.systemUptime
            relayCondition.lock()
            let needed = now - relayKeyframeRequestedAt >= 1
            if needed { relayKeyframeRequestedAt = now }
            relayCondition.unlock()
            if needed, active { requestKeyframe() }
        }

        private func nextRelayFrame() throws -> Data? {
            relayCondition.lock(); defer { relayCondition.unlock() }
            if let error = relayError { throw error }
            if let frame = relayBuffer.pop() { return frame }
            _ = relayCondition.wait(until: Date(timeIntervalSinceNow: 0.5))
            if let error = relayError { throw error }
            return relayBuffer.pop()
        }

        private func runRelay(size: InstrumentFrameSize) throws {
            var lastPicture = ProcessInfo.processInfo.systemUptime
            while active {
                try connection.checkHealth()
                guard let frame = try nextRelayFrame() else {
                    guard active else { break }
                    requestRelayKeyframe()
                    if ProcessInfo.processInfo.systemUptime - lastPicture >= 10 {
                        throw ConfigurationError("H.264 直传连续 10 秒未收到完整源画面，请查看锁屏前后日志或改用兼容转码")
                    }
                    continue
                }
                guard active else { break }
                let pullStarted = ProcessInfo.processInfo.systemUptime
                try connection.waitForFrameRequest()
                let writeStarted = ProcessInfo.processInfo.systemUptime
                try connection.sendFrame(frame, format: .h264)
                let now = ProcessInfo.processInfo.systemUptime
                relayPullTime += writeStarted - pullStarted
                relayWriteTime += now - writeStarted
                lastPicture = now
                reportFrameSent(size: size)
            }
        }

        private func decode(_ data: Data, keyframe: Bool) {
            do {
                var picture: [Data] = []
                for unit in try AnnexB.units(in: data) {
                    if VideoCodec.h264.parameterSet(unit) != nil {
                        if parameters.absorb(unit) { waitingForIDR = true }
                    } else { picture.append(unit) }
                }
                if waitingForIDR {
                    // Throttle rebuilds while VideoToolbox is unavailable during a lock transition.
                    guard parameters.isComplete, keyframe, !picture.isEmpty else { return }
                    guard ProcessInfo.processInfo.systemUptime - lastCodecFailure >= 0.5 else {
                        requestKeyframe()
                        return
                    }
                    decoder?.invalidate()
                    decoder = try TailingH264Decoder(configuration: parameters.decoderConfigurationRecord(),
                        output: { [weak self] image in
                            guard let self else { return }
                            self.lock.withLock { self.decoded = image }
                        }, failure: { [weak self] error in
                            guard let self else { return }
                            self.lock.withLock { self.decodeError = error }
                        })
                    waitingForIDR = false
                }
                guard let decoder, !picture.isEmpty else { return }
                try decoder.decode(AnnexB.lengthPrefixed(picture),
                    presentationTimeMicroseconds: Int64(ProcessInfo.processInfo.systemUptime * 1_000_000), isKeyframe: keyframe)
                decoder.waitForFrames()
                let (image, error) = lock.withLock {
                    defer { decoded = nil; decodeError = nil }
                    return (decoded, decodeError)
                }
                if let error { throw error }
                if let image {
                    latest = image; decodedPictures &+= 1
                    publishPreview(image)
                }
            } catch {
                decoder?.invalidate()
                decoder = nil
                lock.withLock { decoded = nil; decodeError = nil }
                waitingForIDR = true
                logCodecFailure(CWL("解码"), error)
                requestKeyframe()
            }
        }

        func setPreviewEnabled(_ enabled: Bool) {
            lock.withLock { previewEnabled = enabled }
        }

        private func publishPreview(_ buffer: CVPixelBuffer) {
            guard let onPreview else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastPreview >= 0.125, lock.withLock({
                guard !cancelled, acceptingFrames, previewEnabled, !previewPending else { return false }
                previewPending = true
                return true
            }) else { return }
            lastPreview = now
            let sample = PXCH264Output.previewSample(buffer)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let deliver = self.lock.withLock {
                    self.previewPending = false
                    return !self.cancelled && self.acceptingFrames && self.previewEnabled
                }
                if deliver, let sample { onPreview(sample) }
            }
        }

        private func bitrate(for size: InstrumentFrameSize) -> Int {
            guard profile == .carbit else { return frameRate.bitrate }
            // 30 FPS is the tuned baseline; keep the per-second budget proportional to the cadence.
            let scaled = size.width * size.height * 4 * frameRate.rawValue / 30
            return min(8_000_000, max(1_000_000, scaled))
        }

        private func encode(_ image: CVPixelBuffer, size: InstrumentFrameSize, at now: Double, forceKeyframe: Bool) -> H264EncodedFrame? {
            do {
                if encoderSize != size {
                    encoder?.invalidate()
                    encoder = nil
                    encoderSize = size
                }
                if encoder == nil {
                    guard now - lastCodecFailure >= 0.5 else { return nil }
                    encoder = try H264Encoder(width: size.width, height: size.height,
                                              fps: frameRate.rawValue, bitrate: bitrate(for: size)) { [weak self] result in
                        guard let self else { return }
                        self.lock.withLock { self.encoded = result }
                    }
                    lastKeyframe = -.infinity
                }
                guard let encoder else { return nil }
                try encoder.encode(try fittedImage(image, to: size), presentationTime: CMTime(seconds: now, preferredTimescale: 1_000_000),
                                   forceKeyframe: forceKeyframe || lastKeyframe == -.infinity)
                encoder.complete()
                let result = lock.withLock {
                    defer { encoded = nil }
                    return encoded
                }
                let frame = try result?.get()
                if frame?.isKeyframe == true { lastKeyframe = now }
                return frame
            } catch H264EncoderError.frameDropped {
                return nil
            } catch {
                encoder?.invalidate()
                encoder = nil
                lastKeyframe = -.infinity
                lock.withLock { encoded = nil }
                logCodecFailure(CWL("编码"), error)
                return nil
            }
        }

        private func fittedImage(_ image: CVPixelBuffer, to size: InstrumentFrameSize) throws -> CVPixelBuffer {
            let width = size.width, height = size.height
            if CVPixelBufferGetWidth(image) == width, CVPixelBufferGetHeight(image) == height {
                sampleCarbitPixels(source: image, fitted: image, content: CGRect(x: 0, y: 0, width: width, height: height))
                return image
            }
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                             [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
            guard status == kCVReturnSuccess, let buffer else { throw ConfigurationError(CWL("无法分配缩放画面（{1}）", [String(status)])) }
            let source = CIImage(cvPixelBuffer: image)
            let destination = size.fittedRect(for: source.extent.size)
            let scale = destination.width / source.extent.width
            let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let positioned = scaled.transformed(by: CGAffineTransform(
                translationX: destination.minX - scaled.extent.minX,
                y: destination.minY - scaled.extent.minY))
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            compositor.render(positioned.composited(over: CIImage(color: .black)).cropped(to: bounds),
                              to: buffer, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
            sampleCarbitPixels(source: image, fitted: buffer, content: destination)
            return buffer
        }

        // Only record aggregate RGB peaks. Exclude letterboxing when comparing the two frames.
        private func sampleCarbitPixels(source: CVPixelBuffer, fitted: CVPixelBuffer, content: CGRect) {
            let now = ProcessInfo.processInfo.systemUptime
            guard profile == .carbit, now - lastPixelSample >= 4 else { return }
            lastPixelSample = now
            func peak(_ buffer: CVPixelBuffer, in rect: CGRect) -> UInt8? {
                guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
                      CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
                defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
                guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                var maximum: UInt8 = 0
                for row in 0..<12 {
                    let y = min(CVPixelBufferGetHeight(buffer) - 1, Int(rect.minY + (CGFloat(row) + 0.5) * rect.height / 12))
                    for column in 0..<16 {
                        let x = min(CVPixelBufferGetWidth(buffer) - 1, Int(rect.minX + (CGFloat(column) + 0.5) * rect.width / 16))
                        let p = bytes + max(0, y) * stride + max(0, x) * 4
                        maximum = max(maximum, p[0], p[1], p[2])
                    }
                }
                return maximum
            }
            let bounds = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source))
            guard let input = peak(source, in: bounds),
                  let output = (source === fitted ? input : peak(fitted, in: content)) else { return }
            let area = InstrumentFrameSize(width: Int(content.width.rounded()), height: Int(content.height.rounded()))
            onLog(CWL("亿连像素抽样 · 输入峰值 {1}/255 · 编码前峰值 {2}/255 · 内容区 {3} · 源已解码 {4} 帧",
                      [String(input), String(output), area.description, String(decodedPictures)]))
        }

        private func jpeg(_ image: CVPixelBuffer, size: InstrumentFrameSize) throws -> Data {
            if let cachedJPEG, cachedJPEG.source === image && cachedJPEG.size == size { return cachedJPEG.data }
            let buffer = try fittedImage(image, to: size)
            let data = try TailingJPEGEncoder.representation(of: CIImage(cvPixelBuffer: buffer),
                context: compositor, colorSpace: CGColorSpaceCreateDeviceRGB())
            cachedJPEG = (image, size, data)
            return data
        }

        private func reportFrameSent(size: InstrumentFrameSize, format: TailingVideoFormat = .h264, testing: Bool = false) {
            let now = ProcessInfo.processInfo.systemUptime
            if !sentPicture {
                sentPicture = true
                if isRelaying {
                    onLog("极核首帧已发送 · \(size) · H.264 直传 · 源目标 \(frameRate.rawValue) FPS · 码率由 CarPlay 决定")
                } else if format == .h264 {
                    let bitrate = String(format: "%.1f", Double(bitrate(for: size)) / 1_000_000)
                    onLog("\(profile.name)首帧已发送 · \(size) · 兼容转码 · 目标 \(frameRate.rawValue) FPS · 码率 \(bitrate) Mbit/s")
                }
            }
            if let started = lastReply {
                counter &+= 1
                let duration = now - started
                if duration >= 5 {
                    let rate = Double(counter) / duration
                    onLog(String(format: "\(profile.name)实际发送 %.1f FPS，目标 %d FPS（%.1f 秒 / %u 帧）",
                                 rate, frameRate.rawValue, duration, counter))
                    if isRelaying {
                        relayCondition.lock()
                        let inputs = relayInputFrames
                        let discarded = relayBuffer.discardedGroups
                        relayInputFrames = 0
                        relayCondition.unlock()
                        onLog(String(format: "极核直传输入 %.1f FPS，拉帧等待 %.1f ms/帧，写入 %.1f ms/帧，累计丢弃积压帧组 %d",
                            Double(inputs) / duration, relayPullTime * 1000 / Double(counter), relayWriteTime * 1000 / Double(counter), discarded))
                        relayPullTime = 0; relayWriteTime = 0
                    }
                    counter = 0
                    lastReply = now
                }
            } else {
                lastReply = now
                relayCondition.lock(); relayInputFrames = 0; relayCondition.unlock()
                relayPullTime = 0; relayWriteTime = 0
            }
            if profile == .carbit {
                let state = testing ? CWL("正在发送测试色条 · {1} · {2}", [size.description, format.name])
                    : CWL("正在发送 · {1} · {2}", [size.description, format.name])
                report(state)
                return
            }
            report("正在投屏 · \(size) · H.264 · 目标 \(frameRate.rawValue) FPS")
        }

        private func logCodecFailure(_ stage: String, _ error: Error) {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastCodecFailure > 4 { onLog(CWL("{1}{2}恢复：{3}", [profile.name, stage, error.localizedDescription])) }
            lastCodecFailure = now
        }

        private func report(_ message: String) {
            guard active, message != status else { return }
            status = message
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active else { return }
                self.onState(message)
            }
        }

        private func fail(_ error: Error) {
            let message = CWL("{1}输出失败：{2}", [profile.name, error.localizedDescription])
            onLog(message)
            report(message)
            close()
        }

        func close() {
            lock.withLock { acceptingFrames = false }
            connection.close()
            decoder?.invalidate()
            decoder = nil
            encoder?.invalidate()
            encoder = nil
            latest = nil
            cachedJPEG = nil
            relayCondition.lock(); relayBuffer.reset(); relayCondition.broadcast(); relayCondition.unlock()
        }
    }
}

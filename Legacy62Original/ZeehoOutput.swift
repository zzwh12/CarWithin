import CoreImage
import Foundation
import VideoToolbox

/// Runs codecs and UDP writes off the CarPlay receive queue.
final class ZeehoOutput {
    static let width = 1024
    static let height = 480
    static let fps = 25

    private let queue = DispatchQueue(label: "CarWithin.zeeho", qos: .userInitiated)
    private var session: Session?

    deinit { stop() }

    func start(localAddress: String, targetAddress: String, phone: TailingPhoneInfo, onState: @escaping (String) -> Void,
               onLog: @escaping (String) -> Void, requestKeyframe: @escaping () -> Void) {
        stop()
        let next = Session(queue: queue, localAddress: localAddress, targetAddress: targetAddress, phone: phone, onState: onState, onLog: onLog, requestKeyframe: requestKeyframe)
        session = next
        next.start()
    }

    func append(_ data: Data, codec: VideoCodec, keyframe: Bool) {
        guard codec == .h264 else { return }
        session?.append(data, keyframe: keyframe)
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
        let requestKeyframe: () -> Void
        private let lock = NSLock()
        private var cancelled = false
        private var acceptingFrames = true
        private var queued = 0
        private var skipping = false
        private var decoded: CVPixelBuffer?
        private var decodeError: Error?
        private var encoded: Result<H264EncodedFrame, Error>?

        private let connection: TailingConnection
        private var decoder: TailingH264Decoder?
        private var encoder: H264Encoder?
        private var parameters = VideoParameterSets(codec: .h264)
        private var waitingForIDR = true
        private var latest: CVPixelBuffer?
        private lazy var compositor = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
        private var fresh = false
        private let origin = ProcessInfo.processInfo.systemUptime
        private var lastFrame = -Double.infinity
        private var lastKeyframe = -Double.infinity
        private var lastCodecFailure = -Double.infinity
        private var nextHeartbeat = 0.0
        private var counter: UInt32 = 0
        private var lastReply: Double?
        private var sentPicture = false
        private var status = ""

        init(queue: DispatchQueue, localAddress: String, targetAddress: String, phone: TailingPhoneInfo, onState: @escaping (String) -> Void, onLog: @escaping (String) -> Void,
             requestKeyframe: @escaping () -> Void) {
            self.queue = queue
            self.connection = TailingConnection(localIP: localAddress, targetIP: targetAddress,
                profile: .zeeho62, phone: phone, log: onLog)
            self.onState = onState
            self.onLog = onLog
            self.requestKeyframe = requestKeyframe
        }

        func start() {
            report("正在连接极核仪表…")
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                do {
                    try connection.start()
                    guard active else { return }
                    report("仪表已连接，等待 CarPlay 画面…")
                    var first = true
                    var nextFrame = ProcessInfo.processInfo.systemUptime
                    while active {
                        try connection.checkHealth()
                        let ready = queue.sync { latest != nil }
                        if !ready { Thread.sleep(forTimeInterval: 0.05); continue }
                        let remaining = nextFrame - ProcessInfo.processInfo.systemUptime
                        if remaining > 0 { Thread.sleep(forTimeInterval: min(remaining, 0.04)); continue }
                        try connection.waitForH264Request()
                        nextFrame = ProcessInfo.processInfo.systemUptime + 1.0 / Double(ZeehoOutput.fps)
                        guard active else { break }
                        let result = queue.sync { () -> H264EncodedFrame? in
                            guard active, let image = latest else { return nil }
                            return encode(image, at: ProcessInfo.processInfo.systemUptime, forceKeyframe: first)
                        }
                        guard let result else {
                            // Preserve the pending pull request until an encodable frame is available.
                            var recovered: H264EncodedFrame?
                            for _ in 0..<20 where active && recovered == nil {
                                Thread.sleep(forTimeInterval: 0.05)
                                recovered = queue.sync {
                                    guard let image = latest else { return nil }
                                    return encode(image, at: ProcessInfo.processInfo.systemUptime, forceKeyframe: true)
                                }
                            }
                            guard let recovered else { throw TailingError.timeout("等待 H.264 编码画面") }
                            try connection.sendH264(recovered.data)
                            first = false
                            report("正在投屏 · 1024×480 · H.264")
                            continue
                        }
                        try connection.sendH264(result.data)
                        first = false
                        report("正在投屏 · 1024×480 · H.264")
                    }
                } catch {
                    if active {
                        onLog("极核输出失败：\(error.localizedDescription)")
                        report("极核连接失败：\(error.localizedDescription)")
                    }
                }
                connection.close()
                queue.async { [self] in close() }
            }
        }

        private var active: Bool { lock.withLock { !cancelled } }

        func cancel() { lock.withLock { cancelled = true }; connection.close() }

        func append(_ data: Data, keyframe: Bool) {
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
                if let image { latest = image; fresh = true }
            } catch {
                decoder?.invalidate()
                decoder = nil
                lock.withLock { decoded = nil; decodeError = nil }
                waitingForIDR = true
                logCodecFailure("解码", error)
                requestKeyframe()
            }
        }

        private func encode(_ image: CVPixelBuffer, at now: Double, forceKeyframe: Bool) -> H264EncodedFrame? {
            do {
                if encoder == nil {
                    guard now - lastCodecFailure >= 0.5 else { return nil }
                    encoder = try H264Encoder(width: ZeehoOutput.width, height: ZeehoOutput.height,
                                              fps: ZeehoOutput.fps, bitrate: 2_500_000) { [weak self] result in
                        guard let self else { return }
                        self.lock.withLock { self.encoded = result }
                    }
                    lastKeyframe = -.infinity
                }
                guard let encoder else { return nil }
                try encoder.encode(try fittedImage(image), presentationTime: CMTime(seconds: now, preferredTimescale: 1_000_000),
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
                logCodecFailure("编码", error)
                return nil
            }
        }

        private func fittedImage(_ image: CVPixelBuffer) throws -> CVPixelBuffer {
            let width = ZeehoOutput.width, height = ZeehoOutput.height
            if CVPixelBufferGetWidth(image) == width, CVPixelBufferGetHeight(image) == height { return image }
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                             [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
            guard status == kCVReturnSuccess, let buffer else { throw ConfigurationError("无法分配极核缩放画面（\(status)）") }
            let source = CIImage(cvPixelBuffer: image)
            let scale = min(CGFloat(width) / source.extent.width, CGFloat(height) / source.extent.height)
            let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let positioned = scaled.transformed(by: CGAffineTransform(
                translationX: (CGFloat(width) - scaled.extent.width) / 2,
                y: (CGFloat(height) - scaled.extent.height) / 2))
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            compositor.render(positioned.composited(over: CIImage(color: .black)).cropped(to: bounds),
                              to: buffer, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
            return buffer
        }

        private func logCodecFailure(_ stage: String, _ error: Error) {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastCodecFailure > 4 { onLog("极核\(stage)恢复：\(error.localizedDescription)") }
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
            let message = "极核输出失败：\(error.localizedDescription)"
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
        }
    }
}

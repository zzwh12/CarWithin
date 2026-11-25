import CoreImage
import Foundation
import ImageIO
import VideoToolbox

/// Runs codecs and UDP writes off the CarPlay receive queue.
final class NinebotOutput {
    static let width = 848
    static let height = 480
    static let fps = 30
    static let sevenInchFormat = (width: 1024, height: 600, fps: 25)
    static let fourThreeFormat = (width: 480, height: 272, fps: 10)

    enum Mode {
        case fiveInch, sevenInch, fourThreeInch
    }

    private let queue = DispatchQueue(label: "CarWithin.ninebot", qos: .userInitiated)
    private var session: Session?

    private var bmsImage: CGImage?
    private var bmsConfiguration = ANTBMSCardConfiguration()

    func setBMSOverlay(_ image: CGImage?, configuration: ANTBMSCardConfiguration) {
        bmsImage = image; bmsConfiguration = configuration
        let current = session
        queue.async { current?.setBMSOverlay(image, configuration: configuration) }
    }

    deinit { stop() }

    func start(localAddress: String, targetAddress: String, mode: Mode, onState: @escaping (String) -> Void,
               onLog: @escaping (String) -> Void, requestKeyframe: @escaping () -> Void) {
        stop()
        let next = Session(queue: queue, mode: mode, onState: onState, onLog: onLog, requestKeyframe: requestKeyframe)
        session = next
        let overlay = bmsImage, configuration = bmsConfiguration
        queue.async {
            next.setBMSOverlay(overlay, configuration: configuration)
            next.start(localAddress, targetAddress)
        }
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
        let mode: Mode
        var sevenInch: Bool { mode == .sevenInch }
        var usesJPEG: Bool { mode == .fourThreeInch }
        private var kcp: NinebotKCPVideo?
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

        private var timer: DispatchSourceTimer?
        private var video: NinebotUDPSocket?
        private var control: NinebotUDPSocket?
        private let packetizer = NinebotH264Packetizer()
        private lazy var jpegPacketizer = NinebotJPEGPacketizer()
        private var lastJPEG: Data?
        private var jpegTimestamp: UInt32 = 0
        private var jpegFramesSent = 0
        private var jpegFramesDropped = 0
        private var lastJPEGReport = 0.0
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
        private var acknowledgedVideo = false
        private var nextVideoFrame = 0.0
        private var status = ""

        private var bmsOverlay: CIImage?
        private var bmsConfiguration = ANTBMSCardConfiguration()

        func setBMSOverlay(_ image: CGImage?, configuration: ANTBMSCardConfiguration) {
            // Only 5/7-inch H.264 outputs are included in the first BMS integration.
            bmsOverlay = usesJPEG ? nil : image.map { CIImage(cgImage: $0) }
            bmsConfiguration = configuration
            fresh = true
        }

        init(queue: DispatchQueue, mode: Mode, onState: @escaping (String) -> Void, onLog: @escaping (String) -> Void,
             requestKeyframe: @escaping () -> Void) {
            self.queue = queue
            self.mode = mode
            if mode == .fourThreeInch { counter = .max }
            self.onState = onState
            self.onLog = onLog
            self.requestKeyframe = requestKeyframe
        }

        func start(_ local: String, _ target: String) {
            guard active else { return }
            do {
                let videoPort = NinebotH264Packetizer.videoPort
                let controlPort = NinebotH264Packetizer.controlPort
                video = try NinebotUDPSocket(localIP: local, localPort: videoPort, remoteIP: target, remotePort: videoPort)
                control = try NinebotUDPSocket(localIP: local, localPort: controlPort, remoteIP: target, remotePort: controlPort)
                report(sevenInch ? CWL("等待九号 7 寸仪表回应…") : CWL("等待九号仪表回应…"))
                switch mode {
                case .fourThreeInch: onLog(CWL("九号 4.3 寸：JPEG/RTP UDP 5012 · RTCP UDP 5013 · 480×272 · 最高 10 FPS"))
                case .sevenInch: onLog(CWL("九号 7 寸：KCP/UDP 5012 · RTCP/UDP 5013 · 1024×600 · H.264 Baseline 3.1 · 25 FPS"))
                case .fiveInch: onLog(CWL("九号 5 寸：UDP 5012/5013 · 848×480 · H.264 Baseline · 30 FPS"))
                }
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: .milliseconds(sevenInch ? 10 : usesJPEG ? 20 : 33), leeway: .milliseconds(3))
                timer.setEventHandler { [weak self] in self?.tick() }
                self.timer = timer
                timer.resume()
            } catch { fail(error) }
        }

        private var active: Bool { lock.withLock { !cancelled } }

        func cancel() { lock.withLock { cancelled = true } }

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
                logCodecFailure(CWL("解码"), error)
                requestKeyframe()
            }
        }

        private func tick() {
            guard active, let video, let control else { return }
            let now = ProcessInfo.processInfo.systemUptime
            do {
                if now >= nextHeartbeat {
                    nextHeartbeat = now + 1
                    counter &+= 1
                    let heartbeat = usesJPEG ? NinebotJPEGPacketizer.heartbeat(counter: counter)
                                           : NinebotH264Packetizer.heartbeat(counter: counter)
                    do { try control.send(heartbeat) }
                    catch let error as NinebotSocketError where error.isTransient {}
                }
                for _ in 0..<8 {
                    guard let response = try control.receive() else { break }
                    if sevenInch, let reply = NinebotH264Packetizer.sevenInchHeartbeatReply(response), counter &- reply.counter < 8 {
                        lastReply = now
                        if kcp == nil {
                            kcp = try NinebotKCPVideo(socket: video, conversation: reply.conversation)
                            onLog(CWL("九号 7 寸已协商 KCP 会话号：{1}", [String(describing: reply.conversation)]))
                        }
                    } else if !sevenInch, let reply = NinebotH264Packetizer.heartbeatReplyCounter(response), counter &- reply < 8 {
                        if usesJPEG, lastReply.map({ now - $0 >= 4 }) ?? true {
                            onLog(CWL("九号 4.3 寸收到 RTCP 回应 #{1}", [String(describing: reply)]))
                        }
                        lastReply = now
                    }
                }
                if let lastReply, now - lastReply < 4 {
                    if sevenInch, !acknowledgedVideo {
                        report(sentPicture ? CWL("等待仪表确认视频数据…") : CWL("仪表已回应，等待发送画面…"))
                    } else {
                        report(sevenInch ? CWL("仪表已确认收到数据，正在发送画面") :
                               sentPicture ? CWL("仪表已回应，正在发送画面") : CWL("仪表已回应，等待发送画面…"))
                    }
                } else if now - origin > 4 {
                    report(CWL("未收到仪表回应，请检查 Wi-Fi 和仪表 IP。"))
                }
                if usesJPEG {
                    try sendJPEGFrame(to: video, at: now)
                    return
                }
                if sevenInch {
                    guard let kcp else { return }
                    if try kcp.poll(at: now), !acknowledgedVideo {
                        acknowledgedVideo = true
                        onLog(CWL("九号 7 寸仪表已确认收到 KCP 视频数据"))
                    }
                    guard kcp.canAcceptFrame, now >= nextVideoFrame else { return }
                }
                guard let latest, fresh || now - lastFrame >= 0.5 else { return }
                if sevenInch {
                    let interval = 1 / Double(NinebotOutput.sevenInchFormat.fps)
                    nextVideoFrame = max(nextVideoFrame, now - interval / 2) + interval
                }
                lastFrame = now
                fresh = false
                guard let frame = encode(latest, at: now) else { return }
                let timestamp = UInt32(truncatingIfNeeded: Int64(now * 1_000))
                let packets = packetizer.packets(for: frame.data, timestampMilliseconds: timestamp,
                                                isKeyframe: frame.isKeyframe, repeatKeyframe: false)
                do {
                    if sevenInch {
                        guard let kcp, try kcp.enqueueFrame(packets) else { lastKeyframe = -.infinity; return }
                        sentPicture = true
                        if frame.isKeyframe { lastKeyframe = now }
                        return
                    }
                    for (index, packet) in packets.enumerated() {
                        guard active else { return }
                        try video.send(packet)
                        if packets.count > 12, index + 1 < packets.count, (index + 1).isMultiple(of: 8) {
                            usleep(750)
                        }
                    }
                    sentPicture = true
                    if frame.isKeyframe { lastKeyframe = now }
                } catch let error as NinebotSocketError where error.isTransient {
                    lastKeyframe = -.infinity
                }
            } catch { fail(error) }
        }

        private func sendJPEGFrame(to video: NinebotUDPSocket, at now: Double) throws {
            let format = NinebotOutput.fourThreeFormat
            guard let latest, now >= nextVideoFrame, fresh || now - lastFrame >= 0.5 else { return }
            let interval = 1 / Double(format.fps)
            nextVideoFrame = max(nextVideoFrame, now - interval / 2) + interval
            lastFrame = now
            if fresh || lastJPEG == nil {
                fresh = false
                let bounds = CGRect(x: 0, y: 0, width: format.width, height: format.height)
                lastJPEG = compositor.jpegRepresentation(of: fittedCanvas(latest, in: bounds), colorSpace: CGColorSpaceCreateDeviceRGB(),
                    options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.8])
                if lastJPEG == nil {
                    logCodecFailure(CWL(" JPEG 编码"), ConfigurationError(CWL("无法生成九号 4.3 寸画面")))
                }
            }
            guard let jpeg = lastJPEG else { return }
            jpegTimestamp = UInt32(truncatingIfNeeded: Self.unixMilliseconds)
            let packets = try jpegPacketizer.packets(for: jpeg, timestamp: jpegTimestamp)
            do {
                for packet in packets {
                    guard active else { return }
                    try video.send(packet)
                }
                sentPicture = true
                jpegFramesSent += 1
            } catch let error as NinebotSocketError where error.isTransient {
                jpegFramesDropped += 1
            }
            if now - lastJPEGReport >= 5 {
                lastJPEGReport = now
                onLog(CWL("九号 4.3 寸 JPEG：已发送 {1} 帧，发送丢弃 {2} 帧，当前 {3} 字节", [String(describing: jpegFramesSent), String(describing: jpegFramesDropped), String(describing: jpeg.count)]))
            }
        }

        private static var unixMilliseconds: UInt64 { UInt64(Date().timeIntervalSince1970 * 1_000) }

        private func encode(_ image: CVPixelBuffer, at now: Double) -> H264EncodedFrame? {
            do {
                if encoder == nil {
                    guard now - lastCodecFailure >= 0.5 else { return nil }
                    let format = sevenInch ? NinebotOutput.sevenInchFormat : (NinebotOutput.width, NinebotOutput.height, NinebotOutput.fps)
                    encoder = try H264Encoder(width: format.0, height: format.1, fps: format.2, bitrate: sevenInch ? 2_000_000 : 1_500_000,
                                              profileLevel: sevenInch ? kVTProfileLevel_H264_Baseline_3_1 : kVTProfileLevel_H264_Baseline_AutoLevel) { [weak self] result in
                        guard let self else { return }
                        self.lock.withLock { self.encoded = result }
                    }
                    lastKeyframe = -.infinity
                }
                guard let encoder else { return nil }
                try encoder.encode(try fittedImage(image), presentationTime: CMTime(seconds: now, preferredTimescale: 1_000_000),
                                   forceKeyframe: now - lastKeyframe >= 0.5)
                encoder.complete()
                let result = lock.withLock {
                    defer { encoded = nil }
                    return encoded
                }
                return try result?.get()
            } catch H264EncoderError.frameDropped {
                return nil
            } catch {
                encoder?.invalidate()
                encoder = nil
                lock.withLock { encoded = nil }
                logCodecFailure(CWL("编码"), error)
                return nil
            }
        }

        private func fittedImage(_ image: CVPixelBuffer) throws -> CVPixelBuffer {
            let width = sevenInch ? NinebotOutput.sevenInchFormat.width : NinebotOutput.width
            let height = sevenInch ? NinebotOutput.sevenInchFormat.height : NinebotOutput.height
            if bmsOverlay == nil, CVPixelBufferGetWidth(image) == width, CVPixelBufferGetHeight(image) == height { return image }
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                             [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
            guard status == kCVReturnSuccess, let buffer else { throw ConfigurationError(CWL("无法分配九号缩放画面（{1}）", [String(describing: status)])) }
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            compositor.render(fittedCanvas(image, in: bounds), to: buffer, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
            return buffer
        }

        private func fittedCanvas(_ image: CVPixelBuffer, in bounds: CGRect) -> CIImage {
            let source = CIImage(cvPixelBuffer: image)
            let scale = min(bounds.width / source.extent.width, bounds.height / source.extent.height)
            let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let positioned = scaled.transformed(by: CGAffineTransform(
                translationX: (bounds.width - scaled.extent.width) / 2,
                y: (bounds.height - scaled.extent.height) / 2))
            let canvas = positioned.composited(over: CIImage(color: .black)).cropped(to: bounds)
            guard let bmsOverlay else { return canvas }
            let overlayWidth = bounds.width * CGFloat(bmsConfiguration.size.widthFraction)
            let factor = overlayWidth / bmsOverlay.extent.width
            let scaledOverlay = bmsOverlay.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
            let margin = max(6, bounds.width * 0.007)
            let overlay = scaledOverlay.transformed(by: CGAffineTransform(
                translationX: bmsConfiguration.position.isAtRight ? bounds.maxX - margin - scaledOverlay.extent.width : margin,
                y: bmsConfiguration.position.isAtTop ? bounds.maxY - margin - scaledOverlay.extent.height : margin))
            return overlay.composited(over: canvas).cropped(to: bounds)
        }

        private func logCodecFailure(_ stage: String, _ error: Error) {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastCodecFailure > 4 { onLog(CWL("九号{1}恢复：{2}", [String(describing: stage), String(describing: error.localizedDescription)])) }
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
            let message = CWL("九号输出失败：{1}", [String(describing: error.localizedDescription)])
            onLog(message)
            report(message)
            close()
        }

        func close() {
            lock.withLock { acceptingFrames = false }
            timer?.cancel()
            timer = nil
            if usesJPEG {
                try? control?.send(jpegPacketizer.bye(timestamp: jpegTimestamp, unixMilliseconds: Self.unixMilliseconds))
            } else {
                try? control?.send(NinebotH264Packetizer.bye)
            }
            control = nil
            kcp = nil
            video = nil
            decoder?.invalidate()
            decoder = nil
            encoder?.invalidate()
            encoder = nil
            latest = nil
            lastJPEG = nil
        }
    }
}

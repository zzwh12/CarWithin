import Foundation
import CoreImage
import ImageIO
#if DEBUG
import Darwin
#endif

/// The instrument pulls JPEG frames. Neither its socket nor JPEG encoding may block CarPlay.
final class TailingOutput {
    var onLog: ((String) -> Void)?
    var onState: ((String) -> Void)?
    var onKeyframeRequest: (() -> Void)?
    private var session: TailingOutputSession?

    // Called only on NativeReceiver.queue.
    func start(localAddress: String, targetAddress: String, phone: TailingPhoneInfo) {
        stop()
        let run = TailingOutputSession(localAddress: localAddress, targetAddress: targetAddress, phone: phone, log: onLog ?? { _ in })
        session = run
        run.onLog = onLog
        run.onKeyframeRequest = onKeyframeRequest
        let state = onState
        run.onState = { [weak run] message in
            DispatchQueue.main.async { [weak run] in
                guard let run, !run.isClosed else { return }
                state?(message)
            }
        }
        run.start()
    }

    func append(_ data: Data, codec: VideoCodec) {
        guard codec == .h264 else { return }
        session?.append(data)
    }

    func stop() { session?.close(); session = nil }
    deinit { session?.close() }
}

final class TailingOutputSession: @unchecked Sendable {
    var onLog: ((String) -> Void)?
    var onState: ((String) -> Void)?
    var onKeyframeRequest: (() -> Void)?
    private let connection: TailingConnection
    private let decodeQueue = DispatchQueue(label: "CarWithin.tailing.decode", qos: .userInitiated)
    private let jpegQueue = DispatchQueue(label: "CarWithin.tailing.jpeg", qos: .userInitiated)
    private let condition = NSCondition()
    private var closed = false
    private var failed = false
    private var pending = 0
    private var skipping = false
    private var encoding = false
    private var latestJPEG: Data?
    private var latestReduced = false
    private var latestSequence: UInt64 = 0
    private var lastDecoderErrorAt: TimeInterval = -.infinity
    private var decoderNeedsRecovery = false
    private var lastDecoderRecoveryAt: TimeInterval = -.infinity
    private var reportedJPEGError = false // confined to jpegQueue
    private var lastEncode: TimeInterval = 0
    private var decoder: TailingH264Decoder?
    private var parameters = VideoParameterSets(codec: .h264)
    private var waitingForKeyframe = true
    // The 480×272 conversion must also run while locked. A GPU context cannot be
    // used by a background iOS app; always use CPU here to avoid transition races.
    private let context = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: true])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    #if DEBUG
    private let performance = TailingPerformanceDiagnostics()
    #endif

    init(localAddress: String, targetAddress: String, phone: TailingPhoneInfo, log: @escaping (String) -> Void,
         ports: TailingPorts = .ios, identityProvider: @escaping () throws -> TailingIdentity = TailingIdentity.load) {
        // TailingConnection invokes log from its own socket workers.
        connection = TailingConnection(localIP: localAddress, targetIP: targetAddress,
            profile: .tailing43, phone: phone, ports: ports, identityProvider: identityProvider, log: log)
    }

    var isClosed: Bool { condition.lock(); defer { condition.unlock() }; return closed }
    private var isActive: Bool { condition.lock(); defer { condition.unlock() }; return !closed && !failed }

    func start() {
        onState?(CWL("正在连接台铃仪表…"))
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var lastSentJPEGBytes: Int?
            do {
                try connection.start()
                guard !isClosed else { return }
                onState?(CWL("仪表已连接，等待 CarPlay 画面。"))
                onLog?(CWL("台铃 JPEG 转码使用 CPU，锁屏后继续转换新画面"))
                var statistics = TailingDeliveryStatistics()
                var nextSend = Date.distantPast
                var sentFirst = false
                var lastSequence: UInt64?
                while !isClosed {
                    condition.lock()
                    // Keep only the newest image; repeat it when the CarPlay screen is static.
                    while !closed && (latestJPEG == nil || Date() < nextSend) {
                        _ = condition.wait(until: latestJPEG == nil ? Date().addingTimeInterval(0.5) : nextSend)
                        if latestJPEG == nil { break }
                    }
                    let image = latestJPEG
                    let reduced = latestReduced
                    let sequence = latestSequence
                    let stopped = closed
                    condition.unlock()
                    if stopped { break }
                    try connection.checkHealth()
                    guard let image else { continue }
                    let delivery = try connection.sendJPEG(image)
                    lastSentJPEGBytes = image.count
                    if let report = statistics.record(bytes: image.count, reduced: reduced, fresh: sequence != lastSequence,
                        pullWait: delivery.pullWait, writeTime: delivery.writeTime) {
                        onLog?(report)
                        #if DEBUG
                        onLog?(performance.report())
                        #endif
                    }
                    lastSequence = sequence
                    nextSend = Date().addingTimeInterval(1.0 / 20)
                    if !sentFirst {
                        sentFirst = true
                        onState?(CWL("正在投屏 · 480×272 · JPEG · 最高 20 FPS"))
                    }
                }
            } catch {
                if !isClosed {
                    if let lastSentJPEGBytes {
                        onLog?(String(format: CWL("台铃断流前最后一次 TCP 写入：JPEG %.1f KiB"), Double(lastSentJPEGBytes) / 1024))
                    }
                    let message = CWL("台铃连接失败：{1}", [String(describing: error.localizedDescription)])
                    onLog?(message)
                    onState?(message)
                    condition.lock(); failed = true; latestJPEG = nil; condition.unlock()
                    connection.close()
                    decodeQueue.async { [self] in decoder?.invalidate(); decoder = nil }
                }
            }
        }
    }

    func append(_ data: Data) {
        let keyframe = (try? AnnexB.units(in: data).contains { VideoCodec.h264.isRandomAccess($0) }) == true
        condition.lock()
        guard !closed, !failed else { condition.unlock(); return }
        if pending >= 8 || (skipping && !keyframe) {
            let request = !skipping
            skipping = true
            condition.unlock()
            if request { onKeyframeRequest?() }
            return
        }
        skipping = false
        pending += 1
        condition.unlock()
        #if DEBUG
        let enqueuedAt = ProcessInfo.processInfo.systemUptime
        #endif
        decodeQueue.async { [self] in
            #if DEBUG
            let startedAt = ProcessInfo.processInfo.systemUptime
            #endif
            defer {
                condition.lock(); pending -= 1; condition.unlock()
                #if DEBUG
                performance.decoded(duration: ProcessInfo.processInfo.systemUptime - startedAt, queueWait: startedAt - enqueuedAt)
                #endif
            }
            guard isActive else { return }
            do {
                condition.lock()
                let recovery = decoderNeedsRecovery
                let mayRecover = ProcessInfo.processInfo.systemUptime - lastDecoderRecoveryAt >= 2
                if recovery && keyframe && mayRecover {
                    decoderNeedsRecovery = false
                    lastDecoderRecoveryAt = ProcessInfo.processInfo.systemUptime
                }
                condition.unlock()
                if recovery {
                    guard keyframe, mayRecover else { return }
                    decoder?.invalidate(); decoder = nil; waitingForKeyframe = true
                    onLog?(CWL("台铃解码会话失效，正在从关键帧重建"))
                }
                let units = try AnnexB.units(in: data)
                var changed = false
                var picture: [Data] = []
                for unit in units {
                    if VideoCodec.h264.parameterSet(unit) != nil {
                        if parameters.absorb(unit) { changed = true }
                    } else { picture.append(unit) }
                }
                if parameters.isComplete && (changed || decoder == nil) {
                    guard keyframe else { onKeyframeRequest?(); return }
                    decoder?.invalidate()
                    decoder = try TailingH264Decoder(configuration: parameters.decoderConfigurationRecord(),
                        output: { [weak self] in self?.encode($0) },
                        failure: { [weak self] in self?.decoderFailed($0) })
                    onLog?(CWL("台铃 H.264：{1}", [String(describing: decoder?.backendDescription ?? CWL("未创建"))]))
                    waitingForKeyframe = true
                }
                guard let decoder, !picture.isEmpty, !waitingForKeyframe || keyframe else { return }
                waitingForKeyframe = false
                try decoder.decode(AnnexB.lengthPrefixed(picture),
                    presentationTimeMicroseconds: Int64(ProcessInfo.processInfo.systemUptime * 1_000_000), isKeyframe: keyframe)
                decoder.waitForFrames()
            } catch {
                waitingForKeyframe = true
                decoderFailed(error)
            }
        }
    }

    private func decoderFailed(_ error: Error) {
        condition.lock()
        guard !closed, !failed else { condition.unlock(); return }
        decoderNeedsRecovery = true
        let now = ProcessInfo.processInfo.systemUptime
        let report = now - lastDecoderErrorAt >= 5
        if report { lastDecoderErrorAt = now }
        condition.unlock()
        if report { onLog?(CWL("台铃 H.264 解码失败：{1}", [String(describing: error.localizedDescription)])) }
        onKeyframeRequest?()
    }

    private func encode(_ buffer: CVPixelBuffer) {
        condition.lock()
        let now = ProcessInfo.processInfo.systemUptime
        guard !closed, !failed, !encoding, now - lastEncode >= 1.0 / 20 else { condition.unlock(); return }
        encoding = true; lastEncode = now
        condition.unlock()
        jpegQueue.async { [self] in
            #if DEBUG
            let startedAt = ProcessInfo.processInfo.systemUptime
            #endif
            defer {
                condition.lock(); encoding = false; condition.unlock()
                #if DEBUG
                performance.encoded(duration: ProcessInfo.processInfo.systemUptime - startedAt)
                #endif
            }
            guard isActive else { return }
            autoreleasepool {
                let source = CIImage(cvPixelBuffer: buffer)
                let bounds = CGRect(x: 0, y: 0, width: 480, height: 272)
                let scale = min(bounds.width / source.extent.width, bounds.height / source.extent.height)
                let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let centered = scaled.transformed(by: CGAffineTransform(
                    translationX: (bounds.width - scaled.extent.width) / 2 - scaled.extent.minX,
                    y: (bounds.height - scaled.extent.height) / 2 - scaled.extent.minY))
                let image = centered.composited(over: CIImage(color: .black).cropped(to: bounds)).cropped(to: bounds)
                do {
                    let encoded = try TailingJPEGEncoder.encode(image, context: context, colorSpace: colorSpace)
                    reportedJPEGError = false
                    condition.lock()
                    if !closed && !failed {
                        latestJPEG = encoded.data; latestReduced = encoded.reduced
                        latestSequence &+= 1; condition.broadcast()
                    }
                    condition.unlock()
                } catch {
                    // A bad frame must not replace a valid cached image or flood the log.
                    if !reportedJPEGError && isActive {
                        reportedJPEGError = true
                        onLog?(CWL("台铃跳过无法编码的画面：{1}", [String(describing: error.localizedDescription)]))
                    }
                }
            }
        }
    }

    func close() {
        condition.lock(); closed = true; latestJPEG = nil; condition.broadcast(); condition.unlock()
        connection.close()
        decodeQueue.async { [self] in decoder?.invalidate(); decoder = nil }
    }
}

/// Adapted from Ninebot Pro FrameCompositor.tailingJPEG. Keep the negotiated canvas size.
enum TailingJPEGEncoder {
    static let byteLimit = 24 * 1024

    static func encode(_ image: CIImage, context: CIContext, colorSpace: CGColorSpace,
                       quality: Int = 80) throws -> (data: Data, reduced: Bool) {
        func jpeg(_ source: CIImage, _ quality: Int) throws -> Data {
            guard let data = context.jpegRepresentation(of: source, colorSpace: colorSpace,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: CGFloat(quality) / 100]) else {
                throw EncodingError.unavailable
            }
            return data
        }
        let quality = min(100, max(0, quality))
        let original = try jpeg(image, quality)
        guard original.count > byteLimit else { return (original, false) }
        let reducedQuality = max(0, Int(Double(quality) * Double(byteLimit) / Double(original.count)) - 5)
        var attemptedQuality = quality
        for candidate in [reducedQuality, reducedQuality / 2, 0] where candidate < attemptedQuality {
            let reduced = try jpeg(image, candidate)
            if reduced.count <= byteLimit { return (reduced, true) }
            attemptedQuality = candidate
        }
        for radius in [2.0, 5.0] {
            let softened = image.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: image.extent)
            let reduced = try jpeg(softened, 10)
            if reduced.count <= byteLimit { return (reduced, true) }
        }
        throw EncodingError.tooLarge
    }

    private enum EncodingError: LocalizedError {
        case unavailable, tooLarge
        var errorDescription: String? {
            switch self {
            case .unavailable: return CWL("JPEG 编码失败")
            case .tooLarge: return CWL("JPEG 无法压缩到单帧 24 KiB 以下")
            }
        }
    }
}

private struct TailingDeliveryStatistics {
    private var started = ProcessInfo.processInfo.systemUptime
    private var frames = 0, freshFrames = 0, totalBytes = 0, maximumBytes = 0, reducedFrames = 0
    private var maximumPull = 0.0, maximumWrite = 0.0

    mutating func record(bytes: Int, reduced: Bool, fresh: Bool, pullWait: TimeInterval, writeTime: TimeInterval) -> String? {
        frames += 1; totalBytes += bytes; maximumBytes = max(maximumBytes, bytes)
        if reduced { reducedFrames += 1 }
        if fresh { freshFrames += 1 }
        maximumPull = max(maximumPull, pullWait); maximumWrite = max(maximumWrite, writeTime)
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - started
        guard elapsed >= 5 else { return nil }
        let report = String(format: CWL("台铃窗口 %.1f 秒：发送 %.1f FPS，新画面 %d/%d 帧，JPEG 平均 %.1f / 最大 %.1f KiB，限幅 %d 帧，最长等待拉帧 %.0f ms / 写入 %.0f ms"),
            elapsed, Double(frames) / elapsed, freshFrames, frames, Double(totalBytes) / Double(frames) / 1024,
            Double(maximumBytes) / 1024, reducedFrames, maximumPull * 1000, maximumWrite * 1000)
        self = TailingDeliveryStatistics()
        return report
    }
}


#if DEBUG
/// Low-frequency diagnostics; does not change the shipping pipeline or add per-frame logging.
final class TailingPerformanceDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var decodeCount = 0, encodeCount = 0
    private var decodeTime = 0.0, decodeMaximum = 0.0, queueMaximum = 0.0
    private var encodeTime = 0.0, encodeMaximum = 0.0
    private var lastTime = ProcessInfo.processInfo.systemUptime
    private var lastCPU = cpuTime()

    func decoded(duration: Double, queueWait: Double) {
        lock.lock(); defer { lock.unlock() }
        decodeCount += 1; decodeTime += duration
        decodeMaximum = max(decodeMaximum, duration); queueMaximum = max(queueMaximum, queueWait)
    }
    func encoded(duration: Double) {
        lock.lock(); defer { lock.unlock() }
        encodeCount += 1; encodeTime += duration; encodeMaximum = max(encodeMaximum, duration)
    }
    func report() -> String {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime, cpu = Self.cpuTime()
        let elapsed = max(0.001, now - lastTime)
        let text = String(format: CWL("台铃性能：进程 CPU %.0f%%（单核100%%），解码 %d 帧 平均/最大 %.1f/%.1f ms，解码排队最大 %.1f ms，JPEG %d 帧 平均/最大 %.1f/%.1f ms，热状态 %d"),
            (cpu - lastCPU) / elapsed * 100, decodeCount, decodeTime / Double(max(1, decodeCount)) * 1000,
            decodeMaximum * 1000, queueMaximum * 1000, encodeCount,
            encodeTime / Double(max(1, encodeCount)) * 1000, encodeMaximum * 1000,
            ProcessInfo.processInfo.thermalState.rawValue)
        lastTime = now; lastCPU = cpu
        decodeCount = 0; encodeCount = 0
        decodeTime = 0; decodeMaximum = 0; queueMaximum = 0; encodeTime = 0; encodeMaximum = 0
        return text
    }
    static func cpuTime() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
    }
}
#endif

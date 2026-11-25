// SPDX-License-Identifier: GPL-3.0-or-later
import CoreImage
import Foundation
import VideoToolbox

// Original CarWithin v1.0.3 6.2-inch stack, isolated from SE+ adaptations.
// Only the connection prelude adds optional IP discovery and reuses its socket.
enum Zeeho62Legacy {
    // BEGIN ORIGINAL62 output
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
    // END ORIGINAL62 output

    // BEGIN ORIGINAL62 connection
    // Adapted from xmz28/ninebot_pro: NinebotPro/Networking/TailingConnection.swift
    struct TailingDisplayProfile {
        let width: Int
        let height: Int
        let isZeeho: Bool
        static let tailing43 = TailingDisplayProfile(width: 480, height: 272, isZeeho: false)
        static let zeeho62 = TailingDisplayProfile(width: 1024, height: 480, isZeeho: true)
    }


    struct TailingPhoneInfo {
        let package: String
        let versionCode: Int
        let model: String
        let systemVersion: String
        let width: Int
        let height: Int
        let rotation: Int

        func display(mode: Int) -> [String: Any] {
            ["displayRotation": mode == 2 ? 0 : rotation,
             "width": mode == 2 ? min(width, height) : width,
             "height": mode == 2 ? max(width, height) : height,
             "enableAccessibility": false, "enableAOAHid": false, "mode": mode]
        }
    }

    struct TailingPorts {
        let control: UInt16
        let auxiliary: UInt16
        let video: UInt16
        let announcement: UInt16
        static let ios = TailingPorts(control: 10922, auxiliary: 10711, video: 10710, announcement: 10930)
    }

    /// 台铃 JPEG 和极核 H.264 共用的 PXC 投屏会话。
    final class TailingConnection: @unchecked Sendable {
        private let localIP: String
        private var targetIP: String
        private let profile: TailingDisplayProfile
        private let phone: TailingPhoneInfo
        private let ports: TailingPorts
        private let identityProvider: () throws -> TailingIdentity
        private let log: (String) -> Void
        private let condition = NSCondition()
        private var resources: [TailingSocket] = []
        private var timers: [DispatchSourceTimer] = []
        private var closed = false
        private var closeComplete = false
        private var failure: Error?
        private var identity: TailingIdentity?
        private var huid: String?
        private var signedHUID: Data?
        private var video: TailingSocket?
        private var reverseControl: TailingSocket?
        private var sentH264Prefix = false
        private var mediaStarted = false
        private var configured = false
        private var isZeeho: Bool { profile.isZeeho }
        private var dashboard: String { profile.isZeeho ? "极核" : "台铃" }

        init(localIP: String, targetIP: String, profile: TailingDisplayProfile, phone: TailingPhoneInfo,
             ports: TailingPorts = .ios, identityProvider: @escaping () throws -> TailingIdentity = TailingIdentity.load,
             log: @escaping (String) -> Void) {
            self.localIP = localIP; self.targetIP = targetIP; self.profile = profile; self.phone = phone
            self.ports = ports; self.identityProvider = identityProvider; self.log = log
        }

        func start() throws {
            let loaded = try identityProvider()
            condition.lock(); identity = loaded; condition.unlock()
            var discoveredSocket: TailingSocket?
            if targetIP.isEmpty {
                log("极核 6.2 寸正在自动查找仪表 IP，本机 Wi-Fi 地址 \(localIP)")
                let discovered = try TailingDiscovery.connect(localIP: localIP, port: ports.announcement,
                    track: { [self] in try tracked($0) }, check: { [self] in try checkHealth() })
                targetIP = discovered.address
                discoveredSocket = discovered.socket
                log("极核 6.2 寸发现候选地址 \(targetIP)，继续使用原版协商")
            }
            // 先全部监听，再请求仪表反向连接；不使用所有网卡的通配地址。
            var listeners: [(UInt16, TailingSocket)] = []
            for port in [ports.control, ports.auxiliary, ports.video] {
                let server = try tracked(TailingSocket.create())
                try server.listen(localIP: localIP, port: port)
                listeners.append((port, server))
            }
            for (port, server) in listeners {
                DispatchQueue.global(qos: .userInitiated).async { [self] in accept(server, port: port) }
            }
            log("\(dashboard) TCP 已监听 \(localIP):\(ports.control)/\(ports.auxiliary)/\(ports.video)，正在协商")
            let announcement: TailingSocket
            if let discoveredSocket { announcement = discoveredSocket }
            else {
                announcement = try tracked(TailingSocket.create())
                try announcement.connect(localIP: localIP, remoteIP: targetIP, port: ports.announcement)
            }
            defer { announcement.close() }
            try announcement.write(TailingProtocol.control(0x70000010, payload: TailingProtocol.json([
                "phoneType": "iOS", "packageName": phone.package
            ])))
            let reply = try TailingProtocol.readControl { try announcement.readExactly($0, timeout: 3) }
            guard reply.command == 0x70000011,
                  try TailingProtocol.object(reply.payload)["status"] as? Bool == true else {
                throw TailingError.protocolFailure("仪表未接受 iOS 投屏请求")
            }
            let deadline = Date().addingTimeInterval(20)
            condition.lock()
            defer { condition.unlock() }
            while !closed && failure == nil && (signedHUID == nil || video == nil || !mediaStarted || (isZeeho && reverseControl == nil)) {
                if !condition.wait(until: deadline) { throw TailingError.timeout("媒体会话未就绪，请退出官方投屏并重新开启仪表投屏") }
            }
            try checkLocked()
            UserDefaults.standard.set(targetIP, forKey: TailingDiscovery.savedAddressKey)
            log("\(dashboard) 媒体协商完成，等待仪表逐帧请求")
        }

        @discardableResult
        func sendJPEG(_ jpeg: Data) throws -> (pullWait: TimeInterval, writeTime: TimeInterval) {
            let (socket, pullWait) = try readFrameRequest()
            let packet = try TailingProtocol.jpeg(jpeg)
            let writeStarted = ProcessInfo.processInfo.systemUptime
            do {
                try socket.write(packet)
            } catch {
                throw terminalError(or: TailingError.channel("发送 JPEG", error))
            }
            return (pullWait, ProcessInfo.processInfo.systemUptime - writeStarted)
        }

        func waitForH264Request() throws {
            _ = try readFrameRequest()
        }

        // 视频请求与发送由同一个会话任务顺序执行。
        func sendH264(_ accessUnit: Data) throws {
            let socket = try videoSocket()
            let packet = try TailingProtocol.h264(accessUnit, includePrefix: !sentH264Prefix)
            do {
                try socket.write(packet)
                sentH264Prefix = true
            } catch {
                throw terminalError(or: TailingError.channel("发送 H.264", error))
            }
        }

        private func videoSocket() throws -> TailingSocket {
            condition.lock()
            defer { condition.unlock() }
            try checkLocked()
            guard let video else { throw TailingError.closed }
            return video
        }

        private func readFrameRequest() throws -> (TailingSocket, TimeInterval) {
            let socket = try videoSocket()
            let pullStarted = ProcessInfo.processInfo.systemUptime
            let request: TailingProtocol.Auxiliary
            do {
                request = try TailingProtocol.readAuxiliary { try socket.readExactly($0, timeout: 5) }
            } catch {
                throw terminalError(or: TailingError.channel("等待视频拉帧请求", error))
            }
            let pullWait = ProcessInfo.processInfo.systemUptime - pullStarted
            guard request.command == 0x72, request.payload.isEmpty else {
                throw TailingError.protocolFailure(String(format: "视频通道收到 0x%04x（%d 字节），预期空载荷 0x72",
                                                         Int(request.command), request.payload.count))
            }
            return (socket, pullWait)
        }

        func checkHealth() throws {
            condition.lock()
            defer { condition.unlock() }
            try checkLocked()
        }

        private func terminalError(or fallback: Error) -> Error {
            do { try checkHealth() } catch { return error }
            return fallback
        }

        func close() {
            condition.lock()
            if closed {
                while !closeComplete { condition.wait() }
                condition.unlock()
                return
            }
            closed = true
            let sockets = resources
            let pendingTimers = timers
            let reverse = failure == nil ? reverseControl : nil
            resources.removeAll(); timers.removeAll()
            condition.broadcast()
            condition.unlock()
            pendingTimers.forEach { $0.cancel() }
            if let reverse {
                do {
                    try sendMirrorControl(reverse, start: false, identifier: UInt32.max, timeout: 0.25)
                    log("极核已发送停止投屏通知")
                } catch {
                    log("极核停止通知发送失败：\(error.localizedDescription)")
                }
            }
            sockets.forEach { $0.close() }
            condition.lock()
            closeComplete = true
            condition.broadcast()
            condition.unlock()
        }

        private func tracked(_ socket: TailingSocket) throws -> TailingSocket {
            condition.lock()
            defer { condition.unlock() }
            if closed { socket.close(); throw TailingError.closed }
            resources.append(socket)
            return socket
        }

        private func accept(_ server: TailingSocket, port: UInt16) {
            do {
                while true {
                    let socket = try tracked(server.accept(remoteIP: targetIP))
                    if isZeeho { log("极核 TCP\(port) 已回连") }
                    if port == ports.video {
                        condition.lock()
                        if video == nil && !closed { video = socket; condition.broadcast() }
                        else { socket.close() }
                        condition.unlock()
                    } else {
                        DispatchQueue.global(qos: .userInitiated).async { [self] in
                            do {
                                if port == ports.auxiliary { try auxiliary(socket) }
                                else { try control(socket) }
                            } catch {
                                let channel = port == ports.auxiliary ? "媒体控制 TCP\(port)" : "会话控制 TCP\(port)"
                                fail(TailingError.channel(channel, error))
                            }
                        }
                    }
                }
            } catch { fail(error) }
        }

        private func control(_ socket: TailingSocket) throws {
            var reverseStarted = false
            var reportedUnsupported = false
            while true {
                // 连接在两条完整消息之间可以静默，收到半条消息后仍限制读取时间。
                var readingHeader = true
                let request = try TailingProtocol.readControl { count in
                    defer { readingHeader = false }
                    return try socket.readExactly(count, waitForFirstByte: readingHeader)
                }
                var payload = Data()
                switch request.command {
                case 0x10000, 0x20000, 0x10740, 0x10040, 0x70000000:
                    break
                case 0x10690 where isZeeho, 0x10780 where isZeeho:
                    // 极核上报 FTP 速率和运行日志，投屏会话只确认收到。
                    break
                case 0x103e0 where isZeeho:
                    // 0x103e1 是收件确认。序列号校验结果使用独立命令。
                    log("极核收到序列号校验请求，等待仪表继续媒体协商")
                case 0x10010:
                    let object = try TailingProtocol.object(request.payload)
                    guard let name = object["HUName"] as? String, !name.isEmpty, name.utf8.count <= 128,
                          let huid = object["HUID"] as? String, !huid.isEmpty else {
                        throw TailingError.protocolFailure("仪表设备资料不完整")
                    }
                    if isZeeho && name == "TL-DASH-V2" {
                        throw TailingError.protocolFailure("目标报告台铃 TL-DASH-V2，请检查仪表配置")
                    }
                    if !isZeeho && name != "TL-DASH-V2" {
                        throw TailingError.protocolFailure("目标能力不是已支持的 TL-DASH-V2")
                    }
                    condition.lock(); let identity = self.identity; condition.unlock()
                    guard let identity else { throw TailingError.closed }
                    let signature = try identity.sign(huid)
                    payload = try TailingProtocol.json([
                        "pxcVersion": "1.0.2", "phoneUUID": identity.phoneID,
                        "phoneBrand": "iPhone", "phoneModel": phone.model,
                        "phoneOsVersion": phone.systemVersion, "phoneOs": "iOS",
                        "package": phone.package, "versionCode": phone.versionCode, "token": 0,
                        "pubkey": try identity.publicKey().base64EncodedString(),
                        "encryptedHUID": signature.base64EncodedString(), "bluetoothName": "",
                        "supportH264IFrame": isZeeho, "supportFunction": 128, "mirrorRequestReconnect": true
                    ])
                    try replyControl(socket, request, payload: payload)
                    condition.lock()
                    self.huid = huid; signedHUID = signature; condition.broadcast()
                    condition.unlock()
                    log("仪表报告 HUName=\(name.debugDescription)，已回应本机 RSA2048 身份")
                    continue
                case 0x10450:
                    let time = Int64(Date().timeIntervalSince1970 * 1_000)
                    payload = try TailingProtocol.json([
                        "time": time, "currentTime": time + Int64(TimeZone.current.secondsFromGMT()) * 1_000,
                        "currentTimeZone": TimeZone.current.identifier
                    ])
                case 0x80000010:
                    // 与安卓修正一致：这是“不支持”回应，不是请求。可选状态不被支持时，
                    // 仍等待身份、媒体配置与启动三个必要条件，不触发额外状态发送。
                    if !reportedUnsupported {
                        reportedUnsupported = true
                        log("仪表报告不支持某项控制消息，继续核对必要媒体协商")
                    }
                    continue
                case 0x20021, 0x20031, 0x204c1, 0x20491, 0x20051, 0x20591, 0x205a1, 0x70000001:
                    continue // 回应不再回应，避免往返循环。
                default:
                    throw TailingError.protocolFailure(String(format: "未支持的协商命令 0x%08x", request.command))
                }
                try replyControl(socket, request, payload: payload)
                if request.command == 0x20000 && !reverseStarted {
                    reverseStarted = true
                    try sendControl(socket, command: 0x204c0, identifier: 1, object: ["state": 0, "msg": ""])
                    try sendControl(socket, command: 0x20020, identifier: 2, object: phone.display(mode: 2))
                    try sendControl(socket, command: 0x20030, identifier: 3, object: phone.display(mode: 1))
                    try socket.write(TailingProtocol.control(0x20050, identifier: 4))
                    try sendControl(socket, command: 0x205a0, identifier: 5, object: ["isMaskVisible": false])
                    if isZeeho { try startZeehoMirror(socket) }
                    startHeartbeat(socket)
                }
            }
        }

        private func replyControl(_ socket: TailingSocket, _ request: TailingProtocol.Control, payload: Data) throws {
            try socket.write(TailingProtocol.control(request.command &+ 1, identifier: request.identifier, payload: payload))
        }

        private func sendControl(_ socket: TailingSocket, command: UInt32, identifier: UInt32,
                                 object: [String: Any]) throws {
            try socket.write(TailingProtocol.control(command, identifier: identifier, payload: TailingProtocol.json(object)))
        }

        private func startZeehoMirror(_ socket: TailingSocket) throws {
            condition.lock()
            defer { condition.unlock() }
            try checkLocked()
            guard reverseControl == nil else { return }
            try sendMirrorControl(socket, start: true, identifier: 6, timeout: 0.25)
            reverseControl = socket
            log("极核已发送开始投屏通知")
            condition.broadcast()
        }

        private func sendMirrorControl(_ socket: TailingSocket, start: Bool, identifier: UInt32,
                                       timeout: TimeInterval) throws {
            let payload = try TailingProtocol.json(["control": start ? 1 : 0])
            try socket.write(TailingProtocol.control(0x20590, identifier: identifier, payload: payload), timeout: timeout)
        }

        private func startHeartbeat(_ socket: TailingSocket) {
            // iOS 成功抓包中同屏状态只在启动时发送，反向连接随后用 0x70000000 保活。
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.hanlin.ninebotpro.tailing.status"))
            var identifier: UInt32 = isZeeho ? 7 : 6
            timer.schedule(deadline: .now() + 2, repeating: 2)
            timer.setEventHandler { [weak self, weak socket] in
                guard let self, let socket else { return }
                do {
                    try socket.write(TailingProtocol.control(0x70000000, identifier: identifier))
                    identifier &+= 1
                } catch { self.fail(TailingError.channel("发送会话保活", error)) }
            }
            condition.lock()
            let stopped = closed
            if !stopped { timers.append(timer) }
            // 即便已经停止，也先激活再取消，避免释放未激活的 dispatch source。
            timer.resume()
            if stopped { timer.cancel() }
            condition.unlock()
        }

        private func auxiliary(_ socket: TailingSocket) throws {
            while true {
                // 此通道可能长时间空闲，停止通过 shutdown 唤醒。
                var readingHeader = true
                let request = try TailingProtocol.readAuxiliary { count in
                    defer { readingHeader = false }
                    return try socket.readExactly(count, waitForFirstByte: readingHeader)
                }
                var payload = Data()
                let response: UInt16
                switch request.command {
                case 0x10:
                    guard request.payload.count >= 32 else {
                        throw TailingError.protocolFailure("媒体配置载荷不足 32 字节")
                    }
                    let width = request.payload.uint16LE(0)
                    let height = request.payload.uint16LE(2)
                    let validDimensions = isZeeho ? width == 1024 && (height == 480 || height == 488)
                        : width == 480 && height == 272
                    guard validDimensions else {
                        throw TailingError.protocolFailure("仪表媒体尺寸 \(width)×\(height) 与 \(dashboard) 配置不符")
                    }
                    let deadline = Date().addingTimeInterval(5)
                    condition.lock()
                    while signedHUID == nil && !closed {
                        if !condition.wait(until: deadline) { break }
                    }
                    let signature = signedHUID, huid = self.huid, identity = self.identity
                    condition.unlock()
                    guard let signature, let huid, let identity,
                          let echoed = Data(base64Encoded: request.payload.dropFirst(32), options: .ignoreUnknownCharacters),
                          echoed == signature else { throw TailingError.protocolFailure("媒体身份回显不匹配") }
                    try identity.verify(echoed, huid: huid)
                    payload.appendLE(UInt32(isZeeho ? 2 : 1))
                    payload.appendLE(UInt16(profile.width))
                    payload.appendLE(UInt16(profile.height))
                    response = 0x11
                    condition.lock(); configured = true; condition.unlock()
                    log("媒体身份回显校验通过，仪表报告 \(width)×\(height)，回应 \(isZeeho ? "H.264" : "JPEG") / \(profile.width)×\(profile.height)")
                case 0x70:
                    condition.lock(); let ready = configured; condition.unlock()
                    guard ready else { throw TailingError.protocolFailure("仪表在配置完成前请求媒体启动") }
                    try socket.write(TailingProtocol.auxiliary(0x71, token: request.token))
                    condition.lock(); mediaStarted = true; condition.broadcast(); condition.unlock()
                    continue
                case 0x40: response = 0x41
                case 0x30:
                    response = 0x31; payload.appendLE(UInt32(5002)); payload.appendLE(UInt32(1))
                case 0x60:
                    response = 0x61; payload = try TailingProtocol.json(["supportFunction": 0])
                case 0x20: continue // 不执行反控触摸。
                default:
                    response = 0x7f02
                    log(String(format: "媒体控制通道暂不支持 0x%04x", request.command))
                }
                try socket.write(TailingProtocol.auxiliary(response, token: request.token, payload: payload))
            }
        }

        private func checkLocked() throws {
            if let failure { throw failure }
            if closed { throw TailingError.closed }
        }

        private func fail(_ error: Error) {
            condition.lock()
            let shouldFail = !closed && failure == nil
            if shouldFail { failure = error }
            condition.unlock()
            if shouldFail { close() }
        }
    }
    // END ORIGINAL62 connection

    // BEGIN ORIGINAL62 protocol
    enum TailingProtocol {
        struct Control: Equatable {
            let command: UInt32
            let identifier: UInt32
            let payload: Data
        }

        struct Auxiliary: Equatable {
            let command: UInt16
            let token: UInt32
            let payload: Data
        }

        static func control(_ command: UInt32, identifier: UInt32 = 0, payload: Data = Data()) throws -> Data {
            guard payload.count <= 65_536 - 16 else { throw TailingError.protocolFailure("控制帧过长") }
            let size = UInt32(16 + payload.count)
            var data = Data()
            for value in [command, size, command ^ size, identifier] { data.appendLE(value) }
            data.append(payload)
            return data
        }

        static func readControl(_ read: (Int) throws -> Data) throws -> Control {
            let head = try read(16)
            guard head.count == 16 else { throw TailingError.protocolFailure("控制头截断") }
            let command = head.uint32LE(0), length = Int(head.uint32LE(4))
            guard (16...65_536).contains(length), head.uint32LE(8) == command ^ UInt32(length) else {
                throw TailingError.protocolFailure("控制帧长度或异或校验错误")
            }
            // iOS 样本第 4 字段存在非零值；保存并在回复时回显，不将其强制视为零。
            let payload = try read(length - 16)
            guard payload.count == length - 16 else { throw TailingError.protocolFailure("控制载荷截断") }
            return Control(command: command, identifier: head.uint32LE(12), payload: payload)
        }

        static func auxiliary(_ command: UInt16, token: UInt32 = 0, payload: Data = Data()) throws -> Data {
            guard payload.count <= 8_192 else { throw TailingError.protocolFailure("媒体控制帧过长") }
            var data = Data()
            data.appendLE(command); data.appendLE(UInt16(payload.count)); data.appendLE(token)
            data.append(payload)
            return data
        }

        static func readAuxiliary(_ read: (Int) throws -> Data) throws -> Auxiliary {
            let head = try read(8)
            guard head.count == 8 else { throw TailingError.protocolFailure("媒体控制头截断") }
            let length = Int(head.uint16LE(2))
            guard length <= 8_192 else { throw TailingError.protocolFailure("媒体控制载荷过长") }
            let payload = try read(length)
            guard payload.count == length else { throw TailingError.protocolFailure("媒体控制载荷截断") }
            return Auxiliary(command: head.uint16LE(0), token: head.uint32LE(4), payload: payload)
        }

        static func jpeg(_ jpeg: Data) throws -> Data {
            guard jpeg.count >= 4, jpeg.count <= 8 * 1_024 * 1_024,
                  jpeg.starts(with: [0xff, 0xd8]), jpeg.suffix(2) == Data([0xff, 0xd9]) else {
                throw TailingError.protocolFailure("JPEG 不完整或过长")
            }
            var data = Data()
            data.appendLE(UInt32(jpeg.count)); data.append(jpeg)
            return data
        }

        static func h264(_ accessUnit: Data, includePrefix: Bool) throws -> Data {
            guard accessUnit.count > 4, accessUnit.count <= 8 * 1_024 * 1_024,
                  accessUnit.starts(with: [0, 0, 0, 1]) else {
                throw TailingError.protocolFailure("H.264 Annex B 帧无效或过长")
            }
            var data = Data(count: includePrefix ? 8 : 0)
            data.appendLE(UInt32(accessUnit.count))
            data.append(accessUnit)
            return data
        }

        static func json(_ object: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }

        static func object(_ data: Data) throws -> [String: Any] {
            // 官方 iOS 的部分 JSON 以 NUL 结尾。
            var payload = data
            while payload.last == 0 { payload.removeLast() }
            guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
                throw TailingError.protocolFailure("控制 JSON 无效")
            }
            return object
        }
    }
    // END ORIGINAL62 protocol

    // BEGIN ORIGINAL62 errors
    enum TailingError: LocalizedError {
        case protocolFailure(String)
        case timeout(String)
        case closed
        case system(String, Int32)
        case channel(String, Error)

        var errorDescription: String? {
            switch self {
            case .protocolFailure(let text): return "台铃协议：\(text)"
            case .timeout(let text): return "台铃等待超时：\(text)"
            case .closed: return "台铃会话已关闭"
            case .channel(let name, let error): return "\(name)：\(error.localizedDescription)"
            case .system(let text, let code): return "台铃\(text)失败（\(code)）"
            }
        }
    }
    // END ORIGINAL62 errors

}

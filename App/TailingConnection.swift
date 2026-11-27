// Adapted from xmz28/ninebot_pro: NinebotPro/Networking/TailingConnection.swift
import Foundation

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

extension TailingDisplayProfile {
    var name: String {
        switch self {
        case .tailing43: return CWL("台铃")
        case .carbit: return CWL("亿连")
        case .zeeho62, .zeehoSEPlus, .zeehoAE2: return CWL("极核")
        }
    }
}

/// 台铃、极核和亿连共用的 PXC 投屏会话。
final class TailingConnection: @unchecked Sendable {
    private let localIP: String
    private var targetIP: String
    let profile: TailingDisplayProfile
    private let phone: TailingPhoneInfo
    private let ports: TailingPorts
    private let identityProvider: () throws -> TailingIdentity
    let log: (String) -> Void
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
    private var lastSentFormat: TailingVideoFormat?
    private var mediaStarted = false
    private var media: (size: InstrumentFrameSize, format: TailingVideoFormat)?
    private var isZeeho: Bool { profile.isZeeho }

    init(localIP: String, targetIP: String, profile: TailingDisplayProfile, phone: TailingPhoneInfo,
         ports: TailingPorts = .ios, identityProvider: @escaping () throws -> TailingIdentity = TailingIdentity.load,
         log: @escaping (String) -> Void) {
        self.localIP = localIP; self.targetIP = targetIP; self.profile = profile; self.phone = phone
        self.ports = ports; self.identityProvider = identityProvider; self.log = log
    }

    @discardableResult
    func start() throws -> InstrumentFrameSize {
        let loaded = try identityProvider()
        condition.lock(); identity = loaded; condition.unlock()
        var discoveredSocket: TailingSocket?
        if targetIP.isEmpty && isZeeho {
            log("极核正在自动查找仪表 IP，本机 Wi-Fi 地址 \(localIP)")
            let discovered = try TailingDiscovery.connect(localIP: localIP, port: ports.announcement,
                track: { [self] in try tracked($0) }, check: { [self] in try checkHealth() })
            targetIP = discovered.address
            discoveredSocket = discovered.socket
            log("极核发现仪表候选地址 \(targetIP)，正在验证 PXC 投屏请求")
        }
        try checkHealth()
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
        log("\(profile.name) TCP 已监听 \(localIP):\(ports.control)/\(ports.auxiliary)/\(ports.video)，正在协商")
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
            throw TailingError.protocolFailure(CWL("目标设备未接受 iOS 投屏请求"))
        }
        let deadline = Date().addingTimeInterval(20)
        condition.lock()
        defer { condition.unlock() }
        while !closed && failure == nil && (signedHUID == nil || video == nil || !mediaStarted || (profile.usesH264 && reverseControl == nil)) {
            if !condition.wait(until: deadline) { throw TailingError.timeout(CWL("媒体会话未就绪，请在目标设备重新打开投屏页面")) }
        }
        try checkLocked()
        guard let media else { throw TailingError.protocolFailure("仪表启动了视频但未协商画面尺寸") }
        if isZeeho {
            UserDefaults.standard.set(targetIP, forKey: TailingDiscovery.savedAddressKey)
            log("极核仪表连接地址 \(targetIP)，PXC 握手及媒体协商通过")
        }
        log("\(profile.name) 媒体协商完成，等待仪表逐帧请求")
        return media.size
    }

    @discardableResult
    func sendJPEG(_ jpeg: Data) throws -> (pullWait: TimeInterval, writeTime: TimeInterval) {
        let pullWait = try readFrameRequest()
        let writeStarted = ProcessInfo.processInfo.systemUptime
        try sendFrame(jpeg, format: .jpeg)
        return (pullWait, ProcessInfo.processInfo.systemUptime - writeStarted)
    }

    @discardableResult
    func waitForFrameRequest() throws -> (size: InstrumentFrameSize, format: TailingVideoFormat) {
        _ = try readFrameRequest()
        condition.lock()
        defer { condition.unlock() }
        try checkLocked()
        guard let media else { throw TailingError.protocolFailure("仪表启动了视频但未协商画面尺寸") }
        return media
    }

    // One zero length answers one Carbit pull while the first picture is still unavailable.
    func sendEmptyCarbitFrame() throws {
        do { try videoSocket().write(Data(count: 4)) }
        catch { throw terminalError(or: TailingError.channel(CWL("回应亿连拉帧"), error)) }
    }

    // 视频请求与发送由同一个会话任务顺序执行。
    func sendFrame(_ frame: Data, format: TailingVideoFormat) throws {
        let socket = try videoSocket()
        // Carbit reads one little-endian frame length per pull, including the first pull.
        let packet: Data
        switch format {
        case .jpeg: packet = try TailingProtocol.jpeg(frame)
        case .h264: packet = try TailingProtocol.h264(frame, includePrefix: isZeeho && lastSentFormat == nil)
        }
        do {
            try socket.write(packet)
        } catch {
            throw terminalError(or: TailingError.channel(format == .jpeg ? CWL("发送 JPEG") : CWL("发送 H.264"), error))
        }
        if profile == .carbit && lastSentFormat != format {
            if format == .h264 {
                let units = (try? AnnexB.units(in: frame)) ?? []
                let types = units.compactMap { VideoCodec.h264.nalType($0) }.map { String($0) }
                log(CWL("亿连视频首包 · {1} 字节 · NAL {2}", [String(frame.count), types.joined(separator: ",")]))
            } else {
                log(CWL("亿连视频首包 · {1} 字节 · JPEG", [String(frame.count)]))
            }
        }
        lastSentFormat = format
    }

    private func videoSocket() throws -> TailingSocket {
        condition.lock()
        defer { condition.unlock() }
        try checkLocked()
        guard let video else { throw TailingError.closed }
        return video
    }

    private func readFrameRequest() throws -> TimeInterval {
        let socket = try videoSocket()
        let pullStarted = ProcessInfo.processInfo.systemUptime
        let request: TailingProtocol.Auxiliary
        do {
            var waitingForHeader = profile == .carbit
            request = try TailingProtocol.readAuxiliary { count in
                defer { waitingForHeader = false }
                return try socket.readExactly(count, timeout: 5, waitForFirstByte: waitingForHeader)
            }
        } catch {
            throw terminalError(or: TailingError.channel(CWL("等待视频拉帧请求"), error))
        }
        let pullWait = ProcessInfo.processInfo.systemUptime - pullStarted
        guard request.command == 0x72, request.payload.isEmpty else {
            throw TailingError.protocolFailure(String(format: CWL("视频通道收到 0x%04x（%d 字节），预期空载荷 0x72"),
                                                     Int(request.command), request.payload.count))
        }
        return pullWait
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
                log(CWL("{1}已发送停止投屏通知", [profile.name]))
            } catch {
                log(CWL("极核停止通知发送失败：{1}", [String(describing: error.localizedDescription)]))
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
                if profile.usesH264 { log(CWL("{1} TCP{2} 已回连", [profile.name, String(port)])) }
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
                            let channel = port == ports.auxiliary ? CWL("媒体控制 TCP{1}", [String(describing: port)]) : CWL("会话控制 TCP{1}", [String(describing: port)])
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
            case 0x10690 where profile.usesH264, 0x10780 where profile.usesH264:
                // 极核上报 FTP 速率和运行日志，投屏会话只确认收到。
                break
            case 0x103e0 where isZeeho:
                // 0x103e1 是收件确认。序列号校验结果使用独立命令。
                log(CWL("极核收到序列号校验请求，等待仪表继续媒体协商"))
            case 0x10010:
                let object = try TailingProtocol.object(request.payload)
                guard let name = object["HUName"] as? String, !name.isEmpty, name.utf8.count <= 128,
                      let huid = object["HUID"] as? String, !huid.isEmpty else {
                    throw TailingError.protocolFailure(CWL("仪表设备资料不完整"))
                }
                if profile.usesH264 && name == "TL-DASH-V2" {
                    throw TailingError.protocolFailure(CWL("目标报告台铃 TL-DASH-V2，请检查仪表配置"))
                }
                if profile == .tailing43 && name != "TL-DASH-V2" {
                    throw TailingError.protocolFailure(CWL("目标能力不是已支持的 TL-DASH-V2"))
                }
                if profile == .carbit, object["supportScreenMirroring"] as? Bool == false {
                    throw TailingError.protocolFailure(CWL("车机报告未开放镜像视频通道"))
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
                    "supportH264IFrame": profile.usesH264, "supportFunction": 128, "mirrorRequestReconnect": true
                ])
                try replyControl(socket, request, payload: payload)
                condition.lock()
                self.huid = huid; signedHUID = signature; condition.broadcast()
                condition.unlock()
                log(CWL("仪表报告 HUName={1}，已回应本机 RSA2048 身份", [String(describing: name.debugDescription)]))
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
                    log(CWL("仪表报告不支持某项控制消息，继续核对必要媒体协商"))
                }
                continue
            case 0x20021, 0x20031, 0x204c1, 0x20491, 0x20051, 0x20591, 0x205a1, 0x70000001:
                continue // 回应不再回应，避免往返循环。
            default:
                if let acknowledgement = try TailingProtocol.notificationReceipt(to: request, profile: profile) {
                    try socket.write(acknowledgement)
                    let exchange = String(format: "0x%08x → 0x%08x", request.command, request.command + 1)
                    log(CWL("{1}已确认 PXC 通知 {2}（{3} 字节）", [profile.name, exchange, String(request.payload.count)]))
                    continue
                }
                if profile == .carbit {
                    // 蒙迪欧亿连握手会推送多组功能通知；未知请求按空回执确认并记日志，
                    // 未知回应直接忽略，均不中断会话，避免逐一枚举车机私有命令。
                    let code = String(format: "0x%08x", request.command)
                    if request.command & 1 == 0 {
                        try socket.write(TailingProtocol.control(request.command &+ 1, identifier: request.identifier))
                        log(CWL("{1}已按空回执确认未知通知 {2}", [profile.name, code]))
                    } else {
                        log(CWL("{1}忽略未知回应 {2}", [profile.name, code]))
                    }
                    continue
                }
                throw TailingError.protocolFailure(String(format: CWL("未支持的协商命令 0x%08x"), request.command))
            }
            try replyControl(socket, request, payload: payload)
            if request.command == 0x20000 && !reverseStarted {
                reverseStarted = true
                try sendControl(socket, command: 0x204c0, identifier: 1, object: ["state": 0, "msg": ""])
                try sendControl(socket, command: 0x20020, identifier: 2, object: phone.display(mode: 2))
                try sendControl(socket, command: 0x20030, identifier: 3, object: phone.display(mode: 1))
                try socket.write(TailingProtocol.control(0x20050, identifier: 4))
                try sendControl(socket, command: 0x205a0, identifier: 5, object: ["isMaskVisible": false])
                if profile.usesH264 { try startH264Mirror(socket) }
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

    private func startH264Mirror(_ socket: TailingSocket) throws {
        condition.lock()
        defer { condition.unlock() }
        try checkLocked()
        guard reverseControl == nil else { return }
        try sendMirrorControl(socket, start: true, identifier: 6, timeout: 0.25)
        reverseControl = socket
        log(CWL("{1}已发送开始投屏通知", [profile.name]))
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
        var identifier: UInt32 = profile.usesH264 ? 7 : 6
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self, weak socket] in
            guard let self, let socket else { return }
            do {
                try socket.write(TailingProtocol.control(0x70000000, identifier: identifier))
                identifier &+= 1
            } catch { self.fail(TailingError.channel(CWL("发送会话保活"), error)) }
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
        var dumpedScreenEvents = 0
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
                    throw TailingError.protocolFailure(CWL("媒体配置载荷不足 32 字节"))
                }
                let reported = InstrumentFrameSize(width: Int(request.payload.uint16LE(0)),
                                                   height: Int(request.payload.uint16LE(2)))
                guard let size = profile.outputSize(for: reported) else {
                    throw TailingError.protocolFailure("仪表媒体尺寸 \(reported) 与 \(profile.name) 配置不符")
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
                      echoed == signature else { throw TailingError.protocolFailure(CWL("媒体身份回显不匹配")) }
                try identity.verify(echoed, huid: huid)
                let preferred = request.payload.uint32LE(8), supported = request.payload.uint32LE(12)
                let format: TailingVideoFormat = profile == .carbit
                    ? .carbit(preferred: preferred, supported: supported) : (profile.usesH264 ? .h264 : .jpeg)
                condition.lock()
                if profile != .carbit, mediaStarted, media?.size != size {
                    condition.unlock()
                    throw TailingError.protocolFailure("仪表已改为 \(size)，请重新连接以切换编码尺寸")
                }
                media = (size, format)
                condition.unlock()
                payload = TailingProtocol.mediaConfiguration(size: size, h264: format == .h264)
                response = 0x11
                log("媒体身份回显校验通过，仪表报告 \(reported)，回应 \(format.name) / \(size)")
                if profile == .carbit {
                    let fps = request.payload.uint32LE(4)
                    log(CWL("亿连车机请求 · {1} FPS · wantEncoder={2} · supportCodec={3}", [
                        String(fps), String(preferred), String(format: "0x%08X", supported)
                    ]))
                }
            case 0x70:
                condition.lock(); let ready = media != nil; condition.unlock()
                guard ready else { throw TailingError.protocolFailure(CWL("仪表在配置完成前请求媒体启动")) }
                try socket.write(TailingProtocol.auxiliary(0x71, token: request.token))
                condition.lock(); mediaStarted = true; condition.broadcast(); condition.unlock()
                continue
            case 0x40: response = 0x41
            case 0x30:
                response = 0x31; payload.appendLE(UInt32(5002)); payload.appendLE(UInt32(1))
            case 0x60:
                response = 0x61; payload = try TailingProtocol.json(["supportFunction": 0])
            case 0x20:
                // 亿连 EP SDK 屏幕事件（0x20：u16 类型@0、u32 坐标域@2、u16 槽位@6、u16 按键码@8，18 字节）
                // 格式验证期：记录原始字节，暂不执行反控。
                dumpedScreenEvents += 1
                if dumpedScreenEvents <= 100 {
                    let hex = request.payload.map { String(format: "%02x", $0) }.joined(separator: " ")
                    log("亿连屏幕事件 #\(dumpedScreenEvents)（\(request.payload.count) 字节）：\(hex)")
                }
                continue
            default:
                response = 0x7f02
                log(String(format: CWL("媒体控制通道暂不支持 0x%04x"), request.command))
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

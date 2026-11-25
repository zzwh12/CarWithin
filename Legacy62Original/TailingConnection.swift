// Adapted from xmz28/ninebot_pro: NinebotPro/Networking/TailingConnection.swift
struct TailingDisplayProfile {
    let width: Int
    let height: Int
    let isZeeho: Bool
    static let tailing43 = TailingDisplayProfile(width: 480, height: 272, isZeeho: false)
    static let zeeho62 = TailingDisplayProfile(width: 1024, height: 480, isZeeho: true)
}

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

/// 台铃 JPEG 和极核 H.264 共用的 PXC 投屏会话。
final class TailingConnection: @unchecked Sendable {
    private let localIP: String
    private let targetIP: String
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
        let announcement = try tracked(TailingSocket.create())
        defer { announcement.close() }
        try announcement.connect(localIP: localIP, remoteIP: targetIP, port: ports.announcement)
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

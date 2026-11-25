import Foundation

/// 春风 CFMOTO 仪表（MotoPlay / EasyConn / PXC）会话。
///
/// 拓扑和台铃/极核不同，是官方 APP 实车抓包确认的那一套：
/// 1. 手机是服务端，监听 10920（视频）/10921（媒体）/10922（控制）；
/// 2. 手机向 仪表:10930 发一次探测帧（0x70000010），仪表回 {"status":true} 后手机主动断开；
/// 3. 仪表反过来连回手机的三个端口，在 10922 上驱动控制握手（通道选择、身份、SN 校验）；
/// 4. 10921 上仪表下发采集配置与开流请求，10920 上仪表用 114 逐帧"拉"裸 H.264。
final class PxcConnection: @unchecked Sendable {
    struct MediaSize: Equatable {
        let width: Int
        let height: Int
        let fps: Int
    }

    private enum Port {
        static let video: UInt16 = 10920
        static let media: UInt16 = 10921
        static let control: UInt16 = 10922
        static let probe: UInt16 = 10930
    }

    private enum Command {
        static let channelControl: UInt32 = 0x10000
        static let channelData: UInt32 = 0x20000
        static let clientInfo: UInt32 = 0x10010
        static let querySpeed: UInt32 = 0x10690
        static let checkSN: UInt32 = 0x103e0
        static let heartbeat: UInt32 = 0x70000000
        static let probe: UInt32 = 0x70000010
        static let probeAck: UInt32 = 0x70000011

        static let configCapture: UInt16 = 16
        static let getVersion: UInt16 = 48
        static let mediaHeartbeat: UInt16 = 64
        static let configExtend: UInt16 = 96
        static let dataStart: UInt16 = 112
        static let dataNext: UInt16 = 114
    }

    private let localIP: String
    private let targetIP: String
    private let phone: TailingPhoneInfo
    private let dashboard: String
    private let identityProvider: () throws -> TailingIdentity
    private let log: (String) -> Void

    private let condition = NSCondition()
    private var resources: [TailingSocket] = []
    private var closed = false
    private var failure: Error?
    private var identity: TailingIdentity?
    private var huid: String?
    private var video: TailingSocket?
    private var configured = false
    private var mediaStarted = false
    private var frameRequested = false
    private var negotiated = MediaSize(width: 800, height: 384, fps: 30)
    private var framesSent = 0

    init(localIP: String, targetIP: String, phone: TailingPhoneInfo, dashboard: String,
         identityProvider: @escaping () throws -> TailingIdentity = TailingIdentity.load,
         log: @escaping (String) -> Void) {
        self.localIP = localIP
        self.targetIP = targetIP
        self.phone = phone
        self.dashboard = dashboard
        self.identityProvider = identityProvider
        self.log = log
    }

    /// 仪表在媒体配置里要求的实际编码尺寸（已按 16 对齐）。
    var mediaSize: MediaSize {
        condition.lock(); defer { condition.unlock() }
        return negotiated
    }

    /// 由本机 IP 推出来的仪表网关地址：春风仪表热点固定把仪表放在网关（.1）。
    static func gateway(for localIP: String) -> String? {
        var parts = localIP.split(separator: ".").map(String.init)
        guard parts.count == 4, Int(parts[3]) != nil else { return nil }
        parts[3] = "1"
        return parts.joined(separator: ".")
    }

    static func validatedMediaSize(_ body: Data) throws -> MediaSize {
        guard body.count >= 12 else { throw TailingError.protocolFailure("春风媒体配置不完整") }
        let width = Int(body.uint16LE(0)), height = Int(body.uint16LE(2))
        let fps = Int(body.uint32LE(4)), codec = body.uint32LE(8)
        guard (240...1920).contains(width), (240...1080).contains(height),
              (1...60).contains(fps), codec == 0 || codec == 2 else {
            throw TailingError.protocolFailure("春风媒体尺寸、帧率或编码格式无效")
        }
        return MediaSize(width: width & ~0xF, height: height & ~0xF, fps: fps)
    }

    func start() throws {
        let loaded = try identityProvider()
        condition.lock(); identity = loaded; condition.unlock()

        var listeners: [(UInt16, TailingSocket)] = []
        for port in [Port.control, Port.media, Port.video] {
            let server = try tracked(TailingSocket.create())
            try server.listen(localIP: localIP, port: port)
            listeners.append((port, server))
        }
        for (port, server) in listeners {
            DispatchQueue.global(qos: .userInitiated).async { [self] in accept(server, port: port) }
        }
        log("\(dashboard) TCP 已监听 \(localIP):\(Port.control)/\(Port.media)/\(Port.video)，正在探测仪表")

        try probe()

        let deadline = Date().addingTimeInterval(20)
        condition.lock()
        defer { condition.unlock() }
        while !closed && failure == nil && (huid == nil || !configured || !mediaStarted || video == nil) {
            if !condition.wait(until: deadline) {
                throw TailingError.timeout("仪表未完成媒体协商，请确认仪表停在「手机互联」页面并退出官方投屏")
            }
        }
        try checkLocked()
        log("\(dashboard) 媒体协商完成，\(negotiated.width)×\(negotiated.height)@\(negotiated.fps)，等待仪表逐帧请求")
    }

    private func probe() throws {
        var lastError: Error?
        for attempt in 1...4 {
            do {
                let socket = try TailingSocket.create()
                defer { socket.close() }
                try socket.connect(localIP: localIP, remoteIP: targetIP, port: Port.probe, timeout: 3)
                let body = try TailingProtocol.json(["phoneType": "Android", "packageName": phone.package])
                try socket.write(TailingProtocol.control(Command.probe, payload: body))
                let reply = try TailingProtocol.readControl { try socket.readExactly($0, timeout: 4) }
                let text = String(data: reply.payload, encoding: .utf8) ?? ""
                log("\(dashboard) 探测#\(attempt) ← 0x\(String(format: "%08x", reply.command)) \(text)")
                guard reply.command == Command.probeAck, try TailingProtocol.object(reply.payload)["status"] as? Bool == true else {
                    throw TailingError.protocolFailure("仪表拒绝了投屏探测：\(text)")
                }
                log("\(dashboard) 仪表同意投屏，正在等它回连 \(Port.control)/\(Port.media)/\(Port.video)")
                return
            } catch {
                lastError = error
                log("\(dashboard) 探测仪表\(targetIP):\(Port.probe) 第 \(attempt) 次失败：\(error.localizedDescription)")
                if let tailing = error as? TailingError, case .system(_, let code) = tailing, code == EPERM {
                    log("系统拒绝访问局域网（EPERM）。请到 iPhone「设置 → 隐私与安全性 → 本地网络」把 CarWithin 打开后重试。")
                }
                if attempt < 4 { Thread.sleep(forTimeInterval: 1.2) }
            }
        }
        throw lastError ?? TailingError.timeout("探测仪表")
    }

    // MARK: - 反向连接

    private func accept(_ server: TailingSocket, port: UInt16) {
        do {
            while true {
                let socket = try tracked(server.accept(remoteIP: targetIP))
                log("\(dashboard) ★ 仪表回连 TCP\(port)（来自 \(targetIP)）")
                if port == Port.video {
                    condition.lock()
                    if video == nil && !closed { video = socket; condition.broadcast() }
                    else { socket.close() }
                    condition.unlock()
                }
                DispatchQueue.global(qos: .userInitiated).async { [self] in serve(socket, port: port) }
            }
        } catch { fail(error) }
    }

    private func serve(_ socket: TailingSocket, port: UInt16) {
        do {
            if port == Port.control {
                var readingHeader = true
                while true {
                    let request = try TailingProtocol.readControl { count in
                        defer { readingHeader = false }
                        return try socket.readExactly(count, waitForFirstByte: readingHeader)
                    }
                    readingHeader = true
                    try control(socket, request)
                }
            } else {
                var readingHeader = true
                while true {
                    let request = try TailingProtocol.readAuxiliary { count in
                        defer { readingHeader = false }
                        return try socket.readExactly(count, waitForFirstByte: readingHeader)
                    }
                    readingHeader = true
                    try media(socket, port: port, request)
                }
            }
        } catch {
            if let tailing = error as? TailingError, case .closed = tailing { return }
            if !isClosed { log("\(dashboard) TCP\(port) 链路中断：\(error.localizedDescription)") }
            fail(error)
        }
    }

    // MARK: - 控制面

    private func control(_ socket: TailingSocket, _ request: TailingProtocol.Control) throws {
        switch request.command {
        case Command.channelControl:
            try reply(socket, request.command, payload: Data())
        case Command.channelData:
            try reply(socket, request.command, payload: Data())
        case Command.clientInfo:
            try clientInfo(socket, request)
        case Command.querySpeed:
            log("\(dashboard) 仪表查询链路速度：\(String(data: request.payload, encoding: .utf8) ?? "")")
            try reply(socket, request.command, payload: Data())
        case Command.checkSN:
            try checkSerialNumber(socket, request)
        case Command.heartbeat:
            try reply(socket, request.command, payload: Data())
        default:
            log(String(format: "\(dashboard) 控制通道未命名命令 0x%08x（%d 字节）",
                       request.command, request.payload.count))
        }
    }

    private func clientInfo(_ socket: TailingSocket, _ request: TailingProtocol.Control) throws {
        let encoded = String(data: request.payload, encoding: .utf8) ?? ""
        log("\(dashboard) ★ 仪表自报身份：\(encoded.prefix(240))")
        guard let object = try? TailingProtocol.object(request.payload) else {
            log("\(dashboard) 仪表身份不是 JSON，跳过")
            return
        }
        let name = (object["HUName"] ?? object["huName"]).map { "\($0)" } ?? "-"
        guard let huid = (object["HUID"] ?? object["huid"]).map({ "\($0)" }), !huid.isEmpty else {
            throw TailingError.protocolFailure("仪表自报身份缺少 HUID")
        }
        condition.lock(); let identity = self.identity; condition.unlock()
        guard let identity else { throw TailingError.closed }
        let signature = try identity.sign(huid)
        let replyObject: [String: Any] = [
            "pxcVersion": "1.0.2",
            "phoneUUID": identity.phoneID,
            "phoneBrand": "Apple",
            "phoneModel": phone.model,
            "phoneOsVersion": phone.systemVersion,
            "phoneOs": "iOS",
            "package": phone.package,
            "versionCode": phone.versionCode,
            "token": 0,
            "pubkey": try identity.publicKey().base64EncodedString(),
            "encryptedHUID": signature.base64EncodedString(),
            "bluetoothName": "CarWithin",
            "supportH264IFrame": true,
            "supportFunction": 0,
            "appVersionFingerPrint": "carwithin"
        ]
        try reply(socket, request.command, payload: try TailingProtocol.json(replyObject))
        condition.lock()
        self.huid = huid
        condition.broadcast()
        condition.unlock()
        let channel = object["channel"].map { "\($0)" } ?? "-"
        let flavor = object["flavor"].map { "\($0)" } ?? "-"
        log("\(dashboard) 仪表型号=\(name) HUID=\(huid) channel=\(channel) flavor=\(flavor)，已回应本机 RSA 身份")
    }

    private func checkSerialNumber(_ socket: TailingSocket, _ request: TailingProtocol.Control) throws {
        let text = String(data: request.payload, encoding: .utf8) ?? ""
        let object = (try? TailingProtocol.object(request.payload)) ?? [:]
        let sn = object["sn"].map { "\($0)" } ?? ""
        log("\(dashboard) SN 校验：\(text)")
        try reply(socket, request.command, payload: Data())
        let result: [String: Any] = ["isOk": true, "errCode": 0, "errMsg": "", "id": sn, "client_set": "easy_conn"]
        try socket.write(TailingProtocol.control(0x201c0, payload: try TailingProtocol.json(result)))
        log("\(dashboard) → SN 校验通过")
    }

    private func reply(_ socket: TailingSocket, _ command: UInt32, payload: Data) throws {
        try socket.write(TailingProtocol.control(command &+ 1, payload: payload))
    }

    // MARK: - 媒体面

    private func media(_ socket: TailingSocket, port: UInt16, _ request: TailingProtocol.Auxiliary) throws {
        switch request.command {
        case Command.configCapture:
            let body = request.payload
            let size = try Self.validatedMediaSize(body)
            let width = Int(body.uint16LE(0)), height = Int(body.uint16LE(2))
            let fps = size.fps, encoder = Int(body.uint32LE(8))
            let ext = body.count >= 30 ? body[body.startIndex + 29] : 0
            let alignedWidth = size.width, alignedHeight = size.height
            condition.lock()
            let changed = configured && negotiated != size
            condition.unlock()
            guard !changed else { throw TailingError.protocolFailure("春风会话内媒体尺寸发生变化，请重新连接") }
            var payload = Data()
            payload.appendLE(UInt32(encoder == 0 ? 2 : encoder))
            payload.appendLE(UInt16(alignedWidth))
            payload.appendLE(UInt16(alignedHeight))
            payload.append(ext)
            try socket.write(TailingProtocol.auxiliary(Command.configCapture + 1, token: request.token, payload: payload))
            condition.lock()
            negotiated = MediaSize(width: alignedWidth, height: alignedHeight, fps: fps > 0 ? fps : 30)
            configured = true
            condition.broadcast()
            condition.unlock()
            log("\(dashboard) 仪表要求 \(width)×\(height)@\(fps) 编码器=\(encoder) → 回 17（\(alignedWidth)×\(alignedHeight)）")
        case Command.getVersion:
            var payload = Data()
            payload.appendLE(UInt32(3))
            payload.appendLE(UInt32(1))
            try socket.write(TailingProtocol.auxiliary(Command.getVersion + 1, token: request.token, payload: payload))
        case Command.mediaHeartbeat:
            try socket.write(TailingProtocol.auxiliary(Command.mediaHeartbeat + 1, token: request.token, payload: Data()))
        case Command.configExtend:
            let payload = try TailingProtocol.json(["state": 0])
            try socket.write(TailingProtocol.auxiliary(Command.configExtend + 1, token: request.token, payload: payload))
            log("\(dashboard) 扩展采集配置 \(request.payload.count) 字节 → 回 97")
        case Command.dataStart:
            condition.lock()
            guard configured else { condition.unlock(); throw TailingError.protocolFailure("春风在媒体配置前请求开流") }
            mediaStarted = true; condition.broadcast(); condition.unlock()
            try socket.write(TailingProtocol.auxiliary(Command.dataStart + 1, token: request.token, payload: Data()))
            log("\(dashboard) 仪表要求开流，已回 113（等待仪表逐帧拉画面）")
        case Command.dataNext:
            condition.lock()
            frameRequested = true
            condition.broadcast()
            condition.unlock()
        default:
            log(String(format: "\(dashboard) 媒体通道 TCP%d 未命名命令 %d（%d 字节）",
                       Int(port), Int(request.command), request.payload.count))
        }
    }

    // MARK: - 逐帧发送

    func waitForH264Request() throws {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(10)
        while !closed && failure == nil && !frameRequested {
            if !condition.wait(until: deadline) { throw TailingError.timeout("等待仪表逐帧拉取画面") }
        }
        try checkLocked()
        frameRequested = false
    }

    func sendH264(_ accessUnit: Data) throws {
        guard accessUnit.count > 4, accessUnit.count <= 8 * 1_024 * 1_024,
              accessUnit.prefix(4) == Data([0, 0, 0, 1]) else {
            throw TailingError.protocolFailure("H.264 Annex B 帧无效或过长")
        }
        condition.lock()
        guard let socket = video, !closed else { condition.unlock(); throw TailingError.closed }
        condition.unlock()
        var packet = Data()
        packet.appendLE(UInt32(accessUnit.count))
        packet.append(accessUnit)
        do {
            try socket.write(packet)
        } catch {
            throw terminalError(or: TailingError.channel("发送 H.264", error))
        }
        condition.lock()
        let count = framesSent + 1
        framesSent = count
        condition.unlock()
        if count <= 5 || count % 60 == 0 {
            log("\(dashboard) 第 \(count) 帧 \(accessUnit.count) 字节 已送")
        }
    }

    private var isClosed: Bool { condition.lock(); defer { condition.unlock() }; return closed }

    func checkHealth() throws {
        condition.lock()
        defer { condition.unlock() }
        try checkLocked()
    }

    private func checkLocked() throws {
        if let failure { throw failure }
        if closed { throw TailingError.closed }
    }

    private func terminalError(or fallback: Error) -> Error {
        do { try checkHealth() } catch { return error }
        return fallback
    }

    private func tracked(_ socket: TailingSocket) throws -> TailingSocket {
        condition.lock()
        defer { condition.unlock() }
        if closed { socket.close(); throw TailingError.closed }
        resources.append(socket)
        return socket
    }

    private func fail(_ error: Error) {
        condition.lock()
        let shouldFail = !closed && failure == nil
        if shouldFail { failure = error }
        condition.unlock()
        if shouldFail { close() }
    }

    func close() {
        condition.lock()
        if closed { condition.unlock(); return }
        closed = true
        let sockets = resources
        resources.removeAll()
        condition.broadcast()
        condition.unlock()
        sockets.forEach { $0.close() }
    }
}

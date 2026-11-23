// Adapted from xmz28/ninebot_pro tests/TailingTests.swift. Run Tools/test_tailing.sh.
import Foundation
import Security

private enum TestError: Error { case failed(String) }
private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw TestError.failed(message) }
}
private func rejects(_ message: String, _ work: () throws -> Void) throws {
    do { try work() } catch { return }
    throw TestError.failed("应拒绝：" + message)
}

private final class ByteReader {
    var data: Data
    init(_ data: Data) { self.data = data }
    func read(_ count: Int) throws -> Data {
        guard data.count >= count else { throw TestError.failed("截断") }
        let result = Data(data.prefix(count))
        data.removeFirst(count)
        return result
    }
}

private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func set(_ value: Value) { lock.lock(); self.value = value; lock.unlock() }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
}

@main
struct TailingTests {
    static func main() throws {
        #if TAILING_MEDIA_SMOKE
        try tailingJPEGSizeSmoke()
        try tailingMediaSmoke()
        #endif
        try frames()
        try identity()
        try socketCancellation()
        let stableIdentity = try TailingIdentity.generate()
        try simulatedInstrument(identity: stableIdentity, idleControlFrames: 11)
        try simulatedInstrument(identity: stableIdentity)
        try simulatedInstrument(identity: stableIdentity, profile: .zeeho62)
        try simulatedInstrument(identity: stableIdentity, profile: .zeeho62)
        try simulatedInstrument(identity: stableIdentity, profile: .carbit)
        try carbitCodes()
        try rejectedInstrument()
        try rejectedInstrument(profile: .carbit)
        try cancelledHandshake()
        print("PASS: 台铃拆包/合包、长度校验、RSA2048/type1、TCP取消、台铃、极核和亿连模拟握手/逐帧拉取/保活/重启，亿连扫码和宽屏协商、错误型号拒绝、协商中停止")
    }

    private static func carbitCodes() throws {
        let url = CarbitConnectionCode("easyconn://pair?ssid=Ford%20WiFi&huip=192.168.43.1")
        try expect(url.address == "192.168.43.1" && url.ssid == "Ford WiFi", "读取连接参数")
        let json = CarbitConnectionCode(#"{"HUIP":"172.16.0.5","WiFiName":"Ford"}"#)
        try expect(json.address == "172.16.0.5" && json.ssid == "Ford", "JSON 连接参数")
        let wifi = CarbitConnectionCode(#"WIFI:T:WPA;S:Ford\;WiFi;P:sample;;"#)
        try expect(wifi.ssid == "Ford;WiFi" && wifi.address == nil, "Wi-Fi 二维码只提取网络名")
        try expect(CarbitConnectionCode("http://192.168.1.17:10930").address == "192.168.1.17", "本地链接")
        try expect(CarbitConnectionCode("10.0.0.1").address == "10.0.0.1", "私网 IPv4")
        for text in ["https://carbit.com.cn/download", "opaque-token", "127.0.0.1", "172.32.0.1", "224.0.0.1", "10.0.0.256"] {
            try expect(CarbitConnectionCode(text).address == nil, "二维码缺少可用地址")
        }
        let odd = try TailingDisplayProfile.carbit.pictureSize(width: 1281, height: 721)
        try expect(odd == PXCPictureSize(width: 1280, height: 720), "奇数尺寸向下对齐")
        try rejects("车机无效尺寸") { _ = try TailingDisplayProfile.carbit.pictureSize(width: 0, height: 720) }
    }

    private static func frames() throws {
        let json = try TailingProtocol.json(["state": 0]) + Data([0])
        let first = try TailingProtocol.control(0x20030, identifier: 0xfedcba98, payload: json)
        let second = try TailingProtocol.control(0x70000000, identifier: 3)
        let reader = ByteReader(first + second)
        let decoded = try TailingProtocol.readControl(reader.read)
        try expect(decoded.identifier == 0xfedcba98 && decoded.command == 0x20030, "iOS 非零标识字段")
        try expect(try TailingProtocol.object(decoded.payload)["state"] as? Int == 0, "NUL结尾 JSON")
        try expect(try TailingProtocol.readControl(reader.read).identifier == 3 && reader.data.isEmpty, "连续控制帧合包")
        var bad = first; bad[8] ^= 1
        try rejects("错误异或校验") { _ = try TailingProtocol.readControl(ByteReader(bad).read) }
        try rejects("截断载荷") { _ = try TailingProtocol.readControl(ByteReader(Data(first.dropLast())).read) }
        var oversized = Data()
        for v: UInt32 in [0x10000, 65_537, 0x10000 ^ 65_537, 0] { oversized.appendLE(v) }
        try rejects("超长控制帧") { _ = try TailingProtocol.readControl(ByteReader(oversized).read) }
        let aux = try TailingProtocol.auxiliary(0x40, token: 93) + TailingProtocol.auxiliary(0x70, token: 94)
        let requests = ByteReader(aux)
        try expect(try TailingProtocol.readAuxiliary(requests.read).token == 93, "配套 token")
        try expect(try TailingProtocol.readAuxiliary(requests.read).command == 0x70, "配套连续请求")
        var tooLong = Data(); tooLong.appendLE(UInt16(16)); tooLong.appendLE(UInt16(8193)); tooLong.appendLE(UInt32(0))
        try rejects("配套载荷长度限制") { _ = try TailingProtocol.readAuxiliary(ByteReader(tooLong).read) }
        let jpeg = Data([0xff, 0xd8, 1, 2, 0xff, 0xd9])
        let envelope = try TailingProtocol.jpeg(jpeg)
        try expect(envelope.uint32LE(0) == 6 && envelope.dropFirst(4) == jpeg, "JPEG小端长度及内容")
        try rejects("不完整 JPEG") { _ = try TailingProtocol.jpeg(Data(jpeg.dropLast())) }
    }

    private static func identity() throws {
        let identity = try TailingIdentity.generate()
        let huid = "TEST-HUID-0123456789"
        let signature = try identity.sign(huid)
        try identity.verify(signature, huid: huid)
        try rejects("其他仪表身份") { try identity.verify(signature, huid: "OTHER") }
        let publicDER = try identity.publicKey()
        try expect(publicDER.count == 294 && signature.count == 256, "iOS RSA2048/SPKI")
        // 独立做公钥原始运算，验证真正的 type1 填充及原始 HUID，不能仅凭同算法自签自验。
        let publicKey = SecKeyCopyPublicKey(identity.key)!
        var error: Unmanaged<CFError>?
        guard let recovered = SecKeyCreateEncryptedData(publicKey, .rsaEncryptionRaw, signature as CFData, &error) as Data? else {
            throw TestError.failed("RSA原始公钥运算失败")
        }
        let message = Data(huid.utf8)
        let paddingLength = 256 - message.count - 3
        let expected = Data([0, 1]) + Data(repeating: 0xff, count: paddingLength) + Data([0]) + message
        try expect(recovered == expected, "必须为00 01 FF...00 HUID，不能做摘要或无填充")
    }

    private static func socketCancellation() throws {
        let server = try TailingSocket.listening(localIP: "127.0.0.1", port: 0)
        let result = Box<Error?>(nil)
        let group = DispatchGroup(); group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do { _ = try server.accept(remoteIP: "127.0.0.1"); result.set(TestError.failed("已关闭监听仍接受连接")) }
            catch { result.set(error) }
        }
        server.close()
        try expect(group.wait(timeout: .now() + 1) == .success && result.get() != nil, "关闭必须唤醒accept")
    }

    private static func simulatedInstrument(identity: TailingIdentity, idleControlFrames: Int = 0,
                                            profile: TailingDisplayProfile = .tailing43) throws {
        let announcement = try TailingSocket.listening(localIP: "127.0.0.1", port: 0)
        defer { announcement.close() }
        let reservations = try (0..<3).map { _ in try TailingSocket.listening(localIP: "127.0.0.1", port: 0) }
        let ports = try TailingPorts(control: reservations[0].localPort, auxiliary: reservations[1].localPort,
                                     video: reservations[2].localPort, announcement: announcement.localPort)
        reservations.forEach { $0.close() }
        let connection = TailingConnection(localIP: "127.0.0.1", targetIP: "127.0.0.1", profile: profile,
            phone: TailingPhoneInfo(package: "test.ninebot", versionCode: 2, model: "iPhone", systemVersion: "17.0", width: 1320, height: 2868, rotation: 0),
            ports: ports, identityProvider: { identity }, log: { _ in })
        defer { connection.close() }
        let result = Box<Error?>(nil)
        let done = DispatchGroup(); done.enter()
        let holdingVideo = DispatchSemaphore(value: 0)
        let sawFrame = DispatchSemaphore(value: 0)
        let gotHeartbeat = DispatchSemaphore(value: 0)
        let idleFramesReceived = DispatchSemaphore(value: 0)
        let h264 = profile.usesH264
        let name: String, input: (UInt16, UInt16), expected: PXCPictureSize
        switch profile {
        case .tailing43: (name, input, expected) = ("TL-DASH-V2", (480, 272), .init(width: 480, height: 272))
        case .zeeho62: (name, input, expected) = ("ZEEHO-TEST", (1024, 488), .init(width: 1024, height: 480))
        case .carbit: (name, input, expected) = ("CARBIT-SIM", (3840, 1200), .init(width: 1920, height: 600))
        }
        let jpeg = Data([0xff, 0xd8, 1, 2, 0xff, 0xd9])
        let accessUnit = Data([0, 0, 0, 1, 0x65, 1, 2, 3])
        DispatchQueue.global().async {
            defer { done.leave() }
            var sockets: [TailingSocket] = []
            defer { sockets.forEach { $0.close() } }
            func connect(_ port: UInt16) throws -> TailingSocket {
                let s = try TailingSocket.create(); sockets.append(s)
                try s.connect(localIP: "127.0.0.1", remoteIP: "127.0.0.1", port: port)
                return s
            }
            do {
                let a = try announcement.accept(remoteIP: "127.0.0.1"); sockets.append(a)
                let request = try TailingProtocol.readControl { try a.readExactly($0) }
                try expect(request.command == 0x70000010, "平台声明请求")
                try expect(try TailingProtocol.object(request.payload)["phoneType"] as? String == "iOS", "声明真实iOS平台")
                try a.write(TailingProtocol.control(0x70000011, payload: TailingProtocol.json(["status": true])))
                let primary = try connect(ports.control)
                let head = try TailingProtocol.control(0x10000, identifier: 17)
                try primary.write(Data(head.prefix(5)))
                try primary.write(Data(head.dropFirst(5)))
                try expect(try TailingProtocol.readControl { try primary.readExactly($0) }.identifier == 17, "主控制回显标识")
                try primary.write(TailingProtocol.control(0x10010, identifier: 19,
                    payload: TailingProtocol.json(["HUName": name, "supportScreenMirroring": true, "HUID": "SIMULATED-HUID"])))
                let infoReply = try TailingProtocol.readControl { try primary.readExactly($0) }
                let info = try TailingProtocol.object(infoReply.payload)
                try expect(infoReply.command == 0x10011 && infoReply.identifier == 19, "身份回复")
                let signature = Data(base64Encoded: info["encryptedHUID"] as! String)!
                try identity.verify(signature, huid: "SIMULATED-HUID")
                if profile == .zeeho62 {
                    let speed = try TailingProtocol.json(["wifiSpeed": 0, "usbSpeed": 0])
                    try primary.write(TailingProtocol.control(0x10690, identifier: 20, payload: speed))
                    let response = try TailingProtocol.readControl { try primary.readExactly($0) }
                    try expect(response.command == 0x10691 && response.identifier == 20, "速率通知不得中断投屏协商")
                    let runningLog = try TailingProtocol.json(["log": "simulated"])
                    try primary.write(TailingProtocol.control(0x10780, identifier: 21, payload: runningLog))
                    let logResponse = try TailingProtocol.readControl { try primary.readExactly($0) }
                    try expect(logResponse.command == 0x10781 && logResponse.identifier == 21, "仪表运行日志不得中断协商")
                    let serialCheck = try TailingProtocol.json(["sn": "TEST-SERIAL"])
                    try primary.write(TailingProtocol.control(0x103e0, identifier: 24, payload: serialCheck))
                    let receipt = try TailingProtocol.readControl { try primary.readExactly($0) }
                    try expect(receipt.command == 0x103e1 && receipt.identifier == 24 && receipt.payload.isEmpty,
                               "序列号校验请求只确认收到")
                }
                let reverse = try connect(ports.control)
                try reverse.write(TailingProtocol.control(0x20000, identifier: 22))
                try expect(try TailingProtocol.readControl { try reverse.readExactly($0) }.identifier == 22, "反向控制标识")
                for _ in 0..<(h264 ? 6 : 5) {
                    let m = try TailingProtocol.readControl { try reverse.readExactly($0) }
                    if m.command == 0x20030 {
                        let display = try TailingProtocol.object(m.payload)
                        try expect(display["width"] as? Int == 1320 && display["mode"] as? Int == 1, "手机尺寸不能误用JPEG480宽")
                    }
                    if m.command == 0x20590 {
                        try expect(h264 && (try TailingProtocol.object(m.payload)["control"] as? Int == 1), "H.264 主动开始投屏")
                    }
                    try reverse.write(TailingProtocol.control(m.command == 0x205a0 ? 0x80000010 : m.command + 1, identifier: m.identifier))
                }
                let aux = try connect(ports.auxiliary)
                var config = Data()
                config.appendLE(input.0)
                config.appendLE(input.1)
                config.append(Data(repeating: 0, count: 28)); config.append(Data(signature.base64EncodedString().utf8))
                try aux.write(TailingProtocol.auxiliary(0x10, token: 57, payload: config))
                let configured = try TailingProtocol.readAuxiliary { try aux.readExactly($0) }
                try expect(configured.command == 0x11 && configured.token == 57 &&
                           configured.payload.uint32LE(0) == (h264 ? 2 : 1) &&
                           configured.payload.uint16LE(4) == expected.width &&
                           configured.payload.uint16LE(6) == expected.height, "媒体配置回应")
                // 连续心跳、启动请求，验证不会丢弃配置后的消息。
                try aux.write(TailingProtocol.auxiliary(0x40, token: 58) + TailingProtocol.auxiliary(0x70, token: 59))
                try expect(try TailingProtocol.readAuxiliary { try aux.readExactly($0) }.token == 58, "媒体心跳回应")
                try expect(try TailingProtocol.readAuxiliary { try aux.readExactly($0) }.command == 0x71, "媒体启动回应")
                let video = try connect(ports.video)
                for index in 0..<(h264 ? 2 : 1) {
                    try video.write(TailingProtocol.auxiliary(0x72))
                    if h264 && index == 0 {
                        try expect(try video.readExactly(8) == Data(count: 8), "首帧前只写一次零前缀")
                    }
                    let length = Int(try video.readExactly(4).uint32LE(0))
                    try expect(try video.readExactly(length) == (h264 ? accessUnit : jpeg), "逐帧 TCP 载荷完整写入")
                }
                sawFrame.signal()
                let heartbeat = try TailingProtocol.readControl { try reverse.readExactly($0, timeout: 4) }
                try expect(heartbeat.command == 0x70000000, "反向周期心跳")
                try reverse.write(TailingProtocol.control(heartbeat.command + 1, identifier: heartbeat.identifier))
                let nextHeartbeat = try TailingProtocol.readControl { try reverse.readExactly($0, timeout: 4) }
                try expect(nextHeartbeat.command == 0x70000000, "保活期间不重复发送同屏配置")
                gotHeartbeat.signal()
                // 控制连接保持打开但不再发送消息，视频和配套心跳继续超过旧的10秒限制。
                for _ in 0..<idleControlFrames {
                    Thread.sleep(forTimeInterval: 1)
                    try aux.write(TailingProtocol.auxiliary(0x40, token: 60))
                    try expect(try TailingProtocol.readAuxiliary { try aux.readExactly($0, timeout: 2) }.command == 0x41,
                               "控制通道静默期间继续回应媒体心跳")
                    try video.write(TailingProtocol.auxiliary(0x72))
                    let size = Int(try video.readExactly(4, timeout: 2).uint32LE(0))
                    try expect(try video.readExactly(size, timeout: 2) == jpeg, "控制通道静默期间继续发送JPEG")
                }
                idleFramesReceived.signal()
                // 保持连接，主线程关闭会话以取消下一次视频读取。
                if h264 {
                    let stop = try TailingProtocol.readControl { try reverse.readExactly($0, timeout: 2) }
                    try expect(stop.command == 0x20590 && (try TailingProtocol.object(stop.payload)["control"] as? Int == 0),
                               "关闭连接前通知仪表停止投屏")
                } else {
                    _ = holdingVideo.wait(timeout: .now() + 5)
                }
            } catch { result.set(error); sawFrame.signal(); gotHeartbeat.signal(); idleFramesReceived.signal() }
        }
        try connection.start()
        try expect(connection.negotiatedSize == expected, "编码器使用协商后的输出尺寸")
        if h264 {
            for _ in 0..<2 {
                try connection.waitForH264Request()
                try connection.sendH264(accessUnit)
            }
        } else {
            try connection.sendJPEG(jpeg)
        }
        try expect(sawFrame.wait(timeout: .now() + 2) == .success, "首帧超时")
        try expect(gotHeartbeat.wait(timeout: .now() + 6) == .success, "周期交互超时")
        if let error = result.get() { throw error }
        for _ in 0..<idleControlFrames {
            try connection.sendJPEG(jpeg)
        }
        try expect(idleFramesReceived.wait(timeout: .now() + 2) == .success, "静默期间逐帧数据读取完成")
        if let error = result.get() { throw error }
        if idleControlFrames > 0 { print("PASS: 控制连接静默超过10秒仍连续响应拉帧与媒体心跳") }
        let cancelledRead = DispatchGroup(); cancelledRead.enter()
        let cancelled = Box(false)
        DispatchQueue.global().async {
            defer { cancelledRead.leave() }
            do {
                if h264 { try connection.waitForH264Request() }
                else { try connection.sendJPEG(Data([0xff, 0xd8, 0xff, 0xd9])) }
            }
            catch { cancelled.set(true) }
        }
        let closing = DispatchGroup()
        for _ in 0..<2 {
            closing.enter()
            DispatchQueue.global().async { connection.close(); closing.leave() }
        }
        try expect(closing.wait(timeout: .now() + 2) == .success, "并发停止需等待所有端口释放")
        try expect(cancelledRead.wait(timeout: .now() + 1) == .success && cancelled.get(), "停止立即取消逐帧请求读取")
        holdingVideo.signal()
        try expect(done.wait(timeout: .now() + 2) == .success, "模拟仪表线程退出")
        if let error = result.get() { throw error }
        // 原三个端口须能立即重用，不能残留监听。
        for port in [ports.control, ports.auxiliary, ports.video] {
            let rebound = try TailingSocket.listening(localIP: "127.0.0.1", port: port)
            rebound.close()
        }
    }

    private static func rejectedInstrument(profile: TailingDisplayProfile = .tailing43) throws {
        let server = try TailingSocket.listening(localIP: "127.0.0.1", port: 0)
        defer { server.close() }
        let reservations = try (0..<3).map { _ in try TailingSocket.listening(localIP: "127.0.0.1", port: 0) }
        let ports = try TailingPorts(control: reservations[0].localPort, auxiliary: reservations[1].localPort,
                                     video: reservations[2].localPort, announcement: server.localPort)
        reservations.forEach { $0.close() }
        let identity = try TailingIdentity.generate()
        let connection = TailingConnection(localIP: "127.0.0.1", targetIP: "127.0.0.1", profile: profile,
            phone: TailingPhoneInfo(package: "test.carwithin", versionCode: 2, model: "iPhone", systemVersion: "17", width: 1320, height: 2868, rotation: 0),
            ports: ports, identityProvider: { identity }, log: { _ in })
        defer { connection.close() }
        let done = DispatchGroup(); done.enter()
        DispatchQueue.global().async {
            defer { done.leave() }
            do {
                let a = try server.accept(remoteIP: "127.0.0.1"); defer { a.close() }
                _ = try TailingProtocol.readControl { try a.readExactly($0) }
                try a.write(TailingProtocol.control(0x70000011, payload: TailingProtocol.json(["status": true])))
                let control = try TailingSocket.create(); defer { control.close() }
                try control.connect(localIP: "127.0.0.1", remoteIP: "127.0.0.1", port: ports.control)
                try control.write(TailingProtocol.control(0x10010, payload: TailingProtocol.json(["HUName": "OTHER-HARDWARE", "HUID": "TEST", "supportScreenMirroring": false])))
                _ = try control.readExactly(16, timeout: 2)
            } catch { /* App应主动关闭，主线程核对具体拒绝原因。 */ }
        }
        do {
            try connection.start()
            throw TestError.failed("不支持型号被接受")
        } catch let error as TailingError {
            try expect(error.localizedDescription.contains(profile == .carbit ? "未开放镜像" : "TL-DASH-V2"), "型号错误必须明确报告，不能等到泛化超时")
        }
        try expect(done.wait(timeout: .now() + 2) == .success, "错误型号测试退出")
    }

    private static func cancelledHandshake() throws {
        let server = try TailingSocket.listening(localIP: "127.0.0.1", port: 0)
        defer { server.close() }
        let reservations = try (0..<3).map { _ in try TailingSocket.listening(localIP: "127.0.0.1", port: 0) }
        let ports = try TailingPorts(control: reservations[0].localPort, auxiliary: reservations[1].localPort,
                                     video: reservations[2].localPort, announcement: server.localPort)
        reservations.forEach { $0.close() }
        let identity = try TailingIdentity.generate()
        let connection = TailingConnection(localIP: "127.0.0.1", targetIP: "127.0.0.1", profile: .tailing43,
            phone: TailingPhoneInfo(package: "test.carwithin", versionCode: 2, model: "iPhone", systemVersion: "17", width: 1320, height: 2868, rotation: 0),
            ports: ports, identityProvider: { identity }, log: { _ in })
        defer { connection.close() }
        let done = DispatchGroup(); done.enter()
        let stopped = Box(false)
        DispatchQueue.global().async {
            defer { done.leave() }
            do { try connection.start() } catch { stopped.set(true) }
        }
        let requestSocket = try server.accept(remoteIP: "127.0.0.1")
        defer { requestSocket.close() }
        _ = try TailingProtocol.readControl { try requestSocket.readExactly($0) }
        connection.close() // 不发送启动回复，必须立即中断read而非等3秒超时。
        try expect(done.wait(timeout: .now() + 1) == .success && stopped.get(), "协商中停止需及时退出")
    }
}

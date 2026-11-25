// SPDX-FileCopyrightText: 2026 OpenXPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
// Swift port of OpenXPlay-Stream kotlin/carlife (CarlifeFraming, Proto, CarlifeCrypto, CarlifeInput,
// CarlifeSession, CarlifeOutput, ReceiverProfile). Experimental; see THIRD_PARTY_NOTICES.txt.
import Foundation
import Network
import CryptoKit
import CommonCrypto
import Security
import Darwin

/// Sends the CarPlay picture to a head unit's CarLife app and takes its touches and keys back.
///
/// Wire roles follow the OpenXPlay relay: CarWithin listens on seven TCP ports (one per CarLife
/// channel), announces itself with a one-byte UDP datagram to port 7999, and the head unit
/// connects in. Video is H.264 Annex-B on channel 2. CarLife carries no audio: sound stays on the
/// iPhone and reaches the car over its Bluetooth link.
final class CarLifeOutput {
    static let ports: [UInt16] = [7240, 8240, 9240, 9241, 9242, 9340, 9440]
    static let discoveryPort: UInt16 = 7999

    private let queue = DispatchQueue(label: "CarWithin.carlife", qos: .userInitiated)
    private var listeners: [NWListener] = []
    private var session: Session?
    private var generation = UUID()
    private var running = false
    private var targetAddress: String?
    private var videoWidth = 1280, videoHeight = 720, maxFPS = 30
    private var parameters = VideoParameterSets(codec: .h264)
    private var warnedCodec = false
    private var discoverySocket: Int32 = -1
    private var querySocket: Int32 = -1
    private var queryReplies = 0
    private var discoveryErrorLogged = false
    private var timer: DispatchSourceTimer?

    var onLog: ((String) -> Void)?
    var onState: ((String) -> Void)?
    /// Every finger the head unit holds, normalized 0…1; an empty list releases them.
    var onTouches: (([TouchPoint]) -> Void)?
    var onControl: ((CarPlayControl) -> Void)?
    var onKeyframeRequest: ((String) -> Void)?

    func start(targetAddress: String?, width: Int, height: Int, fps: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopOnQueue()
            self.running = true
            self.targetAddress = targetAddress.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            self.videoWidth = width; self.videoHeight = height; self.maxFPS = max(1, min(60, fps))
            let run = self.generation
            self.listenForDiscoveryQueries()
            for (index, port) in Self.ports.enumerated() { self.listen(port: port, channel: index + 1, run: run) }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 0.2, repeating: 1)
            var ticks = 0
            timer.setEventHandler { [weak self] in
                guard let self, self.generation == run else { return }
                self.receiveDiscoveryQueries()
                self.session?.tick()
                self.checkSession()
                if ticks == 15, self.session == nil {
                    self.log("CarLife: no TCP callback after 15 s; UDP 8999 ready replies: \(self.queryReplies). Verify receiver CarLife mode and hotspot connection.")
                }
                // Announce every 2 s until a head unit has authenticated.
                if ticks % 2 == 0, self.session?.authenticated != true { self.discover() }
                ticks += 1
            }
            timer.resume(); self.timer = timer
            self.state(CWL("CarLife：正在等待车机连接（端口 {1}）", [String(describing: Self.ports[0])]))
        }
    }

    func append(_ accessUnit: Data, codec: VideoCodec) {
        queue.async { [weak self] in self?.appendOnQueue(accessUnit, codec: codec) }
    }

    func stop() { queue.async { [weak self] in self?.stopOnQueue() } }

    // MARK: Listeners

    private func listen(port: UInt16, channel: Int, run: UUID) {
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true; tcp.enableKeepalive = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        guard let endpointPort = NWEndpoint.Port(rawValue: port),
              let listener = try? NWListener(using: parameters, on: endpointPort) else {
            log(CWL("CarLife 端口 {1} 无法监听", [String(describing: port)])); return
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, self.generation == run else { return }
            if case .failed(let error) = state { self.log(CWL("CarLife 端口 {1} 监听失败：{2}", [String(describing: port), String(describing: error.localizedDescription)])) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, self.generation == run else { connection.cancel(); return }
            self.accept(connection, channel: channel)
        }
        listener.start(queue: queue)
        listeners.append(listener)
    }

    private func accept(_ connection: NWConnection, channel: Int) {
        let peer: String
        if case .hostPort(let host, _) = connection.endpoint { peer = "\(host)".split(separator: "%").first.map(String.init) ?? "\(host)" }
        else { peer = CWL("车机") }
        if let existing = session, existing.peer != peer {
            // One head unit at a time.
            connection.cancel(); return
        }
        log("CarLife TCP channel \(channel) connected from \(peer)")
        let link = Link(connection: connection, channel: channel)
        if session == nil || (channel == 1 && session?.ownsChannel(1) == true) {
            // A new control socket always starts a new authenticated lifetime.
            session?.close(reason: CWL("控制连接被替换"))
            parameters = VideoParameterSets(codec: .h264)
            session = makeSession(peer: peer)
        }
        guard let session else { connection.cancel(); return }
        session.attach(link)
        connection.stateUpdateHandler = { [weak self, weak session, weak link] state in
            guard let self, let session, let link else { return }
            switch state {
            case .ready: self.receive(link, session: session)
            case .failed, .cancelled: self.ended(session, link: link, reason: CWL("连接已断开"))
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func makeSession(peer: String) -> Session {
        let session = Session(peer: peer, width: videoWidth, height: videoHeight, maxFPS: maxFPS)
        session.log = { [weak self] in self?.log("CarLife \($0)") }
        session.onState = { [weak self] in self?.state($0) }
        session.onTouches = { [weak self] in self?.onTouches?($0) }
        session.onControl = { [weak self] in self?.onControl?($0) }
        session.onKeyframeRequest = { [weak self] in self?.onKeyframeRequest?("CarLife：\($0)") }
        return session
    }

    private func receive(_ link: Link, session: Session) {
        link.connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self, weak session, weak link] data, _, complete, error in
            guard let self, let session, let link, self.session === session, session.owns(link) else { return }
            if let data { link.buffer.append(data) }
            do {
                while let message = try CarLifeFraming.take(from: &link.buffer, channel: link.channel) {
                    try session.receive(message)
                    guard self.session === session else { return }
                }
            } catch {
                session.close(reason: CWL("协议错误：{1}", [String(describing: error.localizedDescription)]))
                self.ended(session, link: link, reason: nil); return
            }
            if complete || error != nil { self.ended(session, link: link, reason: CWL("车机关闭了连接")); return }
            self.receive(link, session: session)
        }
    }

    private func ended(_ session: Session, link: Link, reason: String?) {
        link.connection.cancel()
        guard self.session === session, session.owns(link) || !session.active else { return }
        session.close(reason: reason ?? CWL("会话结束"))
        self.session = nil
        parameters = VideoParameterSets(codec: .h264)
        if running { state(CWL("CarLife：已断开，正在等待车机重新连接")) }
    }

    private func checkSession() {
        guard let session, let failure = session.transportFailure() else { return }
        session.close(reason: failure)
        self.session = nil
        state(CWL("CarLife：{1}，正在等待车机重新连接", [String(describing: failure)]))
    }

    // MARK: Video

    private func appendOnQueue(_ accessUnit: Data, codec: VideoCodec) {
        guard running else { return }
        guard codec == .h264 else {
            if !warnedCodec { warnedCodec = true; log(CWL("CarLife 只支持 H.264，当前 CarPlay 输出 {1}，已忽略画面", [String(describing: codec.displayName)])) }
            return
        }
        guard let units = try? AnnexB.units(in: accessUnit) else { return }
        var picture: [Data] = []
        var keyframe = false
        for unit in units {
            if codec.parameterSet(unit) != nil { _ = parameters.absorb(unit); continue }
            if codec.isRandomAccess(unit) { keyframe = true }
            picture.append(unit)
        }
        guard !picture.isEmpty, let session, parameters.isComplete else { return }
        session.video(picture: picture, keyframe: keyframe, parameterSets: parameters.ordered)
    }

    // MARK: Discovery

    /// One byte to UDP 7999 makes a listening head unit connect back. Broadcast needs the multicast
    /// entitlement on iOS, which a development build may lack, so the local subnet is also swept by
    /// unicast (at most 254 tiny datagrams every 2 s).
    private func discover() {
        if discoverySocket < 0 {
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { return }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            discoverySocket = fd
        }
        var targets: [String] = []
        if let targetAddress { targets = [targetAddress] }
        else {
            targets.append("255.255.255.255")
            for network in Self.localNetworks() {
                targets.append(network.broadcast)
                targets.append(contentsOf: network.hosts)
            }
        }
        var failures = 0, lastError: Int32 = 0
        for target in targets {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
            address.sin_port = Self.discoveryPort.bigEndian
            guard inet_pton(AF_INET, target, &address.sin_addr) == 1 else { continue }
            var byte: UInt8 = 1
            let sent = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(discoverySocket, &byte, 1, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if sent < 0 { failures += 1; lastError = errno }
        }
        if failures > 0, !discoveryErrorLogged {
            discoveryErrorLogged = true
            log(CWL("CarLife 发现包有 {1}/{2} 个发送失败（errno {3}）；广播在 iOS 上可能被限制，仍会逐个地址发送。找不到车机时请填写车机 IP", [String(describing: failures), String(describing: targets.count), String(describing: lastError)]))
        }
    }

    // Some receivers query the phone on UDP 8999 instead of reacting to the 7999 beacon.
    // Kept on the session queue so restart/stop cannot race a receive on a reused descriptor.
    private func listenForDiscoveryQueries() {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { log("CarLife UDP 8999 socket failed: \(errno)"); return }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(8999).bigEndian
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            let failure = errno; close(fd)
            log("CarLife UDP 8999 listen failed: \(failure)"); return
        }
        querySocket = fd
        log("CarLife discovery: UDP 8999 listening; UDP 7999 beacon enabled")
    }

    private func receiveDiscoveryQueries() {
        guard querySocket >= 0 else { return }
        // Bound the work per tick even when another device floods this port.
        for _ in 0..<32 {
            var address = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            var bytes = [UInt8](repeating: 0, count: 2048)
            let count = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(querySocket, &bytes, bytes.count, 0, $0, &length)
                }
            }
            guard count >= 0 else { return }
            guard let host = inet_ntoa(address.sin_addr) else { continue }
            let peer = String(cString: host)
            let allowed = targetAddress.map { $0 == peer }
                ?? Self.localNetworks().contains { $0.hosts.contains(peer) }
            guard allowed else { continue }
            let text = String(decoding: bytes.prefix(count), as: UTF8.self)
            guard text.contains("carlifehost") else { continue }
            // Do not bounce ready responses between two phone-side implementations.
            if let json = try? JSONSerialization.jsonObject(with: Data(bytes.prefix(count))) as? [String: Any],
               json["status"] as? String == "ready" { continue }
            let reply = Data("{\"carlifehost\":\"carlife\",\"status\":\"ready\"}".utf8)
            let sent = reply.withUnsafeBytes { data in
                withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(querySocket, data.baseAddress, data.count, 0, $0, length)
                    }
                }
            }
            queryReplies += 1
            if queryReplies == 1 || queryReplies % 30 == 0 {
                log("CarLife discovery query from \(peer):\(UInt16(bigEndian: address.sin_port)); ready reply \(sent == reply.count ? "sent" : "failed")")
            }
        }
    }

    private struct LocalNetwork { let broadcast: String; let hosts: [String] }
    private static func localNetworks() -> [LocalNetwork] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var result: [LocalNetwork] = []
        var current = first
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge"),
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  let mask = entry.pointee.ifa_netmask else { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            // Sweep only /24 or smaller networks.
            guard netmask >= 0xFFFF_FF00, netmask != 0xFFFF_FFFF else { continue }
            let network = ip & netmask, broadcast = network | ~netmask
            func text(_ value: UInt32) -> String { "\(value >> 24).\((value >> 16) & 255).\((value >> 8) & 255).\(value & 255)" }
            let hosts = (network + 1 ..< broadcast).filter { $0 != ip }.map(text)
            result.append(LocalNetwork(broadcast: text(broadcast), hosts: hosts))
        }
        return result
    }

    // MARK: Lifecycle

    private func stopOnQueue() {
        generation = UUID(); running = false
        timer?.cancel(); timer = nil
        listeners.forEach { $0.cancel() }; listeners.removeAll()
        session?.close(reason: CWL("CarPlay 已停止")); session = nil
        parameters = VideoParameterSets(codec: .h264); warnedCodec = false
        if discoverySocket >= 0 { close(discoverySocket); discoverySocket = -1 }
        discoveryErrorLogged = false
        if querySocket >= 0 { close(querySocket); querySocket = -1 }
        queryReplies = 0
    }

    private func log(_ message: String) { onLog?(message) }
    private func state(_ message: String) {
        onLog?(message)
        DispatchQueue.main.async { [weak self] in self?.onState?(message) }
    }

    deinit {
        if discoverySocket >= 0 { close(discoverySocket) }
        if querySocket >= 0 { close(querySocket) }
    }
}

// MARK: - Transport link

private final class Link {
    let connection: NWConnection
    let channel: Int
    var buffer = Data()
    var pendingBytes = 0
    /// Last time a write completed (or the first write started); detects stalled sockets.
    var progressAt = DispatchTime.now()
    init(connection: NWConnection, channel: Int) { self.connection = connection; self.channel = channel }

    func write(_ data: Data) {
        if pendingBytes == 0 { progressAt = .now() }
        pendingBytes += data.count
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.pendingBytes = max(0, self.pendingBytes - data.count)
            self.progressAt = .now()
            if error != nil { self.connection.cancel() }
        })
    }
    var stalled: Bool { pendingBytes > 0 && DispatchTime.now().uptimeNanoseconds - progressAt.uptimeNanoseconds > 4_000_000_000 }
}

// MARK: - Framing

struct CarLifeMessage { let channel: Int; let id: Int; var payload: Data }

enum CarLifeError: LocalizedError {
    case protocolViolation(String)
    var errorDescription: String? { if case .protocolViolation(let code) = self { return code }; return nil }
}

private func require(_ condition: Bool, _ code: String) throws {
    if !condition { throw CarLifeError.protocolViolation(code) }
}

enum CarLifeFraming {
    static let maximumMessageBytes = 67_108_864
    /// Channels 1 (command) and 6 (touch) use 8-byte headers, the rest 12.
    static func headerSize(_ channel: Int) -> Int { channel == 1 || channel == 6 ? 8 : 12 }

    static func encode(_ message: CarLifeMessage) throws -> Data {
        let header = headerSize(message.channel)
        try require(message.payload.count <= maximumMessageBytes - header, "invalid_payload_length")
        var data = Data(capacity: header + message.payload.count)
        if header == 8 {
            try require(message.payload.count <= 65535, "invalid_payload_length")
            data.appendBE(UInt16(message.payload.count)); data.appendBE(UInt16(0))
        } else {
            data.appendBE(UInt32(message.payload.count)); data.appendBE(UInt32(0))
        }
        data.appendBE(UInt32(truncatingIfNeeded: message.id))
        data.append(message.payload)
        return data
    }

    /// Removes one complete message from `buffer`, or returns nil when more bytes are needed.
    static func take(from buffer: inout Data, channel: Int) throws -> CarLifeMessage? {
        let size = headerSize(channel)
        guard buffer.count >= size else { return nil }
        let bytes = [UInt8](buffer.prefix(size))
        let length: Int, id: Int
        if size == 8 {
            length = Int(bytes[0]) << 8 | Int(bytes[1])
            id = Int(UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7]))
        } else {
            length = Int(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
            id = Int(UInt32(bytes[8]) << 24 | UInt32(bytes[9]) << 16 | UInt32(bytes[10]) << 8 | UInt32(bytes[11]))
        }
        try require((0...(maximumMessageBytes - size)).contains(length), "invalid_payload_length")
        // Bounded input: only the video channel carries large messages, and it is outbound.
        try require(length <= 4 * 1024 * 1024, "payload_too_large")
        guard buffer.count >= size + length else { return nil }
        let payload = Data(buffer[(buffer.startIndex + size)..<(buffer.startIndex + size + length)])
        buffer.removeFirst(size + length)
        return CarLifeMessage(channel: channel, id: id, payload: payload)
    }
}

private extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) { Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) } }
}

// MARK: - Protobuf subset

/// Presence-aware subset of proto2; unknown fields are skipped, never interpreted.
struct CarLifeProto {
    private(set) var integers: [Int: Int64] = [:]
    private(set) var strings: [Int: [Data]] = [:]
    func number(_ field: Int) -> Int64? { integers[field] }
    func text(_ field: Int) -> String? { strings[field]?.last.map { String(decoding: $0, as: UTF8.self) } }
    func messages(_ field: Int) -> [CarLifeProto] { (strings[field] ?? []).compactMap { try? CarLifeProto(parsing: $0) } }

    init(parsing data: Data) throws {
        let bytes = [UInt8](data)
        var offset = 0
        func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for index in 0..<10 {
                try require(offset < bytes.count, "malformed_protobuf")
                let next = bytes[offset]; offset += 1
                if index == 9 { try require(next <= 1, "malformed_protobuf") }
                value |= UInt64(next & 127) << UInt64(index * 7)
                if next < 128 { return value }
            }
            throw CarLifeError.protocolViolation("malformed_protobuf")
        }
        func skip(_ count: Int) throws {
            try require(count >= 0 && count <= bytes.count - offset, "malformed_protobuf"); offset += count
        }
        func field(_ tag: UInt64, depth: Int, collect: Bool) throws {
            try require(depth < 32 && (1...536_870_911).contains(tag >> 3), "malformed_protobuf")
            let number = Int(tag >> 3)
            switch tag & 7 {
            case 0: let value = try varint(); if collect { integers[number] = Int64(bitPattern: value) }
            case 1: try skip(8)
            case 2:
                let length = try varint()
                try require(length <= UInt64(bytes.count - offset), "malformed_protobuf")
                let end = offset + Int(length)
                if collect { strings[number, default: []].append(Data(bytes[offset..<end])) }
                offset = end
            case 3:
                while true {
                    let nested = try varint()
                    if nested & 7 == 4 { try require(nested >> 3 == UInt64(number), "malformed_protobuf"); break }
                    try field(nested, depth: depth + 1, collect: false)
                }
            case 5: try skip(4)
            default: throw CarLifeError.protocolViolation("malformed_protobuf")
            }
        }
        while offset < bytes.count { try field(try varint(), depth: 0, collect: true) }
    }
}

struct CarLifeProtoWriter {
    private(set) var data = Data()
    private mutating func varint(_ number: UInt64) {
        var value = number
        while value & ~UInt64(127) != 0 { data.append(UInt8(value & 127) | 128); value >>= 7 }
        data.append(UInt8(value))
    }
    func number(_ field: Int, _ value: Int64) -> Self {
        var copy = self; copy.varint(UInt64(field) << 3); copy.varint(UInt64(bitPattern: value)); return copy
    }
    func text(_ field: Int, _ value: String) -> Self { bytes(field, Data(value.utf8)) }
    func bytes(_ field: Int, _ value: Data) -> Self {
        var copy = self; copy.varint(UInt64(field) << 3 | 2); copy.varint(UInt64(value.count)); copy.data.append(value); return copy
    }
}

// MARK: - Crypto

private final class CarLifeCrypto {
    private var key: Data?
    private(set) var active = false

    /// RSA-PKCS#1 encrypts a fresh AES-128 key with the head unit's SubjectPublicKeyInfo.
    func negotiate(publicKey base64: String) throws -> String {
        guard let der = Data(base64Encoded: base64) else { throw CarLifeError.protocolViolation("invalid_public_key") }
        let pkcs1 = Self.rsaKey(fromSPKI: der) ?? der
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        guard let publicKey = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, nil) else {
            throw CarLifeError.protocolViolation("invalid_public_key")
        }
        var fresh = Data(count: 16)
        let status = fresh.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        try require(status == errSecSuccess, "random_failed")
        guard let encrypted = SecKeyCreateEncryptedData(publicKey, .rsaEncryptionPKCS1, fresh as CFData, nil) as Data? else {
            throw CarLifeError.protocolViolation("content_encryption_failed")
        }
        key = fresh
        return encrypted.base64EncodedString()
    }

    func activate() throws { try require(key != nil, "unexpected_phase"); active = true }

    func transform(_ message: CarLifeMessage, encrypt: Bool) throws -> CarLifeMessage {
        guard active, message.id != 98305, !message.payload.isEmpty, let key else { return message }
        var output = Data(count: message.payload.count + kCCBlockSizeAES128)
        let outputCount = output.count
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            message.payload.withUnsafeBytes { input in
                key.withUnsafeBytes { k in
                    CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                            k.baseAddress, kCCKeySizeAES128, nil,
                            input.baseAddress, message.payload.count, out.baseAddress, outputCount, &moved)
                }
            }
        }
        try require(status == kCCSuccess, "content_encryption_failed")
        output.count = moved
        var result = message; result.payload = output
        return result
    }

    /// MD5 over "CARLIFE" + brand + model + sdk + the challenge after its "2.0;" prefix.
    static func authenticate(brand: String, model: String, sdk: String, challenge: String) throws -> String {
        try require(challenge.hasPrefix("2.0;") && challenge.count > 4, "unsupported_auth_challenge")
        let text = "CARLIFE" + brand + model + sdk + challenge.dropFirst(4)
        return Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// SubjectPublicKeyInfo → PKCS#1 RSAPublicKey (the BIT STRING contents), as SecKey expects.
    private static func rsaKey(fromSPKI der: Data) -> Data? {
        let bytes = [UInt8](der)
        func tlv(_ at: Int) -> (tag: UInt8, start: Int, end: Int)? {
            guard at + 1 < bytes.count else { return nil }
            var length = Int(bytes[at + 1]), start = at + 2
            if length & 0x80 != 0 {
                let count = length & 0x7f
                guard count > 0, count <= 4, start + count <= bytes.count else { return nil }
                length = bytes[start..<(start + count)].reduce(0) { $0 << 8 | Int($1) }
                start += count
            }
            guard start + length <= bytes.count else { return nil }
            return (bytes[at], start, start + length)
        }
        guard let outer = tlv(0), outer.tag == 0x30,
              let algorithm = tlv(outer.start), algorithm.tag == 0x30,
              let bits = tlv(algorithm.end), bits.tag == 0x03, bits.end > bits.start + 1, bytes[bits.start] == 0 else { return nil }
        return Data(bytes[(bits.start + 1)..<bits.end])
    }
}

// MARK: - Session

/// One head unit and one authenticated lifetime; a reconnect always gets a new instance.
/// Confined to the CarLifeOutput queue.
private final class Session {
    /// 3.x receivers (protocol 1) neither challenge nor accept parameter sets on every keyframe.
    private enum Profile { case legacy, current
        init?(major: Int64) { switch major { case 1: self = .legacy; case 3, 4: self = .current; default: return nil } }
    }
    // Device information the auth hash is computed over; kept equal to the OpenXPlay relay.
    private static let brand = "OpenXPlay", model = "Relay", sdk = "1"

    let peer: String
    private(set) var active = true
    private(set) var authenticated = false
    private var channels: [Int: Link] = [:]
    private let crypto = CarLifeCrypto()
    private var profile: Profile?
    private var deviceSent = false, authAnswered = false, authAccepted = false
    private var streaming = false
    private var encryptionRequested = false
    private let width: Int, height: Int, maxFPS: Int
    private var fps: Int
    private var encoderChannel = 1
    private var lastSent = DispatchTime.now()
    private var lastKeyframeRequest = DispatchTime(uptimeNanoseconds: 0)
    private let createdAt = DispatchTime.now()
    private var framesSent = 0
    private var waitingForKeyframe = true
    private var parameterSetsSent = false
    private var skips = 0
    /// Held fingers in the order they went down; pointer-up indexes refer to this order.
    private var touches: [TouchPoint] = []
    /// Above this backlog on the video socket, frames are skipped to the next keyframe.
    private let skipPendingBytes = 1024 * 1024

    var log: ((String) -> Void)?
    var onState: ((String) -> Void)?
    var onTouches: (([TouchPoint]) -> Void)?
    var onControl: ((CarPlayControl) -> Void)?
    var onKeyframeRequest: ((String) -> Void)?

    init(peer: String, width: Int, height: Int, maxFPS: Int) {
        self.peer = peer; self.width = width; self.height = height; self.maxFPS = maxFPS; fps = maxFPS
    }

    func attach(_ link: Link) {
        channels.updateValue(link, forKey: link.channel)?.connection.cancel()
        if link.channel == 1 { log?(CWL("车机 {1} 已连接", [String(describing: peer)])) }
    }
    func owns(_ link: Link) -> Bool { channels[link.channel] === link }
    func ownsChannel(_ channel: Int) -> Bool { channels[channel] != nil }

    func receive(_ wire: CarLifeMessage) throws {
        guard active else { return }
        let message = try crypto.transform(wire, encrypt: false)
        guard profile != nil || message.id == 98305 else { return }
        func proto() throws -> CarLifeProto { try CarLifeProto(parsing: message.payload) }
        switch message.id {
        case 98305:
            try require(profile == nil, "unexpected_phase")
            let payload = try proto()
            guard let major = payload.number(1), let selected = Profile(major: major) else {
                log?(CWL("车机协议版本不受支持（{1}）", [String(describing: payload.number(1).map(String.init) ?? CWL("无"))]))
                throw CarLifeError.protocolViolation("version_mismatch")
            }
            profile = selected
            log?(CWL("协议版本 {1}.{2}，{3}", [String(describing: major), String(describing: payload.number(2) ?? 0), String(describing: selected == .legacy ? CWL("3.x 车机") : CWL("4.x 车机"))]))
            send(1, 65538, CarLifeProtoWriter().number(1, 1).number(2, major).data)
            onState?(CWL("CarLife：车机 {1} 已连接，正在认证", [String(describing: peer)]))
        case 98343, 98307:
            sendDevice()
        case 98376:
            try require(deviceSent, "unexpected_phase")
            guard let challenge = try proto().text(1) else { throw CarLifeError.protocolViolation("malformed_protobuf") }
            let answer = try CarLifeCrypto.authenticate(brand: Self.brand, model: Self.model, sdk: Self.sdk, challenge: challenge)
            send(1, 65609, CarLifeProtoWriter().text(1, answer).data)
            authAnswered = true
        case 98378:
            try require(authAnswered, "unexpected_phase")
            try require(try proto().number(1) == 1, "auth_rejected")
            authAccepted = true
            send(1, 65611, CarLifeProtoWriter().number(1, 1).data)
        case 98380:
            try require(authAccepted, "unexpected_phase")
            established(reason: CWL("认证通过"))
            let flags: [(String, Int64)] = [("AAC_SUPPORT", 0), ("CONTENT_ENCRYPTION", 0), ("CONNECT_TYPE", 5)]
            var writer = CarLifeProtoWriter().number(1, Int64(flags.count))
            for (key, value) in flags { writer = writer.bytes(2, CarLifeProtoWriter().text(1, key).number(2, value).data) }
            send(1, 65617, writer.data)
        case 98386:
            let wantsEncryption = try proto().messages(2).contains { $0.text(1) == "CONTENT_ENCRYPTION" && $0.number(2) == 1 }
            if wantsEncryption, !encryptionRequested, !crypto.active {
                encryptionRequested = true
                log?(CWL("车机要求内容加密"))
                send(1, 65642)
            }
        case 98411:
            try require(authenticated && !crypto.active, "unexpected_phase")
            guard let key = try proto().text(1) else { throw CarLifeError.protocolViolation("malformed_protobuf") }
            send(1, 65644, CarLifeProtoWriter().text(1, try crypto.negotiate(publicKey: key)).data)
        case 98413:
            try require(!crypto.active, "unexpected_phase")
            send(1, 65646)
        case 98415:
            try crypto.activate()
            log?(CWL("内容加密已启用"))
        case 98311:
            // A receiver that does not challenge establishes the session at video negotiation.
            if !authenticated, profile == .legacy { established(reason: CWL("车机无需认证")) }
            try require(authenticated, "unexpected_phase")
            let payload = try proto()
            guard let rawWidth = payload.number(1), let rawHeight = payload.number(2),
                  (16...16384).contains(rawWidth), (16...16384).contains(rawHeight) else {
                throw CarLifeError.protocolViolation("invalid_display")
            }
            let requestedFPS = Int(payload.number(3) ?? 0)
            fps = requestedFPS > 0 ? min(max(requestedFPS, 1), maxFPS) : maxFPS
            encoderChannel = message.channel
            log?(CWL("车机屏幕 {1}×{2}，请求 {3} FPS；发送 {4}×{5} @ {6} FPS H.264", [String(describing: rawWidth), String(describing: rawHeight), String(describing: requestedFPS), String(describing: width), String(describing: height), String(describing: fps)]))
            send(encoderChannel, 65544, CarLifeProtoWriter().number(1, Int64(width)).number(2, Int64(height)).number(3, Int64(fps)).data)
        case 98313:
            try require(authenticated, "unexpected_phase")
            streaming = true; waitingForKeyframe = true
            onState?(CWL("CarLife：车机已请求画面，正在等待关键帧"))
            requestKeyframe(CWL("车机请求画面"))
        case 98314:
            streaming = false
            releaseTouches()
            onState?(CWL("CarLife：车机暂停了画面"))
        case 98389:
            if let code = try? proto().text(1) { log?(CWL("车机状态码 {1}", [String(describing: code.prefix(40))])) }
        case 425985, 425998:
            guard authenticated else { break }
            do { try touch(message.payload, raw: message.id == 425998) }
            catch { log?(CWL("忽略无效触控数据")) }
        case 425992:
            guard authenticated, let code = try? proto().number(1), let control = Self.control(forKey: code) else { break }
            onControl?(control)
        default:
            // Empty keepalives and unknown extension messages need no reply.
            break
        }
    }

    private func established(reason: String) {
        authenticated = true
        onState?(CWL("CarLife：已与车机 {1} 建立会话（{2}）", [String(describing: peer), String(describing: reason)]))
    }

    private func sendDevice() {
        guard !deviceSent else { return }
        send(1, 65540, CarLifeProtoWriter().text(1, "Android").text(4, Self.brand).text(14, Self.model)
            .text(20, Self.sdk).text(24, "4.0.0").data)
        deviceSent = true
    }

    // MARK: Video

    func video(picture: [Data], keyframe: Bool, parameterSets: [Data]) {
        guard active, authenticated, streaming, let videoLink = channels[2], let profile else { return }
        if waitingForKeyframe {
            guard keyframe else { return }
            waitingForKeyframe = false
        } else if !keyframe, videoLink.pendingBytes > skipPendingBytes {
            // Never drop a single dependent frame: skip the rest of this GOP and ask for an IDR.
            waitingForKeyframe = true; skips += 1
            if skips == 1 || skips % 10 == 0 { log?(CWL("车机网络跟不上，跳到下一个关键帧（第 {1} 次）", [String(describing: skips)])) }
            requestKeyframe(CWL("网络积压"))
            return
        }
        func annexB(_ units: [Data]) -> Data {
            units.reduce(into: Data()) { $0.append(contentsOf: [0, 0, 0, 1]); $0.append($1) }
        }
        var units = picture
        if keyframe {
            switch profile {
            case .current:
                units = parameterSets + picture
            case .legacy:
                // A 3.x receiver keeps the first parameter sets and supplies them itself after a
                // decoder reset, but only to a keyframe whose first NAL is the IDR slice.
                let idr = Array(picture.drop { VideoCodec.h264.nalType($0) != 5 })
                if !idr.isEmpty {
                    units = (parameterSetsSent ? [] : parameterSets) + idr
                    parameterSetsSent = true
                }
            }
        }
        guard send(2, 131073, annexB(units)) else { return }
        framesSent += 1
        if framesSent == 1 { onState?(CWL("CarLife：正在向车机 {1} 发送 CarPlay 画面", [String(describing: peer)])) }
    }

    func tick() {
        guard active, profile != nil else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        if now - lastSent.uptimeNanoseconds > 1_000_000_000 { send(channels[2] != nil ? 2 : 1, 131074) }
        // Some head units only recover from decoder resets at a keyframe; keep them regular.
        if streaming, now - lastKeyframeRequest.uptimeNanoseconds >= 1_500_000_000 { requestKeyframe(nil) }
    }

    private func requestKeyframe(_ reason: String?) {
        lastKeyframeRequest = .now()
        onKeyframeRequest?(reason ?? CWL("定期刷新"))
    }

    func transportFailure() -> String? {
        if channels.values.contains(where: \.stalled) { return CWL("车机连接写入超时") }
        if !authenticated, DispatchTime.now().uptimeNanoseconds - createdAt.uptimeNanoseconds >= 30_000_000_000 { return CWL("车机认证超时") }
        return nil
    }

    @discardableResult
    private func send(_ channel: Int, _ id: Int, _ payload: Data = Data()) -> Bool {
        guard active, let link = channels[channel] else { return false }
        do {
            let message = try crypto.transform(CarLifeMessage(channel: channel, id: id, payload: payload), encrypt: true)
            link.write(try CarLifeFraming.encode(message))
            lastSent = .now()
            return true
        } catch {
            log?(CWL("发送失败：{1}", [String(describing: error.localizedDescription)])); return false
        }
    }

    // MARK: Input

    /// Action (low byte): 0 down, 1 up, 2 move, 3 cancel, 5 pointer down, 6 pointer up (index in bits 8–15).
    private func touch(_ payload: Data, raw: Bool) throws {
        var contacts: [(id: Int, x: Int, y: Int)] = []
        let action: Int
        if raw {
            let bytes = [UInt8](payload)
            try require(bytes.count >= 4 && (bytes.count - 4) % 5 == 0 && (bytes.count - 4) / 5 <= 10, "invalid_touch")
            action = Int(Int32(bitPattern: UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])))
            var offset = 4
            while offset < bytes.count {
                contacts.append((Int(bytes[offset]), Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]),
                                 Int(bytes[offset + 3]) << 8 | Int(bytes[offset + 4])))
                offset += 5
            }
        } else {
            let proto = try CarLifeProto(parsing: payload)
            guard let value = proto.number(1) else { throw CarLifeError.protocolViolation("invalid_touch") }
            action = Int(truncatingIfNeeded: value)
            if let x = proto.number(2), let y = proto.number(3) { contacts.append((0, Int(x), Int(y))) }
            else { try require([1, 3, 6].contains(action & 255), "invalid_touch") }
            let px = Int(proto.number(4) ?? 0), py = Int(proto.number(5) ?? 0)
            if px != 0 || py != 0 { contacts.append((1, px, py)) }
        }
        let masked = action & 255
        try require([0, 1, 2, 3, 5, 6].contains(masked), "invalid_touch")
        func point(_ c: (id: Int, x: Int, y: Int)) -> TouchPoint {
            TouchPoint(id: c.id, x: min(max(Double(c.x) / Double(width), 0), 1), y: min(max(Double(c.y) / Double(height), 0), 1))
        }
        let valid = contacts.filter { (0...9).contains($0.id) }
        func merge(_ update: [(id: Int, x: Int, y: Int)]) {
            for contact in update {
                if let index = touches.firstIndex(where: { $0.id == contact.id }) { touches[index] = point(contact) }
                else { touches.append(point(contact)) }
            }
        }
        switch masked {
        case 1, 3:
            // Move to the release position first, so the lift happens where the finger was.
            let moved = valid.filter { contact in touches.contains { $0.id == contact.id } }
            if !moved.isEmpty { merge(moved); onTouches?(touches) }
            touches.removeAll()
        case 6:
            let releasedIndex = (action >> 8) & 255
            let releasedID = contacts.indices.contains(releasedIndex) ? contacts[releasedIndex].id
                : touches.indices.contains(releasedIndex) ? touches[releasedIndex].id : nil
            merge(valid)
            if let releasedID {
                // Report the lift position first, then release that finger.
                onTouches?(touches)
                touches.removeAll { $0.id == releasedID }
            }
        default:
            var seen = Set<Int>()
            touches = valid.filter { seen.insert($0.id).inserted }.map(point)
        }
        onTouches?(touches)
    }

    private func releaseTouches() {
        guard !touches.isEmpty else { return }
        touches.removeAll(); onTouches?([])
    }

    /// Android key codes are the only mapping this transport supplies; unknown keys stay local.
    private static func control(forKey code: Int64) -> CarPlayControl? {
        switch code {
        case 3: .home
        case 4: .back
        case 19, 21: .knobPrevious
        case 20, 22: .knobNext
        case 23, 66: .select
        case 79, 85: .playPause
        case 87: .next
        case 88: .previous
        case 219, 231: .siri
        default: nil
        }
    }

    func close(reason: String) {
        guard active else { return }
        active = false
        log?(CWL("会话结束：{1}（已发送 {2} 帧）", [String(describing: reason), String(describing: framesSent)]))
        channels.values.forEach { $0.connection.cancel() }
        channels.removeAll()
        releaseTouches()
    }
}

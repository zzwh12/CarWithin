import Foundation

/// Transports one private RTP packet per KCP message. The encoder's sender queue
/// enqueues complete frames, and the session loop handles UDP input and KCP ticks.
final class NinebotKCPVideo {
    private static let mtu: Int32 = 1_400
    private static let maxPendingSegments = 256
    private static let throttleSegments = 64
    private static let responseTimeout: TimeInterval = 8

    private let socket: NinebotUDPSocket
    private let connection: UnsafeMutablePointer<ikcpcb>
    private let lock = NSLock()
    private var outputError: Error?
    private var waitingSince: TimeInterval?

    init(socket: NinebotUDPSocket, conversation: UInt32) throws {
        self.socket = socket
        guard let connection = ikcp_create(conversation, nil) else { throw Failure.setup }
        self.connection = connection
        guard ikcp_setmtu(connection, Self.mtu) == 0 else {
            ikcp_release(connection)
            throw Failure.setup
        }
        ikcp_wndsize(connection, 256, 256)
        ikcp_nodelay(connection, 1, 10, 2, 1)
        connection.pointee.user = Unmanaged.passUnretained(self).toOpaque()
        ikcp_setoutput(connection) { buffer, length, _, context in
            guard let buffer, let context, length > 0 else { return -1 }
            return Unmanaged<NinebotKCPVideo>.fromOpaque(context).takeUnretainedValue()
                .sendDatagram(Data(bytes: buffer, count: Int(length)))
        }
    }

    deinit { ikcp_release(connection) }

    var canAcceptFrame: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ikcp_waitsnd(connection) < Self.throttleSegments
    }

    func enqueueFrame(_ packets: [Data]) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let payloadLimit = Int(connection.pointee.mss)
        let segments = packets.reduce(0) { $0 + ($1.count + payloadLimit - 1) / payloadLimit }
        // Reject the entire frame before enqueuing any segments when the link is backed up.
        guard Int(ikcp_waitsnd(connection)) + segments <= Self.maxPendingSegments else { return false }
        for packet in packets {
            let result = packet.withUnsafeBytes { bytes in
                ikcp_send(connection, bytes.bindMemory(to: CChar.self).baseAddress, Int32(bytes.count))
            }
            guard result == packet.count else { throw Failure.enqueue }
        }
        return true
    }

    /// Returns true when the instrument acknowledges at least one queued segment.
    func poll(at uptime: TimeInterval) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let before = ikcp_waitsnd(connection)
        for _ in 0..<64 {
            guard let datagram = try socket.receive() else { break }
            guard datagram.count <= Self.mtu else { continue }
            _ = datagram.withUnsafeBytes { bytes in
                ikcp_input(connection, bytes.bindMemory(to: CChar.self).baseAddress, bytes.count)
            }
        }
        let pending = ikcp_waitsnd(connection)
        let acknowledged = pending < before
        if pending == 0 {
            waitingSince = nil
        } else {
            if acknowledged || waitingSince == nil { waitingSince = uptime }
            if let waitingSince, uptime - waitingSince >= Self.responseTimeout { throw Failure.noAcknowledgement }
        }

        let milliseconds = UInt32(truncatingIfNeeded: Int64(uptime * 1_000))
        ikcp_update(connection, milliseconds)
        if let outputError { throw outputError }
        return acknowledged
    }

    private func sendDatagram(_ data: Data) -> Int32 {
        do {
            try socket.send(data, retryOnBackpressure: false)
            return 0
        } catch let error as NinebotSocketError where error.isTransient {
            // KCP retransmits if the socket briefly cannot accept a datagram.
            return -1
        } catch {
            if outputError == nil { outputError = error }
            return -1
        }
    }

    private enum Failure: LocalizedError {
        case setup, enqueue, noAcknowledgement

        var errorDescription: String? {
            switch self {
            case .setup: CWL("无法创建七寸 KCP 视频连接")
            case .enqueue: CWL("七寸 KCP 视频分包入队失败")
            case .noAcknowledgement: CWL("七寸仪表 8 秒内未确认 KCP 视频数据，请检查仪表 Wi-Fi 和投屏状态")
            }
        }
    }
}

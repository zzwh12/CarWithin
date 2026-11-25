// Adapted from xmz28/ninebot_pro.
import Darwin
import Foundation

final class NinebotUDPSocket: @unchecked Sendable {
    let localPort: UInt16
    let remotePort: UInt16

    private let lock = NSLock()
    private var descriptor: Int32 = -1

    init(localIP: String, localPort: UInt16, remoteIP: String, remotePort: UInt16) throws {
        self.localPort = localPort
        self.remotePort = remotePort

        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw NinebotSocketError.operation(CWL("创建 UDP socket"), errno) }

        do {
            var sendBuffer: Int32 = 256 * 1_024
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sendBuffer, socklen_t(MemoryLayout.size(ofValue: sendBuffer)))
            var noSigPipe: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout.size(ofValue: noSigPipe)))

            var localAddress = try Self.address(ip: localIP, port: localPort)
            let bindResult = withUnsafePointer(to: &localAddress) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0 else { throw NinebotSocketError.operation(CWL("绑定 {1}:{2}", [String(describing: localIP), String(describing: localPort)]), errno) }

            var remoteAddress = try Self.address(ip: remoteIP, port: remotePort)
            let connectResult = withUnsafePointer(to: &remoteAddress) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connectResult == 0 else { throw NinebotSocketError.operation(CWL("连接 {1}:{2}", [String(describing: remoteIP), String(describing: remotePort)]), errno) }

            let currentFlags = fcntl(fd, F_GETFL, 0)
            if currentFlags >= 0 { _ = fcntl(fd, F_SETFL, currentFlags | O_NONBLOCK) }
            descriptor = fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    deinit { close() }

    /// 非阻塞发送。发送缓冲区满（EAGAIN/ENOBUFS）时短暂退避重试，
    /// 仍失败则抛出 `NinebotSocketError.isTransient == true` 的错误，由调用方决定丢帧还是终止。
    func send(_ data: Data, retryOnBackpressure: Bool = true) throws {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { throw NinebotSocketError.closed }
        var attempt = 0
        while true {
            let (sent, code) = data.withUnsafeBytes { bytes -> (Int, Int32) in
                guard let baseAddress = bytes.baseAddress else { return (0, 0) }
                let sent = Darwin.send(descriptor, baseAddress, bytes.count, 0)
                return (sent, sent < 0 ? errno : 0)
            }
            if sent >= 0 {
                guard sent == data.count else { throw NinebotSocketError.shortWrite(expected: data.count, actual: sent) }
                return
            }
            let retryable = code == EAGAIN || code == EWOULDBLOCK || code == ENOBUFS || code == EINTR
            guard retryOnBackpressure, retryable, attempt < 4 else { throw NinebotSocketError.operation(CWL("发送 UDP 数据"), code) }
            attempt += 1
            // 1 + 2 + 3 + 4 ms，最坏约 10 ms，给 Wi-Fi 驱动队列排空的时间
            usleep(useconds_t(1_000 * attempt))
        }
    }

    func receive() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { throw NinebotSocketError.closed }
        var bytes = [UInt8](repeating: 0, count: 2_048)
        let count = Darwin.recv(descriptor, &bytes, bytes.count, MSG_DONTWAIT)
        if count > 0 { return Data(bytes.prefix(count)) }
        if count == 0 { return nil }
        let code = errno
        if code == EAGAIN || code == EWOULDBLOCK || code == EINTR { return nil }
        // 已 connect 的 UDP socket 收到 ICMP 端口不可达后会返回一次 ECONNREFUSED，
        // 仪表刚开机或端口尚未监听时很常见，不应终止投屏
        if code == ECONNREFUSED { return nil }
        throw NinebotSocketError.operation(CWL("接收 UDP 数据"), code)
    }

    func close() {
        lock.lock()
        let fd = descriptor
        descriptor = -1
        lock.unlock()
        if fd >= 0 { Darwin.close(fd) }
    }

    private static func address(ip: String, port: UInt16) throws -> sockaddr_in {
        var value = sockaddr_in()
        value.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        value.sin_family = sa_family_t(AF_INET)
        value.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &value.sin_addr) == 1 else { throw NinebotSocketError.invalidAddress(ip) }
        return value
    }
}

enum NinebotSocketError: LocalizedError {
    case invalidAddress(String)
    case operation(String, Int32)
    case shortWrite(expected: Int, actual: Int)
    case closed

    /// 发送缓冲区满或对端端口暂不可达，丢弃当前数据即可，不需要结束会话
    var isTransient: Bool {
        guard case .operation(_, let code) = self else { return false }
        return code == EAGAIN || code == EWOULDBLOCK || code == ENOBUFS || code == EINTR || code == ECONNREFUSED
    }

    var errorDescription: String? {
        switch self {
        case .invalidAddress(let address):
            CWL("IPv4 地址无效：{1}", [String(describing: address)])
        case .operation(let operation, let code):
            CWL("{1}失败：{2} (errno {3})", [String(describing: operation), String(describing: String(cString: strerror(code))), String(describing: code)])
        case .shortWrite(let expected, let actual):
            CWL("UDP 数据发送不完整：应发送 {1} 字节，实际 {2} 字节", [String(describing: expected), String(describing: actual)])
        case .closed:
            CWL("UDP socket 已关闭")
        }
    }
}

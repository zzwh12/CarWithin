import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum TailingDiscovery {
    static let savedAddressKey = "zeehoLastDiscoveredAddress"

    static func candidates(localIP: String, netmask: String, previousIP: String?) -> [String] {
        guard let ip = number(localIP), let mask = number(netmask), mask > 0,
              mask != UInt32.max else { return [] }
        let hostMask = ~mask
        guard hostMask & (hostMask + 1) == 0 else { return [] }
        let network = ip & mask, broadcast = network | hostMask
        let scanMask = max(mask, 0xffff_ff00)
        let scanNetwork = ip & scanMask, scanBroadcast = scanNetwork | ~scanMask
        let first = hostMask == 1 ? network : network + 1
        let last = hostMask == 1 ? broadcast : broadcast - 1
        var addresses: [UInt32] = []
        var seen = Set<UInt32>()
        func add(_ candidate: UInt32) {
            guard candidate >= first, candidate <= last, candidate != ip,
                  seen.insert(candidate).inserted else { return }
            addresses.append(candidate)
        }
        if let previousIP, let previous = number(previousIP) { add(previous) }
        add(first)
        add(scanNetwork + 1)
        if scanBroadcast > scanNetwork { add(scanBroadcast - 1) }
        add(last)
        let scanFirst = hostMask == 1 ? scanNetwork : scanNetwork + 1
        let scanLast = hostMask == 1 ? scanBroadcast : scanBroadcast - 1
        if scanFirst <= scanLast {
            for candidate in scanFirst...scanLast { add(candidate) }
        }
        return addresses.map(text)
    }

    private static func number(_ address: String) -> UInt32? {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var result: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  let byte = UInt8(part) else { return nil }
            result = (result << 8) | UInt32(byte)
        }
        return result
    }

    private static func text(_ value: UInt32) -> String {
        "\(value >> 24).\((value >> 16) & 255).\((value >> 8) & 255).\(value & 255)"
    }

    #if canImport(Darwin)
    private static func netmask(localIP: String) -> String? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return nil }
        defer { freeifaddrs(first) }
        var current = first
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  let mask = entry.pointee.ifa_netmask,
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            guard text(ip) == localIP else { continue }
            return mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                text(UInt32(bigEndian: $0.pointee.sin_addr.s_addr))
            }
        }
        return nil
    }

    static func connect(localIP: String, port: UInt16,
                        track: @escaping (TailingSocket) throws -> TailingSocket,
                        check: @escaping () throws -> Void) throws -> (address: String, socket: TailingSocket) {
        guard let mask = netmask(localIP: localIP) else {
            throw TailingError.protocolFailure("无法读取当前 Wi-Fi 子网，请连接仪表 Wi-Fi，或关闭自动查找并填写仪表 IP")
        }
        let addresses = candidates(localIP: localIP, netmask: mask,
                                   previousIP: UserDefaults.standard.string(forKey: savedAddressKey))
        // Unicast TCP avoids relying on a multicast entitlement for discovery.
        for start in stride(from: 0, to: addresses.count, by: 16) {
            try check()
            let results = Connections()
            let group = DispatchGroup()
            for address in addresses[start..<min(start + 16, addresses.count)] {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { group.leave() }
                    var socket: TailingSocket?
                    do {
                        try check()
                        let next = try track(TailingSocket.create())
                        socket = next
                        try next.connect(localIP: localIP, remoteIP: address, port: port, timeout: 0.4)
                        try check()
                        results.add(address: address, socket: next)
                    } catch { socket?.close() }
                }
            }
            group.wait()
            let connected = results.take()
            do { try check() }
            catch { connected.forEach { $0.socket.close() }; throw error }
            for address in addresses[start..<min(start + 16, addresses.count)] {
                if let selected = connected.first(where: { $0.address == address }) {
                    connected.filter { $0.address != address }.forEach { $0.socket.close() }
                    return selected
                }
            }
        }
        throw TailingError.timeout("自动查找未发现仪表，请确认已连接仪表 Wi-Fi 并开启 MotoPlay 投屏，或关闭自动查找后填写仪表 IP")
    }

    private final class Connections: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [(address: String, socket: TailingSocket)] = []

        func add(address: String, socket: TailingSocket) {
            lock.lock(); defer { lock.unlock() }
            values.append((address, socket))
        }

        func take() -> [(address: String, socket: TailingSocket)] {
            lock.lock(); defer { lock.unlock() }
            let result = values
            values.removeAll()
            return result
        }
    }
    #endif
}

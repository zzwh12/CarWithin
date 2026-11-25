// Adapted from xmz28/ninebot_pro.
import Foundation

final class NinebotH264Packetizer {
    static let videoPort: UInt16 = 5012
    static let controlPort: UInt16 = 5013
    static let headerSize = 20
    static let chunkSize = 1_380

    private static let sequenceLock = NSLock()
    private static var nextSequence: UInt16 = 0

    private static func takeSequence() -> UInt16 {
        sequenceLock.lock()
        defer { sequenceLock.unlock() }
        let value = nextSequence
        nextSequence &+= 1
        return value
    }

    func packets(for annexB: Data, timestampMilliseconds: UInt32, isKeyframe: Bool, repeatKeyframe: Bool) -> [Data] {
        guard !annexB.isEmpty else { return [] }
        var result: [Data] = []
        let copies = isKeyframe && repeatKeyframe ? 2 : 1
        for _ in 0..<copies {
            var offset = 0
            while offset < annexB.count {
                let count = min(Self.chunkSize, annexB.count - offset)
                let first = offset == 0
                let last = offset + count == annexB.count
                var header = [UInt8](repeating: 0, count: Self.headerSize)
                header[0] = 0x90
                header[1] = 0x20 | (last ? 0x80 : 0)
                let sequence = Self.takeSequence()
                header.writeBE(sequence, at: 2)
                header.writeBE(timestampMilliseconds, at: 4)
                header[15] = 1
                header[17] = (isKeyframe ? 1 : 2) | (first ? 0x10 : 0) | (last ? 0x08 : 0)
                let timestampExtension = UInt16(timestampMilliseconds & 0x03ff) | 0x0400
                header.writeLE(timestampExtension, at: 18)

                var packet = Data(header)
                packet.append(annexB.subdata(in: offset..<(offset + count)))
                result.append(packet)
                offset += count
            }
        }
        return result
    }

    static func heartbeat(counter: UInt32) -> Data {
        var bytes = [UInt8](repeating: 0, count: 20)
        bytes[0] = 0x85
        bytes[1] = 0xcc
        bytes[3] = 4
        bytes.writeLE(counter, at: 12)
        bytes[16] = 2
        return Data(bytes)
    }

    static let bye = Data([0x80, 0xcb, 0x00, 0x00])

    static func sevenInchHeartbeatReply(_ data: Data) -> (counter: UInt32, conversation: UInt32)? {
        let bytes = [UInt8](data)
        guard bytes.count == 24, bytes.starts(with: [0x85, 0xcc, 0, 5]),
              bytes[4..<12].elementsEqual([0, 0, 0, 1, 0, 0, 0, 0]), bytes.readLE32(at: 16) == 2 else { return nil }
        return (bytes.readLE32(at: 12), bytes.readLE32(at: 20))
    }

    static func heartbeatReplyCounter(_ data: Data) -> UInt32? {
        let bytes = [UInt8](data)
        guard bytes.count == 20,
              bytes[0] == 0x85, bytes[1] == 0xcc, bytes[2] == 0, bytes[3] == 4,
              bytes[4] == 0, bytes[5] == 0, bytes[6] == 0, bytes[7] == 1,
              bytes[8] == 0, bytes[9] == 0, bytes[10] == 0, bytes[11] == 0,
              bytes[16] == 2, bytes[17] == 0, bytes[18] == 0, bytes[19] == 0 else {
            return nil
        }
        return bytes.readLE32(at: 12)
    }
}

final class NinebotJPEGPacketizer {
    static let headerSize = 20
    static let chunkSize = 1_400

    private let ssrc: UInt32
    private(set) var sequence: UInt16 = 0
    private var packetCount: UInt32 = 0
    private var octetCount: UInt32 = 0

    init(ssrc: UInt32 = UInt32.random(in: UInt32.min...UInt32.max)) {
        self.ssrc = ssrc
    }

    func packets(for jpeg: Data, timestamp: UInt32) throws -> [Data] {
        let bytes = [UInt8](jpeg)
        guard bytes.count >= 4,
              bytes[0] == 0xff, bytes[1] == 0xd8,
              bytes[bytes.count - 2] == 0xff, bytes[bytes.count - 1] == 0xd9 else {
            throw NinebotProtocolError.invalidJPEG
        }

        var result: [Data] = []
        var offset = 0
        while offset < jpeg.count {
            let count = min(Self.chunkSize, jpeg.count - offset)
            let last = offset + count == jpeg.count
            var header = [UInt8](repeating: 0, count: Self.headerSize)
            header[0] = 0x90
            header[1] = 0x20 | (last ? 0x80 : 0)
            header.writeBE(sequence, at: 2)
            sequence &+= 1
            header.writeBE(timestamp, at: 4)
            header.writeBE(ssrc, at: 8)
            header[15] = 1
            header[17] = 1

            var packet = Data(header)
            packet.append(jpeg.subdata(in: offset..<(offset + count)))
            result.append(packet)
            packetCount &+= 1
            octetCount &+= UInt32(count)
            offset += count
        }
        return result
    }

    static func heartbeat(counter: UInt32) -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[0] = 0x85
        bytes[1] = 0xcc
        bytes[3] = 3
        bytes[7] = 1
        bytes[8] = 0x6d
        bytes[9] = 0x70
        bytes[10] = 0x76
        bytes.writeLE(counter, at: 12)
        return Data(bytes)
    }

    func bye(timestamp: UInt32, unixMilliseconds: UInt64) -> Data {
        let reason = Array("jlibrtp says bye bye!".utf8)
        let byeLength = 44
        var bytes = [UInt8](repeating: 0, count: 28 + byeLength)
        bytes[0] = 0x80
        bytes[1] = 200
        bytes[3] = 6
        bytes.writeBE(ssrc, at: 4)
        bytes.writeBE(UInt32(truncatingIfNeeded: unixMilliseconds / 1_000 + 2_208_988_800), at: 8)
        let milliseconds = unixMilliseconds % 1_000
        let fraction = UInt32(Double(milliseconds) * 4_294_967_296.0 / 1_000.0)
        bytes.writeBE(fraction, at: 12)
        bytes.writeBE(timestamp, at: 16)
        bytes.writeBE(packetCount, at: 20)
        bytes.writeBE(octetCount, at: 24)
        bytes[28] = 0x81
        bytes[29] = 203
        bytes.writeBE(UInt16(byeLength / 4 - 1), at: 30)
        bytes.writeBE(ssrc, at: 32)
        bytes[36] = UInt8(reason.count)
        bytes.replaceSubrange(37..<(37 + reason.count), with: reason)
        return Data(bytes)
    }
}

enum H264AnnexB {
    static func convertFromAVCC(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return data }
        // VideoToolbox 输出始终是 AVCC。不能用"开头像起始码"来猜格式：
        // 长度 256–511 字节的 NAL，其 4 字节长度前缀是 00 00 01 xx，会被误判成 Annex-B
        // 而原样发出，仪表解出损坏的 P 帧，表现为重影、拖影和卡顿。

        var result = Data()
        result.reserveCapacity(bytes.count + 16)
        var index = 0
        while index < bytes.count {
            guard bytes.count - index >= 4 else { throw NinebotProtocolError.incompleteAVCCLength }
            let size = Int(bytes.readBE32(at: index))
            index += 4
            guard size > 0, size <= bytes.count - index else { throw NinebotProtocolError.unknownH264Framing }
            result.append(contentsOf: [0, 0, 0, 1])
            result.append(contentsOf: bytes[index..<(index + size)])
            index += size
        }
        return result
    }

    static func containsNAL(type: UInt8, in data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return false }
        for index in 0..<(bytes.count - 3) {
            let length = startCodeLength(in: bytes, at: index)
            if length > 0, index + length < bytes.count,
               bytes[index + length] & 0x1f == type { return true }
        }
        return false
    }

    private static func startCodeLength(in bytes: [UInt8], at index: Int) -> Int {
        guard index + 2 < bytes.count, bytes[index] == 0, bytes[index + 1] == 0 else { return 0 }
        if bytes[index + 2] == 1 { return 3 }
        if index + 3 < bytes.count, bytes[index + 2] == 0, bytes[index + 3] == 1 { return 4 }
        return 0
    }
}

enum NinebotProtocolError: LocalizedError {
    case incompleteAVCCLength
    case unknownH264Framing
    case invalidJPEG

    var errorDescription: String? {
        switch self {
        case .incompleteAVCCLength: CWL("H.264 长度前缀不完整")
        case .unknownH264Framing: CWL("未知 H.264 封装")
        case .invalidJPEG: CWL("JPEG 数据不完整")
        }
    }
}

private extension Array where Element == UInt8 {
    mutating func writeBE(_ value: UInt16, at index: Int) {
        self[index] = UInt8(truncatingIfNeeded: value >> 8)
        self[index + 1] = UInt8(truncatingIfNeeded: value)
    }

    mutating func writeBE(_ value: UInt32, at index: Int) {
        for offset in 0..<4 {
            self[index + offset] = UInt8(truncatingIfNeeded: value >> UInt32(24 - offset * 8))
        }
    }

    mutating func writeLE(_ value: UInt16, at index: Int) {
        self[index] = UInt8(truncatingIfNeeded: value)
        self[index + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    mutating func writeLE(_ value: UInt32, at index: Int) {
        for offset in 0..<4 {
            self[index + offset] = UInt8(truncatingIfNeeded: value >> UInt32(offset * 8))
        }
    }

    func readBE32(at index: Int) -> UInt32 {
        (UInt32(self[index]) << 24) |
        (UInt32(self[index + 1]) << 16) |
        (UInt32(self[index + 2]) << 8) |
        UInt32(self[index + 3])
    }

    func readLE32(at index: Int) -> UInt32 {
        UInt32(self[index]) |
        (UInt32(self[index + 1]) << 8) |
        (UInt32(self[index + 2]) << 16) |
        (UInt32(self[index + 3]) << 24)
    }
}

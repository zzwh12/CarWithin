// ANT framing and field layout adapted from https://github.com/lswlc33/maibms.
/*
MIT License

Copyright (c) 2026 lswlc33

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/
import Foundation

public struct ANTBMSReading: Equatable {
    public let voltage: Double
    /// Raw ANT signed current, in amperes. Use stateCode for charge/discharge labels.
    public let current: Double
    public let power: Int
    public let stateOfCharge: Int
    public let stateOfHealth: Int?
    public let stateCode: Int
    public let capacityAh: Double
    public let remainingAh: Double
    public let cells: [Double?]
    public let temperatures: [Double?]
    public let mosTemperature: Double?
    public let protectionBits: UInt64
    public let warningBits: UInt64

    /// maibms separates operating states (MOS on, standby, balancing, etc.)
    /// from actual warnings, including state fields above bit 32.
    public var alarmBits: UInt64 {
        let stateBits = Array(17...30) + [35, 36, 37, 39, 40, 41, 42, 45, 48, 50, 51, 52]
        let mask = stateBits.reduce(UInt64(0)) { $0 | UInt64(1) << $1 }
        return warningBits & ~mask
    }
    public var hasAlarm: Bool { protectionBits != 0 || alarmBits != 0 }
    public var maximumTemperature: Double? { temperatures.compactMap { $0 }.max() }
    public var cellDelta: Double? {
        let values = cells.compactMap { $0 }
        guard let low = values.min(), let high = values.max() else { return nil }
        return high - low
    }

    public static func decode(_ data: Data) -> ANTBMSReading? {
        let bytes = [UInt8](data)
        guard bytes.count >= 28 else { return nil }
        let temperatureCount = Int(bytes[2]), cellCount = Int(bytes[3])
        guard (1...64).contains(cellCount), temperatureCount <= 16 else { return nil }
        let core = 28 + 2 * cellCount + 2 * temperatureCount
        // These fields require at least the first 70 core bytes, as in maibms.
        guard bytes.count >= core + 70 else { return nil }
        func u16(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
        func i16(_ offset: Int) -> Int { Int(Int16(bitPattern: UInt16(u16(offset)))) }
        func u32(_ offset: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
        }
        func u64(_ offset: Int) -> UInt64 {
            (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[offset + $1]) << ($1 * 8) }
        }
        func temperature(_ offset: Int) -> Double? {
            let raw = i16(offset)
            guard raw != -40, (-50...200).contains(raw) else { return nil }
            return Double(raw)
        }
        let voltage = Double(u16(core + 4)) / 100
        let soc = u16(core + 8), soh = u16(core + 10)
        guard voltage > 0, voltage <= 650, soc <= 100 else { return nil }
        return ANTBMSReading(voltage: voltage, current: Double(i16(core + 6)) / 10,
            power: Int(Int32(bitPattern: u32(core + 28))), stateOfCharge: soc,
            stateOfHealth: soh <= 100 ? soh : nil, stateCode: Int(bytes[1]),
            capacityAh: Double(u32(core + 16)) / 1_000_000,
            remainingAh: Double(u32(core + 20)) / 1_000_000,
            cells: (0..<cellCount).map { index in
                let raw = u16(28 + index * 2)
                let value = Double(raw & 0x1fff) / 1000
                return raw != 0xffff && (0.5...6).contains(value) ? value : nil
            },
            temperatures: (0..<temperatureCount).map { temperature(28 + cellCount * 2 + $0 * 2) },
            mosTemperature: temperature(core), protectionBits: u64(4), warningBits: u64(12))
    }
}

public struct ANTBMSSample: Equatable {
    public let reading: ANTBMSReading
    public let uptime: TimeInterval

    public init(reading: ANTBMSReading, uptime: TimeInterval) {
        self.reading = reading; self.uptime = uptime
    }

    public func isFresh(at now: TimeInterval, maximumAge: TimeInterval = 5) -> Bool {
        now >= uptime && now - uptime <= maximumAge
    }
}

/// Streaming realtime-only ANT decoder. No control, parameter-write, auth, or
/// MOS switching commands are exposed. CRC covers address through payload.
public struct ANTBMSProtocol {
    public static let realtimeRequest = Data([0x7e, 0xa1, 0x01, 0, 0, 0xf5, 0x58, 0x62, 0xaa, 0x55])
    public static let maximumBufferedBytes = 4096
    private var bytes: [UInt8] = []
    public var bufferedByteCount: Int { bytes.count }

    public init() {}

    public static func crc16<C: Collection>(_ bytes: C) -> UInt16 where C.Element == UInt8 {
        bytes.reduce(UInt16(0xffff)) { result, byte in
            var crc = result ^ UInt16(byte)
            for _ in 0..<8 { crc = crc & 1 == 0 ? crc >> 1 : (crc >> 1) ^ 0xa001 }
            return crc
        }
    }

    public mutating func append(_ data: Data) -> [ANTBMSReading] {
        bytes.append(contentsOf: data.suffix(Self.maximumBufferedBytes))
        if bytes.count > Self.maximumBufferedBytes {
            bytes.removeFirst(bytes.count - Self.maximumBufferedBytes)
        }
        var readings: [ANTBMSReading] = []
        while bytes.count >= 6 {
            guard bytes[0] == 0x7e, bytes[1] == 0xa1 || bytes[1] == 0xc1,
                  bytes[2] == 0x11, bytes[3] == 0, bytes[4] == 0 else {
                bytes.removeFirst(); continue
            }
            let length = Int(bytes[5]), body = 8 + length
            guard bytes.count >= body else { break }
            let expected = Self.crc16(bytes[1..<(6 + length)])
            guard bytes[body - 2] == UInt8(truncatingIfNeeded: expected),
                  bytes[body - 1] == UInt8(expected >> 8) else {
                bytes.removeFirst(); continue
            }
            if let reading = ANTBMSReading.decode(Data(bytes[6..<(6 + length)])) {
                readings.append(reading)
            }
            // A combined response can put another segment before AA55. Its bytes
            // are skipped; only the CRC-checked realtime group is consumed here.
            bytes.removeFirst(body)
        }
        return readings
    }
}

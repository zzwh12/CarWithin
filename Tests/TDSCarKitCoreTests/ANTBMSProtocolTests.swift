import XCTest
@testable import TDSCarKitCore

// Recorded 20S ANT frame published by maibms; see its MIT notice.
final class ANTBMSProtocolTests: XCTestCase {
    private var recorded: Data {
        Data("""
        7E A1 11 00 00 A8 01 03 04 14 00 00 00 00 00 00 00 00 01 00 80 05 00 00 00 00 00 00 00 00 00 00 00 00
        AB 10 AF 10 AB 10 AB 10 AB 10 B0 10 AD 10 AF 10 AC 10 AB 10 AB 10 AB 10 AE 10 AB 10 AA 10 AB 10 AB 10 AB 10 AB 10
        AD 10 17 00 17 00 17 00 16 00 17 00 17 00
        58 21 01 00 64 00 64 00 01 01 00 00 40 3E BC 06 79 33 BC 06 A8 CE 46 00 08 00 00 00 FB EF 1D 02 00 00 00 00
        B0 10 06 00 AA 10 0F 00 06 00 AC 10 00 00 7C 00 78 00 A8 02 F1 FA EF 7D 42 00 61 1F 4B 00 9F 86 0B 00 03 8B 0F 00
        00 00 00 00 AD 13 00 00 00 00 58 29 01 00 1A 6A AA 55
        """.split(whereSeparator: { $0.isWhitespace }).map { UInt8($0, radix: 16)! })
    }

    private func response(_ payload: Data, address: UInt8 = 0xa1, function: UInt8 = 0x11, register: UInt8 = 0) -> Data {
        var bytes = Data([0x7e, address, function, register, 0, UInt8(payload.count)])
        bytes.append(payload)
        let crc = ANTBMSProtocol.crc16(bytes.dropFirst())
        bytes.append(contentsOf: [UInt8(truncatingIfNeeded: crc), UInt8(crc >> 8), 0xaa, 0x55])
        return bytes
    }

    func testQueryMatchesRecordedReadOnlyCommand() {
        XCTAssertEqual(ANTBMSProtocol.realtimeRequest, Data([0x7e, 0xa1, 1, 0, 0, 0xf5, 0x58, 0x62, 0xaa, 0x55]))
        XCTAssertEqual(ANTBMSProtocol.crc16(ANTBMSProtocol.realtimeRequest[1..<6]), 0x6258)
    }

    func testRecordedFrameMatchesUpstreamDeviceReadings() throws {
        var parser = ANTBMSProtocol()
        XCTAssertEqual(recorded.count, 178)
        let reading = try XCTUnwrap(parser.append(recorded).first)
        XCTAssertEqual(reading.voltage, 85.36, accuracy: 0.001)
        XCTAssertEqual(reading.current, 0.1, accuracy: 0.001)
        XCTAssertEqual(reading.power, 8)
        XCTAssertEqual(reading.stateOfCharge, 100)
        XCTAssertEqual(reading.stateOfHealth, 100)
        XCTAssertEqual(reading.capacityAh, 113, accuracy: 0.000001)
        XCTAssertEqual(reading.remainingAh, 112.997241, accuracy: 0.000001)
        XCTAssertEqual(reading.stateCode, 3)
        XCTAssertEqual(reading.cells.count, 20)
        XCTAssertEqual(try XCTUnwrap(reading.cellDelta), 0.006, accuracy: 0.000001)
        XCTAssertEqual(reading.temperatures, [23, 23, 23, 22])
        XCTAssertEqual(reading.mosTemperature, 23)
        XCTAssertEqual(reading.protectionBits, 0)
        XCTAssertEqual(reading.alarmBits, 1, "MOS/standby state bits must not become alarms")
    }

    func testEveryPossibleBLEFragmentBoundary() {
        for split in 0...recorded.count {
            var parser = ANTBMSProtocol()
            let readings = parser.append(recorded.prefix(split)) + parser.append(recorded.dropFirst(split))
            XCTAssertEqual(readings.count, 1, "split at \(split)")
        }
        var parser = ANTBMSProtocol()
        let readings = recorded.flatMap { parser.append(Data([$0])) }
        XCTAssertEqual(readings.count, 1)
    }

    func testCorruptCRCNoiseAndConcatenatedFramesResynchronize() {
        var damaged = recorded
        damaged[40] ^= 1
        var parser = ANTBMSProtocol()
        XCTAssertTrue(parser.append(damaged).isEmpty)
        let readings = parser.append(Data([0, 0x7e, 0xff, 0]) + recorded + recorded)
        XCTAssertEqual(readings.count, 2)
    }

    func testWrongFunctionAddressRegisterAndTruncatedLayoutAreRejected() {
        let payload = recorded.subdata(in: 6..<174)
        for frame in [response(payload, function: 0x12), response(payload, address: 0xb1), response(payload, register: 1)] {
            var parser = ANTBMSProtocol()
            XCTAssertTrue(parser.append(frame).isEmpty)
        }
        var parser = ANTBMSProtocol()
        XCTAssertEqual(parser.append(response(payload, address: 0xc1)).count, 1)
        var truncated = payload
        truncated[3] = 64
        XCTAssertNil(ANTBMSReading.decode(truncated))
        truncated = payload
        truncated[2] = 255
        XCTAssertNil(ANTBMSReading.decode(truncated))
        XCTAssertNil(ANTBMSReading.decode(payload.prefix(27)))
        XCTAssertNil(ANTBMSReading.decode(payload.prefix(100)))
    }

    func testSignedFieldsMissingSensorsAndCellFlags() throws {
        var payload = recorded.subdata(in: 6..<174)
        let core = 76
        payload[core + 6] = 0x85; payload[core + 7] = 0xff // -123 / 10 A
        payload.replaceSubrange((core + 28)..<(core + 32), with: [0xe6, 0xfb, 0xff, 0xff]) // -1050 W
        payload[68] = 0xd8; payload[69] = 0xff // missing probe (-40)
        payload[29] |= 0xe0 // high three cell flags
        payload[30] = 0xff; payload[31] = 0xff // absent cell
        let reading = try XCTUnwrap(ANTBMSReading.decode(payload))
        XCTAssertEqual(reading.current, -12.3, accuracy: 0.001)
        XCTAssertEqual(reading.power, -1050)
        XCTAssertNil(reading.temperatures[0])
        XCTAssertEqual(reading.maximumTemperature, 23)
        XCTAssertEqual(try XCTUnwrap(reading.cells[0]), 4.267, accuracy: 0.000001)
        XCTAssertNil(reading.cells[1])
    }

    func testInvalidSOCAndShortLayoutDoNotPublishReadings() {
        var payload = recorded.subdata(in: 6..<174)
        payload[84] = 101
        var parser = ANTBMSProtocol()
        XCTAssertTrue(parser.append(response(payload)).isEmpty)
        parser = ANTBMSProtocol()
        XCTAssertTrue(parser.append(recorded.prefix(150)).isEmpty)
    }

    func testOperatingStateBitsDoNotBecomeBatteryAlarms() throws {
        var payload = recorded.subdata(in: 6..<174)
        let states = [17, 23, 24, 26, 35, 50, 52].reduce(UInt64(0)) { $0 | UInt64(1) << $1 }
        for index in 0..<8 { payload[12 + index] = UInt8(truncatingIfNeeded: states >> (index * 8)) }
        let reading = try XCTUnwrap(ANTBMSReading.decode(payload))
        XCTAssertEqual(reading.alarmBits, 0)
        XCTAssertFalse(reading.hasAlarm)
        payload[4] = 1
        XCTAssertTrue(try XCTUnwrap(ANTBMSReading.decode(payload)).hasAlarm)
    }

    func testSampleFreshnessUsesMonotonicAgeAndRejectsClockReversal() throws {
        var parser = ANTBMSProtocol()
        let sample = ANTBMSSample(reading: try XCTUnwrap(parser.append(recorded).first), uptime: 100)
        XCTAssertTrue(sample.isFresh(at: 105))
        XCTAssertFalse(sample.isFresh(at: 105.001))
        XCTAssertFalse(sample.isFresh(at: 99))
    }

    func testNoiseBufferIsBounded() {
        var parser = ANTBMSProtocol()
        XCTAssertTrue(parser.append(Data(repeating: 0x7e, count: 50_000)).isEmpty)
        XCTAssertLessThanOrEqual(parser.bufferedByteCount, ANTBMSProtocol.maximumBufferedBytes)
        XCTAssertEqual(parser.append(recorded).count, 1)
    }
}

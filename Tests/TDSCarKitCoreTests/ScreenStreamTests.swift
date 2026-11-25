import XCTest
import CryptoKit
@testable import TDSCarKitCore

final class ScreenStreamTests: XCTestCase {
    private func header(_ length: Int, opcode: UInt8) -> Data {
        var result = Data(count: 128)
        for offset in 0..<4 { result[offset] = UInt8(truncatingIfNeeded: length >> (offset * 8)) }
        result[4] = opcode; return result
    }
    func testFragmentedEncryptedVideoAndConfiguration() throws {
        let secret = SymmetricKey(size: .bits256)
        let connectionID: UInt64 = 0xf123456789abcdef
        let key = PairVerify.derive(secret, salt: "DataStream-Salt\(connectionID)", info: "DataStream-Output-Encryption-Key")
        let receiver = ScreenStream(secret: secret, connectionID: connectionID)
        let config = Data([1, 0x64, 0, 0x28, 0xff, 0xe1, 0, 2, 0x67, 0x01, 1, 0, 2, 0x68, 0x02])
        let plain = Data([0, 0, 0, 3, 0x65, 0x88, 0x99])
        let head = header(plain.count + 16, opcode: 0)
        let box = try ChaChaPoly.seal(plain, using: key, nonce: .init(data: Data(count: 12)), authenticating: head)
        let emptyConfiguration = header(0, opcode: 1)
        let wire = emptyConfiguration + header(config.count, opcode: 1) + config + emptyConfiguration + head + box.ciphertext + box.tag
        var output: [Data] = []
        for offset in stride(from: 0, to: wire.count, by: 13) { output += try receiver.append(Data(wire.dropFirst(offset).prefix(13))) }
        XCTAssertEqual(output, [Data([0,0,0,1,0x67,1,0,0,0,1,0x68,2]), Data([0,0,0,1,0x65,0x88,0x99])])
        var corrupt = head + box.ciphertext + box.tag; corrupt[128] ^= 1
        XCTAssertThrowsError(try receiver.append(corrupt))
        XCTAssertThrowsError(try receiver.append(Data()))
    }
    func testRejectsOversizedFrameAndTruncatedAVC() throws {
        let receiver = ScreenStream(secret: .init(size: .bits256), connectionID: 1)
        XCTAssertThrowsError(try receiver.append(header(9 * 1024 * 1024, opcode: 0)))
        XCTAssertThrowsError(try ScreenStream.configuration(Data([1,0,0,0,0xff,0xe1,0,10,0x67])))
    }
    // Minimal parameter sets: 2-byte HEVC NAL headers (VPS 32, SPS 33, PPS 34).
    private let vps = Data([0x40, 0x01, 0x0c])
    private let sps = Data([0x42, 0x01, 0x01, 0x01, 0x60, 0x00, 0x00, 0x00, 0xb0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x5d, 0xa0])
    private let pps = Data([0x44, 0x01, 0xc1])
    private func hvcC() -> Data {
        var record = Data([1, 0x01, 0x60, 0, 0, 0, 0xb0, 0, 0, 0, 0, 0, 0x5d, 0xf0, 0, 0xfc, 0xfd, 0xf8, 0xf8, 0, 0, 0x0f, 3])
        for (type, unit) in [(UInt8(32), vps), (33, sps), (34, pps)] {
            record += [0x80 | type, 0, 1, 0, UInt8(unit.count)] + unit
        }
        return record
    }
    func testHEVCConfigurationBoxAndBareRecordBecomeAnnexBParameterSets() throws {
        let expected = Data([0, 0, 0, 1]) + vps + Data([0, 0, 0, 1]) + sps + Data([0, 0, 0, 1]) + pps
        let boxed = Data([0, 0, 0, UInt8(hvcC().count + 8)]) + Data("hvcC".utf8) + hvcC()
        for body in [boxed, hvcC()] {
            let (codec, units) = try ScreenStream.configuration(body)
            XCTAssertEqual(codec, .h265)
            XCTAssertEqual(units, expected)
        }
        var missingPPS = hvcC(); missingPPS[22] = 2
        XCTAssertThrowsError(try ScreenStream.configuration(Data(missingPPS.dropLast(pps.count + 5))))
    }
    func testScreenStreamReportsCodecFromConfiguration() throws {
        let receiver = ScreenStream(secret: .init(size: .bits256), connectionID: 2)
        XCTAssertEqual(receiver.codec, .h264)
        _ = try receiver.append(header(hvcC().count, opcode: 1) + hvcC())
        XCTAssertEqual(receiver.codec, .h265)
    }
    func testParameterSetsBuildMatchingHEVCRecordAndCodecString() throws {
        var sets = VideoParameterSets(codec: .h265)
        XCTAssertTrue(sets.absorb(vps)); XCTAssertTrue(sets.absorb(sps)); XCTAssertTrue(sets.absorb(pps))
        XCTAssertFalse(sets.absorb(pps))
        XCTAssertTrue(sets.isComplete)
        XCTAssertEqual(try sets.decoderConfigurationRecord(), hvcC())
        XCTAssertEqual(try sets.codecString(), "hvc1.1.6.L93.B0")
        XCTAssertTrue(VideoCodec.h265.isRandomAccess(Data([0x26, 0x01])))   // IDR_W_RADL (19)
        XCTAssertFalse(VideoCodec.h265.isRandomAccess(Data([0x02, 0x01])))  // TRAIL_R (1)
        XCTAssertTrue(VideoCodec.h264.isRandomAccess(Data([0x65])))
    }
    func testParameterSetsBuildAVCRecord() throws {
        var sets = VideoParameterSets(codec: .h264)
        sets.absorb(Data([0x67, 0x64, 0x00, 0x28, 0xac])); sets.absorb(Data([0x68, 0xee]))
        XCTAssertEqual(try sets.codecString(), "avc1.640028")
        XCTAssertEqual(try sets.decoderConfigurationRecord(),
                       Data([1, 0x64, 0, 0x28, 0xff, 0xe1, 0, 5, 0x67, 0x64, 0, 0x28, 0xac, 1, 0, 2, 0x68, 0xee]))
    }
    func testEventParserAcceptsResponsesWithoutTreatingThemAsRequests() throws {
        var parser = RTSPParser(allowResponses: true)
        let values = try parser.append(Data("RTSP/1.0 200 OK\r\nContent-Length: 0\r\n\r\nPOST /command RTSP/1.0\r\nContent-Length: 0\r\n\r\n".utf8))
        XCTAssertEqual(values.map(\.method), ["RTSP/1.0", "POST"])
    }
}

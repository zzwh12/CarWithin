// SPDX-License-Identifier: GPL-3.0-or-later
// AirPlay screen framing adapted from PlayPort ScreenStream.kt.
import Foundation
import CryptoKit

public final class ScreenStream {
    private let key: SymmetricKey
    private var buffer = Data()
    private var counter: UInt64 = 0
    private var failed = false
    /// Codec announced by the most recent configuration record. H.264 until one arrives.
    public private(set) var codec: VideoCodec = .h264
    public init(secret: SymmetricKey, connectionID: UInt64) {
        key = PairVerify.derive(secret, salt: "DataStream-Salt\(connectionID)", info: "DataStream-Output-Encryption-Key")
    }
    /// Each returned access unit is Annex-B, including parameter-set configuration units.
    public func append(_ bytes: Data) throws -> [Data] {
        guard !failed else { throw ProtocolError.malformed(CWL("视频流已关闭")) }
        do {
            guard buffer.count + bytes.count <= 8 * 1024 * 1024 + 128 + 65536 else { throw ProtocolError.limitExceeded(CWL("视频缓冲区")) }
            buffer.append(bytes); var result: [Data] = []
            while buffer.count >= 128 {
                let length = (0..<4).reduce(0) { $0 | (Int(buffer.byte($1)) << ($1 * 8)) }
                guard length <= 8 * 1024 * 1024 else { throw ProtocolError.limitExceeded(CWL("视频帧")) }
                guard buffer.count >= 128 + length else { break }
                let header = Data(buffer.prefix(128)), body = Data(buffer.dropFirst(128).prefix(length))
                buffer = Data(buffer.dropFirst(128 + length))
                switch header.byte(4) {
                case 0:
                    guard body.count >= 16, counter < UInt64.max else { throw ProtocolError.malformed(CWL("加密视频帧")) }
                    var nonce = Data(count: 4)
                    for shift in stride(from: 0, through: 56, by: 8) { nonce.append(UInt8(truncatingIfNeeded: counter >> shift)) }
                    let box = try ChaChaPoly.SealedBox(nonce: .init(data: nonce), ciphertext: body.dropLast(16), tag: body.suffix(16))
                    let plain = try ChaChaPoly.open(box, using: key, authenticating: header)
                    counter += 1; result.append(try Self.annexB(plain))
                case 1:
                    // iOS can send a header-only configuration record before the next
                    // real codec configuration. Keep the previous codec and stream open.
                    guard !body.isEmpty else { continue }
                    let parsed: (VideoCodec, Data)
                    do { parsed = try Self.configuration(body) }
                    catch {
                        // Parameter sets are public stream metadata; the prefix identifies the record layout.
                        let prefix = body.prefix(24).map { String(format: "%02x", $0) }.joined()
                        throw ProtocolError.malformed(CWL("{1}（配置记录 {2} 字节：{3}）", [String(describing: error.localizedDescription), String(describing: body.count), String(describing: prefix)]))
                    }
                    self.codec = parsed.0; result.append(parsed.1)
                default: break // Timing/extension records have no picture data.
                }
            }
            return result
        } catch { failed = true; buffer = Data(); throw error }
    }
    private static func annexB(_ data: Data) throws -> Data {
        if data.starts(with: [0, 0, 0, 1]) { _ = try AnnexB.units(in: data); return data }
        var offset = 0, output = Data()
        while offset < data.count {
            guard offset + 4 <= data.count else { throw ProtocolError.malformed(CWL("视频 NAL 长度")) }
            let length = Int(data.be32(offset)); offset += 4
            guard length > 0, length <= data.count - offset else { throw ProtocolError.malformed(CWL("视频 NAL 内容")) }
            output.append(contentsOf: [0, 0, 0, 1]); output.append(data.dropFirst(offset).prefix(length)); offset += length
        }
        return output
    }
    /// Converts an avcC or hvcC record, optionally inside its MP4 box, to Annex-B parameter sets.
    static func configuration(_ body: Data) throws -> (VideoCodec, Data) {
        if let marker = body.range(of: Data("hvcC".utf8)) {
            return (.h265, try hevcConfiguration(Data(body[marker.upperBound...])))
        }
        if let marker = body.range(of: Data("avcC".utf8)) {
            return (.h264, try avcConfiguration(Data(body[marker.upperBound...])))
        }
        // A bare AVC record carries an SPS (type 7) right after its 8-byte header.
        let looksAVC = body.count >= 9 && body.byte(5) & 0x1f >= 1 && body.byte(8) & 0x1f == 7
        return looksAVC ? (.h264, try avcConfiguration(body)) : (.h265, try hevcConfiguration(body))
    }
    private static func avcConfiguration(_ data: Data) throws -> Data {
        guard data.count >= 7, data.byte(0) == 1, data.byte(4) & 3 == 3 else { throw ProtocolError.malformed(CWL("不支持的 AVC 配置")) }
        var offset = 6, output = Data()
        func readUnits(_ count: Int) throws {
            guard count > 0 else { throw ProtocolError.malformed(CWL("缺少 H.264 参数集")) }
            for _ in 0..<count {
                guard offset + 2 <= data.count else { throw ProtocolError.malformed(CWL("AVC 参数长度")) }
                let length = Int(data.be16(offset)); offset += 2
                guard length > 0, length <= data.count - offset else { throw ProtocolError.malformed(CWL("AVC 参数内容")) }
                output.append(contentsOf: [0, 0, 0, 1]); output.append(data.dropFirst(offset).prefix(length)); offset += length
            }
        }
        try readUnits(Int(data.byte(5) & 31))
        guard offset < data.count else { throw ProtocolError.malformed(CWL("缺少 AVC PPS 数量")) }
        let count = Int(data.byte(offset)); offset += 1; try readUnits(count)
        return output
    }
    private static func hevcConfiguration(_ data: Data) throws -> Data {
        guard data.count >= 23, data.byte(0) == 1, data.byte(21) & 3 == 3 else {
            throw ProtocolError.malformed(CWL("不支持的 HEVC 配置"))
        }
        var offset = 23, output = Data(), types = Set<UInt8>()
        for _ in 0..<Int(data.byte(22)) {
            guard offset + 3 <= data.count else { throw ProtocolError.malformed(CWL("HEVC 参数数组")) }
            let type = data.byte(offset) & 0x3f
            let count = Int(data.be16(offset + 1)); offset += 3
            for _ in 0..<count {
                guard offset + 2 <= data.count else { throw ProtocolError.malformed(CWL("HEVC 参数长度")) }
                let length = Int(data.be16(offset)); offset += 2
                guard length > 0, length <= data.count - offset else { throw ProtocolError.malformed(CWL("HEVC 参数内容")) }
                output.append(contentsOf: [0, 0, 0, 1]); output.append(data.dropFirst(offset).prefix(length)); offset += length
                types.insert(type)
            }
        }
        guard types.isSuperset(of: [32, 33, 34]) else { throw ProtocolError.malformed(CWL("缺少 HEVC VPS/SPS/PPS")) }
        return output
    }
}

import Foundation

/// The two codecs CarPlay can send on the main screen stream.
public enum VideoCodec: String, CaseIterable, Sendable {
    case h264
    case h265

    public var displayName: String { self == .h264 ? "H.264" : "H.265" }

    /// NAL unit type of a raw NAL unit (without start code).
    public func nalType(_ unit: Data) -> UInt8? {
        guard let first = unit.first else { return nil }
        return self == .h264 ? first & 0x1f : (first >> 1) & 0x3f
    }

    /// True for IDR (H.264) or IRAP (H.265) pictures, from which a decoder can start.
    public func isRandomAccess(_ unit: Data) -> Bool {
        guard let type = nalType(unit) else { return false }
        return self == .h264 ? type == 5 : (16...21).contains(type)
    }

    /// Parameter-set role of a NAL unit, if any.
    public func parameterSet(_ unit: Data) -> ParameterSet? {
        guard let type = nalType(unit) else { return nil }
        switch (self, type) {
        case (.h264, 7), (.h265, 33): return .sps
        case (.h264, 8), (.h265, 34): return .pps
        case (.h265, 32): return .vps
        default: return nil
        }
    }

    public enum ParameterSet { case vps, sps, pps }
}

/// Parameter sets of one coded video sequence, enough to build a decoder configuration.
public struct VideoParameterSets: Equatable, Sendable {
    public var codec: VideoCodec
    public var vps: Data?
    public var sps: Data?
    public var pps: Data?

    public init(codec: VideoCodec, vps: Data? = nil, sps: Data? = nil, pps: Data? = nil) {
        self.codec = codec; self.vps = vps; self.sps = sps; self.pps = pps
    }

    public var isComplete: Bool {
        sps != nil && pps != nil && (codec == .h264 || vps != nil)
    }

    /// Ordered parameter sets as used by CoreMedia and MP4 sample entries.
    public var ordered: [Data] {
        (codec == .h265 ? [vps, sps, pps] : [sps, pps]).compactMap { $0 }
    }

    /// Records a parameter-set NAL. Returns true when the stored value changed.
    @discardableResult
    public mutating func absorb(_ unit: Data) -> Bool {
        switch codec.parameterSet(unit) {
        case .vps?: if vps != unit { vps = unit; return true }
        case .sps?: if sps != unit { sps = unit; return true }
        case .pps?: if pps != unit { pps = unit; return true }
        case nil: break
        }
        return false
    }

    /// RFC 6381 codec string for MSE / WebCodecs.
    public func codecString() throws -> String {
        guard let sps else { throw ProtocolError.malformed(CWL("缺少 SPS")) }
        switch codec {
        case .h264:
            guard sps.count >= 4 else { throw ProtocolError.malformed(CWL("H.264 SPS 过短")) }
            return String(format: "avc1.%02X%02X%02X", sps.byte(1), sps.byte(2), sps.byte(3))
        case .h265:
            let p = try HEVCProfile(sps: sps)
            let space = ["", "A", "B", "C"][Int(p.profileSpace)]
            var reversed: UInt32 = 0
            for bit in 0..<32 where p.compatibility & (1 << UInt32(bit)) != 0 { reversed |= 1 << UInt32(31 - bit) }
            var constraints = Array(p.constraints)
            while let last = constraints.last, last == 0 { constraints.removeLast() }
            var value = "hvc1.\(space)\(p.profileIDC).\(String(reversed, radix: 16, uppercase: true)).\(p.tier ? "H" : "L")\(p.level)"
            for byte in constraints { value += String(format: ".%02X", byte) }
            return value
        }
    }

    /// Short human-readable description for logs (H.265: picture size, chroma format, bit depth).
    public var summary: String {
        guard codec == .h265, let sps, let p = try? HEVCProfile(sps: sps) else { return codec.displayName }
        let chroma = ["4:0:0", "4:2:0", "4:2:2", "4:4:4"][Int(p.chromaFormat & 3)]
        let size = p.width.flatMap { w in p.height.map { "\(w)×\($0) " } } ?? ""
        return "H.265 \(size)profile \(p.profileIDC) \(chroma) \(p.bitDepthLuma)-bit"
    }

    /// avcC (H.264) or hvcC (H.265) decoder configuration record with 4-byte NAL lengths.
    public func decoderConfigurationRecord() throws -> Data {
        guard isComplete, let sps, let pps else { throw ProtocolError.malformed(CWL("参数集不完整")) }
        for unit in ordered where unit.count > 0xffff { throw ProtocolError.malformed(CWL("参数集过大")) }
        var record = Data()
        switch codec {
        case .h264:
            guard sps.count >= 4 else { throw ProtocolError.malformed(CWL("H.264 SPS 过短")) }
            record.append(contentsOf: [1, sps.byte(1), sps.byte(2), sps.byte(3), 0xff, 0xe1])
            record.putBE16(UInt16(sps.count)); record.append(sps)
            record.append(1); record.putBE16(UInt16(pps.count)); record.append(pps)
        case .h265:
            guard let vps else { throw ProtocolError.malformed(CWL("缺少 VPS")) }
            let p = try HEVCProfile(sps: sps)
            record.append(1)
            record.append(p.profileSpace << 6 | (p.tier ? 0x20 : 0) | (p.profileIDC & 0x1f))
            record.putBE32(p.compatibility)
            record.append(p.constraints)
            record.append(p.level)
            // min_spatial_segmentation=0, parallelismType=0, then chroma format and bit depths from the SPS.
            record.append(contentsOf: [0xf0, 0x00, 0xfc, 0xfc | (p.chromaFormat & 3),
                                       0xf8 | ((p.bitDepthLuma &- 8) & 7), 0xf8 | ((p.bitDepthChroma &- 8) & 7), 0x00, 0x00])
            // constantFrameRate=0, numTemporalLayers, temporalIdNested, lengthSizeMinusOne=3.
            record.append((p.temporalLayers & 7) << 3 | (p.temporalIDNested ? 0x04 : 0) | 0x03)
            record.append(3)
            for (type, unit) in [(UInt8(32), vps), (33, sps), (34, pps)] {
                record.append(0x80 | type)
                record.putBE16(1)
                record.putBE16(UInt16(unit.count)); record.append(unit)
            }
        }
        return record
    }
}

/// general_profile_tier_level fields from an H.265 SPS.
struct HEVCProfile {
    let profileSpace: UInt8
    let tier: Bool
    let profileIDC: UInt8
    let compatibility: UInt32
    let constraints: Data
    let level: UInt8
    let temporalLayers: UInt8
    let temporalIDNested: Bool
    /// From the SPS body. Defaults (4:2:0, 8-bit) are kept only if the SPS is truncated.
    private(set) var chromaFormat: UInt8 = 1
    private(set) var bitDepthLuma: UInt8 = 8
    private(set) var bitDepthChroma: UInt8 = 8
    private(set) var width: Int?
    private(set) var height: Int?

    init(sps: Data) throws {
        // Strip emulation-prevention bytes (00 00 03) before reading bit fields.
        var rbsp = [UInt8](); rbsp.reserveCapacity(sps.count)
        var zeros = 0
        for byte in sps {
            if zeros >= 2, byte == 3 { zeros = 0; continue }
            rbsp.append(byte); zeros = byte == 0 ? zeros + 1 : 0
        }
        // 2-byte NAL header, 1 byte vps_id/max_sub_layers/temporal_id_nesting, then 12-byte PTL.
        guard rbsp.count >= 15 else { throw ProtocolError.malformed(CWL("H.265 SPS 过短")) }
        let maxSubLayersMinus1 = Int((rbsp[2] >> 1) & 7)
        temporalLayers = UInt8(maxSubLayersMinus1 + 1)
        temporalIDNested = rbsp[2] & 1 != 0
        profileSpace = rbsp[3] >> 6
        tier = rbsp[3] & 0x20 != 0
        profileIDC = rbsp[3] & 0x1f
        compatibility = (4...7).reduce(UInt32(0)) { ($0 << 8) | UInt32(rbsp[$1]) }
        constraints = Data(rbsp[8...13])
        level = rbsp[14]
        var bits = BitReader(rbsp, byteOffset: 15)
        guard bits.skipSubLayers(maxSubLayersMinus1),
              bits.ue() != nil, let chroma = bits.ue(), chroma <= 3 else { return }
        if chroma == 3, bits.bit() == nil { return }
        guard let w = bits.ue(), let h = bits.ue(), let window = bits.bit() else { return }
        if window == 1 { for _ in 0..<4 where bits.ue() == nil { return } }
        guard let luma = bits.ue(), let chromaDepth = bits.ue(), luma <= 8, chromaDepth <= 8 else { return }
        chromaFormat = UInt8(chroma); width = w; height = h
        bitDepthLuma = UInt8(luma + 8); bitDepthChroma = UInt8(chromaDepth + 8)
    }
}

/// MSB-first bit reader with Exp-Golomb support, for SPS fields after the fixed header.
struct BitReader {
    private let bytes: [UInt8]
    private var position: Int
    init(_ bytes: [UInt8], byteOffset: Int) { self.bytes = bytes; position = byteOffset * 8 }
    mutating func bit() -> Int? {
        guard position < bytes.count * 8 else { return nil }
        defer { position += 1 }
        return Int(bytes[position >> 3] >> (7 - UInt8(position & 7)) & 1)
    }
    mutating func bits(_ count: Int) -> Int? {
        var value = 0
        for _ in 0..<count { guard let b = bit() else { return nil }; value = value << 1 | b }
        return value
    }
    mutating func ue() -> Int? {
        var leadingZeros = 0
        while true {
            guard let b = bit() else { return nil }
            if b == 1 { break }
            leadingZeros += 1
            guard leadingZeros < 31 else { return nil }
        }
        guard let rest = bits(leadingZeros) else { return nil }
        return (1 << leadingZeros) - 1 + rest
    }
    /// Skips the sub-layer part of profile_tier_level (H.265 7.3.3).
    mutating func skipSubLayers(_ maxSubLayersMinus1: Int) -> Bool {
        guard maxSubLayersMinus1 > 0 else { return true }
        var present: [(profile: Bool, level: Bool)] = []
        for _ in 0..<maxSubLayersMinus1 {
            guard let p = bit(), let l = bit() else { return false }
            present.append((p == 1, l == 1))
        }
        for _ in maxSubLayersMinus1..<8 { guard bits(2) != nil else { return false } }
        for layer in present {
            if layer.profile { guard bits(88) != nil else { return false } }
            if layer.level { guard bits(8) != nil else { return false } }
        }
        return true
    }
}

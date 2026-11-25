import Foundation

/// Minimal single-track fragmented MP4 writer for live H.264 / H.265 access units.
enum FragmentedMP4 {
    struct Format {
        let codecString: String
        let initializationSegment: Data
        let sampleDuration: UInt32
        let timescale: UInt32
    }

    static func format(parameters: VideoParameterSets, width: Int, height: Int, fps: Int) throws -> Format {
        guard parameters.isComplete,
              (1...65_535).contains(width), (1...65_535).contains(height),
              (30...60).contains(fps), fps.isMultiple(of: 5) else {
            throw MP4Error.invalidFormat
        }
        // Each CarPlay rate from 30 to 60 FPS in steps of five divides this exactly.
        let timescale: UInt32 = 138_600
        let duration = timescale / UInt32(fps)
        let record = try parameters.decoderConfigurationRecord()
        let entry: (String, String) = parameters.codec == .h264 ? ("avc1", "avcC") : ("hvc1", "hvcC")
        return Format(codecString: try parameters.codecString(),
                      initializationSegment: initialization(sampleEntry: entry.0, configBox: entry.1, record: record,
                                                            width: width, height: height,
                                                            timescale: timescale, defaultDuration: duration),
                      sampleDuration: duration, timescale: timescale)
    }

    static func fragment(sequence: UInt32, decodeTime: UInt64, duration: UInt32,
                         accessUnit: Data, keyframe: Bool) -> Data {
        let flags: UInt32 = keyframe ? 0x02000000 : 0x01010000
        func makeMoof(dataOffset: UInt32) -> Data {
            let mfhd = fullBox("mfhd", body: be32(sequence))
            let tfhd = fullBox("tfhd", flags: 0x020000, body: be32(1))
            let tfdt = fullBox("tfdt", version: 1, body: be64(decodeTime))
            var trunBody = be32(1)
            trunBody.append(be32(dataOffset))
            trunBody.append(be32(duration))
            trunBody.append(be32(UInt32(accessUnit.count)))
            trunBody.append(be32(flags))
            let trun = fullBox("trun", flags: 0x000701, body: trunBody)
            return box("moof", mfhd + box("traf", tfhd + tfdt + trun))
        }
        let placeholder = makeMoof(dataOffset: 0)
        let moof = makeMoof(dataOffset: UInt32(placeholder.count + 8))
        return moof + box("mdat", accessUnit)
    }

    private static func initialization(sampleEntry: String, configBox: String, record: Data,
                                       width: Int, height: Int,
                                       timescale: UInt32, defaultDuration: UInt32) -> Data {
        let brands = sampleEntry == "avc1" ? "isomiso6avc1mp41" : "isomiso6hvc1mp41"
        let ftyp = box("ftyp", Data("isom".utf8) + be32(0x200) + Data(brands.utf8))

        var mvhd = be32(0) + be32(0) + be32(timescale) + be32(0)
        mvhd.append(be32(0x00010000)); mvhd.append(be16(0x0100)); mvhd.append(Data(count: 10))
        mvhd.append(matrix()); mvhd.append(Data(count: 24)); mvhd.append(be32(2))

        var tkhd = be32(0) + be32(0) + be32(1) + be32(0) + be32(0) + Data(count: 8)
        tkhd.append(be16(0)); tkhd.append(be16(0)); tkhd.append(be16(0)); tkhd.append(be16(0))
        tkhd.append(matrix()); tkhd.append(be32(UInt32(width) << 16)); tkhd.append(be32(UInt32(height) << 16))

        var mdhd = be32(0) + be32(0) + be32(timescale) + be32(0)
        mdhd.append(be16(0x55c4)); mdhd.append(be16(0))
        let hdlr = be32(0) + Data("vide".utf8) + Data(count: 12) + Data("CarWithin\0".utf8)
        let vmhd = be16(0) + be16(0) + be16(0) + be16(0)
        let url = fullBox("url ", flags: 1, body: Data())
        let dref = fullBox("dref", body: be32(1) + url)
        let dinf = box("dinf", dref)

        var visual = Data(count: 6); visual.append(be16(1)); visual.append(Data(count: 16))
        visual.append(be16(UInt16(width))); visual.append(be16(UInt16(height)))
        visual.append(be32(0x00480000)); visual.append(be32(0x00480000)); visual.append(be32(0)); visual.append(be16(1))
        visual.append(Data(count: 32)); visual.append(be16(0x0018)); visual.append(be16(0xffff))
        visual.append(box(configBox, record))
        let stsd = fullBox("stsd", body: be32(1) + box(sampleEntry, visual))
        let emptyTable = be32(0)
        let stbl = box("stbl", stsd + fullBox("stts", body: emptyTable) + fullBox("stsc", body: emptyTable)
                       + fullBox("stsz", body: be32(0) + be32(0)) + fullBox("stco", body: emptyTable))
        let minf = box("minf", fullBox("vmhd", flags: 1, body: vmhd) + dinf + stbl)
        let mdia = box("mdia", fullBox("mdhd", body: mdhd) + fullBox("hdlr", body: hdlr) + minf)
        let trak = box("trak", fullBox("tkhd", flags: 7, body: tkhd) + mdia)
        let trex = fullBox("trex", body: be32(1) + be32(1) + be32(defaultDuration) + be32(0) + be32(0))
        let moov = box("moov", fullBox("mvhd", body: mvhd) + trak + box("mvex", trex))
        return ftyp + moov
    }

    private static func matrix() -> Data {
        be32(0x00010000) + be32(0) + be32(0) + be32(0) + be32(0x00010000) + be32(0)
            + be32(0) + be32(0) + be32(0x40000000)
    }

    private static func fullBox(_ type: String, version: UInt8 = 0, flags: UInt32 = 0, body: Data) -> Data {
        box(type, Data([version, UInt8(truncatingIfNeeded: flags >> 16),
                        UInt8(truncatingIfNeeded: flags >> 8), UInt8(truncatingIfNeeded: flags)]) + body)
    }

    private static func box(_ type: String, _ body: Data) -> Data {
        precondition(type.utf8.count == 4)
        return be32(UInt32(body.count + 8)) + Data(type.utf8) + body
    }

    private static func be16(_ value: UInt16) -> Data {
        Data([UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }

    private static func be32(_ value: UInt32) -> Data {
        Data([24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) })
    }

    private static func be64(_ value: UInt64) -> Data {
        Data(stride(from: 56, through: 0, by: -8).map { UInt8(truncatingIfNeeded: value >> $0) })
    }

    private enum MP4Error: LocalizedError {
        case invalidFormat
        var errorDescription: String? { CWL("无法生成浏览器所需的 MP4 视频配置") }
    }
}

/// Rolling, video-only HLS for AVPlayer and AirPlay video receivers. Access stays scoped
/// to the current session URL, and the server owns all mutations on its serial queue.
final class CarPlayHLS {
    private static let targetDuration = 3
    enum Event { case none, ready, keyframeNeeded }
    private struct Segment {
        let number: UInt64
        let duration: Double
        let data: Data
    }

    let id: UUID
    private let baseURL: String
    private var initialization: Data?
    private var codecString: String?
    private var segments: [Segment] = []
    private var pending = Data()
    private var pendingFrames = 0
    private var pendingDuration: UInt64 = 0
    private var sequence: UInt32 = 1
    private var segmentNumber: UInt64 = 0
    private var decodeTime: UInt64 = 0
    private var requestedAt: UInt64 = 0
    private var announced = false
    private var previousArrivalUs: UInt64?
    private var formatGeneration = 0

    init(id: UUID, origin: String) {
        self.id = id
        baseURL = "\(origin)/airplay/\(id.uuidString)"
    }

    func append(sample: Data, keyframe: Bool, format: FragmentedMP4.Format, arrivalUs: UInt64) -> Event {
        if initialization != format.initializationSegment {
            if initialization != nil { formatGeneration += 1 }
            discardPending()
            initialization = format.initializationSegment
            codecString = format.codecString
            segments.removeAll()
            announced = false
            previousArrivalUs = nil
        }
        if keyframe, pendingFrames > 0 {
            segments.append(Segment(number: segmentNumber,
                duration: Double(pendingDuration) / Double(format.timescale), data: pending))
            segmentNumber += 1
            while segments.count > 12 || segments.reduce(0, { $0 + $1.data.count }) > 32 * 1024 * 1024 {
                segments.removeFirst()
            }
            pending = Data(); pendingFrames = 0; pendingDuration = 0
        }
        if keyframe || pendingFrames > 0 {
            // CarPlay is variable-rate (especially on static screens). Counting every
            // sample as 1/maxFPS compresses real time and drains a live player's buffer.
            let elapsedUs = previousArrivalUs.flatMap { arrivalUs >= $0 ? arrivalUs - $0 : nil }
            let duration = elapsedUs.map {
                UInt32(max(1, min(Double(format.timescale) * 3,
                    (Double($0) * Double(format.timescale) / 1_000_000).rounded())))
            } ?? format.sampleDuration
            previousArrivalUs = arrivalUs
            let fragment = FragmentedMP4.fragment(sequence: sequence, decodeTime: decodeTime,
                duration: duration, accessUnit: sample, keyframe: keyframe)
            pending.append(fragment); pendingFrames += 1
            sequence &+= 1
            pendingDuration += UInt64(duration)
            decodeTime += UInt64(duration)
            if pending.count > 8 * 1024 * 1024 || pendingDuration > UInt64(Self.targetDuration) * UInt64(format.timescale) {
                discardPending()
            }
        }
        if segments.count >= 3, !announced {
            announced = true
            return .ready
        }
        let duration = Double(pendingDuration) / Double(format.timescale)
        if (duration >= 1 || pendingFrames == 0), arrivalUs - requestedAt >= 1_000_000 {
            requestedAt = arrivalUs
            return .keyframeNeeded
        }
        return .none
    }

    private func discardPending() {
        decodeTime -= pendingDuration
        pending = Data(); pendingFrames = 0; pendingDuration = 0
    }

    func resource(at path: String) -> (type: String, body: Data)? {
        let prefix = "/airplay/\(id.uuidString)/"
        guard path.hasPrefix(prefix) else { return nil }
        let tail = path.dropFirst(prefix.count)
        if tail == "master.m3u8", let codecString, !segments.isEmpty {
            let bandwidth = segments.map { Int(ceil(Double($0.data.count * 8) / $0.duration)) }.max() ?? 0
            let text = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n#EXT-X-STREAM-INF:BANDWIDTH=\(max(20_000_000, bandwidth)),CODECS=\"\(codecString)\"\n\(baseURL)/index.m3u8\n"
            return ("application/vnd.apple.mpegurl", Data(text.utf8))
        }
        if tail == "index.m3u8", let first = segments.first {
            var text = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n#EXT-X-TARGETDURATION:\(Self.targetDuration)\n"
            text += "#EXT-X-MEDIA-SEQUENCE:\(first.number)\n#EXT-X-DISCONTINUITY-SEQUENCE:\(formatGeneration)\n"
            text += "#EXT-X-MAP:URI=\"\(baseURL)/init-\(formatGeneration).mp4\"\n"
            for segment in segments {
                text += String(format: "#EXTINF:%.3f,\n", locale: Locale(identifier: "en_US_POSIX"), segment.duration)
                text += "\(baseURL)/\(segment.number).m4s\n"
            }
            return ("application/vnd.apple.mpegurl", Data(text.utf8))
        }
        if tail == "init-\(formatGeneration).mp4", let initialization { return ("video/mp4", initialization) }
        if tail.hasSuffix(".m4s"), let number = UInt64(tail.dropLast(4)),
           let segment = segments.first(where: { $0.number == number }) {
            return ("video/iso.segment", segment.data)
        }
        return nil
    }
}

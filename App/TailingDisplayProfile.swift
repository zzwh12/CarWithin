import Foundation
import CoreGraphics

enum ZeehoFrameRate: Int, CaseIterable, Sendable {
    case fps25 = 25
    case fps30 = 30
    case fps60 = 60

    var title: String { self == .fps60 ? "60 FPS（实验）" : "\(rawValue) FPS" }
    var sourceFPS: Int { max(30, rawValue) }
    var bitrate: Int { 2_500_000 * rawValue / 25 }
}

enum ZeehoVideoMode: Int, CaseIterable, Sendable {
    case transcode = 0, relay = 1
    var title: String { self == .relay ? "H.264 直传（实验）" : "兼容转码" }
    func effective(for rate: ZeehoFrameRate) -> Self {
        // A compressed P-frame cannot be discarded to turn a 30 FPS source into 25 FPS.
        rate == .fps25 ? .transcode : self
    }
}

enum ZeehoCanvas: Int, CaseIterable, Sendable {
    case wide = 0, compatible = 1
    var title: String { self == .wide ? "全宽 1600×770" : "兼容 800×480" }
    var size: InstrumentFrameSize {
        self == .wide ? InstrumentFrameSize(width: 1600, height: 770) : InstrumentFrameSize(width: 800, height: 480)
    }
}

/// A bounded compressed-frame FIFO. On overflow, discard the dependent GOP and wait for IDR.
/// The owner supplies synchronization and SPS/PPS with every keyframe.
struct ZeehoRelayBuffer {
    private var frames: [Data] = []
    private var bytes = 0
    private(set) var waitingForKeyframe = true
    private(set) var discardedGroups = 0
    let maximumFrames: Int
    let maximumBytes: Int

    init(maximumFrames: Int = 30, maximumBytes: Int = 8 * 1024 * 1024) {
        precondition(maximumFrames > 0 && maximumBytes > 0)
        self.maximumFrames = maximumFrames
        self.maximumBytes = maximumBytes
    }

    mutating func reset() {
        frames.removeAll(keepingCapacity: true)
        bytes = 0
        waitingForKeyframe = true
    }

    /// True means that a new keyframe is required. Never retain a dependent tail after overflow.
    mutating func append(_ data: Data, keyframe: Bool) -> Bool {
        if data.count > maximumBytes {
            reset(); discardedGroups += 1
            return true
        }
        if frames.count >= maximumFrames || bytes + data.count > maximumBytes {
            reset(); discardedGroups += 1
        }
        guard !waitingForKeyframe || keyframe else { return true }
        waitingForKeyframe = false
        frames.append(data); bytes += data.count
        return false
    }

    mutating func pop() -> Data? {
        guard !frames.isEmpty else { return nil }
        let result = frames.removeFirst()
        bytes -= result.count
        return result
    }
}

struct InstrumentFrameSize: Equatable, Sendable, CustomStringConvertible {
    let width: Int
    let height: Int

    var description: String { "\(width)×\(height)" }

    func fittedRect(for source: CGSize) -> CGRect {
        let canvasWidth = CGFloat(width), canvasHeight = CGFloat(height)
        let scale = min(canvasWidth / source.width, canvasHeight / source.height)
        let w = source.width * scale, h = source.height * scale
        return CGRect(x: (canvasWidth - w) / 2, y: (canvasHeight - h) / 2, width: w, height: h)
    }
}

enum TailingDisplayProfile: Equatable, Sendable {
    case tailing43
    case zeeho62
    case zeehoSEPlus
    case zeehoAE2
    case carbit

    var isZeeho: Bool { self != .tailing43 && self != .carbit }
    var usesH264: Bool { self != .tailing43 }

    /// CarPlay starts producing frames before the instrument reports its media dimensions.
    var preferredSize: InstrumentFrameSize {
        switch self {
        case .carbit: return InstrumentFrameSize(width: 1280, height: 720)
        case .tailing43: return InstrumentFrameSize(width: 480, height: 272)
        case .zeeho62, .zeehoAE2: return InstrumentFrameSize(width: 1024, height: 480)
        case .zeehoSEPlus: return InstrumentFrameSize(width: 800, height: 480)
        }
    }

    func outputSize(for reported: InstrumentFrameSize) -> InstrumentFrameSize? {
        switch self {
        case .carbit:
            guard (160...8192).contains(reported.width), (120...4320).contains(reported.height) else { return nil }
            let scale = min(1, 1920 / Double(reported.width), 1080 / Double(reported.height))
            return InstrumentFrameSize(width: Int(Double(reported.width) * scale) & ~1,
                                       height: Int(Double(reported.height) * scale) & ~1)
        case .tailing43:
            return reported == preferredSize ? preferredSize : nil
        case .zeeho62:
            guard reported.width == 1024, reported.height == 480 || reported.height == 488 else { return nil }
            return preferredSize
        case .zeehoAE2:
            guard (240...1920).contains(reported.width), (240...1080).contains(reported.height) else { return nil }
            return InstrumentFrameSize(width: reported.width & ~1, height: reported.height & ~1)
        case .zeehoSEPlus:
            // Use the PXC media dimensions verbatim. Bound pixel-buffer allocations and
            // require even dimensions for the encoder's 4:2:0 chroma format.
            guard (2...1920).contains(reported.width), (2...1080).contains(reported.height),
                  reported.width >= reported.height, reported.width.isMultiple(of: 2),
                  reported.height.isMultiple(of: 2) else { return nil }
            return reported
        }
    }
}

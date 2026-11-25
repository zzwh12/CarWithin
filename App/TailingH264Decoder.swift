// Adapted from xmz28/ninebot_pro: NinebotPro/Media/H264Decoder.swift
import AVFoundation
import Foundation
import VideoToolbox

private final class TailingH264DecoderCallbackBox {
    var output: ((CVPixelBuffer) -> Void)?
    var failure: ((Error) -> Void)?
}

private let tailingDecompressionCallback: VTDecompressionOutputCallback = { reference, _, status, _, imageBuffer, _, _ in
    guard let reference else { return }
    let box = Unmanaged<TailingH264DecoderCallbackBox>.fromOpaque(reference).takeUnretainedValue()
    guard status == noErr else {
        box.failure?(TailingH264DecoderError.decode(status))
        return
    }
    guard let imageBuffer else { return }
    box.output?(imageBuffer)
}

final class TailingH264Decoder {
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private let callbackBox = TailingH264DecoderCallbackBox()
    private(set) var nalUnitHeaderLength = 4
    private(set) var backendDescription = CWL("系统解码")

    init(
        configuration: Data,
        output: @escaping (CVPixelBuffer) -> Void,
        failure: @escaping (Error) -> Void
    ) throws {
        callbackBox.output = output
        callbackBox.failure = failure
        try configure(configuration: configuration)
    }

    deinit { invalidate() }

    func decode(_ data: Data, presentationTimeMicroseconds: Int64, isKeyframe: Bool) throws {
        guard let session, let formatDescription else { throw TailingH264DecoderError.invalidated }

        var blockBuffer: CMBlockBuffer?
        let createBlockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard createBlockStatus == kCMBlockBufferNoErr, let blockBuffer else {
            throw TailingH264DecoderError.blockBuffer(createBlockStatus)
        }
        let copyStatus = data.withUnsafeBytes { bytes -> OSStatus in
            guard let source = bytes.baseAddress else { return kCMBlockBufferBadLengthParameterErr }
            return CMBlockBufferReplaceDataBytes(
                with: source,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { throw TailingH264DecoderError.blockCopy(copyStatus) }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: presentationTimeMicroseconds, timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = data.count
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else { throw TailingH264DecoderError.sampleBuffer(sampleStatus) }
        if !isKeyframe {
            CMSetAttachment(
                sampleBuffer,
                key: kCMSampleAttachmentKey_NotSync,
                value: kCFBooleanTrue,
                attachmentMode: kCMAttachmentMode_ShouldNotPropagate
            )
        }

        var infoFlags = VTDecodeInfoFlags()
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression, ._1xRealTimePlayback],
            frameRefcon: nil,
            infoFlagsOut: &infoFlags
        )
        guard decodeStatus == noErr else { throw TailingH264DecoderError.decode(decodeStatus) }
    }

    /// Called on the dedicated decode worker so VT cannot build an unbounded frame backlog.
    func waitForFrames() {
        if let session { VTDecompressionSessionWaitForAsynchronousFrames(session) }
    }

    func invalidate() {
        guard let session else { return }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        VTDecompressionSessionInvalidate(session)
        self.session = nil
        formatDescription = nil
        callbackBox.output = nil
        callbackBox.failure = nil
    }

    private func configure(configuration: Data) throws {
        let parsed = try TailingAVCConfigurationRecord(data: configuration)
        nalUnitHeaderLength = parsed.nalUnitHeaderLength
        let retainedSets = parsed.parameterSets.map { $0 as NSData }
        var pointers = retainedSets.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
        var sizes = retainedSets.map(\.length)
        var description: CMFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: pointers.count,
            parameterSetPointers: &pointers,
            parameterSetSizes: &sizes,
            nalUnitHeaderLength: Int32(parsed.nalUnitHeaderLength),
            formatDescriptionOut: &description
        )
        guard formatStatus == noErr, let description else { throw TailingH264DecoderError.format(formatStatus) }
        formatDescription = description

        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        var record = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: tailingDecompressionCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(callbackBox).toOpaque()
        )
        // iOS may invalidate a hardware decoder when the phone locks. This low-resolution
        // secondary output uses the system software decoder where the public switch exists.
        var specification: CFDictionary?
        if #available(iOS 17.0, macOS 10.9, *) {
            specification = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: false] as CFDictionary
        }
        var created: VTDecompressionSession?
        let sessionStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: description,
            decoderSpecification: specification,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: &record,
            decompressionSessionOut: &created
        )
        guard sessionStatus == noErr, let created else { throw TailingH264DecoderError.create(sessionStatus) }
        session = created
        if #available(iOS 17.0, macOS 10.9, *) {
            var value: Unmanaged<CFBoolean>?
            let queried = VTSessionCopyProperty(created, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                allocator: nil, valueOut: &value)
            if queried == noErr, let value {
                backendDescription = CFBooleanGetValue(value.takeRetainedValue()) ? CWL("硬件解码") : CWL("CPU 软件解码")
            } else { backendDescription = CWL("请求 CPU 软件解码（系统未提供类型查询）") }
        }
        _ = VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    }
}

private struct TailingAVCConfigurationRecord {
    let nalUnitHeaderLength: Int
    let parameterSets: [Data]

    init(data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 7, bytes[0] == 1 else { throw TailingH264DecoderError.invalidConfiguration }
        nalUnitHeaderLength = Int(bytes[4] & 0x03) + 1
        var index = 5
        let spsCount = Int(bytes[index] & 0x1f)
        index += 1
        var sets: [Data] = []
        for _ in 0..<spsCount {
            sets.append(try Self.readParameterSet(bytes, index: &index))
        }
        guard index < bytes.count else { throw TailingH264DecoderError.invalidConfiguration }
        let ppsCount = Int(bytes[index])
        index += 1
        for _ in 0..<ppsCount {
            sets.append(try Self.readParameterSet(bytes, index: &index))
        }
        guard spsCount > 0, ppsCount > 0 else { throw TailingH264DecoderError.missingParameterSets }
        parameterSets = sets
    }

    private static func readParameterSet(_ bytes: [UInt8], index: inout Int) throws -> Data {
        guard index + 2 <= bytes.count else { throw TailingH264DecoderError.invalidConfiguration }
        let count = Int(bytes[index]) << 8 | Int(bytes[index + 1])
        index += 2
        guard count > 0, index + count <= bytes.count else { throw TailingH264DecoderError.invalidConfiguration }
        let result = Data(bytes[index..<(index + count)])
        index += count
        return result
    }
}

enum TailingH264DecoderError: LocalizedError {
    case invalidConfiguration
    case missingParameterSets
    case format(OSStatus)
    case create(OSStatus)
    case blockBuffer(OSStatus)
    case blockCopy(OSStatus)
    case sampleBuffer(OSStatus)
    case decode(OSStatus)
    case invalidated

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: CWL("台铃输出 H.264 配置不是有效的 avcC 数据")
        case .missingParameterSets: CWL("台铃输出 H.264 配置缺少 SPS/PPS")
        case .format(let code): CWL("创建 H.264 解码格式失败（{1}）", [String(describing: code)])
        case .create(let code): CWL("创建 VideoToolbox 解码器失败（{1}）", [String(describing: code)])
        case .blockBuffer(let code): CWL("创建视频压缩数据块失败（{1}）", [String(describing: code)])
        case .blockCopy(let code): CWL("复制视频压缩数据失败（{1}）", [String(describing: code)])
        case .sampleBuffer(let code): CWL("创建视频样本失败（{1}）", [String(describing: code)])
        case .decode(let code): CWL("VideoToolbox 解码失败（{1}）", [String(describing: code)])
        case .invalidated: CWL("H.264 解码器已停止")
        }
    }
}

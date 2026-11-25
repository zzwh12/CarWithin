// Adapted from xmz28/ninebot_pro.
import AVFoundation
import Foundation
import VideoToolbox

struct H264EncodedFrame {
    let data: Data
    let isKeyframe: Bool
    let presentationTime: CMTime
}

private final class H264CallbackBox {
    var handler: ((Result<H264EncodedFrame, Error>) -> Void)?
}

private let h264CompressionCallback: VTCompressionOutputCallback = { reference, _, status, infoFlags, sampleBuffer in
    guard let reference else { return }
    let box = Unmanaged<H264CallbackBox>.fromOpaque(reference).takeUnretainedValue()
    guard status == noErr else {
        box.handler?(.failure(H264EncoderError.compression(status)))
        return
    }
    // RealTime + 码率上限下，VideoToolbox 会主动丢帧并回调空 sampleBuffer，这是正常行为
    if infoFlags.contains(.frameDropped) || sampleBuffer == nil {
        box.handler?(.failure(H264EncoderError.frameDropped))
        return
    }
    guard let sampleBuffer, CMSampleBufferDataIsReady(sampleBuffer) else {
        box.handler?(.failure(H264EncoderError.missingSampleBuffer))
        return
    }

    do {
        // NotSync 位于"样本附件数组"中，不是 CMSampleBuffer 级附件；
        // 用 CMGetAttachment 读永远是 nil，会把每个 P 帧都当成关键帧发给仪表
        var notSync = false
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[CFString: Any]],
           let first = attachments.first {
            notSync = (first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
        }
        let isKeyframe = !notSync

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw H264EncoderError.missingBlockBuffer
        }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        var avcc = Data(count: length)
        let copyStatus = avcc.withUnsafeMutableBytes { bytes in
            guard let destination = bytes.baseAddress else { return kCMBlockBufferBadCustomBlockSourceErr }
            return CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: length,
                destination: destination
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { throw H264EncoderError.blockCopy(copyStatus) }
        var annexB = try H264AnnexB.convertFromAVCC(avcc)

        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            var parameterSets = Data()
            var parameterSetCount = 0
            var nalHeaderLength: Int32 = 0
            for index in 0..<2 {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                let parameterStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format,
                    parameterSetIndex: index,
                    parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size,
                    parameterSetCountOut: &parameterSetCount,
                    nalUnitHeaderLengthOut: &nalHeaderLength
                )
                if parameterStatus == noErr, let pointer, size > 0 {
                    parameterSets.append(contentsOf: [0, 0, 0, 1])
                    parameterSets.append(pointer, count: size)
                }
            }
            if !H264AnnexB.containsNAL(type: 7, in: annexB) || !H264AnnexB.containsNAL(type: 8, in: annexB) {
                annexB = parameterSets + annexB
            }
        }

        guard !isKeyframe || (
            H264AnnexB.containsNAL(type: 7, in: annexB) &&
            H264AnnexB.containsNAL(type: 8, in: annexB)
        ) else {
            throw H264EncoderError.missingParameterSets
        }
        box.handler?(.success(H264EncodedFrame(
            data: annexB,
            isKeyframe: isKeyframe,
            presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        )))
    } catch {
        box.handler?(.failure(error))
    }
}

final class H264Encoder {
    private var session: VTCompressionSession?
    private let callbackBox = H264CallbackBox()
    private let fps: Int

    init(width: Int, height: Int, fps: Int, bitrate: Int, profileLevel: CFString = kVTProfileLevel_H264_Baseline_AutoLevel,
         output: @escaping (Result<H264EncodedFrame, Error>) -> Void) throws {
        self.fps = fps
        callbackBox.handler = output

        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        func create(_ specification: CFDictionary?) -> (OSStatus, VTCompressionSession?) {
            var created: VTCompressionSession?
            let status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: Int32(width),
                height: Int32(height),
                codecType: kCMVideoCodecType_H264,
                encoderSpecification: specification,
                imageBufferAttributes: attributes as CFDictionary,
                compressedDataAllocator: nil,
                outputCallback: h264CompressionCallback,
                refcon: Unmanaged.passUnretained(callbackBox).toOpaque(),
                compressionSessionOut: &created
            )
            return (status, created)
        }
        // 不使用 kVTVideoEncoderSpecification_EnableLowLatencyRateControl：实测它把 SPS 改成
        // max_num_ref_frames=5 并带 VUI，与官方 iOS 码流（refs=1、无 VUI）不同，且手机端编码耗时没有下降
        let (status, created) = create(nil)
        guard status == noErr, let created else { throw H264EncoderError.create(status) }
        session = created
        do {
            try configure(created, bitrate: bitrate, profileLevel: profileLevel)
        } catch {
            VTCompressionSessionInvalidate(created)
            session = nil
            throw error
        }
    }

    private func configure(_ created: VTCompressionSession, bitrate: Int, profileLevel: CFString) throws {
        do {
            try set(kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            try set(kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
            try set(kVTCompressionPropertyKey_ProfileLevel, value: profileLevel)
            try set(kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
            try set(kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
            // 关键帧节奏由 MirrorSession 每 0.5 秒强制请求（与官方 iOS 抓包、Android 版一致）；
            // 这里的 1 秒只是兜底，避免两套计时错开导致每秒 3–4 个关键帧
            try set(kVTCompressionPropertyKey_MaxKeyFrameInterval, value: fps as CFNumber)
            try set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 1 as CFNumber)
            // 硬上限等于平均码率时，每秒一次的关键帧会把预算吃光，紧随其后的帧被丢弃，
            // 表现为每秒卡顿一下。留 1.5 倍余量吸收关键帧峰值。
            let byteLimit = max(1, bitrate * 3 / 2 / 8)
            try set(kVTCompressionPropertyKey_DataRateLimits, value: [byteLimit, 1] as CFArray)
            // 低延迟：不缓存帧，尽量优先编码速度。部分设备不支持，失败时忽略。
            try? set(kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
            try? set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
            let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(created)
            guard prepareStatus == noErr else { throw H264EncoderError.prepare(prepareStatus) }
        }
    }

    deinit { invalidate() }

    func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, forceKeyframe: Bool) throws {
        guard let session else { throw H264EncoderError.invalidated }
        var flags = VTEncodeInfoFlags()
        let properties: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: CMTime(value: 1, timescale: CMTimeScale(fps)),
            frameProperties: properties,
            sourceFrameRefcon: nil,
            infoFlagsOut: &flags
        )
        guard status == noErr else { throw H264EncoderError.encode(status) }
    }

    func complete() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }

    func invalidate() {
        guard let session else { return }
        VTCompressionSessionInvalidate(session)
        self.session = nil
        callbackBox.handler = nil
    }

    private func set(_ key: CFString, value: CFTypeRef) throws {
        guard let session else { throw H264EncoderError.invalidated }
        let status = VTSessionSetProperty(session, key: key, value: value)
        guard status == noErr else { throw H264EncoderError.property(key as String, status) }
    }
}

enum H264EncoderError: LocalizedError {
    case create(OSStatus)
    case property(String, OSStatus)
    case prepare(OSStatus)
    case encode(OSStatus)
    case compression(OSStatus)
    case blockCopy(OSStatus)
    case missingSampleBuffer
    case missingBlockBuffer
    case missingParameterSets
    case frameDropped
    case invalidated

    var errorDescription: String? {
        switch self {
        case .frameDropped: CWL("编码器丢弃了一帧")
        case .create(let code): CWL("无法创建 H.264 编码器（{1}）", [String(describing: code)])
        case .property(let key, let code): CWL("编码器不接受参数 {1}（{2}）", [String(describing: key), String(describing: code)])
        case .prepare(let code): CWL("H.264 编码器准备失败（{1}）", [String(describing: code)])
        case .encode(let code): CWL("提交 H.264 帧失败（{1}）", [String(describing: code)])
        case .compression(let code): CWL("H.264 压缩失败（{1}）", [String(describing: code)])
        case .blockCopy(let code): CWL("读取 H.264 输出失败（{1}）", [String(describing: code)])
        case .missingSampleBuffer: CWL("编码器没有返回有效帧")
        case .missingBlockBuffer: CWL("编码器输出缺少数据块")
        case .missingParameterSets: CWL("H.264 关键帧缺少 SPS/PPS")
        case .invalidated: CWL("H.264 编码器已停止")
        }
    }
}

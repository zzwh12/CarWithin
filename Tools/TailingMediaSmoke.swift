import Foundation
import AVFoundation
import VideoToolbox
import ImageIO
import CoreImage

private final class MediaBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func set(_ value: Value) { lock.lock(); self.value = value; lock.unlock() }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
}
// The standalone media test compiles the output without the iPhone receiver settings.
struct ConfigurationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private struct MediaSmokeError: Error { let message: String }
private func require(_ value: Bool, _ message: String) throws {
    if !value { throw MediaSmokeError(message: message) }
}

func verifyCarbitBitmapPreview() throws {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(nil, 1904, 672, kCVPixelFormatType_32BGRA,
                                     [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer)
    guard status == kCVReturnSuccess, let buffer = pixelBuffer else { throw MediaSmokeError(message: "无法创建预览测试帧") }
    CVPixelBufferLockBaseAddress(buffer, [])
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<672 {
        for x in 0..<1904 {
            let p = base + y * stride + x * 4
            p[0] = x >= 952 ? 255 : 0
            p[1] = x < 952 && y >= 336 ? 255 : 0
            p[2] = x < 952 && y < 336 ? 255 : 0
            p[3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    guard let bitmap = PXCH264Output.previewBitmap(buffer), let data = bitmap.dataProvider?.data,
          let pixels = CFDataGetBytePtr(data) else { throw MediaSmokeError(message: "未生成位图预览") }
    CVPixelBufferLockBaseAddress(buffer, [])
    memset(CVPixelBufferGetBaseAddress(buffer)!, 0, stride * 672)
    CVPixelBufferUnlockBaseAddress(buffer, [])
    try require(bitmap.width == 640 && bitmap.height == 226 && bitmap.bitsPerPixel == 32, "位图预览尺寸或格式不符")
    func channel(_ x: Int, _ y: Int, _ c: Int) -> UInt8 { pixels[y * bitmap.bytesPerRow + x * 4 + c] }
    try withExtendedLifetime(data) {
        try require(channel(80, 40, 2) == 255 && channel(80, 180, 1) == 255 && channel(560, 180, 0) == 255,
                    "预览必须自己持有像素并保留 BGRA 色彩及上下方向")
    }
    print("PASS: Carbit preview uses an independent, correctly oriented 640×226 CPU bitmap")
}

func makeH264TestBars(_ size: InstrumentFrameSize) throws -> Data {
    let encoded = MediaBox<Result<H264EncodedFrame, Error>?>(nil)
    let encoder = try H264Encoder(width: size.width, height: size.height, fps: 25, bitrate: 4_000_000) {
        encoded.set($0)
    }
    defer { encoder.invalidate() }
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(nil, size.width, size.height, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer)
    guard status == kCVReturnSuccess, let buffer = pixelBuffer else { throw MediaSmokeError(message: "创建测试画面失败") }
    CVPixelBufferLockBaseAddress(buffer, [])
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<size.height {
        for x in 0..<size.width {
            let offset = y * stride + x * 4
            let left = x < size.width / 2
            base[offset] = left ? 0 : 255
            base[offset + 1] = 0
            base[offset + 2] = left ? 255 : 0
            base[offset + 3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    try encoder.encode(buffer, presentationTime: .zero, forceKeyframe: true)
    encoder.complete()
    guard let result = encoded.get() else { throw MediaSmokeError(message: "未生成 H.264 首帧") }
    return try result.get().data
}

// Read the coded dimensions, before the SPS cropping rectangle. The 7.0.1 iOS receiver
// checks these before handing the picture to MediaCodec. A normal decoder applies the crop.
private func baselineMacroblockSize(_ sps: Data) -> InstrumentFrameSize? {
    var rbsp: [UInt8] = []
    var zeros = 0
    for byte in sps {
        if zeros == 2 && byte == 3 { zeros = 0; continue }
        rbsp.append(byte)
        zeros = byte == 0 ? zeros + 1 : 0
    }
    guard rbsp.count >= 4, rbsp[1] == 66 else { return nil }
    var bits = BitReader(rbsp, byteOffset: 4)
    // seq_parameter_set_id, log2_max_frame_num_minus4, pic_order_cnt_type
    guard bits.ue() != nil, bits.ue() != nil, let order = bits.ue(), order <= 2 else { return nil }
    if order == 0 {
        guard bits.ue() != nil else { return nil }
    } else if order == 1 {
        // Signed and unsigned Exp-Golomb fields have the same length when skipping offsets.
        guard bits.bit() != nil, bits.ue() != nil, bits.ue() != nil, let cycle = bits.ue(), cycle <= 255 else { return nil }
        for _ in 0..<cycle where bits.ue() == nil { return nil }
    }
    guard bits.ue() != nil, bits.bit() != nil, let widthMinusOne = bits.ue(),
          let heightMinusOne = bits.ue(), bits.bit() == 1 else { return nil }
    return InstrumentFrameSize(width: (widthMinusOne + 1) * 16, height: (heightMinusOne + 1) * 16)
}

func verifyCarbitCroppedSPS() throws {
    let previousSize = InstrumentFrameSize(width: 486, height: 1080)
    let frame = try makeH264TestBars(previousSize)
    let sps = try AnnexB.units(in: frame).first { VideoCodec.h264.nalType($0) == 7 }
    try require(sps.flatMap(baselineMacroblockSize) == InstrumentFrameSize(width: 496, height: 1088),
                "旧协商尺寸应能复现亿连首帧 SPS 的宏块尺寸差异")
    print("PASS: Carbit 7.0.1 dimension check reproduces 486×1080 vs 496×1088 in the VideoToolbox SPS")
}

func verifyH264TestBars(_ data: Data, size: InstrumentFrameSize, greenCenter: Bool = false, contentHeight: Int? = nil) throws {
    var parameters = VideoParameterSets(codec: .h264)
    var picture: [Data] = []
    for unit in try AnnexB.units(in: data) {
        if VideoCodec.h264.parameterSet(unit) != nil { _ = parameters.absorb(unit) }
        else { picture.append(unit) }
    }
    try require(parameters.isComplete && picture.contains { VideoCodec.h264.nalType($0) == 5 },
                "亿连首帧需包含 SPS、PPS 和 IDR")
    try require(parameters.sps.flatMap(baselineMacroblockSize) == size, "H.264 SPS 宏块宽高必须匹配车机收到的协商值")
    let image = MediaBox<CVPixelBuffer?>(nil)
    let failure = MediaBox<Error?>(nil)
    let decoder = try TailingH264Decoder(configuration: parameters.decoderConfigurationRecord(),
        output: { image.set($0) }, failure: { failure.set($0) })
    try decoder.decode(AnnexB.lengthPrefixed(picture), presentationTimeMicroseconds: 0, isKeyframe: true)
    decoder.waitForFrames()
    if let error = failure.get() { throw error }
    guard let buffer = image.get() else { throw MediaSmokeError(message: "亿连首帧没有解出画面") }
    try require(CVPixelBufferGetWidth(buffer) == size.width && CVPixelBufferGetHeight(buffer) == size.height,
                "解码首帧应匹配协商的尺寸")
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let row = size.height / 2 * CVPixelBufferGetBytesPerRow(buffer)
    let left = row + (size.width / 4) * 4
    let right = row + (size.width * 3 / 4) * 4
    let middle = row + (size.width / 2) * 4
    try require(bytes[left + 2] > 200 && bytes[left] < 50 && bytes[right] > 200 && bytes[right + 2] < 50,
                "亿连接收的 H.264 应解出左红右蓝的测试画面")
    try require(greenCenter ? bytes[middle + 1] > 200 : bytes[middle + 1] < 50, "H.264 画面来源与当前模式应一致")
    if let contentHeight {
        let top = (size.height - contentHeight) / 2, bottom = top + contentHeight
        func red(at y: Int) -> UInt8 { bytes[y * CVPixelBufferGetBytesPerRow(buffer) + size.width / 4 * 4 + 2] }
        try require(red(at: top - 4) < 40 && red(at: top + 4) > 200 &&
                    red(at: bottom - 4) > 200 && red(at: bottom + 4) < 40,
                    "竖屏中应保留居中、等比例的横屏图像")
    }
}

func verifyJPEGTestBars(_ data: Data, size: InstrumentFrameSize, greenCenter: Bool = false) throws {
    guard data.starts(with: [0xff, 0xd8]), let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw MediaSmokeError(message: "JPEG 不可解码")
    }
    try require(image.width == size.width && image.height == size.height, "JPEG 应匹配协商的尺寸")
    var pixels = [UInt8](repeating: 0, count: size.width * size.height * 4)
    try pixels.withUnsafeMutableBytes { bytes in
        guard let context = CGContext(data: bytes.baseAddress, width: size.width, height: size.height,
            bitsPerComponent: 8, bytesPerRow: size.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw MediaSmokeError(message: "无法读取 JPEG 像素")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
    }
    let left = (size.height / 2 * size.width + size.width / 4) * 4
    let right = (size.height / 2 * size.width + size.width * 3 / 4) * 4
    let middle = (size.height / 2 * size.width + size.width / 2) * 4
    try require(pixels[left] > 220 && pixels[left + 2] < 35 && pixels[right + 2] > 220 && pixels[right] < 35,
                "JPEG 应解出左红右蓝的测试画面")
    try require(greenCenter ? pixels[middle + 1] > 200 : pixels[middle + 1] < 50, "JPEG 画面来源与当前模式应一致")
}

/// Real VT H.264 → decoder → Core Image JPEG → pull-frame socket round trip on loopback.
func tailingMediaSmoke() throws {
    let accessUnit = try makeH264TestBars(.init(width: 960, height: 544))
    let failure = MediaBox<Error?>(nil)

    let announcement = try TailingSocket.listening(localIP: "127.0.0.1", port: 0)
    defer { announcement.close() }
    let reserved = try (0..<3).map { _ in try TailingSocket.listening(localIP: "127.0.0.1", port: 0) }
    let ports = try TailingPorts(control: reserved[0].localPort, auxiliary: reserved[1].localPort,
        video: reserved[2].localPort, announcement: announcement.localPort)
    reserved.forEach { $0.close() }
    let identity = try TailingIdentity.generate()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        var sockets: [TailingSocket] = []
        defer { sockets.forEach { $0.close() }; done.signal() }
        func connect(_ port: UInt16) throws -> TailingSocket {
            let s = try TailingSocket.create(); sockets.append(s)
            try s.connect(localIP: "127.0.0.1", remoteIP: "127.0.0.1", port: port)
            return s
        }
        do {
            let a = try announcement.accept(remoteIP: "127.0.0.1"); sockets.append(a)
            _ = try TailingProtocol.readControl { try a.readExactly($0) }
            try a.write(TailingProtocol.control(0x70000011, payload: TailingProtocol.json(["status": true])))
            let control = try connect(ports.control)
            try control.write(TailingProtocol.control(0x10010,
                payload: TailingProtocol.json(["HUName": "TL-DASH-V2", "HUID": "MEDIA-SMOKE"])))
            let info = try TailingProtocol.object(TailingProtocol.readControl { try control.readExactly($0) }.payload)
            let signature = info["encryptedHUID"] as! String
            let reverse = try connect(ports.control)
            try reverse.write(TailingProtocol.control(0x20000))
            _ = try TailingProtocol.readControl { try reverse.readExactly($0) }
            for _ in 0..<5 {
                let m = try TailingProtocol.readControl { try reverse.readExactly($0) }
                try reverse.write(TailingProtocol.control(m.command == 0x205a0 ? 0x80000010 : m.command + 1, identifier: m.identifier))
            }
            let aux = try connect(ports.auxiliary)
            var config = Data(); config.appendLE(UInt32(272 << 16 | 480))
            config.append(Data(repeating: 0, count: 28)); config.append(Data(signature.utf8))
            try aux.write(TailingProtocol.auxiliary(0x10, payload: config))
            _ = try TailingProtocol.readAuxiliary { try aux.readExactly($0) }
            try aux.write(TailingProtocol.auxiliary(0x70))
            _ = try TailingProtocol.readAuxiliary { try aux.readExactly($0) }
            let video = try connect(ports.video)
            var previous: Data?
            for _ in 0..<3 {
                try video.write(TailingProtocol.auxiliary(0x72))
                let length = Int(try video.readExactly(4, timeout: 20).uint32LE(0))
                try require((1...1_000_000).contains(length), "JPEG 长度合理")
                let jpeg = try video.readExactly(length)
                if let previous { try require(jpeg == previous, "静态画面复用最新 JPEG") }
                previous = jpeg
                try verifyJPEGTestBars(jpeg, size: .init(width: 480, height: 272))
            }
        } catch { failure.set(error) }
    }
    let output = TailingOutputSession(localAddress: "127.0.0.1", targetAddress: "127.0.0.1",
        phone: TailingPhoneInfo(package: "test.carwithin", versionCode: 12, model: "iPhone", systemVersion: "16.0",
            width: 1320, height: 2868, rotation: 0), log: { print($0) }, ports: ports, identityProvider: { identity })
    defer { output.close() }
    output.start()
    output.append(accessUnit)
    try require(done.wait(timeout: .now() + 25) == .success, "转码输出超时")
    if let error = failure.get() { throw error }
    print("PASS: 真实 H.264 → JPEG → 模拟仪表，480×272、颜色方向、静态画面三次拉取")
}


func tailingJPEGSizeSmoke() throws {
    var buffer: CVPixelBuffer?
    try require(CVPixelBufferCreate(nil, 480, 272, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess, "创建复杂画面")
    guard let buffer else { return }
    CVPixelBufferLockBaseAddress(buffer, [])
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    var random: UInt32 = 1234567
    for y in 0..<272 {
        for x in 0..<480 {
            for channel in 0..<3 {
                random = random &* 1664525 &+ 1013904223
                base[y * stride + x * 4 + channel] = UInt8(truncatingIfNeeded: random >> 24)
            }
            base[y * stride + x * 4 + 3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    let context = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: true])
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let image = CIImage(cvPixelBuffer: buffer)
    guard let original = context.jpegRepresentation(of: image, colorSpace: colorSpace,
        options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.8]) else {
        throw MediaSmokeError(message: "复杂画面原始 JPEG 编码")
    }
    try require(original.count > TailingJPEGEncoder.byteLimit, "复杂画面须触发限幅")
    for quality in [80, 100, 0] {
        let bounded = try TailingJPEGEncoder.encode(image, context: context, colorSpace: colorSpace, quality: quality)
        try require(bounded.data.count <= TailingJPEGEncoder.byteLimit, "每帧不超过 24 KiB")
        if quality == 80 { try require(bounded.reduced, "默认质量复杂帧记录限幅") }
        guard let source = CGImageSourceCreateWithData(bounded.data as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw MediaSmokeError(message: "限幅 JPEG 无法解码")
        }
        try require(decoded.width == 480 && decoded.height == 272, "限幅保持协商尺寸")
    }
    let simple = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 480, height: 272))
    let unchanged = try TailingJPEGEncoder.encode(simple, context: context, colorSpace: colorSpace)
    let baseline = context.jpegRepresentation(of: simple, colorSpace: colorSpace,
        options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.8])
    try require(!unchanged.reduced && unchanged.data == baseline, "小帧保留原质量")
    print("PASS: 复杂 JPEG 单帧 ≤24 KiB、480×272，最低质量兜底；简单画面保留原质量")
}

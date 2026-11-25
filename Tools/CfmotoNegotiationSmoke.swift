import Foundation

func cfmotoNegotiationSmoke() throws {
    func body(_ width: UInt16, _ height: UInt16, _ fps: UInt32 = 30, _ codec: UInt32 = 2) -> Data {
        var data = Data(); data.appendLE(width); data.appendLE(height); data.appendLE(fps); data.appendLE(codec); return data
    }
    let five = try PxcConnection.validatedMediaSize(body(800, 386))
    precondition(five.width == 800 && five.height == 384 && five.fps == 30)
    let six = try PxcConnection.validatedMediaSize(body(1024, 515))
    precondition(six.width == 1024 && six.height == 512)
    for invalid in [Data(), body(0, 480), body(65535, 480), body(800, 0), body(800, 480, 0), body(800, 480, 61), body(800, 480, 30, 3)] {
        do { _ = try PxcConnection.validatedMediaSize(invalid); fatalError("Accepted invalid PXC media configuration") }
        catch TailingError.protocolFailure { }
    }
    print("PASS: 春风媒体配置长度、尺寸、帧率、编码器边界与对齐")
}

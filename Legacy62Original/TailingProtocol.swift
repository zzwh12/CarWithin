// Adapted from xmz28/ninebot_pro: NinebotPro/Networking/TailingProtocol.swift
import Foundation

/// 台铃 PXC 控制、ReqBase 配套通道和逐帧 JPEG；与九号 RTP 分开。
enum TailingProtocol {
    struct Control: Equatable {
        let command: UInt32
        let identifier: UInt32
        let payload: Data
    }

    struct Auxiliary: Equatable {
        let command: UInt16
        let token: UInt32
        let payload: Data
    }

    static func control(_ command: UInt32, identifier: UInt32 = 0, payload: Data = Data()) throws -> Data {
        guard payload.count <= 65_536 - 16 else { throw TailingError.protocolFailure("控制帧过长") }
        let size = UInt32(16 + payload.count)
        var data = Data()
        for value in [command, size, command ^ size, identifier] { data.appendLE(value) }
        data.append(payload)
        return data
    }

    static func readControl(_ read: (Int) throws -> Data) throws -> Control {
        let head = try read(16)
        guard head.count == 16 else { throw TailingError.protocolFailure("控制头截断") }
        let command = head.uint32LE(0), length = Int(head.uint32LE(4))
        guard (16...65_536).contains(length), head.uint32LE(8) == command ^ UInt32(length) else {
            throw TailingError.protocolFailure("控制帧长度或异或校验错误")
        }
        // iOS 样本第 4 字段存在非零值；保存并在回复时回显，不将其强制视为零。
        let payload = try read(length - 16)
        guard payload.count == length - 16 else { throw TailingError.protocolFailure("控制载荷截断") }
        return Control(command: command, identifier: head.uint32LE(12), payload: payload)
    }

    static func auxiliary(_ command: UInt16, token: UInt32 = 0, payload: Data = Data()) throws -> Data {
        guard payload.count <= 8_192 else { throw TailingError.protocolFailure("媒体控制帧过长") }
        var data = Data()
        data.appendLE(command); data.appendLE(UInt16(payload.count)); data.appendLE(token)
        data.append(payload)
        return data
    }

    static func readAuxiliary(_ read: (Int) throws -> Data) throws -> Auxiliary {
        let head = try read(8)
        guard head.count == 8 else { throw TailingError.protocolFailure("媒体控制头截断") }
        let length = Int(head.uint16LE(2))
        guard length <= 8_192 else { throw TailingError.protocolFailure("媒体控制载荷过长") }
        let payload = try read(length)
        guard payload.count == length else { throw TailingError.protocolFailure("媒体控制载荷截断") }
        return Auxiliary(command: head.uint16LE(0), token: head.uint32LE(4), payload: payload)
    }

    static func jpeg(_ jpeg: Data) throws -> Data {
        guard jpeg.count >= 4, jpeg.count <= 8 * 1_024 * 1_024,
              jpeg.starts(with: [0xff, 0xd8]), jpeg.suffix(2) == Data([0xff, 0xd9]) else {
            throw TailingError.protocolFailure("JPEG 不完整或过长")
        }
        var data = Data()
        data.appendLE(UInt32(jpeg.count)); data.append(jpeg)
        return data
    }

    static func h264(_ accessUnit: Data, includePrefix: Bool) throws -> Data {
        guard accessUnit.count > 4, accessUnit.count <= 8 * 1_024 * 1_024,
              accessUnit.starts(with: [0, 0, 0, 1]) else {
            throw TailingError.protocolFailure("H.264 Annex B 帧无效或过长")
        }
        var data = Data(count: includePrefix ? 8 : 0)
        data.appendLE(UInt32(accessUnit.count))
        data.append(accessUnit)
        return data
    }

    static func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func object(_ data: Data) throws -> [String: Any] {
        // 官方 iOS 的部分 JSON 以 NUL 结尾。
        var payload = data
        while payload.last == 0 { payload.removeLast() }
        guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw TailingError.protocolFailure("控制 JSON 无效")
        }
        return object
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    func uint16LE(_ offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }

    func uint32LE(_ offset: Int) -> UInt32 {
        UInt32(uint16LE(offset)) | UInt32(uint16LE(offset + 2)) << 16
    }
}

enum TailingError: LocalizedError {
    case protocolFailure(String)
    case timeout(String)
    case closed
    case system(String, Int32)
    case channel(String, Error)

    var errorDescription: String? {
        switch self {
        case .protocolFailure(let text): return "台铃协议：\(text)"
        case .timeout(let text): return "台铃等待超时：\(text)"
        case .closed: return "台铃会话已关闭"
        case .channel(let name, let error): return "\(name)：\(error.localizedDescription)"
        case .system(let text, let code): return "台铃\(text)失败（\(code)）"
        }
    }
}

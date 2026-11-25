import Foundation

@main
struct ZeehoControlSmoke {
    static func main() throws {
        let commands: [UInt32] = [0x103b0, 0x103a0, 0x10470, 0x104a0, 0x10020]
        for (index, command) in commands.enumerated() {
            let identifier = UInt32(0xa0000000 + index)
            let request = TailingProtocol.Control(command: command, identifier: identifier,
                                                  payload: Data("synthetic notification".utf8))
            guard let encoded = try TailingProtocol.notificationReceipt(to: request, profile: .zeehoSEPlus) else {
                fatalError("Expected MotoPlay notification acknowledgement")
            }
            precondition(encoded.count == 16)
            precondition(encoded.uint32LE(0) == command + 1)
            precondition(encoded.uint32LE(4) == 16)
            precondition(encoded.uint32LE(8) == ((command + 1) ^ 16))
            precondition(encoded.uint32LE(12) == identifier)
            var offset = 0
            let response = try TailingProtocol.readControl { count in
                defer { offset += count }
                return encoded.subdata(in: offset..<(offset + count))
            }
            precondition(response.payload.isEmpty && response.identifier == identifier)
            let carbitReply = try TailingProtocol.notificationReceipt(to: request, profile: .carbit)
            let carbitNotification = command == 0x103a0 || command == 0x10020
            precondition(carbitReply == (carbitNotification ? encoded : nil))
            for otherProfile: TailingDisplayProfile in [.zeeho62, .zeehoAE2, .tailing43] {
                let excluded = try TailingProtocol.notificationReceipt(to: request, profile: otherProfile)
                precondition(excluded == nil)
            }
            for profile: TailingDisplayProfile in [.zeehoSEPlus, .carbit] {
                let repeatedReply = try TailingProtocol.notificationReceipt(to: response, profile: profile)
                precondition(repeatedReply == nil)
            }
        }
        let carbitOnly = TailingProtocol.Control(command: 0x10430, identifier: 0xa0000100,
                                                payload: Data("synthetic notification".utf8))
        guard let extended = try TailingProtocol.notificationReceipt(to: carbitOnly, profile: .carbit) else {
            fatalError("Expected Carbit 0x10430 notification acknowledgement")
        }
        precondition(extended.count == 16 && extended.uint32LE(0) == 0x10431 && extended.uint32LE(12) == carbitOnly.identifier)
        let sePlusExcluded = try TailingProtocol.notificationReceipt(to: carbitOnly, profile: .zeehoSEPlus)
        precondition(sePlusExcluded == nil)
        let repeatedReceipt = try TailingProtocol.notificationReceipt(to: TailingProtocol.Control(command: 0x10431, identifier: 1, payload: Data()),
                                                                      profile: .carbit)
        precondition(repeatedReceipt == nil)
        for command: UInt32 in [0x103b1, 0x103b2, 0x10600, 0x10450, 0x10790, 0x20000, 0x70000000, 0x80000010, 0xfffffff0] {
            let request = TailingProtocol.Control(command: command, identifier: 1, payload: Data())
            for profile: TailingDisplayProfile in [.zeehoSEPlus, .carbit] {
                let acknowledgement = try TailingProtocol.notificationReceipt(to: request, profile: profile)
                precondition(acknowledgement == nil)
            }
        }
        precondition(TailingError.protocolFailure("test").localizedDescription.contains("PXC"))
        print("PASS: Carbit 0x103a0/0x10020/0x10430 and five SE+ notification receipts, profile isolation, identifiers, empty payloads and reply-loop exclusion")
    }
}

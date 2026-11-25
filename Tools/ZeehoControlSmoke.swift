import Foundation

@main
struct ZeehoControlSmoke {
    static func main() throws {
        let commands: [UInt32] = [0x103b0, 0x103a0, 0x10470, 0x104a0, 0x10020]
        for (index, command) in commands.enumerated() {
            let identifier = UInt32(0xa0000000 + index)
            let request = TailingProtocol.Control(command: command, identifier: identifier,
                                                  payload: Data("synthetic notification".utf8))
            guard let encoded = try TailingProtocol.zeehoExtensionReply(to: request, profile: .zeehoSEPlus) else {
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
            for otherProfile: TailingDisplayProfile in [.zeeho62, .tailing43] {
                let excluded = try TailingProtocol.zeehoExtensionReply(to: request, profile: otherProfile)
                precondition(excluded == nil)
            }
            let repeatedReply = try TailingProtocol.zeehoExtensionReply(to: response, profile: .zeehoSEPlus)
            precondition(repeatedReply == nil)
        }
        for command: UInt32 in [0x103b1, 0x103b2, 0x10600, 0x10450, 0x10790, 0x20000, 0x70000000, 0x80000010, 0xfffffff0] {
            let request = TailingProtocol.Control(command: command, identifier: 1, payload: Data())
            let acknowledgement = try TailingProtocol.zeehoExtensionReply(to: request, profile: .zeehoSEPlus)
            precondition(acknowledgement == nil)
        }
        precondition(TailingError.protocolFailure("test").localizedDescription.contains("PXC"))
        print("PASS: 5 SE+ notification acknowledgements, 6.2/4.3 profile isolation, identifiers, empty payloads, semantic-command and reply-loop exclusion")
    }
}

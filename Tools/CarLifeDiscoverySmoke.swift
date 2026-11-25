import Foundation
import Darwin

@main
struct CarLifeDiscoverySmoke {
    static func main() throws {
        let output = CarLifeOutput()
        output.onLog = { print($0); fflush(stdout) }
        if CommandLine.arguments.count > 1 {
            output.start(targetAddress: CommandLine.arguments[1], width: 1280, height: 720, fps: 30)
            Thread.sleep(forTimeInterval: 40)
            output.stop()
            Thread.sleep(forTimeInterval: 0.3)
            return
        }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        precondition(fd >= 0)
        defer { close(fd) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(8999).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        func query(_ text: String) -> String? {
            let data = Data(text.utf8)
            let sent = data.withUnsafeBytes { bytes in
                withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            precondition(sent == data.count)
            var bytes = [UInt8](repeating: 0, count: 2048)
            let count = recv(fd, &bytes, bytes.count, 0)
            return count >= 0 ? String(decoding: bytes.prefix(count), as: UTF8.self) : nil
        }
        output.start(targetAddress: "127.0.0.1", width: 1280, height: 720, fps: 30)
        Thread.sleep(forTimeInterval: 0.4)
        precondition(query("not a discovery") == nil)
        precondition(query("{\"carlifehost\":\"carlife\",\"status\":\"ready\"}") == nil)
        let reply = try JSONSerialization.jsonObject(with: Data(query("{\"carlifehost\":\"query\"}")!.utf8)) as! [String: String]
        precondition(reply["status"] == "ready" && reply["carlifehost"] == "carlife")
        output.stop()
        Thread.sleep(forTimeInterval: 0.3)
        output.start(targetAddress: "127.0.0.2", width: 1280, height: 720, fps: 30)
        Thread.sleep(forTimeInterval: 0.3)
        precondition(query("carlifehost") == nil, "Must reject a different explicitly selected peer")
        output.stop()
        Thread.sleep(forTimeInterval: 0.3)
        output.start(targetAddress: "127.0.0.1", width: 1280, height: 720, fps: 30)
        Thread.sleep(forTimeInterval: 0.3)
        precondition(query("carlifehost") != nil, "Restart must rebind the discovery port")
        output.stop()
        Thread.sleep(forTimeInterval: 0.3)
        print("PASS: discovery response, source filtering, unrelated packets, echo prevention and restart")
    }
}

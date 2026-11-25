import Foundation

@main
struct TailingDiscoverySmoke {
    static func main() {
        let regular = TailingDiscovery.candidates(localIP: "192.168.0.23", netmask: "255.255.255.0", previousIP: nil)
        precondition(regular.count == 253 && Set(regular).count == 253)
        precondition(regular.first == "192.168.0.1")
        precondition(!regular.contains("192.168.0.23") && !regular.contains("192.168.0.0") && !regular.contains("192.168.0.255"))

        let cached = TailingDiscovery.candidates(localIP: "192.168.0.23", netmask: "255.255.255.0", previousIP: "192.168.0.88")
        precondition(cached.first == "192.168.0.88" && Set(cached) == Set(regular))
        let foreign = TailingDiscovery.candidates(localIP: "192.168.0.23", netmask: "255.255.255.0", previousIP: "10.0.0.1")
        precondition(foreign == regular)

        let narrow = TailingDiscovery.candidates(localIP: "10.0.0.6", netmask: "255.255.255.248", previousIP: "10.0.0.7")
        precondition(Set(narrow) == Set((1...5).map { "10.0.0.\($0)" }))
        let pair = TailingDiscovery.candidates(localIP: "10.0.0.1", netmask: "255.255.255.254", previousIP: nil)
        precondition(pair == ["10.0.0.0"])

        let wide = TailingDiscovery.candidates(localIP: "10.20.3.12", netmask: "255.255.0.0", previousIP: "10.20.8.40")
        precondition(wide.first == "10.20.8.40")
        precondition(wide.contains("10.20.0.1") && wide.contains("10.20.3.1") && wide.contains("10.20.3.254"))
        precondition(wide.count <= 256 && !wide.contains("10.20.3.12"))

        for (address, mask) in [("bad", "255.255.255.0"), ("1.2.3.256", "255.255.255.0"),
                                ("1.2.3.4", "255.0.255.0"), ("1.2.3.4", "0.0.0.0"),
                                ("1.2.3.4", "255.255.255.255")] {
            precondition(TailingDiscovery.candidates(localIP: address, netmask: mask, previousIP: nil).isEmpty)
        }
        print("PASS: discovery candidates, subnet boundaries, saved-address priority, deduplication, /29, /31, wide subnet and invalid inputs")
    }
}

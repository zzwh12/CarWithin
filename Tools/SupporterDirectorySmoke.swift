import Foundation

@main struct SupporterDirectorySmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let data = try Data(contentsOf: root.appendingPathComponent("App/Support/supporters.json"))
        let directory = try SupporterDirectory.decode(data)
        precondition(directory.appContributors.map(\.name).prefix(4) == ["yiquchangge1", "武汉", "Boos4721", "扫毒单位"])
        precondition(directory.appContributors.first { $0.name == "武汉" }?.github == "yuliang-shuji")
        precondition(directory.supporters.count == 41)
        precondition(directory.supporters.first { $0.name == "正美旅行🤿海岛潜水 Ryan" }?.color == .green)
        precondition(directory.supporters.filter { $0.name == "**栋" }.count == 2)
        precondition(Set(directory.supporters.map(\.color)) == Set(SupporterDirectory.Supporter.Color.allCasesForTest))
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let people = object["supporters"] as! [[String: Any]]
        precondition(people.allSatisfy { Set($0.keys) == ["id", "name", "color"] }, "Public records must not contain payment evidence or amounts")
        precondition(!String(decoding: data, as: UTF8.self).contains("amount"))
        object["future_optional_field"] = "ignored"
        _ = try SupporterDirectory.decode(JSONSerialization.data(withJSONObject: object))
        object["supporters"] = people + [people[0]]
        do { _ = try SupporterDirectory.decode(JSONSerialization.data(withJSONObject: object)); fatalError("Accepted duplicate identifiers") }
        catch SupporterDirectory.DirectoryError.invalid { }
        object["supporters"] = people
        object["schema_version"] = 1
        do { _ = try SupporterDirectory.decode(JSONSerialization.data(withJSONObject: object)); fatalError("Accepted legacy monetary schema") }
        catch SupporterDirectory.DirectoryError.invalid { }
        print("Supporter directory: public fields, colors, duplicate handling and schema compatibility passed.")
    }
}

private extension SupporterDirectory.Supporter.Color {
    static let allCasesForTest: [Self] = [.standard, .green, .blue, .purple, .gold]
}

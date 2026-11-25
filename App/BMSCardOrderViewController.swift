import UIKit

/// Reorders visible fields without changing the selected metrics or BLE session.
final class BMSCardOrderViewController: UITableViewController {
    private var fields: [ANTBMSCardConfiguration.Field]
    private let onMove: (ANTBMSCardConfiguration.Field, Int) -> Void

    init(fields: [ANTBMSCardConfiguration.Field], onMove: @escaping (ANTBMSCardConfiguration.Field, Int) -> Void) {
        self.fields = fields; self.onMove = onMove
        super.init(style: .insetGrouped)
        title = "字段顺序"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.setEditing(true, animated: false)
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { fields.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { "已显示的字段" }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "拖动右侧手柄调整顺序，从左到右排布，超过三项自动分为两行。修改后立即生效并保存。"
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        let field = fields[indexPath.row]
        var content = cell.defaultContentConfiguration(); content.text = field.title
        cell.contentConfiguration = content
        cell.showsReorderControl = true; cell.selectionStyle = .none
        cell.accessibilityValue = "第 \(indexPath.row + 1) 项，共 \(fields.count) 项"
        cell.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "上移") { [weak self] _ in self?.move(field, offset: -1) ?? false },
            UIAccessibilityCustomAction(name: "下移") { [weak self] _ in self?.move(field, offset: 1) ?? false }
        ]
        return cell
    }
    override func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle { .none }
    override func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool { false }
    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool { fields.count > 1 }
    override func tableView(_ tableView: UITableView, moveRowAt source: IndexPath, to destination: IndexPath) {
        let field = fields.remove(at: source.row); fields.insert(field, at: destination.row)
        onMove(field, destination.row)
        tableView.reloadData()
    }
    private func move(_ field: ANTBMSCardConfiguration.Field, offset: Int) -> Bool {
        guard let source = fields.firstIndex(of: field), fields.indices.contains(source + offset) else { return false }
        fields.remove(at: source); fields.insert(field, at: source + offset)
        onMove(field, source + offset); tableView.reloadData()
        return true
    }
}

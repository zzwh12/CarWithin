import UIKit
import Photos

enum DeveloperSupport {
    static let email = "hl8380@qq.com"
    static let alipay = URL(string: "https://qr.alipay.com/fkx16608y1puemmltuocze0")!

    static func groups(in directory: SupporterDirectory?) -> [(tier: Int, people: [SupporterDirectory.Supporter])] {
        (1...5).reversed().compactMap { tier in
            let people = (directory?.supporters ?? []).filter { $0.tier == tier }
            return people.isEmpty ? nil : (tier, people)
        }
    }

    static func namesView(_ groups: [(tier: Int, people: [SupporterDirectory.Supporter])]) -> UIStackView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 14
        for group in groups {
            let label = UILabel()
            label.font = .preferredFont(forTextStyle: .body)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = color(for: group.tier)
            label.numberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            // WORD JOINER keeps a nickname together; spaces between names are the wrap opportunities.
            let names = group.people.map { $0.name.map(String.init).joined(separator: "\u{2060}") }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 8
            label.attributedText = NSAttributedString(string: names.joined(separator: "    "), attributes: [
                .font: UIFont.preferredFont(forTextStyle: .body),
                .foregroundColor: color(for: group.tier),
                .paragraphStyle: paragraph
            ])
            label.accessibilityLabel = group.people.map(\.name).joined(separator: "，")
            stack.addArrangedSubview(label)
        }
        return stack
    }

    static func contact(from controller: UIViewController) {
        let sheet = UIAlertController(title: CWL("联系作者"), message: email, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: CWL("发送邮件"), style: .default) { _ in
            composeEmail(from: controller)
        })
        sheet.addAction(UIAlertAction(title: CWL("复制邮箱"), style: .default) { _ in
            UIPasteboard.general.string = email
            let notice = UIAlertController(title: CWL("已复制邮箱"), message: email, preferredStyle: .alert)
            notice.addAction(UIAlertAction(title: CWL("好"), style: .default))
            controller.present(notice, animated: true)
        })
        sheet.addAction(UIAlertAction(title: CWL("取消"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = controller.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.maxY - 80, width: 1, height: 1)
        controller.present(sheet, animated: true)
    }

    static func composeEmail(from controller: UIViewController) {
        var url = URLComponents()
        url.scheme = "mailto"; url.path = email
        url.queryItems = [URLQueryItem(name: "subject", value: CWL("赞赏名单修改或核对"))]
        guard let address = url.url else { return }
        UIApplication.shared.open(address) { opened in
            guard !opened else { return }
            DispatchQueue.main.async { contact(from: controller) }
        }
    }

    static func color(for tier: Int) -> UIColor {
        switch tier {
        case 5: return UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.94, green: 0.76, blue: 0.36, alpha: 1) : UIColor(red: 0.48, green: 0.32, blue: 0.04, alpha: 1) }
        case 4: return UIColor { $0.userInterfaceStyle == .dark ? .systemPurple : UIColor(red: 0.49, green: 0.23, blue: 0.68, alpha: 1) }
        case 3: return .systemBlue
        case 2: return UIColor { $0.userInterfaceStyle == .dark ? .systemGreen : UIColor(red: 0.12, green: 0.43, blue: 0.23, alpha: 1) }
        default: return .label
        }
    }
}

final class ContributionsViewController: UITableViewController {
    private let store = SupporterDirectoryStore()
    private var refreshTask: Task<Void, Never>?
    private var groups: [(tier: Int, people: [SupporterDirectory.Supporter])] = []
    private var directory: SupporterDirectory? { store.directory }

    init() { super.init(style: .insetGrouped); title = CWL("赞赏与支持") }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { refreshTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "info.circle"), style: .plain,
                                                           target: self, action: #selector(showInformation))
        navigationItem.rightBarButtonItem?.accessibilityLabel = CWL("名单说明")
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 56
        tableView.cellLayoutMarginsFollowReadableWidth = true
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(refreshDirectory), for: .valueChanged)
        rebuild()
        refreshDirectory()
    }

    private func rebuild() {
        groups = DeveloperSupport.groups(in: directory)
        tableView.reloadData()
    }

    @objc private func refreshDirectory() {
        guard refreshTask == nil else { refreshControl?.endRefreshing(); return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            if await store.refresh() { rebuild() }
            refreshControl?.endRefreshing()
            refreshTask = nil
        }
    }
    @objc private func showInformation() { navigationController?.pushViewController(SupportInformationViewController(), animated: true) }

    override func numberOfSections(in tableView: UITableView) -> Int { 4 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 1 { return max(1, directory?.appContributors.count ?? 0) }
        return 1
    }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 1: return CWL("开发与测试贡献")
        case 2: return CWL("感谢赞赏支持")
        default: return nil
        }
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 2 { return CWL("作者旗下多个项目共用这份赞赏名单，感谢大家对开发与维护的支持。") }
        if section == 3 {
            return CWL("名单更新于 {1}。昵称有误、漏登或需要匿名、移除，可通过邮箱联系作者。", [directory?.updatedAt ?? "—"])
        }
        return nil
    }

    private func namesCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        let names = DeveloperSupport.namesView(groups)
        names.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(names)
        let margins = cell.contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            names.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            names.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            names.topAnchor.constraint(equalTo: margins.topAnchor, constant: 8),
            names.bottomAnchor.constraint(equalTo: margins.bottomAnchor, constant: -8)
        ])
        return cell
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory ||
            previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            tableView.reloadData()
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let section = indexPath.section
        if section == 2 { return namesCell() }
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        var content = cell.defaultContentConfiguration()
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.numberOfLines = 0
        if section == 0 {
            content.image = UIImage(systemName: "heart.circle.fill")
            content.imageProperties.tintColor = .systemOrange
            content.text = CWL("感谢每一位同行者")
            content.textProperties.font = .preferredFont(forTextStyle: .headline)
            content.secondaryText = CWL("一起让更多车型用上 CarPlay。感谢大家的代码、适配测试、资料与赞赏支持。")
        } else if section == 1 {
            let people = directory?.appContributors ?? []
            if people.isEmpty {
                content.text = CWL("致谢名单持续整理中")
                content.secondaryText = CWL("感谢帮助优化代码、适配车型、实车测试和提供资料的朋友。")
                content.textProperties.color = .secondaryLabel
            } else {
                let person = people[indexPath.row]
                if person.github != nil { cell.accessoryType = .disclosureIndicator; cell.selectionStyle = .default }
                content.text = person.github.map { person.name == $0 ? person.name : "\(person.name) · @\($0)" } ?? person.name
                content.secondaryText = people[indexPath.row].contribution
            }
        } else {
            content.text = CWL("联系作者")
            content.secondaryText = DeveloperSupport.email
            content.image = UIImage(systemName: "envelope")
            content.imageProperties.tintColor = .systemBlue
            cell.accessoryType = .disclosureIndicator; cell.selectionStyle = .default
        }
        cell.contentConfiguration = content
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 1, let people = directory?.appContributors,
           people.indices.contains(indexPath.row), let login = people[indexPath.row].github,
           login.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil,
           let url = URL(string: "https://github.com/\(login)") { UIApplication.shared.open(url) }
        if indexPath.section == 3 { DeveloperSupport.contact(from: self) }
    }
}

final class SupportInformationViewController: UITableViewController {
    private let rules: [(String, String, String, UIColor)] = [
        (CWL("展示昵称"), CWL("优先使用备注昵称。未备注时，微信使用赞赏昵称，支付宝使用脱敏姓名。"), "person.text.rectangle", .systemBlue),
        (CWL("匿名或不上名单"), CWL("备注「匿名」隐藏昵称；备注「不上名单」不展示。也可通过邮件修改或移除。"), "hand.raised.fill", .systemTeal),
        (CWL("累计与颜色"), CWL("昵称颜色按累计赞赏金额区分，仅用于表达感谢，不展示具体金额。"), "paintpalette.fill", .systemPurple)
    ]
    init() { super.init(style: .insetGrouped); title = CWL("名单说明") }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 100
    }
    override func numberOfSections(in tableView: UITableView) -> Int { 3 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 1 ? rules.count : 1 }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 1 ? CWL("昵称与展示") : section == 2 ? CWL("修改、补登与核对") : nil
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 1 { return CWL("赞赏自愿，不影响软件使用或适配安排。") }
        if section == 2 { return CWL("名单定期整理；离线设备可能稍后同步。") }
        return nil
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        if indexPath.section == 2 {
            let note = UILabel()
            note.text = CWL("请说明当前昵称和修改内容。漏登、累计有误或需要合并时，可提供支付截图或订单号，并遮挡无关信息。")
            note.font = .preferredFont(forTextStyle: .subheadline); note.textColor = .secondaryLabel
            note.numberOfLines = 0; note.adjustsFontForContentSizeCategory = true
            let address = UILabel(); address.text = DeveloperSupport.email
            address.font = .preferredFont(forTextStyle: .headline); address.adjustsFontForContentSizeCategory = true
            address.textColor = .label
            var sendConfig = UIButton.Configuration.tinted()
            sendConfig.title = CWL("发送邮件"); sendConfig.image = UIImage(systemName: "envelope")
            sendConfig.imagePadding = 6; sendConfig.cornerStyle = .capsule
            let send = UIButton(configuration: sendConfig, primaryAction: UIAction { [weak self] _ in
                guard let self else { return }; DeveloperSupport.composeEmail(from: self)
            })
            var copyConfig = UIButton.Configuration.gray()
            copyConfig.title = CWL("复制邮箱"); copyConfig.image = UIImage(systemName: "doc.on.doc")
            copyConfig.imagePadding = 6; copyConfig.cornerStyle = .capsule
            let copy = UIButton(configuration: copyConfig, primaryAction: UIAction { [weak self] _ in
                UIPasteboard.general.string = DeveloperSupport.email
                let alert = UIAlertController(title: CWL("已复制邮箱"), message: DeveloperSupport.email, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: CWL("好"), style: .default)); self?.present(alert, animated: true)
            })
            let buttons = UIStackView(arrangedSubviews: [send, copy])
            buttons.axis = .horizontal; buttons.spacing = 10; buttons.distribution = .fillEqually
            send.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            let stack = UIStackView(arrangedSubviews: [address, note, buttons])
            stack.axis = .vertical; stack.spacing = 14; stack.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
                stack.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 18),
                stack.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -18)
            ])
            return cell
        }
        var content = cell.defaultContentConfiguration()
        content.textProperties.font = .preferredFont(forTextStyle: .headline)
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.numberOfLines = 0
        content.textToSecondaryTextVerticalPadding = 6
        content.directionalLayoutMargins.top = 16; content.directionalLayoutMargins.bottom = 16
        if indexPath.section == 0 {
            content.text = CWL("每一份支持，都值得感谢")
            content.secondaryText = CWL("这份名单由作者旗下多个项目共用，感谢你帮助项目持续改进。")
            content.image = SettingsIcon.image("heart.fill", .systemOrange)
        } else {
            let rule = rules[indexPath.row]
            content.text = rule.0; content.secondaryText = rule.1
            content.image = SettingsIcon.image(rule.2, rule.3)
        }
        cell.contentConfiguration = content
        return cell
    }
}

/// Offline payment cards and the same compact list used by the About page.
final class DeveloperSupportViewController: UITableViewController {
    private var savingQRCode = false
    private let openAlipayOnEntry: Bool
    private static let didAutoOpenAlipayKey = "DeveloperSupport.didAutoOpenAlipay"
    private let store = SupporterDirectoryStore()
    private var refreshTask: Task<Void, Never>?

    init(openAlipayOnEntry: Bool = true) {
        self.openAlipayOnEntry = openAlipayOnEntry
        super.init(style: .insetGrouped)
        title = CWL("请我喝杯咖啡")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { refreshTask?.cancel() }
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 180
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "info.circle"), style: .plain,
            target: self, action: #selector(showInformation))
        navigationItem.rightBarButtonItem?.accessibilityLabel = CWL("名单说明")
        refreshTask = Task { [weak self] in
            guard let self else { return }
            if await store.refresh() { tableView.reloadData() }
            refreshTask = nil
        }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Only the first coffee-entry visit opens Alipay automatically, including across app launches.
        if openAlipayOnEntry && !UserDefaults.standard.bool(forKey: Self.didAutoOpenAlipayKey) {
            UserDefaults.standard.set(true, forKey: Self.didAutoOpenAlipayKey)
            openAlipay()
        }
    }
    @objc private func showInformation() { navigationController?.pushViewController(SupportInformationViewController(), animated: true) }
    override func numberOfSections(in tableView: UITableView) -> Int { 3 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 1 }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 2 ? CWL("感谢赞赏支持") : nil
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 2 ? CWL("作者旗下多个项目共用这份赞赏名单，感谢大家对开发与维护的支持。") : nil
    }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory ||
            previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle { tableView.reloadData() }
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        if indexPath.section == 0 {
            var content = cell.defaultContentConfiguration()
            content.text = CWL("感谢你对开发与维护的支持")
            content.textProperties.font = .preferredFont(forTextStyle: .headline)
            content.textProperties.numberOfLines = 0
            content.secondaryText = CWL("赞赏完全自愿，感谢每一份心意。")
            content.secondaryTextProperties.numberOfLines = 0
            cell.contentConfiguration = content
            return cell
        }
        let custom: UIView
        if indexPath.section == 1 {
            let cards = UIStackView(arrangedSubviews: [paymentCard(wechat: true), paymentCard(wechat: false)])
            cards.axis = .horizontal; cards.spacing = 12; cards.distribution = .fillEqually
            custom = cards
            cell.backgroundColor = .clear
        } else { custom = DeveloperSupport.namesView(DeveloperSupport.groups(in: store.directory)) }
        custom.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(custom)
        let inset: CGFloat = indexPath.section == 1 ? 0 : 20
        NSLayoutConstraint.activate([
            custom.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: inset),
            custom.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -inset),
            custom.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: inset),
            custom.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -inset)
        ])
        return cell
    }

    private func paymentCard(wechat: Bool) -> UIView {
        let card = UIView()
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 20; card.layer.cornerCurve = .continuous
        let color: UIColor = wechat ? .systemGreen : .systemBlue
        let title = UILabel()
        title.text = wechat ? CWL("微信赞赏") : CWL("支付宝")
        title.font = .preferredFont(forTextStyle: .headline); title.adjustsFontForContentSizeCategory = true
        title.textAlignment = .center; title.numberOfLines = 0
        let image = UIImageView(image: UIImage(named: wechat ? "support-wechat.png" : "support-alipay.png"))
        image.contentMode = .scaleAspectFit; image.backgroundColor = .white
        image.layer.cornerRadius = 12; image.clipsToBounds = true
        image.translatesAutoresizingMaskIntoConstraints = false
        image.heightAnchor.constraint(equalTo: image.widthAnchor).isActive = true
        image.isAccessibilityElement = true
        image.accessibilityLabel = wechat ? CWL("微信赞赏码") : CWL("支付宝收款码")
        image.isUserInteractionEnabled = true
        image.tag = wechat ? 1 : 0
        image.accessibilityTraits.insert(.button)
        image.accessibilityHint = wechat ? CWL("轻点保存，长按确认保存") : CWL("轻点打开支付宝")
        let tap = UITapGestureRecognizer(target: self, action: #selector(tappedQRCode(_:)))
        if wechat {
            let hold = UILongPressGestureRecognizer(target: self, action: #selector(heldQRCode(_:)))
            tap.require(toFail: hold)
            image.addGestureRecognizer(hold)
        }
        image.addGestureRecognizer(tap)
        var configuration = UIButton.Configuration.tinted()
        configuration.title = wechat ? CWL("保存赞赏码") : CWL("打开支付宝")
        configuration.image = UIImage(systemName: wechat ? "arrow.down.to.line" : "arrow.up.right")
        configuration.imagePadding = 5
        configuration.baseForegroundColor = color
        configuration.baseBackgroundColor = color
        configuration.cornerStyle = .capsule
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var result = incoming; result.font = UIFont.preferredFont(forTextStyle: .subheadline); return result
        }
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            if wechat { self?.saveQRCode() } else { self?.openAlipay() }
        })
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        let stack = UIStackView(arrangedSubviews: [title, image, button])
        stack.axis = .vertical; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14)
        ])
        return card
    }

    @objc private func tappedQRCode(_ gesture: UITapGestureRecognizer) {
        if gesture.view?.tag == 1 { saveQRCode() } else { openAlipay() }
    }

    @objc private func heldQRCode(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        guard gesture.view?.tag == 1 else { return }
        let prompt = UIAlertController(title: CWL("保存二维码图片？"),
            message: CWL("保存到系统相册，方便稍后在支付应用中扫码。"), preferredStyle: .alert)
        prompt.addAction(UIAlertAction(title: CWL("取消"), style: .cancel))
        prompt.addAction(UIAlertAction(title: CWL("保存到相册"), style: .default) { [weak self] _ in self?.saveQRCode() })
        present(prompt, animated: true)
    }

    private func openAlipay() {
        UIApplication.shared.open(DeveloperSupport.alipay) { [weak self] opened in
            guard !opened else { return }
            DispatchQueue.main.async {
                self?.showNotice(CWL("未能打开支付宝"), CWL("请稍后重试，也可以使用支付宝扫描上方收款码。"))
            }
        }
    }

    private func saveQRCode() {
        guard !savingQRCode, let image = UIImage(named: "support-wechat.png") else { return }
        savingQRCode = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { savingQRCode = false }
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                let prompt = UIAlertController(title: CWL("需要保存照片的权限"),
                    message: CWL("请在系统设置中允许 CarWithin 添加照片，然后重试。"), preferredStyle: .alert)
                prompt.addAction(UIAlertAction(title: CWL("取消"), style: .cancel))
                prompt.addAction(UIAlertAction(title: CWL("打开设置"), style: .default) { _ in
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                })
                present(prompt, animated: true)
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAsset(from: image) }
                showNotice(CWL("已保存到相册"), CWL("可在微信「扫一扫」中从相册选择这张赞赏码。"))
            } catch {
                showNotice(CWL("保存失败"), CWL("请稍后重试，或检查相册权限及可用存储空间。"))
            }
        }
    }

    private func showNotice(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: CWL("好"), style: .default))
        present(alert, animated: true)
    }

}

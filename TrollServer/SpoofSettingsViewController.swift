import UIKit

/// 设备伪装设置页：开关 + 目标 iPad 型号选择。
/// 改动只写入共享配置，真正生效需要 QQ / 微信“重启”（杀进程后重新打开）。
class SpoofSettingsViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    // 可选 iPad 型号（标识符 + 展示名）
    private let models: [(id: String, name: String)] = [
        ("iPad14,2",  "iPad Pro 11-inch (3rd gen)"),
        ("iPad14,3",  "iPad Pro 12.9-inch (5th gen)"),
        ("iPad13,1",  "iPad Air (4th gen)"),
        ("iPad13,16", "iPad Air (5th gen)"),
        ("iPad12,1",  "iPad (10th gen)"),
        ("iPad11,6",  "iPad (9th gen)"),
        ("iPad11,1",  "iPad mini (5th gen)"),
        ("iPad7,11",  "iPad (10.2-inch)"),
    ]

    private let switchView = UISwitch()
    private let tableView  = UITableView(frame: .zero, style: .insetGrouped)
    private let tipLabel   = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "设备伪装 (iPad)"
        view.backgroundColor = .systemGroupedBackground
        setupNav()
        setupUI()
        syncUI()
    }

    private func setupNav() {
        navigationItem.leftBarButtonItem =
            UIBarButtonItem(barButtonSystemItem: .done, target: self,
                            action: #selector(done))
    }

    private func setupUI() {
        // 开关行
        switchView.addTarget(self, action: #selector(toggleChanged), for: .valueChanged)
        let switchRow = UIStackView(arrangedSubviews: [
            label("启用 iPad 伪装"),
            switchView,
        ])
        switchRow.axis = .horizontal
        switchRow.distribution = .equalSpacing
        switchRow.translatesAutoresizingMaskIntoConstraints = false

        // 表格
        tableView.dataSource = self
        tableView.delegate   = self
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")

        // 提示
        tipLabel.numberOfLines = 0
        tipLabel.font = UIFont.systemFont(ofSize: 12)
        tipLabel.textColor = .secondaryLabel
        tipLabel.text = "⚠️ 本设置仅对“已注入 libiPadSpoof.dylib 且通过 TrollStore 安装的 QQ / 微信”生效。\n修改后请彻底关闭并重开对应 App。TrollStore 无法全局修改系统，需分别注入每个目标 App。"
        tipLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [switchRow, tableView, tipLabel])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            tableView.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.5),
        ])
    }

    private func label(_ text: String) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        return l
    }

    private func syncUI() {
        switchView.isOn = SpoofConfig.isEnabled
    }

    // MARK: - 交互

    @objc private func done() { dismiss(animated: true) }

    @objc private func toggleChanged() {
        SpoofConfig.isEnabled = switchView.isOn
        tableView.reloadData()
    }

    // MARK: - UITableView

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        models.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        "目标 iPad 型号"
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let m = models[indexPath.row]
        cell.textLabel?.text = "\(m.name)"
        cell.detailTextLabel?.text = m.id
        cell.detailTextLabel?.textColor = .tertiaryLabel
        let selected = SpoofConfig.productType == m.id
        cell.accessoryType = selected ? .checkmark : .none
        cell.selectionStyle = .default
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let m = models[indexPath.row]
        SpoofConfig.productType = m.id
        tableView.reloadData()
    }
}

import Velora
import UIKit

final class KeyboardViewController: UIInputViewController {
    private let store = KeyboardBridgeStore.defaultStore()
    private let statusLabel = UILabel()
    private let insertButton = UIButton(type: .system)
    private let refreshButton = UIButton(type: .system)
    private let openAppButton = UIButton(type: .system)
    private var latestPayload: KeyboardBridgePayload?

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        reloadCandidate()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadCandidate()
    }

    private func configureView() {
        view.backgroundColor = .veloraBackground

        statusLabel.font = .preferredFont(forTextStyle: .callout)
        statusLabel.numberOfLines = 2
        statusLabel.textColor = .veloraInkSecondary

        insertButton.setTitle("插入最近结果", for: .normal)
        insertButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        insertButton.tintColor = .veloraAccent
        insertButton.addTarget(self, action: #selector(insertCandidate), for: .touchUpInside)

        refreshButton.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
        refreshButton.accessibilityLabel = "刷新候选"
        refreshButton.tintColor = .veloraAccent
        refreshButton.addTarget(self, action: #selector(refreshCandidate), for: .touchUpInside)

        openAppButton.setImage(UIImage(systemName: "waveform"), for: .normal)
        openAppButton.accessibilityLabel = "打开 Velora"
        openAppButton.tintColor = .veloraAccent
        openAppButton.addTarget(self, action: #selector(openContainingApp), for: .touchUpInside)

        let buttonRow = UIStackView(arrangedSubviews: [insertButton, refreshButton, openAppButton])
        buttonRow.axis = .horizontal
        buttonRow.alignment = .center
        buttonRow.spacing = 10
        refreshButton.widthAnchor.constraint(equalToConstant: 40).isActive = true
        openAppButton.widthAnchor.constraint(equalToConstant: 40).isActive = true

        let stack = UIStackView(arrangedSubviews: [statusLabel, buttonRow])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -10),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 108),
        ])
    }

    private func reloadCandidate() {
        do {
            latestPayload = try store.loadLatestPayload()
            renderCandidate()
        } catch {
            latestPayload = nil
            statusLabel.text = "候选读取失败：\(error)"
            insertButton.isEnabled = false
        }
    }

    private func renderCandidate() {
        guard let latestPayload else {
            statusLabel.text = "没有待插入结果。打开主 App 录音或翻译后再回来。"
            insertButton.isEnabled = false
            return
        }

        let prefix = latestPayload.isTranslation ? "翻译" : latestPayload.mode.rawValue
        let preview = latestPayload.insertText
            .split(whereSeparator: \.isNewline)
            .prefix(2)
            .joined(separator: " ")

        // Low-confidence results honor the same review contract as the Mac
        // path: no one-tap insertion of text the pipeline flagged.
        if latestPayload.needsReview {
            statusLabel.text = "⚠️ 低置信结果，请回主 App 确认后重新生成：\(preview)"
            insertButton.isEnabled = false
            return
        }

        statusLabel.text = "\(prefix)：\(preview)"
        insertButton.isEnabled = true
    }

    @objc private func insertCandidate() {
        guard let latestPayload else {
            reloadCandidate()
            return
        }

        textDocumentProxy.insertText(latestPayload.insertText)
        store.clear()
        self.latestPayload = nil
        renderCandidate()
    }

    @objc private func refreshCandidate() {
        reloadCandidate()
    }

    @objc private func openContainingApp() {
        guard let url = URL(string: "velora://record") else {
            return
        }

        extensionContext?.open(url)
    }
}

import AppKit

/// A simple solid panel shown over the page when it can't be loaded.
@MainActor
final class ErrorView: NSView {
    private let background = SolidView(color: Theme.background)
    private let titleLabel = NSTextField(labelWithString: "This page couldn't be opened")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.textColor = Theme.text
        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.textColor = Theme.mutedText
        messageLabel.alignment = .center
        messageLabel.preferredMaxLayoutWidth = 420

        let stack = NSStackView(views: [titleLabel, messageLabel])
        stack.orientation = .vertical
        stack.spacing = 8
        for v in [background, stack] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -40),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(message: String, address: String) {
        messageLabel.stringValue = address.isEmpty ? message : "\(address): \(message)\n\nPress Cmd+R to try again."
        isHidden = false
    }
}

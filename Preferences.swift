//
// User-visible choices and where they are kept.
//
// The `launcher` script stays the single source of truth for how a choice turns
// into a running instance; this file only decides what to ask for, remembers the
// answer, and hands it over as command-line arguments.
//

import AppKit

// MARK: - Backend

/// Which dsh the launcher script should boot.
enum Backend: String, CaseIterable {
    /// The user's own dsh install.
    case stock
    /// dsh-mfw: a patched dsh where one workspace can hold several folders.
    case mfw

    var title: String {
        switch self {
        case .stock: return "原版 DSH"
        case .mfw: return "多文件夹工作区（dsh-mfw）"
        }
    }

    var summary: String {
        switch self {
        case .stock:
            return "启动你自己安装的 dsh。行为与在终端里跑 dsh web 完全一致。"
        case .mfw:
            return "启动 dsh-mfw：它准备一棵打了补丁的 dsh 运行时，让一个工作区可以"
                + "包含多个分散的文件夹。首次启动需要联网，约 300 MB。"
        }
    }

    var repoURL: String {
        switch self {
        case .stock: return "https://github.com/deepseek-ai/deepseek-harness"
        case .mfw: return "https://github.com/Boy-Grid/dsh-multi-folder-workspace"
        }
    }

    /// Stated wherever mfw can be turned on. The multi-folder feature widens
    /// what an agent may write, which is a change in security semantics rather
    /// than a convenience — so it is never implied, only spelled out.
    static let mfwWarning = """
        多文件夹工作区会扩大 Agent 的写面：工作区内的会话可以写入全部成员文件夹，\
        而不只是它自己的工作目录。请自行评估这个取舍。
        """
}

// MARK: - Preferences

/// UserDefaults-backed settings. Deliberately small — anything the launcher
/// script can already decide for itself is not duplicated here.
final class Preferences {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let backend = "backend"
        static let dshHome = "dshHome"
        static let backendChosen = "backendChosen"
        static let tabs = "tabs"
    }

    private init() {}

    /// Defaults to stock: mfw is opt-in, see `Backend.mfwWarning`.
    var backend: Backend {
        get { Backend(rawValue: defaults.string(forKey: Key.backend) ?? "") ?? .stock }
        set { defaults.set(newValue.rawValue, forKey: Key.backend) }
    }

    /// nil means "whatever a plain dsh would use" — the launcher resolves it.
    var dshHome: String? {
        get { nonEmpty(defaults.string(forKey: Key.dshHome)) }
        set { defaults.set(nonEmpty(newValue), forKey: Key.dshHome) }
    }

    /// Whether the first-run question has been answered. Asked once, then never
    /// again — the setting stays reachable in Preferences.
    var backendChosen: Bool {
        get { defaults.bool(forKey: Key.backendChosen) }
        set { defaults.set(newValue, forKey: Key.backendChosen) }
    }

    /// The tabs to restore on the next launch, in chronological order.
    var tabs: [TabRecord] {
        get {
            guard let data = defaults.data(forKey: Key.tabs) else { return [] }
            return (try? JSONDecoder().decode([TabRecord].self, from: data)) ?? []
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.tabs)
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }
}

// MARK: - Shared bits of UI

/// A label whose text can carry links.
private func linkLabel(_ text: String, url: String) -> NSTextField {
    let field = NSTextField(labelWithAttributedString: NSAttributedString(
        string: text,
        attributes: [.link: url, .font: NSFont.systemFont(ofSize: 11)]))
    field.allowsEditingTextAttributes = true
    field.isSelectable = true
    return field
}

private func bodyLabel(_ text: String, size: CGFloat = 11, width: CGFloat = 380) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.font = .systemFont(ofSize: size)
    field.textColor = .secondaryLabelColor
    field.preferredMaxLayoutWidth = width
    field.isSelectable = false
    return field
}

// MARK: - First run

/// The one-time question about which backend to boot.
///
/// Asked before the first instance is started, so the answer does not cost a
/// stop/start cycle. Both projects are linked, because the honest answer to
/// "which should I pick" is "read what they do".
enum FirstRunPrompt {
    static func ask() -> Backend {
        let alert = NSAlert()
        alert.messageText = "选择要启动的 DSH"
        alert.informativeText = "这个选择随时可以在「DSH Desktop → 偏好设置」里改。"
        alert.addButton(withTitle: "使用原版 DSH")
        alert.addButton(withTitle: "使用多文件夹工作区")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        for backend in Backend.allCases {
            let title = NSTextField(labelWithString: backend.title)
            title.font = .systemFont(ofSize: 12, weight: .semibold)
            stack.addView(title, in: .top)
            stack.addView(bodyLabel(backend.summary), in: .top)
            stack.addView(linkLabel("项目主页", url: backend.repoURL), in: .top)
        }

        let warning = bodyLabel("⚠︎ " + Backend.mfwWarning)
        warning.textColor = .labelColor
        stack.addView(warning, in: .top)

        stack.frame = NSRect(x: 0, y: 0, width: 380,
                             height: stack.fittingSize.height)
        alert.accessoryView = stack

        let choice: Backend = alert.runModal() == .alertFirstButtonReturn ? .stock : .mfw
        Preferences.shared.backend = choice
        Preferences.shared.backendChosen = true
        return choice
    }
}

// MARK: - Preferences window

/// A small settings window: which backend, and which DSH home. Both require the
/// served instance to be restarted, so the controller reports the change and
/// lets the Agent decide what to do about it.
final class PreferencesWindowController: NSWindowController {
    /// Called when a change requires the instance to be restarted.
    var onRestartNeeded: (() -> Void)?
    /// Called when the user declines the restart.
    var onChanged: (() -> Void)?

    private let backendPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let homeField = NSTextField(string: "")
    private let mfwNote = bodyLabel("", width: 420)

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "偏好设置"
        self.init(window: window)
        window.contentView = buildContent()
        window.center()
    }

    private func buildContent() -> NSView {
        let root = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20),
        ])

        // --- backend ---
        stack.addView(sectionTitle("启动哪个 DSH"), in: .top)
        for backend in Backend.allCases {
            backendPopup.addItem(withTitle: backend.title)
            backendPopup.lastItem?.representedObject = backend.rawValue
        }
        backendPopup.selectItem(at: Backend.allCases.firstIndex(of: Preferences.shared.backend) ?? 0)
        backendPopup.target = self
        backendPopup.action = #selector(backendPicked)
        stack.addView(backendPopup, in: .top)

        let links = NSStackView()
        links.orientation = .horizontal
        links.spacing = 12
        links.addView(linkLabel("原版 DSH 仓库", url: Backend.stock.repoURL), in: .leading)
        links.addView(linkLabel("多文件夹工作区仓库", url: Backend.mfw.repoURL), in: .leading)
        stack.addView(links, in: .top)

        stack.addView(mfwNote, in: .top)

        // --- DSH home ---
        stack.addView(sectionTitle("DSH home（会话与凭据）"), in: .top)
        stack.addView(pathRow(field: homeField,
                              value: Preferences.shared.dshHome,
                              placeholder: "默认：~/.dsh",
                              pick: #selector(pickHome),
                              clear: #selector(clearHome)), in: .top)
        stack.addView(bodyLabel("两个后端默认共享同一个 home，会话与凭据互相可见。"
                                + "当 dsh-mfw 的基线与已安装的 dsh 版本错开时，"
                                + "必须在这里指定一个独立目录才能启动 mfw。", width: 420), in: .top)

        updateMFWNote()
        return root
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12, weight: .semibold)
        return field
    }

    private func pathRow(field: NSTextField, value: String?, placeholder: String,
                         pick: Selector, clear: Selector) -> NSView {
        field.stringValue = value ?? ""
        field.placeholderString = placeholder
        field.isEditable = false
        field.isSelectable = true
        field.font = .systemFont(ofSize: 11)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let choose = NSButton(title: "选择…", target: self, action: pick)
        let reset = NSButton(title: "用默认", target: self, action: clear)
        for button in [choose, reset] { button.bezelStyle = .rounded }
        let row = NSStackView(views: [field, choose, reset])
        row.orientation = .horizontal
        row.spacing = 8
        field.widthAnchor.constraint(greaterThanOrEqualTo: row.widthAnchor, multiplier: 0.5).isActive = true
        return row
    }

    private func updateMFWNote() {
        let isMFW = selectedBackend == .mfw
        mfwNote.stringValue = isMFW ? "⚠︎ " + Backend.mfwWarning : Backend.stock.summary
        mfwNote.textColor = isMFW ? .labelColor : .secondaryLabelColor
    }

    private var selectedBackend: Backend {
        guard let raw = backendPopup.selectedItem?.representedObject as? String,
              let backend = Backend(rawValue: raw) else { return .stock }
        return backend
    }

    // MARK: actions

    @objc private func backendPicked() {
        let chosen = selectedBackend
        updateMFWNote()
        guard chosen != Preferences.shared.backend else { return }
        Preferences.shared.backend = chosen
        Preferences.shared.backendChosen = true
        requestRestart(reason: "切换后端需要停止当前实例并以 \(chosen.title) 重新启动。")
    }

    @objc private func pickHome() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        homeField.stringValue = url.path
        Preferences.shared.dshHome = url.path
        requestRestart(reason: "改变 DSH home 需要重新启动实例。")
    }

    @objc private func clearHome() {
        homeField.stringValue = ""
        Preferences.shared.dshHome = nil
        requestRestart(reason: "改变 DSH home 需要重新启动实例。")
    }

    private func requestRestart(reason: String) {
        let alert = NSAlert()
        alert.messageText = "需要重启实例"
        alert.informativeText = reason + "\n\n已打开的标签会重新加载。"
        alert.addButton(withTitle: "现在重启")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            onRestartNeeded?()
        } else {
            onChanged?()
        }
    }
}

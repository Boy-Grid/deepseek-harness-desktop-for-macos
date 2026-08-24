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

// MARK: - Network exposure

/// The rules and the wording for letting dsh listen somewhere other than
/// loopback.
///
/// This is the one setting in the app that can change who is able to use the
/// machine, so the consequence is spelled out rather than hinted at: the
/// DeepSeek Harness web UI ships no authentication of any kind. Its
/// `--trusted-host` fence validates the Host header (a defence against DNS
/// rebinding); it does not ask anyone who they are. Reachable therefore means
/// operable, by whoever can route to the interface.
enum NetworkExposure {
    /// Mirrors `is_loopback` in the `launcher` script. Both copies exist because
    /// the script must decide this without the app, and the app must decide it
    /// without paying for a subprocess on every keystroke; tests/t-05-lint.sh
    /// asserts the two lists stay in step.
    static func isLoopback(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: .whitespaces).lowercased()
        return h == "localhost" || h == "::1" || h == "[::1]" || h.hasPrefix("127.")
    }

    /// Split a free-typed list of authorities on commas and whitespace.
    static func parseAuthorities(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { String($0) }
            .filter { !$0.isEmpty }
    }

    /// nil for anything that is not a usable TCP port, so the caller can refuse
    /// instead of writing a value that only fails later at bind time.
    static func normalizedPort(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let n = Int(trimmed), (1...65535).contains(n) else { return nil }
        return String(n)
    }

    static let warningTitle = "确定要让其他设备访问吗？"

    static func warning(for host: String) -> String {
        """
        绑定到 \(host) 之后，能连上这台机器该地址的人都可以直接使用 DSH，\
        不需要任何密码或令牌 —— DeepSeek Harness 的 Web 界面没有认证机制。

        这意味着同一网络里的任何人都可以让 Agent 读写你的文件、执行命令、\
        使用你已登录的凭据。「受信任主机」只校验 Host 头，用于防御 DNS 重绑定，\
        它不做访问控制。

        只有当你信任这个网络上的每一台设备时才这样做。
        """
    }
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
        static let bindHost = "bindHost"
        static let trustedHosts = "trustedHosts"
        static let port = "port"
    }

    static let defaultBindHost = "127.0.0.1"
    static let defaultPort = "3080"

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

    /// The interface dsh binds to. Loopback unless the user deliberately opened
    /// it up — see `NetworkExposure` for why that is a question worth asking.
    var bindHost: String {
        get { nonEmpty(defaults.string(forKey: Key.bindHost)) ?? Preferences.defaultBindHost }
        set { defaults.set(nonEmpty(newValue), forKey: Key.bindHost) }
    }

    /// Extra authorities for the web app's Host-header fence, one per entry.
    /// Needed when the UI is reached through a name the server does not already
    /// trust (a reverse proxy, an mDNS name), not for granting access.
    var trustedHosts: [String] {
        get { defaults.stringArray(forKey: Key.trustedHosts) ?? [] }
        set { defaults.set(NetworkExposure.parseAuthorities(newValue.joined(separator: " ")),
                           forKey: Key.trustedHosts) }
    }

    /// The port to serve on. Read at launch only: the state directory, the window
    /// title and every tab's URL are derived from it, so a change needs the app
    /// restarted rather than just the instance.
    var port: String {
        get { nonEmpty(defaults.string(forKey: Key.port)) ?? Preferences.defaultPort }
        set { defaults.set(NetworkExposure.normalizedPort(newValue), forKey: Key.port) }
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
final class PreferencesWindowController: NSWindowController, NSTextFieldDelegate {
    /// Called when a change requires the instance to be restarted.
    var onRestartNeeded: (() -> Void)?
    /// Called when the user declines the restart.
    var onChanged: (() -> Void)?
    /// Called when a change can only take effect with the whole app restarted.
    var onRelaunchNeeded: ((String) -> Void)?

    private let backendPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let homeField = NSTextField(string: "")
    private let mfwNote = bodyLabel("", width: 420)
    private let bindHostField = NSTextField(string: "")
    private let trustedField = NSTextField(string: "")
    private let portField = NSTextField(string: "")
    private let exposureNote = bodyLabel("", width: 420)

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "偏好设置"
        self.init(window: window)
        let content = buildContent()
        window.contentView = content
        // The window is not resizable and the content grew a section, so its
        // height comes from the layout rather than from a number kept in sync by
        // hand.
        content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 480, height: content.fittingSize.height))
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
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
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

        // --- network ---
        stack.addView(sectionTitle("网络访问"), in: .top)
        stack.addView(fieldRow(label: "绑定地址", field: bindHostField,
                               value: Preferences.shared.bindHost,
                               placeholder: Preferences.defaultBindHost,
                               reset: #selector(resetBindHost)), in: .top)
        stack.addView(exposureNote, in: .top)

        stack.addView(fieldRow(label: "受信任主机", field: trustedField,
                               value: Preferences.shared.trustedHosts.joined(separator: ", "),
                               placeholder: "留空即可，例：dsh.local, box:3080",
                               reset: #selector(resetTrusted)), in: .top)
        stack.addView(bodyLabel("额外允许的 Host 头，逗号分隔。只在通过反向代理或另一个域名"
                                + "访问时需要；它校验 Host 头以防 DNS 重绑定，不是访问控制。",
                                width: 420), in: .top)

        stack.addView(fieldRow(label: "端口", field: portField,
                               value: Preferences.shared.port,
                               placeholder: Preferences.defaultPort,
                               reset: #selector(resetPort)), in: .top)
        stack.addView(bodyLabel("端口决定了状态目录与每个标签的地址，改动需要重新启动应用。"
                                + "环境变量 DSH_LAUNCHER_PORT 优先于这里的设置。", width: 420), in: .top)

        updateMFWNote()
        updateExposureNote()
        return root
    }

    /// A labelled, editable one-line field with a "back to default" button.
    private func fieldRow(label: String, field: NSTextField, value: String,
                          placeholder: String, reset: Selector) -> NSView {
        let caption = NSTextField(labelWithString: label)
        caption.font = .systemFont(ofSize: 11)
        caption.alignment = .right
        caption.widthAnchor.constraint(equalToConstant: 68).isActive = true

        field.stringValue = value
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 11)
        field.delegate = self
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let button = NSButton(title: "用默认", target: self, action: reset)
        button.bezelStyle = .rounded

        let row = NSStackView(views: [caption, field, button])
        row.orientation = .horizontal
        row.spacing = 8
        field.widthAnchor.constraint(greaterThanOrEqualTo: row.widthAnchor, multiplier: 0.45).isActive = true
        return row
    }

    /// Restate the current exposure in place, so the window itself says whether
    /// this instance is private — not only the alert shown when it changed.
    private func updateExposureNote() {
        let host = Preferences.shared.bindHost
        if NetworkExposure.isLoopback(host) {
            exposureNote.stringValue = "仅这台机器可以访问。改成 0.0.0.0 会让局域网内的设备也能访问。"
            exposureNote.textColor = .secondaryLabelColor
        } else {
            exposureNote.stringValue = "⚠︎ 已对外开放：能连到 \(host) 的设备都可以直接使用 DSH，"
                + "而 DSH 没有任何认证。请只在完全信任的网络中保持这个设置。"
            exposureNote.textColor = .systemRed
        }
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

    // MARK: network actions

    /// Commit on Enter and on focus loss alike: a value typed and then clicked
    /// away from has been entered, and silently dropping it would be worse than
    /// asking about it.
    func controlTextDidEndEditing(_ note: Notification) {
        switch note.object as? NSTextField {
        case bindHostField: commitBindHost()
        case trustedField:  commitTrusted()
        case portField:     commitPort()
        default: break
        }
    }

    @objc private func resetBindHost() {
        bindHostField.stringValue = Preferences.defaultBindHost
        commitBindHost()
    }

    @objc private func resetTrusted() {
        trustedField.stringValue = ""
        commitTrusted()
    }

    @objc private func resetPort() {
        portField.stringValue = Preferences.defaultPort
        commitPort()
    }

    private func commitBindHost() {
        let typed = bindHostField.stringValue.trimmingCharacters(in: .whitespaces)
        let host = typed.isEmpty ? Preferences.defaultBindHost : typed
        guard host != Preferences.shared.bindHost else {
            bindHostField.stringValue = host
            return
        }
        // Leaving loopback is the one change here that alters who can use this
        // machine, so it needs an explicit yes, and the safe button is the
        // default one — Enter must not be enough to open the door.
        if !NetworkExposure.isLoopback(host) {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = NetworkExposure.warningTitle
            alert.informativeText = NetworkExposure.warning(for: host)
            alert.addButton(withTitle: "取消")
            alert.addButton(withTitle: "我了解，仍要开放")
            guard alert.runModal() != .alertFirstButtonReturn else {
                bindHostField.stringValue = Preferences.shared.bindHost
                return
            }
        }
        Preferences.shared.bindHost = host
        bindHostField.stringValue = host
        updateExposureNote()
        requestRestart(reason: "改变绑定地址需要停止当前实例并重新启动。")
    }

    private func commitTrusted() {
        let list = NetworkExposure.parseAuthorities(trustedField.stringValue)
        let normalized = list.joined(separator: ", ")
        guard list != Preferences.shared.trustedHosts else {
            trustedField.stringValue = normalized
            return
        }
        Preferences.shared.trustedHosts = list
        trustedField.stringValue = normalized
        requestRestart(reason: "改变受信任主机需要停止当前实例并重新启动。")
    }

    private func commitPort() {
        let typed = portField.stringValue.trimmingCharacters(in: .whitespaces)
        let source = typed.isEmpty ? Preferences.defaultPort : typed
        // Refuse rather than store something that would only fail at bind time.
        guard let port = NetworkExposure.normalizedPort(source) else {
            portField.stringValue = Preferences.shared.port
            let alert = NSAlert()
            alert.messageText = "端口无效"
            alert.informativeText = "「\(typed)」不是 1–65535 之间的端口号，设置未改动。"
            alert.addButton(withTitle: "好")
            alert.runModal()
            return
        }
        guard port != Preferences.shared.port else {
            portField.stringValue = port
            return
        }
        Preferences.shared.port = port
        portField.stringValue = port
        onRelaunchNeeded?("端口已改为 \(port)。它决定了状态目录与每个标签的地址，"
                          + "需要重新启动应用才能生效。")
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

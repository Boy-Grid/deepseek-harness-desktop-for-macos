// DSH Desktop for macOS — Launcher Agent
//
// A small AppKit process that keeps the launcher alive in the Dock while the
// DeepSeek Harness Web UI instance may run, with a unidirectional Dock->tab
// binding implemented via a system WebView instead of a browser tab:
//
//   - plain Dock icon for the app's whole lifetime (no badge);
//   - the Web UI is shown in a built-in WKWebView window (the "tab");
//   - a tab bar floats in the title bar, horizontally CENTERED, vertically
//     inset; inside the strip the layout follows the user's sketch: "+" at
//     the far LEFT, then a horizontally scrollable area whose content is
//     anchored to the RIGHT; tabs render in reversed order, so the NEWEST
//     tab sits right next to "+" and the oldest tab at the far right
//     ("从右向左排列"); the strip's trailing padding equals its top spacing;
//   - tabs support add (+, ⌘T, context menu), close (×, ⌘W, context menu) and
//     rename (double-click or context menu, inline edit); names follow the page
//     title until renamed, after which the manual name wins; closing the last
//     tab shows an empty state; up to 8 tabs;
//   - every tab is a separate WKWebView with its own PERSISTENT
//     WKWebsiteDataStore (see TabStore.swift), so several DSH sessions can be
//     worked on side by side and each tab returns to its own session after a
//     relaunch;
//   - which dsh to boot (stock or dsh-mfw), the DSH home and the working
//     directory are user choices (see Preferences.swift);
//   - closing the window does NOT quit the app and does NOT touch the
//     instance; Quit (right-click Dock icon -> Quit, or Cmd-Q) closes
//     everything and stops the instance we started ourselves;
//   - external links open in the default browser; same-origin target=_blank
//     requests open a new tab instead;
//   - single instance: LaunchServices activates this process instead of
//     launching a second one.
//
// Interaction model: the tab chip handles ALL mouse events itself in
// `mouseDown` (close glyph area → close, double-click → rename, else select).
// No gesture recognizers are used: AppKit click recognizers attached to a
// parent view intercept and swallow mouse events destined for subview
// buttons, which is why a plain NSButton inside a chip cannot work.
//
// All instance management is delegated to the `launcher` shell script next to
// this binary (start/stop/status logic stays in one place).  Environment
// overrides (DSH_LAUNCHER_PORT, DSH_LAUNCHER_STATE, DSH_HOME, ...) are
// honoured and forwarded to the script.  Without an explicit state dir, a
// non-default port gets its own per-port state dir so the CLI can run several
// instances side by side.

import AppKit
import WebKit
import Foundation

// MARK: - Tab

final class Tab {
    let id = UUID()
    /// Identifies this tab's own persistent web storage; see TabStore.swift for
    /// why the store is per tab rather than shared.
    let storeID: UUID
    var name: String
    /// A name the user typed. Auto titles from the page must not overwrite it.
    var manuallyNamed: Bool
    let webView: WKWebView

    init(storeID: UUID, name: String, manuallyNamed: Bool = false, webView: WKWebView) {
        self.storeID = storeID
        self.name = name
        self.manuallyNamed = manuallyNamed
        self.webView = webView
    }

    var record: TabRecord {
        TabRecord(storeID: storeID, name: name, manuallyNamed: manuallyNamed)
    }
}

// MARK: - Tab chip (one title-bar tab)
//
// Pill-shaped chip: [ × glyph | name (right-aligned) ].  Handles clicks in
// mouseDown directly (see header comment).  Tab names follow the page title
// automatically until the user renames one, after which the manual name wins.

/// A label that passes clicks through to the chip while it is NOT being edited;
/// once editing begins it takes clicks normally, so the caret can be placed.
final class NonInteractiveLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? {
        isEditable ? super.hitTest(point) : nil
    }
}

/// Same pass-through behaviour for SF Symbol image views.
final class NonInteractiveImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Non-interactive circular backdrop; always draws a PERFECT circle inscribed
/// in its bounds, so a non-square frame can never squash it into an ellipse.
final class CircleBackdropView: NSView {
    var color: NSColor = .clear {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard color.alphaComponent > 0 else { return }
        let d = min(bounds.width, bounds.height)
        let r = NSRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
        color.setFill()
        NSBezierPath(ovalIn: r).fill()
    }
}

/// Identity + display name for a strip item (the id follows the agent's Tab,
/// so the strip can report a reordered visual list back to the agent).
struct TabChipInfo {
    let id: UUID
    let name: String
}

final class TabChipView: NSView, NSTextFieldDelegate {
    static let chipWidth: CGFloat = 150
    static let chipHeight: CGFloat = 24

    let id: UUID
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onCloseOthers: (() -> Void)?
    var onNewTab: (() -> Void)?
    var onRename: ((String) -> Void)?
    var onDrag: ((NSPoint) -> Void)?       // location in the document view
    var onDragEnd: (() -> Void)?

    /// Manual double-click detection: AppKit's event.clickCount proved
    /// unreliable inside a title-bar accessory (it never reached 2 there).
    private var lastClickTime: TimeInterval = 0
    private var lastClickPos = NSPoint.zero

    var selected = false {
        didSet { updateAppearance() }
    }

    private var hovering = false {
        didSet { updateAppearance() }
    }

    /// True only while the mouse is directly over the × glyph (drives the
    /// circular backdrop, distinct from the tab-wide hover that shows the ×).
    private var closeHovering = false {
        didSet { updateAppearance() }
    }

    private let closeGlyph = NonInteractiveImageView()
    private let closeBackdrop = CircleBackdropView()
    private let titleField = NonInteractiveLabel(string: "")

    /// Generous hit area around the × glyph (for mouseDown hit-testing).
    private var closeHitRect: NSRect {
        NSRect(x: 0, y: 0, width: 26, height: TabChipView.chipHeight)
    }

    init(id: UUID, name: String) {
        self.id = id
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = TabChipView.chipHeight / 2   // pill

        closeBackdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeBackdrop)
        closeBackdrop.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5).isActive = true
        closeBackdrop.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        closeBackdrop.widthAnchor.constraint(equalToConstant: 16).isActive = true
        closeBackdrop.heightAnchor.constraint(equalToConstant: 16).isActive = true

        let xmarkImage = (NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭标签页")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10.5, weight: .regular)))!
        closeGlyph.image = xmarkImage
        closeGlyph.imageScaling = .scaleProportionallyDown
        closeGlyph.wantsLayer = true
        closeGlyph.alphaValue = 0
        closeGlyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeGlyph)
        closeGlyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5).isActive = true
        closeGlyph.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        closeGlyph.widthAnchor.constraint(equalToConstant: 16).isActive = true
        closeGlyph.heightAnchor.constraint(equalToConstant: 16).isActive = true

        titleField.stringValue = name
        titleField.isEditable = false
        titleField.isSelectable = false
        titleField.isBezeled = false
        titleField.drawsBackground = false
        titleField.alignment = .right
        titleField.font = .systemFont(ofSize: 11)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleField)
        titleField.leadingAnchor.constraint(equalTo: closeGlyph.trailingAnchor, constant: 2).isActive = true
        titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10).isActive = true
        titleField.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        titleField.heightAnchor.constraint(equalToConstant: 16).isActive = true
        titleField.delegate = self
        titleField.target = self
        titleField.action = #selector(renameCommitted)

        menu = buildContextMenu()
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateName(_ name: String) {
        titleField.stringValue = name
    }

    private func updateAppearance() {
        if selected {
            // gray fill only (no accent colour), no border
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.14).cgColor
            layer?.borderWidth = 0
            titleField.textColor = .labelColor
            titleField.font = .systemFont(ofSize: 11, weight: .medium)
            closeGlyph.contentTintColor = .labelColor
            closeGlyph.animator().alphaValue = 0.85
            // "punched hole" in the pill while the mouse is on the × itself:
            // the circle takes the title bar's own background colour.
            closeBackdrop.color = closeHovering ? .windowBackgroundColor : .clear
        } else {
            // transparent, borderless; the × shows only on hover
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderWidth = 0
            titleField.textColor = NSColor.labelColor.withAlphaComponent(hovering ? 1.0 : 0.65)
            titleField.font = .systemFont(ofSize: 11)
            closeGlyph.contentTintColor = .secondaryLabelColor
            closeGlyph.animator().alphaValue = hovering ? 0.9 : 0
            closeBackdrop.color = closeHovering
                ? NSColor.labelColor.withAlphaComponent(0.14)
                : .clear
        }
    }

    // MARK: - events (no gesture recognizers — they swallow subview clicks)

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Never let the title bar's window-drag steal the chip's drag gesture.
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // The × is only clickable when the mouse is actually on it
        // (closeHovering), or on the selected tab (× always visible there).
        if closeHitRect.contains(p), closeHovering || selected {
            onClose?()
            return
        }
        // The first click reaches the chip even when the window is inactive,
        // so a double-click is not eaten by the activation click.
        let now = event.timestamp
        let sameSpot = abs(p.x - lastClickPos.x) < 4 && abs(p.y - lastClickPos.y) < 4
        let isDouble = sameSpot && (now - lastClickTime) < 0.35
        lastClickTime = now
        lastClickPos = p
        if isDouble {
            beginRename()
        } else {
            onSelect?()
        }
    }

    // MARK: - inline rename

    private func beginRename() {
        titleField.isEditable = true
        titleField.isSelectable = true
        titleField.isBezeled = true
        titleField.drawsBackground = true
        NSApp.activate()
        window?.makeKey()
        titleField.selectText(nil)
    }

    @objc private func renameCommitted() { commitRename() }

    private func commitRename() {
        guard titleField.isEditable else { return }
        let newName = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        titleField.isEditable = false
        titleField.isSelectable = false
        titleField.isBezeled = false
        titleField.drawsBackground = false
        guard !newName.isEmpty else { return }
        titleField.stringValue = newName
        onRename?(newName)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitRename()
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let sp = superview?.convert(p, from: self) ?? p
        onDrag?(sp)
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnd?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self, userInfo: nil))
        addTrackingArea(NSTrackingArea(rect: closeGlyph.frame.insetBy(dx: -2, dy: -2),
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self, userInfo: ["close": true]))
    }

    override func mouseEntered(with event: NSEvent) {
        if event.trackingArea?.userInfo?["close"] != nil {
            closeHovering = true
        } else {
            hovering = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if event.trackingArea?.userInfo?["close"] != nil {
            closeHovering = false
        } else {
            hovering = false
        }
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        let rename = menu.addItem(withTitle: "重命名", action: #selector(menuRename), keyEquivalent: "")
        let close = menu.addItem(withTitle: "关闭标签页", action: #selector(menuClose), keyEquivalent: "")
        let closeOthers = menu.addItem(withTitle: "关闭其他标签页", action: #selector(menuCloseOthers), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        let newTab = menu.addItem(withTitle: "新建标签页", action: #selector(menuNewTab), keyEquivalent: "")
        for item in [rename, close, closeOthers, newTab] { item.target = self }
        return menu
    }

    @objc private func menuRename() { beginRename() }
    @objc private func menuClose() { onClose?() }
    @objc private func menuCloseOthers() { onCloseOthers?() }
    @objc private func menuNewTab() { onNewTab?() }
}

// MARK: - Edge fade (overflow indicator)
//
// A vertical gradient that fades a scroll-area edge toward the title-bar
// background; alpha-animates in/out as content overflows that side.

final class FadeView: NSView {
    enum Side { case leading, trailing }

    private let side: Side
    private let gradient = CAGradientLayer()

    init(side: Side) {
        self.side = side
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(gradient)
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        alphaValue = 0
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // click-through

    override func layout() {
        super.layout()
        gradient.frame = bounds
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        let c = NSColor.windowBackgroundColor
        gradient.colors = side == .leading
            ? [c.cgColor, c.withAlphaComponent(0).cgColor]
            : [c.withAlphaComponent(0).cgColor, c.cgColor]
    }
}

/// Document view that draws the thin separators between adjacent tabs
/// (50% height, hidden beside the selected tab).
final class StripDocumentView: NSView {
    var separators: [CGFloat] = [] {
        didSet { needsDisplay = true }
    }

    /// Vertical wheel deltas over the tab row are remapped to horizontal
    /// scrolling by the strip.
    var onScrollWheel: ((CGFloat) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        var dx = event.scrollingDeltaX
        if dx == 0 { dx = event.scrollingDeltaY }
        if let handler = onScrollWheel, dx != 0 {
            handler(dx)
            return
        }
        super.scrollWheel(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.withAlphaComponent(0.6).setFill()
        let h = TabChipView.chipHeight * 0.5
        let y = (bounds.height - h) / 2
        for x in separators {
            NSRect(x: x - 0.5, y: y, width: 1, height: h).fill()
        }
    }
}

// MARK: - Tab strip
//
// Frame-managed view: [ "+" ] [ scroll area — content anchored RIGHT; edge
// fades indicate overflow ]. Chips render in reversed order: the newest tab
// is leftmost (next to "+"), the oldest at the far right. Insert/remove are
// animated inside ONE shared animation group (survivors slide into place).

final class TabStripView: NSView {
    var onAdd: (() -> Void)?
    var onSelect: ((Int) -> Void)?        // visual index (0 = leftmost = newest)
    var onClose: ((Int) -> Void)?
    var onCloseOthers: ((Int) -> Void)?
    var onNewTab: (() -> Void)?
    var onRename: ((Int, String) -> Void)?  // visual index + the name the user typed
    var onReorder: (([UUID]) -> Void)?    // visual (left→right) id order after a drag

    static let trailingPadding: CGFloat = 8
    private static let chipSpacing: CGFloat = 5
    private static let fadeWidth: CGFloat = 28
    private static let animationDuration: TimeInterval = 0.25

    private let scrollView = NSScrollView()
    private let documentView = StripDocumentView()
    private let addButton = NSButton()
    private let leftFade = FadeView(side: .leading)
    private let rightFade = FadeView(side: .trailing)
    private let addBackdrop = CircleBackdropView()
    private var chips: [TabChipView] = []   // visual order: [0] = leftmost = newest
    private var clipObserver: NSObjectProtocol?
    private var addHovering = false {
        didSet {
            addBackdrop.color = addHovering
                ? NSColor.labelColor.withAlphaComponent(0.14)
                : .clear
        }
    }

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 120, height: TabChipView.chipHeight))

        // "+" at the far LEFT of the strip
        addBackdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(addBackdrop)
        addBackdrop.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6).isActive = true
        addBackdrop.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        addBackdrop.widthAnchor.constraint(equalToConstant: 20).isActive = true
        addBackdrop.heightAnchor.constraint(equalToConstant: 20).isActive = true

        let plusImage = (NSImage(systemSymbolName: "plus", accessibilityDescription: "新建标签页")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)))!
        addButton.image = plusImage
        addButton.imageScaling = .scaleProportionallyDown
        addButton.isBordered = false
        addButton.contentTintColor = .labelColor
        addButton.target = self
        addButton.action = #selector(addTapped)
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(addButton)
        addButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6).isActive = true
        addButton.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        addButton.widthAnchor.constraint(equalToConstant: 20).isActive = true
        addButton.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let ta = NSTrackingArea(rect: .zero,
                                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                owner: self, userInfo: ["addButton": true])
        addButton.addTrackingArea(ta)

        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        scrollView.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 4).isActive = true
        scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -TabStripView.trailingPadding).isActive = true
        scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 0).isActive = true
        scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 0).isActive = true

        scrollView.documentView = documentView
        documentView.onScrollWheel = { [weak self] dx in
            self?.scrollTabs(by: dx)
        }

        // edge fades sit above the scroll area (click-through)
        addSubview(leftFade)
        addSubview(rightFade)

        if let clip = scrollView.contentView as? NSClipView {
            clipObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                self?.updateFades()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func addTapped() { onAdd?() }

    /// Map wheel/trackpad deltas over the tab row to horizontal scrolling.
    /// Direction: scroll "up" moves toward the left (newer tabs); invert the
    /// sign here if it feels backwards.
    func scrollTabs(by dx: CGFloat) {
        guard let clip = scrollView.contentView as? NSClipView else { return }
        let maxX = max(0, documentView.frame.width - clip.bounds.width)
        var target = clip.bounds.origin.x - dx * 4   // ×4 scroll coefficient
        target = min(max(0, target), maxX)
        if target != clip.bounds.origin.x {
            clip.scroll(to: NSPoint(x: target, y: clip.bounds.origin.y))
            scrollView.reflectScrolledClipView(clip)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        var dx = event.scrollingDeltaX
        if dx == 0 { dx = event.scrollingDeltaY }
        if dx != 0 {
            scrollTabs(by: dx)
            return
        }
        super.scrollWheel(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        if event.trackingArea?.userInfo?["addButton"] != nil { addHovering = true }
    }

    override func mouseExited(with event: NSEvent) {
        if event.trackingArea?.userInfo?["addButton"] != nil { addHovering = false }
    }

    // MARK: chip factory

    /// Chip callbacks resolve their CURRENT visual index by identity, so
    /// animations that shift the array never leave stale indices behind.
    private func makeChip(item: TabChipInfo) -> TabChipView {
        let chip = TabChipView(id: item.id, name: item.name)
        chip.onSelect = { [weak self, weak chip] in
            guard let self, let chip, let idx = self.chips.firstIndex(where: { $0 === chip }) else { return }
            self.onSelect?(idx)
        }
        chip.onClose = { [weak self, weak chip] in
            guard let self, let chip, let idx = self.chips.firstIndex(where: { $0 === chip }) else { return }
            self.onClose?(idx)
        }
        chip.onCloseOthers = { [weak self, weak chip] in
            guard let self, let chip, let idx = self.chips.firstIndex(where: { $0 === chip }) else { return }
            self.onCloseOthers?(idx)
        }
        chip.onNewTab = { [weak self] in self?.onNewTab?() }
        chip.onRename = { [weak self, weak chip] name in
            guard let self, let chip, let idx = self.chips.firstIndex(where: { $0 === chip }) else { return }
            self.onRename?(idx, name)
        }
        chip.onDrag = { [weak self, weak chip] point in
            guard let self, let chip else { return }
            self.handleDrag(of: chip, at: point)
        }
        chip.onDragEnd = { [weak self, weak chip] in
            guard let self, let chip else { return }
            self.handleDragEnd(of: chip)
        }
        return chip
    }

    private func applySelection(_ selectedVisual: Int?) {
        for (i, chip) in chips.enumerated() {
            chip.selected = (i == selectedVisual)
        }
    }

    // MARK: geometry

    private func clipWidth() -> CGFloat {
        (scrollView.contentView as? NSClipView)?.bounds.width ?? 0
    }

    private func contentWidth(for count: Int) -> CGFloat {
        count > 0 ? CGFloat(count) * (TabChipView.chipWidth + Self.chipSpacing) - Self.chipSpacing : 0
    }

    /// Final (right-anchored) frames for the given chip list; also sizes the
    /// document view.
    private func finalFrames(for list: [TabChipView]) -> [NSRect] {
        let cw = contentWidth(for: list.count)
        let docW = max(cw, clipWidth())
        documentView.frame = NSRect(x: 0, y: 0, width: docW, height: TabChipView.chipHeight)
        var x = docW - cw
        return list.map { _ in
            let f = NSRect(x: x, y: 0, width: TabChipView.chipWidth, height: TabChipView.chipHeight)
            x += TabChipView.chipWidth + Self.chipSpacing
            return f
        }
    }

    private func layoutDocument() {
        let frames = finalFrames(for: chips)
        for (i, chip) in chips.enumerated() {
            if isDragging, chip === draggedChip { continue }
            chip.frame = frames[i]
        }
        var seps: [CGFloat] = []
        if chips.count > 1 {
            for i in 0..<(chips.count - 1) {
                if chips[i].selected || chips[i + 1].selected { continue }
                seps.append(chips[i].frame.maxX + Self.chipSpacing / 2)
            }
        }
        documentView.separators = seps
        layoutFades()
        updateFades()
    }

    private func layoutFades() {
        let sw = scrollView.frame
        leftFade.frame = NSRect(x: sw.minX, y: sw.minY, width: Self.fadeWidth, height: sw.height)
        rightFade.frame = NSRect(x: sw.maxX - Self.fadeWidth, y: sw.minY, width: Self.fadeWidth, height: sw.height)
    }

    override func layout() {
        super.layout()
        layoutDocument()
    }

    /// Overflow indicators: fade in only when content extends past that side.
    private func updateFades() {
        guard let clip = scrollView.contentView as? NSClipView else { return }
        let maxX = max(0, documentView.frame.width - clip.bounds.width)
        let hasLeft = clip.bounds.origin.x > 0.5
        let hasRight = clip.bounds.origin.x < maxX - 0.5
        leftFade.animator().alphaValue = hasLeft ? 1 : 0
        rightFade.animator().alphaValue = hasRight ? 1 : 0
    }

    private func reveal(rect: NSRect) {
        guard let clip = scrollView.contentView as? NSClipView else { return }
        var target = clip.bounds.origin.x
        if rect.minX < clip.bounds.minX {
            target = rect.minX
        } else if rect.maxX > clip.bounds.maxX {
            target = rect.maxX - clip.bounds.width
        }
        clip.scroll(to: NSPoint(x: max(0, target), y: 0))
        scrollView.reflectScrolledClipView(clip)
    }

    private func reveal(_ chip: TabChipView) { reveal(rect: chip.frame) }

    // MARK: drag reordering

    private var dragStartPoint: NSPoint?
    private var dragStartIndex: Int?
    private var dragGrabOffset: CGFloat = 0
    private var draggedChip: TabChipView?
    private var isDragging = false
    private var autoScrollTimer: Timer?
    private var lastDragPoint: NSPoint?

    private func handleDrag(of chip: TabChipView, at point: NSPoint) {
        guard chips.contains(where: { $0 === chip }) else { return }
        if !isDragging {
            let start = dragStartPoint ?? point
            dragStartPoint = start
            guard abs(point.x - start.x) >= 4 else { return }   // click vs drag
            guard chips.contains(where: { $0 === chip }) else { return }
            isDragging = true
            draggedChip = chip
            dragStartIndex = chips.firstIndex(where: { $0 === chip })
            dragGrabOffset = start.x - chip.frame.origin.x
            // lift the dragged chip above its neighbours
            chip.layer?.shadowColor = NSColor.black.cgColor
            chip.layer?.shadowOpacity = 0.35
            chip.layer?.shadowRadius = 6
            chip.layer?.shadowOffset = CGSize(width: 0, height: -2)
            documentView.addSubview(chip)   // re-add on top
            startAutoScrollTimer()
        }
        guard isDragging, chip === draggedChip else { return }
        lastDragPoint = point
        var f = chip.frame
        f.origin.x = point.x - dragGrabOffset
        chip.frame = f
        // push neighbours out of the way when the chip crosses their midpoints
        let currentIdx = chips.firstIndex(where: { $0 === chip }) ?? 0
        let targetIdx = insertionIndex(for: chip)
        if targetIdx != currentIdx {
            chips.remove(at: currentIdx)
            chips.insert(chip, at: targetIdx)
            animateNeighbours(keeping: chip)
        }
    }

    /// Insertion slot = number of other chips whose centre is left of the
    /// dragged chip's centre.
    private func insertionIndex(for dragged: TabChipView) -> Int {
        let center = dragged.frame.midX
        return chips.filter { $0 !== dragged && $0.frame.midX < center }.count
    }

    /// Neighbours slide into their new slots (shared animation group).
    private func animateNeighbours(keeping dragged: TabChipView) {
        let frames = finalFrames(for: chips)
        let keepFrame = dragged.frame
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for (i, c) in chips.enumerated() where c !== dragged {
                c.animator().frame = frames[i]
            }
        })
        dragged.frame = keepFrame   // keep following the mouse
    }

    private func handleDragEnd(of chip: TabChipView) {
        guard isDragging, chip === draggedChip else {
            resetDrag()
            return
        }
        isDragging = false
        chip.layer?.shadowOpacity = 0
        let orderChanged = chips.firstIndex(where: { $0 === chip }) != dragStartIndex
        let frames = finalFrames(for: chips)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for (i, c) in chips.enumerated() {
                c.animator().frame = frames[i]
            }
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.layoutDocument()
            if orderChanged {
                self.onReorder?(self.chips.map(\.id))
            }
        })
        resetDrag()
    }

    private func resetDrag() {
        stopAutoScrollTimer()
        draggedChip?.layer?.shadowOpacity = 0
        draggedChip = nil
        dragStartPoint = nil
        dragStartIndex = nil
        lastDragPoint = nil
    }

    // MARK: edge auto-scroll while dragging

    private func startAutoScrollTimer() {
        guard autoScrollTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.autoScrollTick()
        }
        RunLoop.main.add(t, forMode: .common)
        autoScrollTimer = t
    }

    private func stopAutoScrollTimer() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
    }

    /// While dragging near the scroll area's edges, scroll the content so the
    /// drag can travel further; the dragged chip is shifted with the scroll so
    /// it stays under the cursor, and reordering keeps updating.
    private func autoScrollTick() {
        guard isDragging,
              let chip = draggedChip,
              let last = lastDragPoint,
              let clip = scrollView.contentView as? NSClipView else { return }
        let visibleMin = clip.bounds.origin.x
        let visibleMax = visibleMin + clip.bounds.width
        let margin: CGFloat = 96   // ×4 edge band for auto-scroll
        var speed: CGFloat = 0
        if last.x < visibleMin + margin {
            speed = -min(12, (visibleMin + margin - last.x) * 0.5)
        } else if last.x > visibleMax - margin {
            speed = min(12, (last.x - (visibleMax - margin)) * 0.5)
        }
        guard speed != 0 else { return }
        let maxX = max(0, documentView.frame.width - clip.bounds.width)
        var target = clip.bounds.origin.x + speed
        target = min(max(0, target), maxX)
        let delta = target - clip.bounds.origin.x
        guard delta != 0 else { return }
        clip.scroll(to: NSPoint(x: target, y: clip.bounds.origin.y))
        scrollView.reflectScrolledClipView(clip)
        var f = chip.frame
        f.origin.x += delta
        chip.frame = f
        let currentIdx = chips.firstIndex(where: { $0 === chip }) ?? 0
        let targetIdx = insertionIndex(for: chip)
        if targetIdx != currentIdx {
            chips.remove(at: currentIdx)
            chips.insert(chip, at: targetIdx)
            animateNeighbours(keeping: chip)
        }
    }

    // MARK: public API

    /// Full rebuild, no animation (initial state / closing the last tab).
    func setTabs(_ items: [TabChipInfo], selectedVisual: Int?) {
        chips.forEach { $0.removeFromSuperview() }
        chips = items.reversed().map { makeChip(item: $0) }
        chips.forEach { documentView.addSubview($0) }
        applySelection(selectedVisual)
        layoutDocument()
        if let sv = selectedVisual, sv < chips.count { reveal(chips[sv]) }
    }

    /// Insert a new (newest) tab at the left end of the cluster; all moved
    /// survivors share the same animation group.
    func animateInsert(_ item: TabChipInfo, selectedVisual: Int) {
        let oldFrames = chips.map { $0.frame }
        let chip = makeChip(item: item)
        chip.alphaValue = 0
        chips.insert(chip, at: 0)
        documentView.addSubview(chip)
        applySelection(selectedVisual)
        let finalFrames = finalFrames(for: chips)
        // start positions: survivors stay put, the new chip starts one slot left
        for (i, c) in chips.enumerated() {
            if c === chip {
                var f = finalFrames[i]
                f.origin.x -= TabChipView.chipWidth + Self.chipSpacing
                c.frame = f
            } else {
                c.frame = oldFrames[i - 1]
            }
        }
        layoutFades()
        reveal(rect: finalFrames[0])
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.animationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for (i, c) in chips.enumerated() {
                c.animator().frame = finalFrames[i]
            }
            chip.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            self?.layoutDocument()
        })
    }

    /// Animate removing one chip: it slides left and fades while survivors
    /// slide into their new slots.
    func animateRemove(atVisual v: Int, selectedVisual: Int?) {
        guard v >= 0, v < chips.count else { return }
        let removed = chips.remove(at: v)
        let survivorFrames = chips.map { $0.frame }
        applySelection(selectedVisual)
        let finalFrames = finalFrames(for: chips)
        for (i, c) in chips.enumerated() { c.frame = survivorFrames[i] }
        layoutFades()
        var slide = removed.frame
        slide.origin.x -= TabChipView.chipWidth + Self.chipSpacing
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.animationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for (i, c) in chips.enumerated() {
                c.animator().frame = finalFrames[i]
            }
            removed.animator().frame = slide
            removed.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            removed.removeFromSuperview()
            guard let self else { return }
            self.layoutDocument()
            if let sv = selectedVisual, sv < self.chips.count {
                self.reveal(self.chips[sv])
            }
        })
    }

    /// Close everything except one chip; the keeper slides to the left end.
    func animateRemoveOthers(keepVisual k: Int, selectedVisual: Int) {
        guard k >= 0, k < chips.count else { return }
        let keeper = chips[k]
        var doomed: [TabChipView] = []
        for (i, c) in chips.enumerated() where i != k { doomed.append(c) }
        chips = [keeper]
        applySelection(selectedVisual)
        let finalFrames = finalFrames(for: chips)
        layoutFades()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.animationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            keeper.animator().frame = finalFrames[0]
            for c in doomed {
                var f = c.frame
                f.origin.x -= TabChipView.chipWidth + Self.chipSpacing
                c.animator().frame = f
                c.animator().alphaValue = 0
            }
        }, completionHandler: { [weak self] in
            doomed.forEach { $0.removeFromSuperview() }
            guard let self else { return }
            self.layoutDocument()
            self.reveal(self.chips[0])
        })
    }

    /// In-place update for title / selection changes (no animation needed).
    func updateSelection(_ items: [TabChipInfo], selectedVisual: Int?) {
        guard !isDragging else { return }   // never yank frames mid-drag
        let visualItems = Array(items.reversed())
        if chips.count != visualItems.count {
            setTabs(items, selectedVisual: selectedVisual)
            return
        }
        for (i, chip) in chips.enumerated() { chip.updateName(visualItems[i].name) }
        applySelection(selectedVisual)
        layoutDocument()
        if let sv = selectedVisual, sv < chips.count { reveal(chips[sv]) }
    }
}

// MARK: - Root view: chrome band (centered tab strip) + web container
//
// Everything here is frame-managed (no Auto Layout for the container views —
// constraint-managed views with missing constraints collapse to zero size).

final class RootView: NSView {
    static let chromeHeight: CGFloat = 40   // adjustable custom chrome height

    var onLayout: (() -> Void)?            // notified on every layout pass

    let tabStrip: TabStripView
    weak var stripHost: NSView?             // full-width title-bar accessory host
    let webContainer = NSView()

    init(tabStrip: TabStripView, stripHost: NSView) {
        self.tabStrip = tabStrip
        self.stripHost = stripHost
        super.init(frame: .zero)
        webContainer.autoresizesSubviews = true
        addSubview(webContainer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let w = bounds.width
        let h = bounds.height
        // web content below the chrome band
        webContainer.frame = NSRect(x: 0, y: 0, width: w, height: h - RootView.chromeHeight)
        // The accessory host stays full-width; the strip's x/width are synced
        // to the page's center column by the agent (DOM geometry), so here we
        // only keep the host stretched and the strip vertically centered.
        if let host = stripHost {
            host.frame.size.width = w
            tabStrip.frame.origin.y = (host.frame.height - tabStrip.frame.height) / 2
        }
        onLayout?()
    }
}

// MARK: - Window subclass (intercepts the zoom animation)

/// Intercepts `zoom:` so the agent can drive the resize animation itself —
/// the system zoom animates only the window frame and applies the content
/// size at the end, which makes the WebView snap.  Driving `setFrame` per
/// tick keeps the content layout in sync with the frame.
final class LauncherWindow: NSWindow {
    var onZoom: (() -> Void)?

    override func zoom(_ sender: Any?) {
        onZoom?()
    }
}

// MARK: - Agent

final class Agent: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    private let port: String
    private var stateDir: String
    private let scriptPath: String
    private let baseURL: URL
    private var logPath: String
    private var prefsController: PreferencesWindowController?

    private var window: NSWindow?
    private var rootView: RootView!
    private var tabStrip: TabStripView!
    private var stripHost: NSView?
    private var accessoryView: NSTitlebarAccessoryViewController?
    private var stripSyncTimer: Timer?
    private var lastStripSync: TimeInterval = 0
    private var savedUserFrame: NSRect?
    private var isZoomed = false
    private var isZoomAnimating = false
    private var tabs: [Tab] = []          // chronological: [0] oldest
    private var selectedIndex: Int?       // chronological index
    private var emptyView: NSView?
    private var didPruneStores = false

    /// The backend the *live* instance was started with — not the same thing as
    /// the preference. The preference is what the user wants next; this is what
    /// is running now, and stopping has to use this one. Using the new backend
    /// to stop an instance the old one started makes the launcher refuse (the
    /// pid file lives in the other backend's state dir), and the switch then
    /// silently does nothing.
    private var activeBackend: Backend = Preferences.shared.backend

    private static let maxTabs = 8

    override init() {
        let env = ProcessInfo.processInfo.environment
        port = env["DSH_LAUNCHER_PORT"] ?? "3080"
        let bundle = Bundle.main.bundlePath
        scriptPath = bundle + "/Contents/MacOS/launcher"
        baseURL = URL(string: "http://127.0.0.1:\(port)")!
        let defaultState = NSHomeDirectory() + "/Library/Application Support/DSH Desktop"
        if let s = env["DSH_LAUNCHER_STATE"], !s.isEmpty {
            stateDir = s
        } else if port != "3080" {
            stateDir = defaultState + "/ports/" + port
        } else {
            stateDir = defaultState
        }
        logPath = stateDir + "/logs/agent.log"
        super.init()
        // The launcher partitions its state per (backend, port); rather than
        // reimplementing that rule here, ask it where the state went.
        refreshStateDir()
        log("agent started (port \(port), backend \(Preferences.shared.backend.rawValue), state \(stateDir))")
        log("process cwd is \(FileManager.default.currentDirectoryPath); children get \(NSHomeDirectory())")
    }

    /// Read the state directory back from the launcher, so the two can never
    /// disagree about where the pid file and logs live.
    private func refreshStateDir() {
        // `status` reports "stopped" with exit 1 when nothing is running, which
        // is the normal case at startup -- only the printed state path matters.
        let (_, out) = runScript("status")
        guard !out.isEmpty else { return }
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "state" else { continue }
            let dir = parts[1].trimmingCharacters(in: .whitespaces)
            guard !dir.isEmpty else { continue }
            stateDir = dir
            logPath = dir + "/logs/agent.log"
            return
        }
    }

    // MARK: - helpers

    private func log(_ s: String) {
        let line = "[\(Date())] \(s)\n"
        let dir = (logPath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: Data(line.utf8))
                try? h.close()
            } else {
                try line.data(using: .utf8)?.write(to: URL(fileURLWithPath: logPath))
            }
        } catch {
            NSLog("DSH launcher agent: %@", s)
        }
    }

    /// Run the launcher script with the settings the user picked.
    ///
    /// `--state` is deliberately not passed: the script derives it from the
    /// backend and the port (and honours DSH_LAUNCHER_STATE), and having one
    /// owner of that rule is what keeps `status` and `stop` looking at the same
    /// pid file after a backend switch.
    @discardableResult
    private func runScript(_ cmd: String, backend: Backend? = nil) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: scriptPath)
        var args: [String] = []
        if port != "3080" { args += ["--port", port] }
        args += ["--backend", (backend ?? Preferences.shared.backend).rawValue]
        if let home = Preferences.shared.dshHome { args += ["--dsh-home", home] }
        args += [cmd]
        p.arguments = args
        // A double-clicked app starts at "/", and an inherited "/" is a bad
        // working directory for anything: a relative write lands at the root of
        // the disk. Hand the child somewhere real.
        //
        // This is hygiene, not a feature. It does NOT decide where a session's
        // tools run: dsh resolves that from the workspace (dsh-tool-bash's
        // resolveWorkdir uses policy.workspaceRoot, then the session header's
        // cwd), and only headless mode ever seeds a session from process.cwd().
        p.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
        } catch {
            log("cannot run launcher script: \(error)")
            return (127, "无法运行启动器脚本：\(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// Which backend, if any, claims the server currently on our port.
    ///
    /// Asked at startup because the instance may be a survivor of a previous run
    /// (or of a refused stop), and only the backend that owns its pid file can
    /// stop it again.
    private func detectActiveBackend() -> Backend? {
        for backend in Backend.allCases {
            let (_, out) = runScript("status", backend: backend)
            if out.contains("this launcher") { return backend }
        }
        return nil
    }

    private func isUp() -> Bool {
        var req = URLRequest(url: baseURL)
        req.timeoutInterval = 1.5
        var ok = false
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            if let r = resp as? HTTPURLResponse {
                ok = (200..<500).contains(r.statusCode)
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 2.5)
        return ok
    }

    private func isSameOrigin(_ url: URL) -> Bool {
        guard let scheme = url.scheme, let host = url.host else { return false }
        let urlPort = url.port ?? (scheme == "https" ? 443 : (scheme == "http" ? 80 : nil))
        let basePort = baseURL.port ?? (baseURL.scheme == "https" ? 443 : 80)
        return scheme == baseURL.scheme && host == baseURL.host && urlPort == basePort
    }

    private func handleExternal(_ url: URL) {
        log("external URL → system browser: \(url.absoluteString)")
        NSWorkspace.shared.open(url)
    }

    /// Auto-name tabs from the page's document title (DSH sets session-aware
    /// titles on session create/switch); manual renames win over auto titles.
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard keyPath == #keyPath(WKWebView.title), let wv = object as? WKWebView else { return }
        let title = wv.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let index = self.tabs.firstIndex(where: { $0.webView === wv }),
                  !self.tabs[index].manuallyNamed,
                  !title.isEmpty,
                  title != self.tabs[index].name else { return }
            self.tabs[index].name = title
            self.refreshStrip()
            self.persistTabs()
            self.log("auto title tab \(index) → '\(title)'")
        }
    }

    // MARK: - tab management

    /// Build the web view for a tab. Each tab gets its own *persistent* store,
    /// keyed by the tab's storeID — see TabStore.swift for why sharing one store
    /// would collapse every tab onto the same DSH session.
    private func makeWebView(storeID: UUID) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = TabDataStore.store(for: storeID)
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        wv.addObserver(self, forKeyPath: #keyPath(WKWebView.title), options: [.new], context: nil)
        return wv
    }

    private func addTab(url: URL? = nil) {
        guard tabs.count < Self.maxTabs else {
            let alert = NSAlert()
            alert.messageText = "标签页已达上限（\(Self.maxTabs)）"
            alert.informativeText = "请先关闭部分标签页。"
            alert.addButton(withTitle: "好")
            alert.runModal()
            return
        }
        let storeID = UUID()
        let wv = makeWebView(storeID: storeID)
        let tab = Tab(storeID: storeID, name: "标签 \(tabs.count + 1)", webView: wv)
        tabs.append(tab)
        showWebView(at: tabs.count - 1)
        tabStrip.animateInsert(TabChipInfo(id: tab.id, name: tab.name), selectedVisual: 0)
        wv.load(URLRequest(url: url ?? baseURL))
        persistTabs()
        log("new tab \(tabs.count - 1) '\(tab.name)' store \(storeID) → \(url?.absoluteString ?? baseURL.absoluteString)")
    }

    /// Recreate the tabs of the previous run. Each one reloads the same URL, but
    /// its own storage comes back with it — including DSH's `dsh.sessions.current`,
    /// so a tab returns to the session it was last on.
    private func restoreTabs() {
        let records = Array(Preferences.shared.tabs.prefix(Self.maxTabs))
        guard !records.isEmpty else { return }
        for record in records {
            let wv = makeWebView(storeID: record.storeID)
            let tab = Tab(storeID: record.storeID,
                          name: record.name,
                          manuallyNamed: record.manuallyNamed,
                          webView: wv)
            tabs.append(tab)
            wv.load(URLRequest(url: baseURL))
        }
        showWebView(at: tabs.count - 1)
        tabStrip.setTabs(tabs.reversed().map { TabChipInfo(id: $0.id, name: $0.name) },
                         selectedVisual: 0)
        log("restored \(tabs.count) tab(s)")
    }

    private func persistTabs() {
        Preferences.shared.tabs = tabs.map { $0.record }
    }

    /// Sweep storage that no tab claims any more — what a crash or a force quit
    /// leaves behind, since those skip the per-tab removal in closeTab.
    ///
    /// Must run after the first WKWebView exists. WebKit initializes its main
    /// run loop when the first instance is created; calling the *static*
    /// data-store API before that crashes on a WebKit IO queue, because the
    /// completion is dispatched to a main run loop that does not exist yet
    /// (SIGSEGV in WTF::RunLoop::dispatch, observed at launch).
    private func pruneOrphanedStores() {
        guard !didPruneStores, !tabs.isEmpty else { return }
        didPruneStores = true
        TabDataStore.prune(keeping: Set(tabs.map { $0.storeID })) { [weak self] in
            self?.log($0)
        }
    }

    private func renameTab(at index: Int, name: String) {
        guard index >= 0, index < tabs.count else { return }
        tabs[index].name = name
        tabs[index].manuallyNamed = true   // a typed name outranks the page title
        refreshStrip()
        persistTabs()
        log("rename tab \(index) → '\(name)'")
    }

    /// Visual index (0 = leftmost = newest) → chronological index.
    private func arrayIndex(fromVisual visual: Int) -> Int {
        tabs.count - 1 - visual
    }

    /// The strip reports the new VISUAL (left→right) id order after a drag;
    /// the chronological tabs array is its reverse.
    private func applyVisualOrder(_ visualIds: [UUID]) {
        guard visualIds.count == tabs.count else { return }
        let byId = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        let selectedId = selectedIndex.map { tabs[$0].id }
        tabs = visualIds.reversed().compactMap { byId[$0] }
        if let sel = selectedId {
            selectedIndex = tabs.firstIndex { $0.id == sel }
        }
        refreshStrip()
        persistTabs()
        log("reorder applied → \(tabs.count) tabs")
    }

    /// Swap the visible webview without touching the tab strip.
    private func showWebView(at index: Int) {
        guard index >= 0, index < tabs.count else { return }
        selectedIndex = index
        emptyView?.removeFromSuperview()
        emptyView = nil
        rootView.webContainer.subviews.forEach { $0.removeFromSuperview() }
        let wv = tabs[index].webView
        wv.autoresizingMask = [.width, .height]
        wv.frame = rootView.webContainer.bounds
        rootView.webContainer.addSubview(wv)
        syncStripToCenterColumn()
    }

    /// User clicked a chip: swap view + refresh strip selection.
    private func showTab(at index: Int) {
        showWebView(at: index)
        refreshStrip()
    }

    /// Layout-driven sync: the window re-lays out on every animation tick
    /// and live-resize tick — sync the strip at up to ~20 Hz so it tracks
    /// the WebView smoothly (the 0.5s timer below still covers page-internal
    /// pane resizes, where no window layout occurs).
    private func syncStripOnLayout() {
        let now = CACurrentMediaTime()
        guard now - lastStripSync > 0.05 else { return }
        lastStripSync = now
        syncStripToCenterColumn()
    }

    /// Align the tab strip with the page's center column: read the live DOM
    /// geometry of the `centerCol` element in the active tab and mirror its
    /// x/width (the webview fills the window horizontally, so viewport CSS
    /// coordinates map 1:1 to window coordinates).
    private func syncStripToCenterColumn() {
        guard let index = selectedIndex, index < tabs.count, let host = stripHost else { return }
        let js = "(function(){var el=document.querySelector('[class*=\"centerCol\"]');if(!el)return null;var r=el.getBoundingClientRect();return {x:r.x,width:r.width};})()"
        tabs[index].webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self,
                  let d = result as? [String: Any],
                  let x = d["x"] as? Double,
                  let width = d["width"] as? Double,
                  width > 120 else { return }
            DispatchQueue.main.async {
                guard let host = self.stripHost else { return }
                let p = host.convert(NSPoint(x: x, y: 0), from: nil)
                var f = self.tabStrip.frame
                f.origin.x = p.x
                f.size.width = width
                self.tabStrip.frame = f
                self.tabStrip.needsLayout = true
            }
        }
    }

    private func closeTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }
        let visual = tabs.count - 1 - index
        let tab = tabs.remove(at: index)
        tab.webView.removeObserver(self, forKeyPath: #keyPath(WKWebView.title))
        tab.webView.stopLoading()
        tab.webView.removeFromSuperview()
        // The tab is gone for good, so its storage goes with it; otherwise the
        // directories pile up, one per tab ever opened.
        TabDataStore.remove(tab.storeID) { [weak self] in self?.log($0) }
        persistTabs()
        log("close tab \(index) '\(tab.name)'")
        if tabs.isEmpty {
            selectedIndex = nil
            rootView.webContainer.subviews.forEach { $0.removeFromSuperview() }
            showEmptyState()
            tabStrip.setTabs([], selectedVisual: nil)
            return
        }
        selectedIndex = min(index, tabs.count - 1)
        showWebView(at: selectedIndex!)
        tabStrip.animateRemove(atVisual: visual, selectedVisual: tabs.count - 1 - selectedIndex!)
    }

    private func closeOtherTabs(keep index: Int) {
        let keepVisual = tabs.count - 1 - index
        for (i, tab) in tabs.enumerated().reversed() where i != index {
            tab.webView.removeObserver(self, forKeyPath: #keyPath(WKWebView.title))
            tab.webView.stopLoading()
            tab.webView.removeFromSuperview()
            TabDataStore.remove(tab.storeID) { [weak self] in self?.log($0) }
            tabs.remove(at: i)
        }
        showWebView(at: 0)
        tabStrip.animateRemoveOthers(keepVisual: keepVisual, selectedVisual: 0)
        persistTabs()
    }

    private func refreshStrip() {
        tabStrip?.updateSelection(tabs.map { TabChipInfo(id: $0.id, name: $0.name) },
                                   selectedVisual: selectedIndex.map { tabs.count - 1 - $0 })
    }

    private func showEmptyState() {
        let v = NSView()
        let btn = NSButton(title: "+", target: self, action: #selector(newTabTapped))
        btn.isBordered = false
        btn.font = .systemFont(ofSize: 64, weight: .ultraLight)
        btn.contentTintColor = .tertiaryLabelColor
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 44
        btn.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        btn.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(btn)
        let label = NSTextField(labelWithString: "新建标签页，开始多会话工作")
        label.textColor = .tertiaryLabelColor
        label.font = .systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(label)
        NSLayoutConstraint.activate([
            btn.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            btn.centerYAnchor.constraint(equalTo: v.centerYAnchor, constant: -18),
            btn.widthAnchor.constraint(equalToConstant: 88),
            btn.heightAnchor.constraint(equalToConstant: 88),
            label.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            label.topAnchor.constraint(equalTo: btn.bottomAnchor, constant: 10),
        ])
        v.autoresizingMask = [.width, .height]
        v.frame = rootView.webContainer.bounds
        rootView.webContainer.addSubview(v)
        emptyView = v
    }

    @objc private func newTabTapped() { addTab() }

    // MARK: - window

    private func showWindow() {
        let win: NSWindow
        if let existing = window {
            win = existing
        } else {
            let strip = TabStripView()
            strip.onAdd = { [weak self] in self?.addTab() }
            strip.onSelect = { [weak self] v in
                guard let self else { return }
                self.showTab(at: self.arrayIndex(fromVisual: v))
            }
            strip.onClose = { [weak self] v in
                guard let self else { return }
                self.closeTab(at: self.arrayIndex(fromVisual: v))
            }
            strip.onCloseOthers = { [weak self] v in
                guard let self else { return }
                self.closeOtherTabs(keep: self.arrayIndex(fromVisual: v))
            }
            strip.onNewTab = { [weak self] in self?.addTab() }
            strip.onRename = { [weak self] v, name in
                guard let self else { return }
                self.renameTab(at: self.arrayIndex(fromVisual: v), name: name)
            }
            strip.onReorder = { [weak self] visualIds in
                self?.applyVisualOrder(visualIds)
            }
            tabStrip = strip

            // The strip lives inside a full-width LEADING title-bar accessory:
            // the system inserts accessory views natively into the title bar,
            // where they receive mouse events (plain contentView subviews in
            // the title-bar band are hit-tested away by the window frame).
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 1120, height: 28))
            host.addSubview(strip)
            stripHost = host
            let accessory = NSTitlebarAccessoryViewController()
            accessory.layoutAttribute = .leading
            accessory.view = host
            accessoryView = accessory

            let root = RootView(tabStrip: strip, stripHost: host)
            root.onLayout = { [weak self] in self?.syncStripOnLayout() }

            let w = LauncherWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            // The app's own name, not the upstream product name: "DeepSeek Harness" is
            // DeepSeek's trademark and the title bar is its most visible use.
            w.title = port == "3080" ? "DSH Desktop" : "DSH Desktop (\(port))"
            w.minSize = NSSize(width: 760, height: 540)
            w.titleVisibility = .hidden          // the tab strip is the chrome
            w.titlebarAppearsTransparent = true  // content extends under the title bar
            w.isMovableByWindowBackground = true // drag the window from the chrome band
            // A compact unified toolbar raises the interactive title-bar area.
            let toolbar = NSToolbar(identifier: "DSHLauncherToolbar")
            toolbar.displayMode = .iconOnly
            toolbar.showsBaselineSeparator = false
            w.toolbar = toolbar
            w.toolbarStyle = .unifiedCompact
            w.contentView = root
            w.addTitlebarAccessoryViewController(accessory)
            w.isReleasedWhenClosed = false
            w.center()

            rootView = root
            window = w
            win = w

            // Rewire the green (zoom) button to the in-sync custom animation.
            w.onZoom = { [weak self] in self?.customZoom() }
            if let zb = w.standardWindowButton(.zoomButton) {
                zb.target = self
                zb.action = #selector(customZoomAction)
            }
        }
        if tabs.isEmpty {
            restoreTabs()
        }
        if tabs.isEmpty {
            addTab()
        }
        pruneOrphanedStores()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate()
        log("showing window \(baseURL.absoluteString)")
        if stripSyncTimer == nil {
            stripSyncTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.syncStripToCenterColumn()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, let host = self.stripHost else { return }
            self.log("diagnostic host.frame=\(host.frame) strip.frame=\(self.tabStrip.frame)")
            let p = host.convert(NSPoint(x: self.tabStrip.frame.midX, y: self.tabStrip.frame.midY), to: nil)
            if let frame = self.window?.contentView?.superview {
                let hit = frame.hitTest(frame.convert(p, from: nil))
                let desc = hit.map { String(describing: type(of: $0)) } ?? "nil"
                self.log("diagnostic hitTest(strip center)= \(desc)")
            }
        }
    }

    private func ensureAndOpen() {
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            self.log("ensureAndOpen: probing \(self.baseURL.absoluteString)")
            if self.isUp() {
                // A survivor from a previous run: remember who owns it, or the
                // next stop goes to the wrong state dir and gets refused.
                if let owner = self.detectActiveBackend() {
                    self.activeBackend = owner
                    self.log("adopting running instance started by backend \(owner.rawValue)")
                    if owner != Preferences.shared.backend {
                        self.log("note: preference is \(Preferences.shared.backend.rawValue) — restart needed to switch")
                        DispatchQueue.main.async { self.offerSwitchToPreferredBackend(running: owner) }
                    }
                } else {
                    self.log("port \(self.port) is served by something we do not own")
                }
            } else {
                let (code, out) = self.runScript("start", backend: Preferences.shared.backend)
                self.log("start exit=\(code)")
                if code == 0 {
                    self.activeBackend = Preferences.shared.backend
                }
                if code != 0 {
                    let detail = out.trimmingCharacters(in: .whitespacesAndNewlines)
                    DispatchQueue.main.async {
                        let alert = NSAlert()
                        alert.messageText = "DeepSeek Harness Web UI 启动失败"
                        alert.informativeText = detail.isEmpty ? "未知错误，详见日志" : detail
                        alert.addButton(withTitle: "好")
                        alert.runModal()
                    }
                    return
                }
            }
            DispatchQueue.main.async { self.showWindow() }
        }
    }

    // MARK: - zoom (in-sync window/content animation)

    @objc private func customZoomAction(_ sender: Any?) { customZoom() }

    private func customZoom() {
        guard let win = window, !isZoomAnimating else { return }
        let target: NSRect
        if isZoomed, let saved = savedUserFrame {
            isZoomed = false
            target = saved
        } else {
            savedUserFrame = win.frame
            isZoomed = true
            target = (win.screen ?? NSScreen.main)?.visibleFrame ?? win.frame
        }
        log("custom zoom → \(NSStringFromRect(target))")
        animateWindowFrame(to: target)
    }

    /// 60fps eased frame animation; each tick calls setFrame(display:true),
    /// which synchronously re-lays-out the content view — so the WebView
    /// viewport follows the window frame instead of snapping at the end.
    private func animateWindowFrame(to target: NSRect) {
        guard let win = window else { return }
        isZoomAnimating = true
        let start = win.frame
        let duration: TimeInterval = 0.25
        let startTime = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            guard let self, let win = self.window else { t.invalidate(); return }
            let progress = min(1.0, (CACurrentMediaTime() - startTime) / duration)
            let eased = 0.5 - 0.5 * cos(.pi * progress)   // ease-in-out
            let f = NSRect(x: start.origin.x + (target.origin.x - start.origin.x) * eased,
                           y: start.origin.y + (target.origin.y - start.origin.y) * eased,
                           width: start.width + (target.width - start.width) * eased,
                           height: start.height + (target.height - start.height) * eased)
            win.setFrame(f, display: true)
            if progress >= 1.0 {
                t.invalidate()
                self.isZoomAnimating = false
                win.setFrame(target, display: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if let scheme = url.scheme, scheme == "javascript" || scheme == "about" || scheme == "data" || scheme == "blob" {
            decisionHandler(.allow)
        } else if isSameOrigin(url) {
            decisionHandler(.allow)
        } else {
            handleExternal(url)
            decisionHandler(.cancel)
        }
    }

    /// target="_blank" / window.open: same-origin popups open as NEW TABS,
    /// external URLs go to the system browser.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        syncStripToCenterColumn()
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if isSameOrigin(url) {
                addTab(url: url)
            } else {
                handleExternal(url)
            }
        }
        return nil
    }

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        // Ask before the first instance is started, so choosing mfw does not
        // cost a stop/start cycle.
        if !Preferences.shared.backendChosen {
            NSApp.activate()
            let chosen = FirstRunPrompt.ask()
            activeBackend = chosen
            refreshStateDir()
            log("first run: backend \(chosen.rawValue)")
        }
        // Orphaned storage is swept in showWindow(), not here: WebKit's static
        // data-store API must not be touched before WebKit has been initialized
        // on the main thread, which happens when the first WKWebView is created.
        ensureAndOpen()
        NSApp.activate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ensureAndOpen()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Stopping waits for the whole process tree to go away, which can take
    /// seconds — so it runs off the main thread and the app reports back with
    /// `reply(toApplicationShouldTerminate:)`. Doing it inline would freeze the
    /// UI (and show the spinning cursor) for the duration.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        log("quit requested — stopping the \(activeBackend.rawValue) instance")
        DispatchQueue.global().async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
                return
            }
            // Stop with the backend that started it, not the one the preference
            // now names — otherwise the launcher looks in the wrong state dir,
            // refuses, and the instance is left running after the app is gone.
            let code = self.runScript("stop", backend: self.activeBackend).0
            self.log("stop exit=\(code)")
            DispatchQueue.main.async {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    // MARK: - about panel
    //
    // The standard panel already shows the icon, CFBundleName, the version and
    // NSHumanReadableCopyright; the credits block carries what this project is
    // required to state: where the icon comes from, whose trademarks these are,
    // and that the project is independent.

    private static let repoURL = "https://github.com/Boy-Grid/deepseek-harness-desktop-for-macos"
    private static let upstreamURL = "https://github.com/deepseek-ai/deepseek-harness"
    private static let mfwURL = "https://github.com/Boy-Grid/dsh-multi-folder-workspace"

    @objc private func showAboutPanel() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 2
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .paragraphStyle: paragraph,
        ]
        let credits = NSMutableAttributedString()
        func text(_ string: String) {
            credits.append(NSAttributedString(string: string, attributes: base))
        }
        func link(_ label: String, _ url: String) {
            credits.append(NSAttributedString(string: label,
                                              attributes: base.merging([.link: url]) { $1 }))
        }

        text("把 DeepSeek Harness Web UI 装进原生窗口的独立开源项目。\n\n")
        text("应用图标由 DeepSeek Harness Web UI 的 favicon 派生。\n")
        text("“DeepSeek” 与 “DeepSeek Harness” 为 DeepSeek 的商标。本项目与\n")
        text("DeepSeek 无关联，也未获其背书（not affiliated with, endorsed by,\n")
        text("or sponsored by DeepSeek）。\n\n")
        text("本项目以 MIT 许可发布；第三方声明见应用包内的\n")
        text("THIRD_PARTY_NOTICES.md。\n\n")
        link("本项目仓库", Self.repoURL)
        text("　·　")
        link("DeepSeek Harness", Self.upstreamURL)
        text("　·　")
        link("多文件夹工作区", Self.mfwURL)

        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate()
    }

    // MARK: - preferences

    @objc private func showPreferences() {
        if prefsController == nil {
            let controller = PreferencesWindowController()
            controller.onRestartNeeded = { [weak self] in self?.restartInstance() }
            controller.onChanged = { [weak self] in self?.log("preferences changed (applies next start)") }
            prefsController = controller
        }
        prefsController?.showWindow(nil)
        prefsController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Offered when the app adopts an instance that a different backend started:
    /// the preference cannot take effect until that one is stopped.
    private func offerSwitchToPreferredBackend(running: Backend) {
        let wanted = Preferences.shared.backend
        let alert = NSAlert()
        alert.messageText = "当前运行的是 \(running.title)"
        alert.informativeText = "偏好设置里选的是 \(wanted.title)，但端口上的实例是上一次用 "
            + "\(running.title) 启动的，还在运行。要现在停掉它并以 \(wanted.title) 重启吗？"
        alert.addButton(withTitle: "现在重启")
        alert.addButton(withTitle: "保持现状")
        if alert.runModal() == .alertFirstButtonReturn {
            restartInstance()
        }
    }

    /// Switch the served instance over to the current settings.
    ///
    /// Order matters: stop with the backend that actually started the instance
    /// (`activeBackend`), then start with the one the user now wants. Stopping
    /// under the new backend would look in the wrong state dir, the launcher
    /// would refuse, and the old instance would survive.
    private func restartInstance() {
        let wanted = Preferences.shared.backend
        log("restarting: \(activeBackend.rawValue) → \(wanted.rawValue)")
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }

            let (stopCode, stopOut) = self.runScript("stop", backend: self.activeBackend)
            self.log("stop (\(self.activeBackend.rawValue)) exit=\(stopCode)")
            // A refused stop means the port is still held by something we must
            // not touch. Starting anyway would either fail or — worse — succeed
            // against the survivor and look like the switch worked.
            if stopCode != 0, self.isUp() {
                let detail = stopOut.trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "无法停止当前实例，后端未切换"
                    alert.informativeText = (detail.isEmpty ? "详见日志" : detail)
                        + "\n\n端口 \(self.port) 上的服务仍在运行，设置将在它停止后生效。"
                    alert.addButton(withTitle: "好")
                    alert.runModal()
                }
                return
            }

            let (startCode, startOut) = self.runScript("start", backend: wanted)
            self.log("start (\(wanted.rawValue)) exit=\(startCode)")
            guard startCode == 0 else {
                let detail = startOut.trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "以 \(wanted.title) 启动失败"
                    alert.informativeText = detail.isEmpty ? "未知错误，详见日志" : detail
                    alert.addButton(withTitle: "好")
                    alert.runModal()
                }
                return
            }

            // Confirm the running instance really is the new backend's, rather
            // than trusting the exit code.
            let owner = self.detectActiveBackend()
            self.activeBackend = owner ?? wanted
            DispatchQueue.main.async {
                self.refreshStateDir()
                if owner != wanted {
                    let alert = NSAlert()
                    alert.messageText = "切换结果与预期不符"
                    alert.informativeText = "启动命令成功了，但端口 \(self.port) 上的服务并不属于 "
                        + "\(wanted.title)（检测到：\(owner?.title ?? "非本应用启动"))。详见日志。"
                    alert.addButton(withTitle: "好")
                    alert.runModal()
                    return
                }
                for tab in self.tabs {
                    tab.webView.load(URLRequest(url: self.baseURL))
                }
                self.log("switched to \(wanted.rawValue), \(self.tabs.count) tab(s) reloaded")
            }
        }
    }

    // MARK: - menus & shortcuts

    @objc private func newTabAction() { addTab() }

    @objc private func closeTabAction() {
        if let i = selectedIndex { closeTab(at: i) }
    }

    @objc private func reloadTabAction() {
        if let i = selectedIndex { tabs[i].webView.reload() }
    }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        let about = appMenu.addItem(withTitle: "关于 DSH Desktop",
                                    action: #selector(showAboutPanel),
                                    keyEquivalent: "")
        about.target = self
        appMenu.addItem(.separator())
        let prefs = appMenu.addItem(withTitle: "偏好设置…",
                                    action: #selector(showPreferences),
                                    keyEquivalent: ",")
        prefs.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 DSH Desktop",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: Selector(("cut:")), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: Selector(("copy:")), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: Selector(("paste:")), keyEquivalent: "v")
        editMenu.addItem(withTitle: "删除", action: Selector(("delete:")), keyEquivalent: "")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "全选", action: Selector(("selectAll:")), keyEquivalent: "a")
        editItem.submenu = editMenu

        let tabItem = NSMenuItem()
        main.addItem(tabItem)
        let tabMenu = NSMenu(title: "标签页")
        let newTab = NSMenuItem(title: "新建标签页", action: #selector(newTabAction), keyEquivalent: "t")
        newTab.target = self
        tabMenu.addItem(newTab)
        let closeTab = NSMenuItem(title: "关闭标签页", action: #selector(closeTabAction), keyEquivalent: "w")
        closeTab.target = self
        tabMenu.addItem(closeTab)
        let reload = NSMenuItem(title: "重新加载", action: #selector(reloadTabAction), keyEquivalent: "r")
        reload.target = self
        tabMenu.addItem(reload)
        tabMenu.addItem(NSMenuItem.separator())
        tabMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "W")
        tabItem.submenu = tabMenu

        let winItem = NSMenuItem()
        main.addItem(winItem)
        let winMenu = NSMenu(title: "窗口")
        winMenu.addItem(withTitle: "最小化", action: Selector(("performMiniaturize:")), keyEquivalent: "m")
        winMenu.addItem(withTitle: "缩放", action: Selector(("performZoom:")), keyEquivalent: "")
        winItem.submenu = winMenu
        NSApp.windowsMenu = winMenu

        NSApp.mainMenu = main
    }
}



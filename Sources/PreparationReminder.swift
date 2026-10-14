import AppKit

/// A passive bubble: it never activates the app or intercepts typing/clicks.
final class PreparationReminder: NSPanel {
    private let bubble = PreparationBubbleView(frame: NSRect(x: 0, y: 0, width: 292, height: 104))
    private weak var anchorButton: NSStatusBarButton?
    private weak var anchorWindow: NSWindow?
    private var originalPostsFrameChanges = true
    private var pendingPlacement: DispatchWorkItem?
    private var seconds = 0

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: bubble.bounds, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        contentView = bubble
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        animationBehavior = .none
    }

    func show(below button: NSStatusBarButton, seconds: Int) {
        guard let window = button.window else {
            hide()
            return
        }
        if anchorButton !== button || anchorWindow !== window {
            hide()
            anchorButton = button
            anchorWindow = window
            originalPostsFrameChanges = button.postsFrameChangedNotifications
            button.postsFrameChangedNotifications = true

            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(anchorGeometryChanged(_:)),
                               name: NSView.frameDidChangeNotification, object: button)
            for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification,
                         NSWindow.didChangeScreenNotification] {
                center.addObserver(self, selector: #selector(anchorGeometryChanged(_:)),
                                   name: name, object: window)
            }
        }
        self.seconds = seconds
        schedulePlacement()
    }

    func hide() {
        pendingPlacement?.cancel()
        pendingPlacement = nil
        let center = NotificationCenter.default
        if let button = anchorButton {
            center.removeObserver(self, name: NSView.frameDidChangeNotification, object: button)
            button.postsFrameChangedNotifications = originalPostsFrameChanges
        }
        if let window = anchorWindow {
            for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification,
                         NSWindow.didChangeScreenNotification] {
                center.removeObserver(self, name: name, object: window)
            }
        }
        anchorButton = nil
        anchorWindow = nil
        orderOut(nil)
    }

    @objc private func anchorGeometryChanged(_ notification: Notification) {
        schedulePlacement()
    }

    private func schedulePlacement() {
        pendingPlacement?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingPlacement = nil
            self?.placeIfReady()
        }
        pendingPlacement = work
        // Coalesce button and window geometry notifications from the same update.
        DispatchQueue.main.async(execute: work)
    }

    private func placeIfReady() {
        guard let button = anchorButton else { return }
        guard let window = button.window, let screen = window.screen else {
            hide()
            return
        }
        window.contentView?.layoutSubtreeIfNeeded()
        // Changing the image resizes the status-bar window asynchronously.
        // View layout alone cannot flush that resize: wait for real geometry
        // that fits the new image instead of showing at the old icon's center.
        let requiredWidth = max(button.image?.size.width ?? 0, button.intrinsicContentSize.width)
        guard button.bounds.width + 0.5 >= requiredWidth,
              window.frame.width + 0.5 >= button.frame.width else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screenFrame = screen.frame
        let size = bubble.bounds.size
        let x = min(max(anchor.midX - size.width / 2, screenFrame.minX + 12),
                    screenFrame.maxX - size.width - 12)
        // Also stay below the menu bar when its button is offscreen/auto-hidden.
        let top = min(anchor.minY - 6, screenFrame.maxY - NSStatusBar.system.thickness - 6)
        let y = max(screenFrame.minY + 12, top - size.height)
        bubble.update(seconds: seconds, arrowX: anchor.midX - x)
        setFrameOrigin(NSPoint(x: x, y: y))
        if !isVisible { orderFrontRegardless() }
    }
}

private final class PreparationBubbleView: NSView {
    private let countdown = NSTextField(labelWithString: "")
    private var arrowX: CGFloat = 146
    private let fill = NSColor(srgbRed: 1, green: 0.91, blue: 0.70, alpha: 1)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let title = NSTextField(labelWithString: "准备开始休息")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = NSColor(srgbRed: 0.25, green: 0.16, blue: 0.04, alpha: 1)
        title.frame = NSRect(x: 18, y: 56, width: 190, height: 24)
        addSubview(title)

        countdown.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        countdown.textColor = NSColor(srgbRed: 0.51, green: 0.27, blue: 0.02, alpha: 1)
        countdown.alignment = .right
        countdown.frame = NSRect(x: 210, y: 57, width: 64, height: 22)
        addSubview(countdown)

        let detail = NSTextField(labelWithString: "请看向远处，让眼睛放松 20 秒")
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = NSColor(srgbRed: 0.40, green: 0.31, blue: 0.17, alpha: 1)
        detail.frame = NSRect(x: 18, y: 23, width: 256, height: 20)
        addSubview(detail)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(seconds: Int, arrowX: CGFloat) {
        let text = "\(seconds) 秒后"
        if countdown.stringValue != text { countdown.stringValue = text }
        let newArrowX = min(max(arrowX, 20), bounds.width - 20)
        if self.arrowX != newArrowX {
            self.arrowX = newArrowX
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        let body = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - 8)
        NSBezierPath(roundedRect: body, xRadius: 14, yRadius: 14).fill()
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: arrowX - 9, y: body.maxY - 1))
        arrow.line(to: NSPoint(x: arrowX, y: bounds.maxY))
        arrow.line(to: NSPoint(x: arrowX + 9, y: body.maxY - 1))
        arrow.close()
        arrow.fill()
    }
}

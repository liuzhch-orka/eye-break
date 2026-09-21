import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum Phase {
        case working, preparing, resting

        var duration: TimeInterval {
            switch self {
            case .working: return 20 * 60
            case .preparing: return 3
            case .resting: return 20
            }
        }

        var next: Phase {
            switch self {
            case .working: return .preparing
            case .preparing: return .resting
            case .resting: return .working
            }
        }
    }

    private var statusItem: NSStatusItem!
    private let statusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let pauseMenuItem = NSMenuItem(title: "暂停", action: #selector(togglePause), keyEquivalent: "")
    private let loginMenuItem = NSMenuItem(title: "开机自启", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let loginSettingsMenuItem = NSMenuItem(title: "在系统设置中允许…", action: #selector(openLoginSettings), keyEquivalent: "")
    private let loginErrorMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var loginError: String?
    private var timer: Timer?
    private var phase: Phase = .working
    private var deadline: TimeInterval = 0
    private var pausedRemaining: TimeInterval?
    private var lastRenderedDescription: String?
    private var lastRenderedImageKey: String?
    private var symbolImages: [String: NSImage] = [:]
    private var isMenuOpen = false
    private var isSleeping = false
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        statusItem.button?.imagePosition = .imageLeading

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        let restItem = NSMenuItem(title: "立即休息", action: #selector(restNow), keyEquivalent: "")
        restItem.target = self
        menu.addItem(restItem)
        pauseMenuItem.target = self
        menu.addItem(pauseMenuItem)
        menu.addItem(.separator())
        loginMenuItem.target = self
        menu.addItem(loginMenuItem)
        loginSettingsMenuItem.target = self
        menu.addItem(loginSettingsMenuItem)
        loginErrorMenuItem.isEnabled = false
        menu.addItem(loginErrorMenuItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 EyeBreak", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
        updateLoginMenu()

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(suspendTimer), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(suspendTimer), name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(wakeUp), name: NSWorkspace.didWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(wakeUp), name: NSWorkspace.screensDidWakeNotification, object: nil)

        begin(.working)
    }

    private func scheduleNextUpdate() {
        timer?.invalidate()
        timer = nil
        guard pausedRemaining == nil, !isSleeping else { return }

        let remaining = max(0, deadline - now)
        let needsSeconds = phase != .working || isMenuOpen
        // Idle: wait directly for the phase deadline. Visible countdown: wait
        // for the next displayed second, always calculated from the deadline.
        let delay = needsSeconds ? remaining - max(0, ceil(remaining) - 1) : remaining
        let timer = Timer(timeInterval: max(0.001, delay), target: self,
                          selector: #selector(timerFired(_:)), userInfo: nil, repeats: false)
        timer.tolerance = needsSeconds ? 0.02 : 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func begin(_ phase: Phase) {
        self.phase = phase
        deadline = now + phase.duration
        render()
        scheduleNextUpdate()
    }

    @objc private func timerFired(_ timer: Timer) {
        refresh()
    }

    private func refresh() {
        if pausedRemaining == nil, !isSleeping, now >= deadline {
            begin(phase.next)
        } else {
            render()
            scheduleNextUpdate()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        refresh()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateLoginMenu()
    }

    private func updateLoginMenu() {
        let status = SMAppService.mainApp.status
        loginMenuItem.state = status == .enabled ? .on : status == .requiresApproval ? .mixed : .off
        loginMenuItem.title = status == .requiresApproval ? "开机自启（待系统允许）" : "开机自启"
        loginMenuItem.toolTip = "登录 macOS 后自动启动 EyeBreak"
        loginSettingsMenuItem.isHidden = status != .requiresApproval
        loginErrorMenuItem.isHidden = loginError == nil
        loginErrorMenuItem.title = loginError.map { "设置失败：\($0)" } ?? ""
        loginErrorMenuItem.toolTip = loginError
    }

    @objc private func toggleLaunchAtLogin() {
        loginError = nil
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled, .requiresApproval:
                // A pending registration can also be cancelled with the toggle.
                try service.unregister()
            case .notRegistered, .notFound:
                try service.register()
            @unknown default:
                loginError = "无法识别系统状态，请在系统设置中检查登录项。"
            }
        } catch {
            loginError = error.localizedDescription
        }
        updateLoginMenu()
        if loginError != nil || service.status == .requiresApproval {
            // Keep feedback inside the menu, including a route to system approval.
            statusItem.button?.performClick(nil)
        }
    }

    @objc private func openLoginSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        refresh()
    }

    private func render() {
        let seconds = max(0, Int(ceil(pausedRemaining ?? (deadline - now))))
        let symbol: String
        let description: String
        let background: NSColor?

        if pausedRemaining != nil {
            symbol = "pause.circle"
            description = "提醒已暂停"
            background = nil
        } else {
            switch phase {
            case .working:
                symbol = "eye"
                description = isMenuOpen
                    ? String(format: "距离下次休息 %02d:%02d", seconds / 60, seconds % 60)
                    : "每 20 分钟提醒远眺 · 点击查看剩余时间"
                background = nil
            case .preparing:
                symbol = "eye"
                description = "准备远眺：\(seconds) 秒后开始"
                background = NSColor(srgbRed: 1, green: 0.70, blue: 0.18, alpha: 1)
            case .resting:
                symbol = "leaf"
                description = "请看向远处，剩余 \(seconds) 秒"
                background = NSColor(srgbRed: 0.35, green: 0.83, blue: 0.53, alpha: 1)
            }
        }

        guard description != lastRenderedDescription else { return }
        lastRenderedDescription = description

        let imageKey = background == nil ? symbol : "\(symbol)-\(seconds)"
        if imageKey != lastRenderedImageKey {
            lastRenderedImageKey = imageKey
            if let background {
                statusItem.button?.image = countdownBadge(symbol: symbol, seconds: seconds, background: background)
            } else {
                statusItem.button?.image = symbolImage(symbol)
            }
        }
        statusItem.button?.toolTip = description
        statusItem.button?.setAccessibilityLabel(description)
        statusMenuItem.title = description
        pauseMenuItem.title = pausedRemaining == nil ? "暂停" : "继续"
    }

    private func symbolImage(_ symbol: String, forCountdown: Bool = false) -> NSImage? {
        let key = forCountdown ? "\(symbol)-black" : symbol
        if let image = symbolImages[key] { return image }
        var image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        if forCountdown {
            let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.black]))
            image = image?.withSymbolConfiguration(configuration)
        }
        image?.isTemplate = !forCountdown
        symbolImages[key] = image
        return image
    }

    private func countdownBadge(symbol: String, seconds: Int, background: NSColor) -> NSImage {
        let icon = symbolImage(symbol, forCountdown: true)
        let label = NSAttributedString(string: String(seconds), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.black
        ])

        // Draw the whole badge as a non-template image so macOS preserves its
        // background and dark foreground in both light and dark menu bars.
        let badge = NSImage(size: NSSize(width: 58, height: 22), flipped: false) { rect in
            background.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: 1), xRadius: 5, yRadius: 5).fill()
            if let icon {
                let size = icon.size
                let scale = min(14 / size.width, 14 / size.height)
                let width = size.width * scale
                let height = size.height * scale
                icon.draw(in: NSRect(x: 7 + (14 - width) / 2, y: (rect.height - height) / 2,
                                    width: width, height: height))
            }
            let size = label.size()
            label.draw(at: NSPoint(x: 28 + (23 - size.width) / 2, y: (rect.height - size.height) / 2))
            return true
        }
        badge.isTemplate = false
        return badge
    }

    @objc private func restNow() {
        pausedRemaining = nil
        begin(.preparing)
    }

    @objc private func togglePause() {
        if let remaining = pausedRemaining {
            deadline = now + remaining
            pausedRemaining = nil
        } else {
            pausedRemaining = max(0, deadline - now)
        }
        refresh()
    }

    @objc private func suspendTimer() {
        isSleeping = true
        timer?.invalidate()
        timer = nil
    }

    @objc private func wakeUp() {
        isSleeping = false
        // A sleeping Mac counts as time away; start a fresh work interval.
        if pausedRemaining != nil {
            pausedRemaining = Phase.working.duration
        }
        begin(.working)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

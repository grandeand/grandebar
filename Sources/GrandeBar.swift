import AppKit
import Foundation
import ServiceManagement

private enum AppConfig {
    static let defaultAPIBase = "http://localhost:8317"
    static let apiBaseKey = "apiBase"
    static let defaultsKey = "managementKey"
    static let lastRefreshKey = "lastRefreshAt"
    static let autoRefreshMinutesKey = "autoRefreshMinutes"
    static let autoRefreshOptions = [0, 5, 10, 15, 30, 60]

    static func apiBase() -> String {
        let saved = UserDefaults.standard.string(forKey: apiBaseKey) ?? defaultAPIBase
        return normalizedBase(saved)
    }

    static func managementURL() -> URL {
        URL(string: "\(apiBase())/management.html#/quota")!
    }

    static func autoRefreshMinutes() -> Int {
        let saved = UserDefaults.standard.integer(forKey: autoRefreshMinutesKey)
        return autoRefreshOptions.contains(saved) ? saved : 0
    }

    static func autoRefreshTitle(for minutes: Int) -> String {
        minutes == 0 ? "Manual only" : "\(minutes) min"
    }

    static func normalizedBase(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") ? trimmed : "https://\(trimmed)"
        return withScheme.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

private enum UI {
    static let popoverWidth: CGFloat = 315
    static let popoverHeight: CGFloat = 475
    static let cardWidth: CGFloat = 291
    static let accountCardHeight: CGFloat = 106
    static let summaryCardHeight: CGFloat = 104
}

private struct QuotaCard {
    let name: String
    let plan: String
    let sessionPercent: Int?
    let sessionResetSeconds: Int?
    let weeklyPercent: Int?
    let weeklyResetSeconds: Int?
    let resetCreditsAvailableCount: Int?
    let resetCreditExpiries: [Date]
    let updatedAt: Date
}

private struct LocalUsage {
    let today: Double
    let week: Double
    let month: Double
}

private struct ResetCreditsInfo {
    let availableCount: Int?
    let expiries: [Date]
}

private struct TotalLimitSummary {
    let sessionRemaining: Int?
    let sessionTotal: Int?
    let weeklyRemaining: Int?
    let weeklyTotal: Int?
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var quotaViewController: QuotaViewController!
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "GrandeBar"
        let iconConfig = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let icon = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "GrandeBar")?.withSymbolConfiguration(iconConfig)
        icon?.isTemplate = true
        statusItem.button?.image = icon
        statusItem.button?.imagePosition = .imageLeading
        setStatusTitle("--%")
        statusItem.button?.toolTip = "GrandeBar"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        quotaViewController = QuotaViewController { [weak self] title, tooltip in
            self?.setStatusTitle(title)
            self?.statusItem.button?.toolTip = tooltip
        }

        popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: UI.popoverWidth, height: UI.popoverHeight)
        popover.contentViewController = quotaViewController
    }

    @objc private func statusItemClicked() {
        guard let button = statusItem.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu(from: button)
            return
        }

        if popover.isShown {
            closePopover()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            startEventMonitors()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        stopEventMonitors()
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Refresh", action: #selector(refresh), keyEquivalent: "r")
        menu.addItem(withTitle: "Open Panel", action: #selector(openPanel), keyEquivalent: "o")
        menu.addItem(withTitle: "Settings", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func refresh() {
        quotaViewController.refreshQuota()
    }

    @objc private func openPanel() {
        NSWorkspace.shared.open(AppConfig.managementURL())
    }

    @objc private func showSettings() {
        quotaViewController.showSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func closePopover() {
        popover.performClose(nil)
        stopEventMonitors()
    }

    private func startEventMonitors() {
        stopEventMonitors()

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { self?.closePopover() }
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window === self.popover.contentViewController?.view.window {
                return event
            }
            self.closePopover()
            return event
        }
    }

    private func stopEventMonitors() {
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
    }

    private func setStatusTitle(_ title: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .baselineOffset: -1
        ]
        statusItem.button?.attributedTitle = NSAttributedString(string: title, attributes: attributes)
    }
}

final class QuotaViewController: NSViewController {
    private let statusUpdate: (String, String) -> Void
    private let api = QuotaAPI()
    private var stackView: NSStackView!
    private var scrollView: NSScrollView!
    private var subtitleLabel: NSTextField!
    private var usageLabel: NSTextField!
    private var lastRefreshLabel: NSTextField!
    private var refreshButton: NSButton!
    private var copyButton: NSButton!
    private var lastRefreshAt: Date?
    private var elapsedTimer: Timer?
    private var autoRefreshTimer: Timer?
    private var isRefreshing = false
    private var latestCards: [QuotaCard] = []
    private var latestUsage: LocalUsage?

    init(statusUpdate: @escaping (String, String) -> Void) {
        self.statusUpdate = statusUpdate
        super.init(nibName: nil, bundle: nil)
        updateAutoRefreshTimer()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: UI.popoverWidth, height: UI.popoverHeight))
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedRed: 0.035, green: 0.055, blue: 0.078, alpha: 0.94).cgColor
        root.widthAnchor.constraint(equalToConstant: UI.popoverWidth).isActive = true
        root.heightAnchor.constraint(equalToConstant: UI.popoverHeight).isActive = true

        let headerIcon = NSImageView(image: NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: nil) ?? NSImage())
        headerIcon.contentTintColor = NSColor.systemBlue.withAlphaComponent(0.95)
        headerIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        headerIcon.translatesAutoresizingMaskIntoConstraints = false

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false

        let titleBlock = NSStackView()
        titleBlock.orientation = .vertical
        titleBlock.alignment = .leading
        titleBlock.spacing = 1
        titleBlock.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "GrandeBar")
        title.font = .systemFont(ofSize: 15, weight: .bold)
        title.textColor = .white

        subtitleLabel = NSTextField(labelWithString: "Codex quota")
        subtitleLabel.font = .systemFont(ofSize: 10, weight: .medium)
        subtitleLabel.textColor = NSColor.white.withAlphaComponent(0.64)
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        titleBlock.addArrangedSubview(title)
        titleBlock.addArrangedSubview(subtitleLabel)
        titleBlock.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        refreshButton = toolbarButton("arrow.clockwise", title: nil, action: #selector(refreshQuota), width: 28)
        let openButton = toolbarButton("arrow.up.right.square", title: nil, action: #selector(openPanel), width: 28)

        header.addSubview(headerIcon)
        header.addSubview(titleBlock)
        header.addSubview(refreshButton)
        header.addSubview(openButton)

        let divider = NSView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor

        stackView = FlippedStackView()
        stackView.frame = NSRect(x: 0, y: 0, width: UI.popoverWidth, height: 1)
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 10
        stackView.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.documentView = stackView

        let footer = RoundedView(color: NSColor(calibratedRed: 0.055, green: 0.075, blue: 0.095, alpha: 0.78), radius: 8, borderColor: NSColor.white.withAlphaComponent(0.11))
        footer.translatesAutoresizingMaskIntoConstraints = false

        let footerTitle = NSTextField(labelWithString: "ccusage")
        footerTitle.font = .systemFont(ofSize: 10, weight: .medium)
        footerTitle.textColor = NSColor.white.withAlphaComponent(0.70)
        footerTitle.translatesAutoresizingMaskIntoConstraints = false

        lastRefreshLabel = NSTextField(labelWithString: "Son Güncelleme: yok")
        lastRefreshLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        lastRefreshLabel.textColor = NSColor.white.withAlphaComponent(0.45)
        lastRefreshLabel.alignment = .right
        lastRefreshLabel.translatesAutoresizingMaskIntoConstraints = false

        usageLabel = NSTextField(labelWithString: "Today -- · Week -- · Month --")
        usageLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        usageLabel.textColor = NSColor.white.withAlphaComponent(0.82)
        usageLabel.lineBreakMode = .byTruncatingTail
        usageLabel.translatesAutoresizingMaskIntoConstraints = false
        usageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        copyButton = footerIconButton("doc.on.doc", action: #selector(copyUsageTable))
        copyButton.toolTip = "Copy ccusage summary"

        footer.addSubview(footerTitle)
        footer.addSubview(lastRefreshLabel)
        footer.addSubview(usageLabel)
        footer.addSubview(copyButton)

        root.addSubview(header)
        root.addSubview(divider)
        root.addSubview(scrollView)
        root.addSubview(footer)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            header.heightAnchor.constraint(equalToConstant: 32),

            headerIcon.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            headerIcon.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            headerIcon.widthAnchor.constraint(equalToConstant: 28),
            headerIcon.heightAnchor.constraint(equalToConstant: 28),

            openButton.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            openButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            refreshButton.trailingAnchor.constraint(equalTo: openButton.leadingAnchor, constant: -6),
            refreshButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            titleBlock.leadingAnchor.constraint(equalTo: headerIcon.trailingAnchor, constant: 8),
            titleBlock.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -8),
            titleBlock.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            divider.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            divider.heightAnchor.constraint(equalToConstant: 1),

            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 10),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
            footer.heightAnchor.constraint(equalToConstant: 48),

            footerTitle.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 9),
            footerTitle.trailingAnchor.constraint(lessThanOrEqualTo: lastRefreshLabel.leadingAnchor, constant: -8),
            footerTitle.topAnchor.constraint(equalTo: footer.topAnchor, constant: 7),

            lastRefreshLabel.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -12),
            lastRefreshLabel.centerYAnchor.constraint(equalTo: footerTitle.centerYAnchor),
            lastRefreshLabel.widthAnchor.constraint(equalToConstant: 128),

            usageLabel.leadingAnchor.constraint(equalTo: footerTitle.leadingAnchor),
            usageLabel.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -2),
            usageLabel.topAnchor.constraint(equalTo: footerTitle.bottomAnchor, constant: 6),

            copyButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -3),
            copyButton.centerYAnchor.constraint(equalTo: usageLabel.centerYAnchor)
        ])

        view = root
        if let saved = UserDefaults.standard.object(forKey: AppConfig.lastRefreshKey) as? Date {
            lastRefreshAt = saved
        }
        renderIdle()
        startElapsedTimer()
        updateLastRefreshLabel()
    }

    @objc func refreshQuota() {
        loadViewIfNeeded()
        guard !isRefreshing else { return }
        isRefreshing = true
        lastRefreshLabel.stringValue = "Yenileniyor..."
        refreshLocalUsage()
        refreshButton.isEnabled = false
        subtitleLabel.stringValue = "Refreshing..."

        api.fetchQuota { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRefreshing = false
                self.refreshButton.isEnabled = true
                self.lastRefreshAt = Date()
                UserDefaults.standard.set(self.lastRefreshAt, forKey: AppConfig.lastRefreshKey)
                self.updateLastRefreshLabel()
                switch result {
                case .success(let cards):
                    self.render(cards: cards)
                case .failure(let error):
                    self.renderError(error.localizedDescription)
                }
            }
        }
    }

    deinit {
        elapsedTimer?.invalidate()
        autoRefreshTimer?.invalidate()
    }

    @objc private func openPanel() {
        NSWorkspace.shared.open(AppConfig.managementURL())
    }

    @objc private func copyUsageTable() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(usageTableText(), forType: .string)
        copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10.8, weight: .regular))
        copyButton.toolTip = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10.8, weight: .regular))
            self?.copyButton.toolTip = "Copy ccusage summary"
        }
    }

    func showSettings() {
        let baseField = NSTextField(string: AppConfig.apiBase())
        let keyField = NSSecureTextField(string: UserDefaults.standard.string(forKey: AppConfig.defaultsKey) ?? "")
        let autoRefreshPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        let launchAtLogin = NSButton(checkboxWithTitle: "Launch at Login", target: nil, action: nil)
        launchAtLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
        baseField.placeholderString = "https://ai.example.com"
        keyField.placeholderString = "Management key"
        for minutes in AppConfig.autoRefreshOptions {
            autoRefreshPopup.addItem(withTitle: AppConfig.autoRefreshTitle(for: minutes))
            autoRefreshPopup.lastItem?.representedObject = minutes
        }
        autoRefreshPopup.selectItem(withTitle: AppConfig.autoRefreshTitle(for: AppConfig.autoRefreshMinutes()))

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 158))
        let baseLabel = NSTextField(labelWithString: "Base URL")
        let keyLabel = NSTextField(labelWithString: "Management key")
        let autoRefreshLabel = NSTextField(labelWithString: "Auto refresh")
        baseLabel.frame = NSRect(x: 0, y: 134, width: 340, height: 18)
        baseField.frame = NSRect(x: 0, y: 106, width: 340, height: 24)
        keyLabel.frame = NSRect(x: 0, y: 80, width: 340, height: 18)
        keyField.frame = NSRect(x: 0, y: 52, width: 340, height: 24)
        autoRefreshLabel.frame = NSRect(x: 0, y: 24, width: 150, height: 22)
        autoRefreshPopup.frame = NSRect(x: 156, y: 22, width: 184, height: 26)
        launchAtLogin.frame = NSRect(x: 0, y: -4, width: 340, height: 22)
        view.addSubview(baseLabel)
        view.addSubview(baseField)
        view.addSubview(keyLabel)
        view.addSubview(keyField)
        view.addSubview(autoRefreshLabel)
        view.addSubview(autoRefreshPopup)
        view.addSubview(launchAtLogin)

        let alert = NSAlert()
        alert.messageText = "GrandeBar Settings"
        alert.informativeText = "Panel adresi ve management key burada saklanır."
        alert.accessoryView = view
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            UserDefaults.standard.set(AppConfig.normalizedBase(baseField.stringValue), forKey: AppConfig.apiBaseKey)
            UserDefaults.standard.set(keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: AppConfig.defaultsKey)
            UserDefaults.standard.set(autoRefreshPopup.selectedItem?.representedObject as? Int ?? 0, forKey: AppConfig.autoRefreshMinutesKey)
            UserDefaults.standard.synchronize()
            updateAutoRefreshTimer()
            setLaunchAtLogin(launchAtLogin.state == .on)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Launch at Login kaydedilemedi"
            alert.runModal()
        }
    }

    private func refreshLocalUsage() {
        DispatchQueue.global(qos: .utility).async {
            let usage = LocalCodexUsage.read()
            DispatchQueue.main.async {
                if let usage {
                    self.latestUsage = usage
                    self.usageLabel.stringValue = "Today \(LocalCodexUsage.format(usage.today)) · Week \(LocalCodexUsage.format(usage.week)) · Month \(LocalCodexUsage.format(usage.month))"
                } else {
                    self.latestUsage = nil
                    self.usageLabel.stringValue = "ccusage okunamadı"
                }
            }
        }
    }

    private func renderIdle() {
        clearCards()
        let label = NSTextField(labelWithString: "Refresh'e bas")
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.6)
        stackView.addArrangedSubview(label)
        resizeDocument(rowCount: 1)
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateLastRefreshLabel()
        }
    }

    private func updateAutoRefreshTimer() {
        autoRefreshTimer?.invalidate()
        autoRefreshTimer = nil

        let minutes = AppConfig.autoRefreshMinutes()
        guard minutes > 0 else { return }

        let timer = Timer(timeInterval: TimeInterval(minutes * 60), repeats: true) { [weak self] _ in
            self?.refreshQuota()
        }
        RunLoop.main.add(timer, forMode: .common)
        autoRefreshTimer = timer
    }

    private func updateLastRefreshLabel() {
        guard let lastRefreshAt else {
            lastRefreshLabel.stringValue = "Son Güncelleme: yok"
            return
        }
        let seconds = max(0, Int(Date().timeIntervalSince(lastRefreshAt)))
        if seconds < 60 {
            lastRefreshLabel.stringValue = "Son Güncelleme: \(seconds) sn"
        } else {
            lastRefreshLabel.stringValue = "Son Güncelleme: \(seconds / 60) dk \(seconds % 60) sn"
        }
    }

    private func render(cards: [QuotaCard]) {
        clearCards()

        if cards.isEmpty {
            renderError("No Codex credentials found")
            return
        }

        subtitleLabel.stringValue = summaryText(for: cards)
        latestCards = cards
        let summary = totalLimitSummary(for: cards)
        let title = sessionPoolTitle(summary)
        let tooltip = cards.map { "\($0.name): \($0.sessionPercent.map(String.init) ?? "--")% session, \($0.weeklyPercent.map(String.init) ?? "--")% weekly" }.joined(separator: "\n")
        statusUpdate(title, tooltip)

        let totalView = TotalLimitCardView(summary: summary)
        totalView.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(totalView)
        totalView.widthAnchor.constraint(equalToConstant: currentCardWidth()).isActive = true

        for card in cards.sorted(by: sortCards) {
            let view = AccountCardView(card: card)
            view.translatesAutoresizingMaskIntoConstraints = false
            stackView.addArrangedSubview(view)
            view.widthAnchor.constraint(equalToConstant: currentCardWidth()).isActive = true
        }
        resizeDocument(rowCount: cards.count + 1)
    }

    private func renderError(_ message: String) {
        clearCards()
        subtitleLabel.stringValue = "Could not load quota"
        statusUpdate(message.contains("IP banned") ? "ban" : "err", message)

        let box = RoundedView(color: NSColor(calibratedRed: 0.18, green: 0.08, blue: 0.08, alpha: 0.72), radius: 16)
        box.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = NSColor(calibratedRed: 1.0, green: 0.38, blue: 0.32, alpha: 1)
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false

        box.addSubview(icon)
        box.addSubview(label)
        stackView.addArrangedSubview(box)

        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: currentCardWidth()),
            box.heightAnchor.constraint(greaterThanOrEqualToConstant: 92),
            icon.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            icon.topAnchor.constraint(equalTo: box.topAnchor, constant: 18),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 16)
        ])
        resizeDocument(rowCount: 1)
    }

    private func clearCards() {
        stackView.arrangedSubviews.forEach {
            stackView.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
    }

    private func resizeDocument(rowCount: Int) {
        let rows = max(1, rowCount)
        let rowsHeight = rowCount <= 1
            ? CGFloat(rows) * 96
            : UI.summaryCardHeight + CGFloat(rows - 1) * UI.accountCardHeight
        let contentHeight = rowsHeight + CGFloat(max(0, rows - 1)) * stackView.spacing
        let width = max(UI.popoverWidth, scrollView.contentSize.width)
        stackView.setFrameSize(NSSize(width: width, height: max(scrollView.contentSize.height + 1, contentHeight)))
        stackView.needsLayout = true
        stackView.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func currentCardWidth() -> CGFloat {
        UI.cardWidth
    }

    private func sortCards(_ lhs: QuotaCard, _ rhs: QuotaCard) -> Bool {
        let left = min(lhs.sessionPercent ?? 101, lhs.weeklyPercent ?? 101)
        let right = min(rhs.sessionPercent ?? 101, rhs.weeklyPercent ?? 101)
        if left != right { return left < right }
        return lhs.name < rhs.name
    }

    private func summaryText(for cards: [QuotaCard]) -> String {
        let resetTotal = cards.compactMap(\.resetCreditsAvailableCount).reduce(0, +)
        return "\(cards.count) account · \(resetTotal) reset"
    }

    private func earliestResetExpiry(in cards: [QuotaCard]) -> (name: String, date: Date)? {
        let now = Date()
        return cards.compactMap { card -> (String, Date)? in
            guard let date = card.resetCreditExpiries.filter({ $0 > now }).sorted().first else { return nil }
            return (card.name, date)
        }.min { $0.1 < $1.1 }
    }

    private func compactAccountName(_ value: String) -> String {
        value.replacingOccurrences(of: "-team", with: "")
    }

    private func formatExpiry(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "d MMM HH:mm"
        return formatter.string(from: date)
    }

    private func totalLimitSummary(for cards: [QuotaCard]) -> TotalLimitSummary {
        let sessions = cards.compactMap(\.sessionPercent)
        let weeklies = cards.compactMap(\.weeklyPercent)
        return TotalLimitSummary(
            sessionRemaining: sessions.isEmpty ? nil : sessions.reduce(0, +),
            sessionTotal: sessions.isEmpty ? nil : sessions.count * 100,
            weeklyRemaining: weeklies.isEmpty ? nil : weeklies.reduce(0, +),
            weeklyTotal: weeklies.isEmpty ? nil : weeklies.count * 100
        )
    }

    private func sessionPoolTitle(_ summary: TotalLimitSummary) -> String {
        guard let remaining = summary.sessionRemaining,
              let total = summary.sessionTotal,
              total > 0 else {
            return "--%"
        }
        return "\(Int((Double(remaining) / Double(total) * 100).rounded()))%"
    }

    private func usageTableText() -> String {
        var usageLine = "ccusage okunamadı."
        if let usage = latestUsage {
            usageLine = "Token cost: today \(LocalCodexUsage.format(usage.today)), this week \(LocalCodexUsage.format(usage.week)), month to date \(LocalCodexUsage.format(usage.month))."
        }

        guard !latestCards.isEmpty else {
            return "\(usageLine)\nAccount quota is not loaded yet."
        }

        let summary = totalLimitSummary(for: latestCards)
        let weeklyTotal = poolPercentText(remaining: summary.weeklyRemaining, total: summary.weeklyTotal)
        let accounts = latestCards
            .sorted(by: sortCards)
            .map { "- \(compactAccountName($0.name)): session \(percentText($0.sessionPercent)), weekly \(percentText($0.weeklyPercent))" }
            .joined(separator: "\n")
        let resetTotal = latestCards.compactMap(\.resetCreditsAvailableCount).reduce(0, +)
        let closestReset = earliestResetExpiry(in: latestCards)
            .map { "\(formatExpiry($0.date)) (\(compactAccountName($0.name)))" } ?? "--"

        return "\(usageLine)\nRemaining total: session \(sessionPoolTitle(summary)), weekly \(weeklyTotal). Reset credits: \(resetTotal), nearest expiry: \(closestReset).\nAccount remaining:\n\(accounts)"
    }

    private func percentText(_ percent: Int?) -> String {
        percent.map { "\($0)%" } ?? "--"
    }

    private func poolPercentText(remaining: Int?, total: Int?) -> String {
        guard let remaining, let total, total > 0 else { return "--" }
        return "\(Int((Double(remaining) / Double(total) * 100).rounded()))%"
    }

    private func toolbarButton(_ symbol: String, title: String?, action: Selector, width: CGFloat) -> NSButton {
        let button = NSButton(title: title ?? "", target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = title == nil ? .imageOnly : .imageLeading
        button.bezelStyle = .rounded
        button.isBordered = true
        button.font = .systemFont(ofSize: 10, weight: .semibold)
        button.contentTintColor = NSColor.white.withAlphaComponent(0.86)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    private func footerIconButton(_ symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10.8, weight: .regular))
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.controlSize = .small
        button.contentTintColor = NSColor.white.withAlphaComponent(0.78)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 19).isActive = true
        button.heightAnchor.constraint(equalToConstant: 19).isActive = true
        return button
    }
}

private final class AccountCardView: RoundedView {
    init(card: QuotaCard) {
        super.init(color: NSColor(calibratedRed: 0.055, green: 0.077, blue: 0.102, alpha: 0.72), radius: 8, borderColor: NSColor.white.withAlphaComponent(0.10))
        translatesAutoresizingMaskIntoConstraints = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.10
        layer?.shadowRadius = 7
        layer?.shadowOffset = NSSize(width: 0, height: -1)

        let accent = NSView()
        accent.wantsLayer = true
        accent.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.82).cgColor
        accent.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: compactName(card.name))
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.textColor = .white
        name.lineBreakMode = .byTruncatingMiddle
        name.translatesAutoresizingMaskIntoConstraints = false

        let resetCount = NSTextField(labelWithString: resetCountText(card))
        resetCount.font = .systemFont(ofSize: 11, weight: .semibold)
        resetCount.textColor = NSColor.white.withAlphaComponent(0.82)
        resetCount.alignment = .right
        resetCount.lineBreakMode = .byTruncatingMiddle
        resetCount.translatesAutoresizingMaskIntoConstraints = false
        resetCount.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let resetExpiry = NSTextField(labelWithString: resetExpiryText(card))
        resetExpiry.font = .monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        resetExpiry.textColor = NSColor.white.withAlphaComponent(0.52)
        resetExpiry.alignment = .right
        resetExpiry.lineBreakMode = .byTruncatingMiddle
        resetExpiry.translatesAutoresizingMaskIntoConstraints = false
        resetExpiry.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let session = MetricView(title: "Session 5h", percent: card.sessionPercent, resetSeconds: card.sessionResetSeconds)
        let weekly = MetricView(title: "Weekly", percent: card.weeklyPercent, resetSeconds: card.weeklyResetSeconds)
        session.translatesAutoresizingMaskIntoConstraints = false
        weekly.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        separator.translatesAutoresizingMaskIntoConstraints = false

        addSubview(accent)
        addSubview(name)
        addSubview(resetCount)
        addSubview(resetExpiry)
        addSubview(separator)
        addSubview(session)
        addSubview(weekly)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: UI.accountCardHeight),

            accent.leadingAnchor.constraint(equalTo: leadingAnchor),
            accent.topAnchor.constraint(equalTo: topAnchor),
            accent.bottomAnchor.constraint(equalTo: bottomAnchor),
            accent.widthAnchor.constraint(equalToConstant: 1),

            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            name.trailingAnchor.constraint(lessThanOrEqualTo: resetCount.leadingAnchor, constant: -10),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 12),

            resetCount.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            resetCount.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            resetCount.widthAnchor.constraint(lessThanOrEqualToConstant: 90),

            resetExpiry.trailingAnchor.constraint(equalTo: resetCount.trailingAnchor),
            resetExpiry.topAnchor.constraint(equalTo: resetCount.bottomAnchor, constant: 2),
            resetExpiry.widthAnchor.constraint(lessThanOrEqualToConstant: 90),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            separator.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 12),
            separator.heightAnchor.constraint(equalToConstant: 1),

            session.leadingAnchor.constraint(equalTo: separator.leadingAnchor),
            session.trailingAnchor.constraint(equalTo: separator.trailingAnchor),
            session.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 8),

            weekly.leadingAnchor.constraint(equalTo: session.leadingAnchor),
            weekly.trailingAnchor.constraint(equalTo: session.trailingAnchor),
            weekly.topAnchor.constraint(equalTo: session.bottomAnchor, constant: 5)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func compactName(_ value: String) -> String {
        value.replacingOccurrences(of: "-team", with: "")
    }

    private func resetCountText(_ card: QuotaCard) -> String {
        let count = card.resetCreditsAvailableCount.map(String.init) ?? "--"
        return "Reset \(count) adet"
    }

    private func resetExpiryText(_ card: QuotaCard) -> String {
        let futureExpiries = card.resetCreditExpiries.filter { $0 > Date() }.sorted()
        guard let first = futureExpiries.first ?? card.resetCreditExpiries.sorted().first else {
            return "--"
        }
        return formatExpiry(first)
    }

    private func formatExpiry(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "d MMM HH:mm"
        return formatter.string(from: date)
    }

}

private final class TotalLimitCardView: RoundedView {
    init(summary: TotalLimitSummary) {
        super.init(color: NSColor(calibratedRed: 0.055, green: 0.075, blue: 0.098, alpha: 0.76), radius: 8, borderColor: NSColor.white.withAlphaComponent(0.14))

        let sessionPercent = percent(remaining: summary.sessionRemaining, total: summary.sessionTotal)
        let weeklyPercent = percent(remaining: summary.weeklyRemaining, total: summary.weeklyTotal)
        let session = TotalMetricView(title: "Session pool", value: valueText(sessionPercent), detail: "toplam kalan", percent: sessionPercent, tint: color(for: sessionPercent))
        let weekly = TotalMetricView(title: "Weekly pool", value: valueText(weeklyPercent), detail: "toplam kalan", percent: weeklyPercent, tint: color(for: weeklyPercent))
        let divider = divider()
        session.translatesAutoresizingMaskIntoConstraints = false
        weekly.translatesAutoresizingMaskIntoConstraints = false
        divider.translatesAutoresizingMaskIntoConstraints = false

        addSubview(session)
        addSubview(divider)
        addSubview(weekly)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: UI.summaryCardHeight),

            session.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            session.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            session.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),

            divider.leadingAnchor.constraint(equalTo: session.trailingAnchor, constant: 10),
            divider.centerYAnchor.constraint(equalTo: centerYAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 64),

            weekly.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 10),
            weekly.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            weekly.topAnchor.constraint(equalTo: session.topAnchor),
            weekly.bottomAnchor.constraint(equalTo: session.bottomAnchor),
            session.widthAnchor.constraint(equalTo: weekly.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func percent(remaining: Int?, total: Int?) -> Int? {
        guard let remaining, let total, total > 0 else { return nil }
        return Int((Double(remaining) / Double(total) * 100).rounded())
    }

    private func valueText(_ percent: Int?) -> String {
        percent.map { "\($0)%" } ?? "--"
    }

    private func color(for percent: Int?) -> NSColor {
        guard let percent else { return NSColor.white.withAlphaComponent(0.55) }
        if percent <= 20 { return NSColor(calibratedRed: 1.0, green: 0.31, blue: 0.29, alpha: 1) }
        if percent <= 60 { return NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.25, alpha: 1) }
        return NSColor(calibratedRed: 0.42, green: 0.84, blue: 0.34, alpha: 1)
    }

    private func divider() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        return view
    }
}

private final class TotalMetricView: RoundedView {
    init(title: String, value: String, detail: String, percent: Int?, tint: NSColor) {
        super.init(color: .clear, radius: 0)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.76)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .bold)
        valueLabel.textColor = tint
        valueLabel.alignment = .center
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 9, weight: .medium)
        detailLabel.textColor = NSColor.white.withAlphaComponent(0.58)
        detailLabel.alignment = .center
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        let bar = ProgressBar(percent: percent)
        bar.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(valueLabel)
        addSubview(detailLabel)
        if percent != nil {
            addSubview(bar)
        }

        var constraints = [
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 0),

            valueLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            valueLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),
        ]

        if percent != nil {
            constraints += [
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            bar.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: 6),
            bar.heightAnchor.constraint(equalToConstant: 5),

            detailLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            detailLabel.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 6)
            ]
        } else {
            constraints += [
                detailLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
                detailLabel.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: 9)
            ]
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class MetricView: NSView {
    init(title: String, percent: Int?, resetSeconds: Int?) {
        super.init(frame: .zero)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.80)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let timeLabel = NSTextField(labelWithString: formatDuration(resetSeconds))
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        timeLabel.textColor = NSColor.white.withAlphaComponent(0.62)
        timeLabel.alignment = .right
        timeLabel.lineBreakMode = .byTruncatingTail
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let percentLabel = NSTextField(labelWithString: percent.map { "\($0)%" } ?? "--")
        percentLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        percentLabel.textColor = color(for: percent)
        percentLabel.alignment = .right
        percentLabel.translatesAutoresizingMaskIntoConstraints = false
        percentLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let bar = ProgressBar(percent: percent)
        bar.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(timeLabel)
        addSubview(percentLabel)
        addSubview(bar)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 21),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.widthAnchor.constraint(equalToConstant: 58),

            timeLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            timeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            timeLabel.widthAnchor.constraint(equalToConstant: 40),

            percentLabel.trailingAnchor.constraint(equalTo: timeLabel.leadingAnchor, constant: -6),
            percentLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            percentLabel.widthAnchor.constraint(equalToConstant: 32),

            bar.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6),
            bar.trailingAnchor.constraint(equalTo: percentLabel.leadingAnchor, constant: -8),
            bar.centerYAnchor.constraint(equalTo: centerYAnchor),
            bar.heightAnchor.constraint(equalToConstant: 5)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func color(for percent: Int?) -> NSColor {
        guard let percent else { return NSColor.white.withAlphaComponent(0.45) }
        if percent <= 20 { return NSColor(calibratedRed: 1.0, green: 0.31, blue: 0.29, alpha: 1) }
        if percent <= 60 { return NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.25, alpha: 1) }
        return NSColor(calibratedRed: 0.42, green: 0.84, blue: 0.34, alpha: 1)
    }

    private func formatDuration(_ seconds: Int?) -> String {
        guard let seconds, seconds > 0 else { return "--" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d\(hours)h" }
        if hours > 0 { return "\(hours)h\(minutes)m" }
        return "\(max(1, minutes))m"
    }
}

private final class ProgressBar: NSView {
    private let percent: Int?

    init(percent: Int?) {
        self.percent = percent
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.34).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()

        guard let percent else { return }
        let width = bounds.width * max(0, min(CGFloat(percent), 100)) / 100
        color(for: percent).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height), xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }

    private func color(for percent: Int) -> NSColor {
        if percent <= 20 { return NSColor(calibratedRed: 1.0, green: 0.31, blue: 0.29, alpha: 1) }
        if percent <= 60 { return NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.25, alpha: 1) }
        return NSColor(calibratedRed: 0.42, green: 0.84, blue: 0.34, alpha: 1)
    }
}

private class RoundedView: NSView {
    init(color: NSColor, radius: CGFloat, borderColor: NSColor? = nil) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        if let borderColor {
            layer?.borderColor = borderColor.cgColor
            layer?.borderWidth = 1
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

private enum LocalCodexUsage {
    static func read() -> LocalUsage? {
        let dates = dateKeys()
        guard let json = ccusageJSON(since: min(dates.weekStart, dates.monthStart)),
              let rows = json["daily"] as? [[String: Any]] else {
            return nil
        }

        var today = 0.0
        var week = 0.0
        var month = 0.0

        for row in rows {
            guard let date = row["date"] as? String,
                  let cost = doubleValue(row["costUSD"]) else { continue }
            if date == dates.today { today += cost }
            if date >= dates.weekStart { week += cost }
            if date >= dates.monthStart { month += cost }
        }

        return LocalUsage(today: today, week: week, month: month)
    }

    static func format(_ amount: Double) -> String {
        String(format: "$%.2f", amount)
    }

    private static func ccusageJSON(since: String) -> [String: Any]? {
        guard let path = ccusagePath() else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["codex", "daily", "--json", "--timezone", TimeZone.current.identifier, "--since", since, "--offline"]
        var environment = ProcessInfo.processInfo.environment
        let extraPath = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = "\(extraPath):\(environment["PATH"] ?? "")"
        process.environment = environment
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func ccusagePath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.npm-global/bin/ccusage",
            "/opt/homebrew/bin/ccusage",
            "/usr/local/bin/ccusage"
        ]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return path
        }
        return ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map { "\($0)/ccusage" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func dateKeys() -> (today: String, weekStart: String, monthStart: String) {
        let now = Date()
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: now)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? today
        return (dateKey(today), dateKey(weekStart), dateKey(monthStart))
    }

    private static func dateKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}

private final class QuotaAPI {
    func fetchQuota(completion: @escaping (Result<[QuotaCard], Error>) -> Void) {
        guard let managementKey = UserDefaults.standard.string(forKey: AppConfig.defaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !managementKey.isEmpty else {
            completion(.failure(NSError(domain: "GrandeBar", code: 1, userInfo: [NSLocalizedDescriptionKey: "Management key is missing"])))
            return
        }

        apiJSON(path: "/auth-files", managementKey: managementKey) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let json):
                let files = (json["files"] as? [[String: Any]] ?? [])
                    .filter { ($0["disabled"] as? Bool) != true }
                    .filter { (($0["auth_index"] as? String) ?? ($0["authIndex"] as? String)) != nil }

                let group = DispatchGroup()
                let lock = NSLock()
                var cards: [QuotaCard] = []
                var firstError: Error?

                for file in files {
                    guard let authIndex = (file["auth_index"] as? String) ?? (file["authIndex"] as? String) else { continue }
                    group.enter()
                    self.fetchCodexUsage(authIndex: authIndex, file: file, managementKey: managementKey) { result in
                        defer { group.leave() }
                        lock.lock()
                        defer { lock.unlock() }
                        switch result {
                        case .success(let card):
                            cards.append(card)
                        case .failure(let error):
                            firstError = firstError ?? error
                        }
                    }
                }

                group.notify(queue: .global(qos: .utility)) {
                    if cards.isEmpty {
                        completion(.failure(firstError ?? NSError(domain: "GrandeBar", code: 2, userInfo: [NSLocalizedDescriptionKey: "No quota data returned"])))
                    } else {
                        completion(.success(cards))
                    }
                }
            }
        }
    }

    private func fetchCodexUsage(authIndex: String, file: [String: Any], managementKey: String, completion: @escaping (Result<QuotaCard, Error>) -> Void) {
        let payload: [String: Any] = [
            "authIndex": authIndex,
            "method": "GET",
            "url": "https://chatgpt.com/backend-api/wham/usage",
            "header": codexHeaders()
        ]

        apiJSON(path: "/api-call", method: "POST", payload: payload, managementKey: managementKey) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let json):
                if let status = json["status_code"] as? Int, status < 200 || status >= 300 {
                    let body = json["body"] as? String ?? "HTTP \(status)"
                    completion(.failure(NSError(domain: "GrandeBar", code: status, userInfo: [NSLocalizedDescriptionKey: body])))
                    return
                }

                let body = json["body"] as? [String: Any] ?? self.parseJSONString(json["body"] as? String)
                let quota = self.quotaWindows(from: body)
                let name = (file["account"] as? String) ?? (file["name"] as? String) ?? authIndex
                let plan = self.planLabel(file["plan"] as? String ?? file["plan_type"] as? String ?? body["plan_type"] as? String)
                self.fetchResetCredits(authIndex: authIndex, managementKey: managementKey) { resets in
                    completion(.success(QuotaCard(
                        name: name,
                        plan: plan,
                        sessionPercent: quota.sessionPercent,
                        sessionResetSeconds: quota.sessionResetSeconds,
                        weeklyPercent: quota.weeklyPercent,
                        weeklyResetSeconds: quota.weeklyResetSeconds,
                        resetCreditsAvailableCount: resets.availableCount,
                        resetCreditExpiries: resets.expiries,
                        updatedAt: Date()
                    )))
                }
            }
        }
    }

    private func fetchResetCredits(authIndex: String, managementKey: String, completion: @escaping (ResetCreditsInfo) -> Void) {
        let payload: [String: Any] = [
            "authIndex": authIndex,
            "method": "GET",
            "url": "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits",
            "header": codexHeaders(extra: [
                "Accept": "application/json",
                "OpenAI-Beta": "codex-1",
                "Originator": "Codex Desktop"
            ])
        ]

        apiJSON(path: "/api-call", method: "POST", payload: payload, managementKey: managementKey) { result in
            guard case .success(let json) = result,
                  (json["status_code"] as? Int).map({ $0 >= 200 && $0 < 300 }) != false else {
                completion(ResetCreditsInfo(availableCount: nil, expiries: []))
                return
            }
            let body = json["body"] as? [String: Any] ?? self.parseJSONString(json["body"] as? String)
            completion(self.resetCredits(from: body))
        }
    }

    private func codexHeaders(extra: [String: String] = [:]) -> [String: String] {
        var headers = [
            "Authorization": "Bearer $TOKEN$",
            "Content-Type": "application/json",
            "User-Agent": "codex_cli_rs/0.76.0 (Debian 13.0.0; x86_64) WindowsTerminal"
        ]
        extra.forEach { headers[$0.key] = $0.value }
        return headers
    }

    private func apiJSON(path: String, method: String = "GET", payload: [String: Any]? = nil, managementKey: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard let url = URL(string: "\(AppConfig.apiBase())/v0/management\(path)") else {
            completion(.failure(NSError(domain: "GrandeBar", code: 3, userInfo: [NSLocalizedDescriptionKey: "Base URL is invalid"])))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("GrandeBar/0.2", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let payload {
            request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }

            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let data = data ?? Data()
            if status < 200 || status >= 300 {
                let message = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
                completion(.failure(NSError(domain: "GrandeBar", code: status, userInfo: [NSLocalizedDescriptionKey: message])))
                return
            }

            do {
                let object = try JSONSerialization.jsonObject(with: data)
                completion(.success(object as? [String: Any] ?? [:]))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    private func parseJSONString(_ string: String?) -> [String: Any] {
        guard let data = string?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    private func resetCredits(from json: [String: Any]) -> ResetCreditsInfo {
        let available = intValue(json["available_count"]) ?? intValue(json["availableCount"])
        let rawCredits = json["credits"] as? [[String: Any]] ?? []
        let expiries = rawCredits.compactMap { credit -> Date? in
            let type = stringValue(credit["reset_type"] ?? credit["resetType"])?.lowercased()
            let status = stringValue(credit["status"])?.lowercased()
            guard (type == nil || type == "codex_rate_limits"),
                  (status == nil || status == "available"),
                  let value = stringValue(credit["expires_at"] ?? credit["expiresAt"]) else {
                return nil
            }
            return parseDate(value)
        }
        return ResetCreditsInfo(availableCount: available ?? expiries.count, expiries: expiries)
    }

    private func quotaWindows(from usage: [String: Any]) -> (sessionPercent: Int?, sessionResetSeconds: Int?, weeklyPercent: Int?, weeklyResetSeconds: Int?) {
        var sessionPercent: Int?
        var sessionResetSeconds: Int?
        var weeklyPercent: Int?
        var weeklyResetSeconds: Int?

        for key in ["rate_limit", "rateLimit"] {
            if let limit = usage[key] as? [String: Any] {
                updateWindows(from: limit, sessionPercent: &sessionPercent, sessionResetSeconds: &sessionResetSeconds, weeklyPercent: &weeklyPercent, weeklyResetSeconds: &weeklyResetSeconds)
            }
        }

        return (sessionPercent, sessionResetSeconds, weeklyPercent, weeklyResetSeconds)
    }

    private func updateWindows(
        from limit: [String: Any],
        sessionPercent: inout Int?,
        sessionResetSeconds: inout Int?,
        weeklyPercent: inout Int?,
        weeklyResetSeconds: inout Int?
    ) {
        for key in ["primary_window", "primaryWindow", "secondary_window", "secondaryWindow"] {
            guard let window = limit[key] as? [String: Any] else { continue }
            let seconds = intValue(window["limit_window_seconds"]) ?? intValue(window["limitWindowSeconds"])
            let usedPercent = intValue(window["used_percent"]) ?? intValue(window["usedPercent"])
            let reset = intValue(window["reset_after_seconds"]) ?? intValue(window["resetAfterSeconds"])
            guard let seconds, let usedPercent else { continue }
            let percent = max(0, min(100, 100 - usedPercent))

            if seconds == 18_000 {
                sessionPercent = percent
                sessionResetSeconds = reset
            } else if seconds == 604_800 || (seconds >= 2_419_200 && seconds <= 2_678_400) {
                weeklyPercent = percent
                weeklyResetSeconds = reset
            }
        }
    }

    private func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return Int(number.doubleValue.rounded()) }
        if let string = value as? String, let number = Double(string) { return Int(number.rounded()) }
        return nil
    }

    private func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }

    private func planLabel(_ value: String?) -> String {
        let normalized = (value ?? "team").lowercased()
        if normalized.contains("team") { return "Team" }
        if normalized.contains("pro") { return "Pro" }
        if normalized.contains("free") { return "Free" }
        return normalized.isEmpty ? "Team" : normalized.capitalized
    }
}

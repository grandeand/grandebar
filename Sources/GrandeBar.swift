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
    static let appearanceKey = "appearanceMode"
    static let appearanceOptions = ["auto", "light", "dark"]
    static let languageKey = "languageMode"
    static let languageOptions = ["auto", "en", "tr"]

    static func apiBase() -> String {
        let saved = UserDefaults.standard.string(forKey: apiBaseKey) ?? defaultAPIBase
        return normalizedBase(saved)
    }

    static func hasManagementKey() -> Bool {
        !(UserDefaults.standard.string(forKey: defaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    static func managementURL() -> URL {
        URL(string: "\(apiBase())/management.html#/quota")!
    }

    static func autoRefreshMinutes() -> Int {
        let saved = UserDefaults.standard.integer(forKey: autoRefreshMinutesKey)
        return autoRefreshOptions.contains(saved) ? saved : 0
    }

    static func autoRefreshTitle(for minutes: Int) -> String {
        minutes == 0 ? L.text("Manual only", "Sadece manuel") : "\(minutes) \(L.text("min", "dk"))"
    }

    static func appearanceMode() -> String {
        let saved = UserDefaults.standard.string(forKey: appearanceKey) ?? "auto"
        return appearanceOptions.contains(saved) ? saved : "auto"
    }

    static func appearanceTitle(for mode: String) -> String {
        switch mode {
        case "light": return L.text("Light", "Açık")
        case "dark": return L.text("Dark", "Koyu")
        default: return L.text("Auto", "Otomatik")
        }
    }

    static func languageMode() -> String {
        let saved = UserDefaults.standard.string(forKey: languageKey) ?? "auto"
        return languageOptions.contains(saved) ? saved : "auto"
    }

    static func languageTitle(for mode: String) -> String {
        switch mode {
        case "en": return "English"
        case "tr": return "Türkçe"
        default: return L.text("System", "Sistem")
        }
    }

    static func normalizedBase(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") ? trimmed : "https://\(trimmed)"
        return withScheme.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

private enum L {
    static var isTurkish: Bool {
        switch AppConfig.languageMode() {
        case "tr": return true
        case "en": return false
        default:
            let preferred = Locale.preferredLanguages.first ?? Locale.current.identifier
            return preferred.lowercased().hasPrefix("tr")
        }
    }

    static func text(_ en: String, _ tr: String) -> String {
        isTurkish ? tr : en
    }
}

private enum UI {
    static let popoverWidth: CGFloat = 315
    static let popoverHeight: CGFloat = 475
    static let cardWidth: CGFloat = 291
    static let accountCardHeight: CGFloat = 106
    static let summaryCardHeight: CGFloat = 104
}

private enum Theme {
    static var appAppearance: NSAppearance? {
        appearance(for: AppConfig.appearanceMode())
    }

    static func appearance(for mode: String) -> NSAppearance? {
        switch mode {
        case "dark": return NSAppearance(named: .darkAqua)
        case "light": return NSAppearance(named: .aqua)
        default: return nil
        }
    }

    static var isDark: Bool {
        let mode = AppConfig.appearanceMode()
        if mode == "dark" { return true }
        if mode == "light" { return false }
        return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }
    static var rootBackground: NSColor {
        isDark
            ? NSColor(calibratedRed: 0.035, green: 0.055, blue: 0.078, alpha: 0.94)
            : NSColor(calibratedRed: 0.93, green: 0.95, blue: 0.97, alpha: 0.96)
    }
    static var cardBackground: NSColor {
        isDark
            ? NSColor(calibratedRed: 0.055, green: 0.077, blue: 0.102, alpha: 0.72)
            : NSColor(calibratedRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.82)
    }
    static var footerBackground: NSColor {
        isDark
            ? NSColor(calibratedRed: 0.055, green: 0.075, blue: 0.095, alpha: 0.78)
            : NSColor(calibratedRed: 0.98, green: 0.985, blue: 0.99, alpha: 0.86)
    }
    static var errorBackground: NSColor {
        isDark
            ? NSColor(calibratedRed: 0.18, green: 0.08, blue: 0.08, alpha: 0.72)
            : NSColor(calibratedRed: 1.0, green: 0.92, blue: 0.91, alpha: 0.86)
    }
    static var border: NSColor { isDark ? NSColor.white.withAlphaComponent(0.11) : NSColor.black.withAlphaComponent(0.12) }
    static var cardBorder: NSColor { isDark ? NSColor.white.withAlphaComponent(0.10) : NSColor.black.withAlphaComponent(0.10) }
    static var divider: NSColor { isDark ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.10) }
    static var subtleDivider: NSColor { isDark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.08) }
    static var progressTrack: NSColor { isDark ? NSColor.black.withAlphaComponent(0.34) : NSColor.black.withAlphaComponent(0.12) }
    static let primaryText = NSColor.labelColor
    static let secondaryText = NSColor.secondaryLabelColor
    static let mutedText = NSColor.tertiaryLabelColor
    static let buttonTint = NSColor.labelColor.withAlphaComponent(0.82)
    static var shadow: NSColor { NSColor.black.withAlphaComponent(isDark ? 0.10 : 0.20) }
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
    /// false when workspace credits / plan blocks further Codex use.
    let allowed: Bool?
    let limitReached: Bool?
    let updatedAt: Date

    var isLocked: Bool {
        if allowed == false { return true }
        if limitReached == true { return true }
        return false
    }
}

private struct LocalUsage {
    let today: Double
    let week: Double
    let month: Double
    let models: [String]
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
        setStatusTitle(" --%\n --%")
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

        DispatchQueue.main.async { [weak self] in
            self?.quotaViewController.showSettingsIfNeeded(refreshAfterSave: true)
        }
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
        menu.addItem(withTitle: L.text("Refresh", "Yenile"), action: #selector(refresh), keyEquivalent: "r")
        menu.addItem(withTitle: L.text("Open Panel", "Paneli Aç"), action: #selector(openPanel), keyEquivalent: "o")
        menu.addItem(withTitle: L.text("Settings", "Ayarlar"), action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: L.text("Quit", "Çık"), action: #selector(quit), keyEquivalent: "q")
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
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        paragraph.minimumLineHeight = 10
        paragraph.maximumLineHeight = 10
        paragraph.lineBreakMode = .byClipping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: title.contains("\n") ? 10.2 : 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
            .baselineOffset: title.contains("\n") ? -4 : -1
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
    /// Second header line: locked / new / warm status (primary line stays short).
    private var detailLabel: NSTextField!
    private var usageLabel: NSTextField!
    private var lastRefreshLabel: NSTextField!
    private var refreshButton: NSButton!
    private var warmButton: NSButton!
    private var copyButton: NSButton!
    private var lastRefreshAt: Date?
    private var elapsedTimer: Timer?
    private var autoRefreshTimer: Timer?
    private var isRefreshing = false
    private var isWarming = false
    private var activeWarmup: SessionWarmupAPI?
    /// Last warm-run "new windows opened" count; shown in subtitle until cleared.
    private var lastWarmNewCount: Int?
    private var warmNewClearWorkItem: DispatchWorkItem?
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
        root.appearance = Theme.appAppearance
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.rootBackground.cgColor
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
        title.textColor = Theme.primaryText

        // Line 1: short classic summary (accounts · resets)
        subtitleLabel = NSTextField(labelWithString: L.text("Codex quota", "Codex kota"))
        subtitleLabel.font = .systemFont(ofSize: 10, weight: .medium)
        subtitleLabel.textColor = Theme.secondaryText
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Line 2: locked / new / warming — has full width under the title block
        detailLabel = NSTextField(labelWithString: "")
        detailLabel.font = .systemFont(ofSize: 10, weight: .medium)
        detailLabel.textColor = Theme.mutedText
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.isHidden = true

        titleBlock.addArrangedSubview(title)
        titleBlock.addArrangedSubview(subtitleLabel)
        titleBlock.addArrangedSubview(detailLabel)
        titleBlock.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        warmButton = toolbarButton("flame", title: nil, action: #selector(warmSessionsClicked), width: 28)
        warmButton.toolTip = L.text("Warm all cold 5h session windows", "Soğuk 5s oturum pencerelerini aç")
        refreshButton = toolbarButton("arrow.clockwise", title: nil, action: #selector(refreshQuota), width: 28)
        refreshButton.toolTip = L.text("Refresh quota", "Kotayı yenile")
        let openButton = toolbarButton("arrow.up.right.square", title: nil, action: #selector(openPanel), width: 28)
        openButton.toolTip = L.text("Open Management Center", "Management Center'ı aç")

        header.addSubview(headerIcon)
        header.addSubview(titleBlock)
        header.addSubview(warmButton)
        header.addSubview(refreshButton)
        header.addSubview(openButton)

        let divider = NSView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Theme.divider.cgColor

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

        let footer = RoundedView(color: Theme.footerBackground, radius: 8, borderColor: Theme.border)
        footer.translatesAutoresizingMaskIntoConstraints = false

        let footerTitle = NSTextField(labelWithString: "ccusage")
        footerTitle.font = .systemFont(ofSize: 10, weight: .medium)
        footerTitle.textColor = Theme.secondaryText
        footerTitle.translatesAutoresizingMaskIntoConstraints = false

        lastRefreshLabel = NSTextField(labelWithString: L.text("Last refresh: never", "Son güncelleme: yok"))
        lastRefreshLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        lastRefreshLabel.textColor = Theme.mutedText
        lastRefreshLabel.alignment = .right
        lastRefreshLabel.translatesAutoresizingMaskIntoConstraints = false

        usageLabel = NSTextField(labelWithString: usageLineText(nil))
        usageLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        usageLabel.textColor = Theme.primaryText
        usageLabel.lineBreakMode = .byTruncatingTail
        usageLabel.translatesAutoresizingMaskIntoConstraints = false
        usageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        copyButton = footerIconButton("doc.on.doc", action: #selector(copyUsageTable))
        copyButton.toolTip = L.text("Copy ccusage summary", "ccusage özetini kopyala")

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
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            // Title + 2 subtitle lines need a bit more than the old 32pt row.
            header.heightAnchor.constraint(equalToConstant: 48),

            headerIcon.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            headerIcon.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            headerIcon.widthAnchor.constraint(equalToConstant: 28),
            headerIcon.heightAnchor.constraint(equalToConstant: 28),

            openButton.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            openButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            refreshButton.trailingAnchor.constraint(equalTo: openButton.leadingAnchor, constant: -6),
            refreshButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            warmButton.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -6),
            warmButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            titleBlock.leadingAnchor.constraint(equalTo: headerIcon.trailingAnchor, constant: 8),
            titleBlock.trailingAnchor.constraint(equalTo: warmButton.leadingAnchor, constant: -8),
            titleBlock.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            divider.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
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
        guard !isRefreshing, !isWarming else { return }
        if showSettingsIfNeeded(refreshAfterSave: true) {
            return
        }
        isRefreshing = true
        lastRefreshLabel.stringValue = L.text("Refreshing...", "Yenileniyor...")
        refreshLocalUsage()
        setHeaderActionsEnabled(false)
        if !isWarming {
            subtitleLabel.stringValue = L.text("Refreshing...", "Yenileniyor...")
            // Keep detail line visible if we already have pool info.
            if latestCards.isEmpty {
                setDetailLine(nil)
            }
        }

        api.fetchQuota { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRefreshing = false
                self.setHeaderActionsEnabled(true)
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

    @objc private func warmSessionsClicked() {
        loadViewIfNeeded()
        guard !isRefreshing, !isWarming else { return }
        if showSettingsIfNeeded(refreshAfterSave: false) {
            return
        }

        isWarming = true
        setHeaderActionsEnabled(false)
        // Primary line stays classic; detail line shows warm progress.
        if !latestCards.isEmpty {
            subtitleLabel.stringValue = summaryText(for: latestCards)
        }
        setDetailLine(detailText(for: latestCards, warming: true))
        lastRefreshLabel.stringValue = L.text("Warming...", "Açılıyor...")

        let warmup = SessionWarmupAPI()
        activeWarmup = warmup
        warmup.warmEligibleAccounts { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.activeWarmup = nil
                self.isWarming = false
                self.setHeaderActionsEnabled(true)

                switch result {
                case .success(let summary):
                    self.recordWarmNewCount(summary.warmed)
                    self.warmButton.toolTip = self.warmTooltip(for: summary)
                    self.refreshQuota()
                case .failure(let error):
                    self.setDetailLine(L.text(
                        "Warm failed · \(error.localizedDescription)",
                        "Warm hata · \(error.localizedDescription)"
                    ))
                    self.warmButton.toolTip = L.text("Warm all cold 5h session windows", "Soğuk 5s oturum pencerelerini aç")
                }
            }
        }
    }

    private func setHeaderActionsEnabled(_ enabled: Bool) {
        warmButton.isEnabled = enabled
        refreshButton.isEnabled = enabled
    }

    private func recordWarmNewCount(_ count: Int) {
        warmNewClearWorkItem?.cancel()
        // Show "warmed N" for 15s (hide cold while visible), then restore cold bucket.
        lastWarmNewCount = count
        if !latestCards.isEmpty {
            setDetailLine(detailText(for: latestCards))
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lastWarmNewCount = nil
            if !self.latestCards.isEmpty {
                self.setDetailLine(self.detailText(for: self.latestCards))
            }
        }
        warmNewClearWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
    }

    private func setDetailLine(_ text: String?) {
        let value = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if value.isEmpty {
            detailLabel.stringValue = ""
            detailLabel.isHidden = true
        } else {
            detailLabel.stringValue = value
            detailLabel.isHidden = false
        }
    }

    private func warmTooltip(for summary: SessionWarmupSummary) -> String {
        let lines = summary.results.map { item -> String in
            let mark: String
            switch item.action {
            case .warmed: mark = "✓"
            case .skipped: mark = "·"
            case .failed: mark = "✗"
            }
            let shortAccount = item.account.split(separator: "@").first.map(String.init) ?? item.account
            return "\(mark) \(shortAccount): \(item.note)"
        }
        let header = L.text(
            "Warm: \(summary.warmed) new · \(summary.skipped) skip · \(summary.failed) fail",
            "Warm: \(summary.warmed) yeni · \(summary.skipped) atlandı · \(summary.failed) hata"
        )
        return ([header] + lines).joined(separator: "\n")
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
        copyButton.toolTip = L.text("Copied", "Kopyalandı")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10.8, weight: .regular))
            self?.copyButton.toolTip = L.text("Copy ccusage summary", "ccusage özetini kopyala")
        }
    }

    @discardableResult
    func showSettingsIfNeeded(refreshAfterSave: Bool) -> Bool {
        guard !AppConfig.hasManagementKey() else { return false }
        showSettings(isInitialSetup: true, refreshAfterSave: refreshAfterSave)
        return true
    }

    func showSettings(isInitialSetup: Bool = false, refreshAfterSave: Bool = false) {
        let baseField = NSTextField(string: AppConfig.apiBase())
        let keyField = NSSecureTextField(string: UserDefaults.standard.string(forKey: AppConfig.defaultsKey) ?? "")
        let autoRefreshPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        let appearancePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        let launchAtLogin = NSButton(checkboxWithTitle: L.text("Launch at Login", "Girişte aç"), target: nil, action: nil)
        launchAtLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
        baseField.placeholderString = "https://ai.example.com"
        keyField.placeholderString = L.text("Management key", "Management key")
        for minutes in AppConfig.autoRefreshOptions {
            autoRefreshPopup.addItem(withTitle: AppConfig.autoRefreshTitle(for: minutes))
            autoRefreshPopup.lastItem?.representedObject = minutes
        }
        autoRefreshPopup.selectItem(withTitle: AppConfig.autoRefreshTitle(for: AppConfig.autoRefreshMinutes()))
        for mode in AppConfig.appearanceOptions {
            appearancePopup.addItem(withTitle: AppConfig.appearanceTitle(for: mode))
            appearancePopup.lastItem?.representedObject = mode
        }
        appearancePopup.selectItem(withTitle: AppConfig.appearanceTitle(for: AppConfig.appearanceMode()))
        appearancePopup.target = self
        appearancePopup.action = #selector(settingsAppearanceChanged(_:))
        for mode in AppConfig.languageOptions {
            languagePopup.addItem(withTitle: AppConfig.languageTitle(for: mode))
            languagePopup.lastItem?.representedObject = mode
        }
        languagePopup.selectItem(withTitle: AppConfig.languageTitle(for: AppConfig.languageMode()))

        let settingsView = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 214))
        settingsView.appearance = Theme.appAppearance
        let baseLabel = NSTextField(labelWithString: "Base URL")
        let keyLabel = NSTextField(labelWithString: L.text("Management key", "Management key"))
        let autoRefreshLabel = NSTextField(labelWithString: L.text("Auto refresh", "Otomatik yenile"))
        let appearanceLabel = NSTextField(labelWithString: L.text("Appearance", "Görünüm"))
        let languageLabel = NSTextField(labelWithString: L.text("Language", "Dil"))
        baseLabel.frame = NSRect(x: 0, y: 190, width: 340, height: 18)
        baseField.frame = NSRect(x: 0, y: 162, width: 340, height: 24)
        keyLabel.frame = NSRect(x: 0, y: 136, width: 340, height: 18)
        keyField.frame = NSRect(x: 0, y: 108, width: 340, height: 24)
        autoRefreshLabel.frame = NSRect(x: 0, y: 80, width: 150, height: 22)
        autoRefreshPopup.frame = NSRect(x: 156, y: 78, width: 184, height: 26)
        appearanceLabel.frame = NSRect(x: 0, y: 52, width: 150, height: 22)
        appearancePopup.frame = NSRect(x: 156, y: 50, width: 184, height: 26)
        languageLabel.frame = NSRect(x: 0, y: 24, width: 150, height: 22)
        languagePopup.frame = NSRect(x: 156, y: 22, width: 184, height: 26)
        launchAtLogin.frame = NSRect(x: 0, y: -4, width: 340, height: 22)
        settingsView.addSubview(baseLabel)
        settingsView.addSubview(baseField)
        settingsView.addSubview(keyLabel)
        settingsView.addSubview(keyField)
        settingsView.addSubview(autoRefreshLabel)
        settingsView.addSubview(autoRefreshPopup)
        settingsView.addSubview(appearanceLabel)
        settingsView.addSubview(appearancePopup)
        settingsView.addSubview(languageLabel)
        settingsView.addSubview(languagePopup)
        settingsView.addSubview(launchAtLogin)

        let alert = NSAlert()
        alert.messageText = isInitialSetup ? L.text("GrandeBar Setup", "GrandeBar Kurulum") : L.text("GrandeBar Settings", "GrandeBar Ayarlar")
        alert.informativeText = isInitialSetup
            ? L.text("Enter the CLIProxyAPI Management Center URL and management key.", "CLIProxyAPI Management Center URL ve management key gir.")
            : L.text("Panel URL and management key are stored here.", "Panel adresi ve management key burada saklanır.")
        alert.accessoryView = settingsView
        alert.addButton(withTitle: L.text("Save", "Kaydet"))
        alert.addButton(withTitle: L.text("Cancel", "İptal"))
        alert.window.appearance = Theme.appAppearance

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let managementKey = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(AppConfig.normalizedBase(baseField.stringValue), forKey: AppConfig.apiBaseKey)
            UserDefaults.standard.set(managementKey, forKey: AppConfig.defaultsKey)
            UserDefaults.standard.set(autoRefreshPopup.selectedItem?.representedObject as? Int ?? 0, forKey: AppConfig.autoRefreshMinutesKey)
            UserDefaults.standard.set(appearancePopup.selectedItem?.representedObject as? String ?? "auto", forKey: AppConfig.appearanceKey)
            UserDefaults.standard.set(languagePopup.selectedItem?.representedObject as? String ?? "auto", forKey: AppConfig.languageKey)
            UserDefaults.standard.synchronize()
            reloadViewForAppearance()
            updateAutoRefreshTimer()
            setLaunchAtLogin(launchAtLogin.state == .on)
            if refreshAfterSave && !managementKey.isEmpty {
                refreshQuota()
            }
        }
    }

    @objc private func settingsAppearanceChanged(_ sender: NSPopUpButton) {
        let mode = sender.selectedItem?.representedObject as? String ?? "auto"
        let appearance = Theme.appearance(for: mode)
        sender.window?.appearance = appearance
        sender.window?.contentView?.appearance = appearance
        sender.superview?.appearance = appearance
    }

    private func reloadViewForAppearance() {
        let cards = latestCards
        let usage = latestUsage
        loadView()
        latestUsage = usage
        if let usage {
            usageLabel.stringValue = usageLineText(usage)
        }
        if !cards.isEmpty {
            render(cards: cards)
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
            alert.messageText = L.text("Launch at Login could not be saved", "Girişte aç ayarı kaydedilemedi")
            alert.runModal()
        }
    }

    private func refreshLocalUsage() {
        DispatchQueue.global(qos: .utility).async {
            let usage = LocalCodexUsage.read()
            DispatchQueue.main.async {
                if let usage {
                    self.latestUsage = usage
                    self.usageLabel.stringValue = self.usageLineText(usage)
                } else {
                    self.latestUsage = nil
                    self.usageLabel.stringValue = L.text("ccusage unavailable", "ccusage okunamadı")
                }
            }
        }
    }

    private func renderIdle() {
        clearCards()
        let label = NSTextField(labelWithString: L.text("Press Refresh", "Yenile'ye bas"))
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = Theme.secondaryText
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
            lastRefreshLabel.stringValue = L.text("Last refresh: never", "Son güncelleme: yok")
            return
        }
        let seconds = max(0, Int(Date().timeIntervalSince(lastRefreshAt)))
        if seconds < 60 {
            lastRefreshLabel.stringValue = L.text("Last refresh: \(seconds)s", "Son güncelleme: \(seconds) sn")
        } else {
            lastRefreshLabel.stringValue = L.text("Last refresh: \(seconds / 60)m \(seconds % 60)s", "Son güncelleme: \(seconds / 60) dk \(seconds % 60) sn")
        }
    }

    private func render(cards: [QuotaCard]) {
        clearCards()

        if cards.isEmpty {
            renderError(L.text("No Codex credentials found", "Codex hesabı bulunamadı"))
            return
        }

        latestCards = cards
        subtitleLabel.stringValue = summaryText(for: cards)
        setDetailLine(detailText(for: cards))
        let summary = totalLimitSummary(for: cards)
        let title = menuBarPoolTitle(summary)
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
        subtitleLabel.stringValue = L.text("Could not load quota", "Kota yüklenemedi")
        setDetailLine(nil)
        statusUpdate(message.contains("IP banned") ? "ban" : "err", message)

        let box = RoundedView(color: Theme.errorBackground, radius: 16, borderColor: Theme.border)
        box.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = NSColor(calibratedRed: 1.0, green: 0.38, blue: 0.32, alpha: 1)
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = Theme.primaryText
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

    /// Primary header line (classic, short): `6 account · 12 reset`
    private func summaryText(for cards: [QuotaCard]) -> String {
        let resetTotal = cards.compactMap(\.resetCreditsAvailableCount).reduce(0, +)
        return L.text("\(cards.count) account · \(resetTotal) reset", "\(cards.count) hesap · \(resetTotal) reset")
    }

    /// Secondary header line — pool buckets (locked + open + cold == account count).
    ///
    /// Display rules:
    /// - locked: only if > 0
    /// - open: always
    /// - cold: always, except while "warmed N" is visible (15s after flame)
    /// - warmed N: 15s after a warm run (not a bucket)
    ///
    /// Examples:
    ///   `0 open · 6 cold`
    ///   `6 open · 6 warmed`          (15s, no cold)
    ///   `6 open · 0 cold`            (after 15s)
    ///   `1 locked · 0 open · 5 cold`
    ///   `1 locked · 5 open · 5 warmed` (15s)
    ///   `1 locked · 5 open · 0 cold`
    private func detailText(for cards: [QuotaCard], warming: Bool = false) -> String? {
        guard !cards.isEmpty else { return nil }

        let locked = cards.filter(\.isLocked).count
        // Display "open": countdown has moved off full 5h (even 1s). Stuck 18000 + used% is cold.
        let open = cards.filter { card in
            guard !card.isLocked else { return false }
            return Self.isSessionTimerLive(resetSeconds: card.sessionResetSeconds, threshold: 1)
        }.count
        let cold = max(0, cards.count - locked - open)
        let showingWarmed = lastWarmNewCount != nil

        var parts: [String] = []
        if locked > 0 {
            parts.append(L.text("\(locked) locked", "\(locked) kilitli"))
        }
        parts.append(L.text("\(open) open", "\(open) açık"))

        if warming {
            // During in-flight warm: hide cold (same as warmed window).
            parts.append(L.text("warming…", "ısın…"))
        } else if showingWarmed, let warmed = lastWarmNewCount {
            // 15s window: show warmed, omit cold entirely.
            parts.append(L.text("\(warmed) warmed", "\(warmed) warmed"))
        } else {
            // Normal: always show cold, including 0.
            parts.append(L.text("\(cold) cold", "\(cold) cold"))
        }
        return parts.joined(separator: " · ")
    }

    /// True when the 5h countdown has moved at least `threshold` seconds off full window.
    /// Warm *skip* still uses a higher threshold (120s) in SessionWarmupAPI.
    private static func isSessionTimerLive(resetSeconds: Int?, threshold: Int = 1) -> Bool {
        guard let reset = resetSeconds else { return false }
        let elapsed = max(0, 18_000 - reset)
        return elapsed >= threshold
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
        formatter.locale = Locale(identifier: L.isTurkish ? "tr_TR" : "en_US_POSIX")
        formatter.dateFormat = L.isTurkish ? "d MMM HH:mm" : "MMM d HH:mm"
        return formatter.string(from: date)
    }

    private func totalLimitSummary(for cards: [QuotaCard]) -> TotalLimitSummary {
        let sessions = cards.compactMap { card -> Int? in
            guard let session = card.sessionPercent else { return nil }
            return card.weeklyPercent == 0 ? 0 : session
        }
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

    private func menuBarPoolTitle(_ summary: TotalLimitSummary) -> String {
        "\(paddedMenuBarPercent(sessionPoolTitle(summary)))\n\(paddedMenuBarPercent(poolPercentText(remaining: summary.weeklyRemaining, total: summary.weeklyTotal)))"
    }

    private func paddedMenuBarPercent(_ value: String) -> String {
        String(repeating: " ", count: max(0, 4 - value.count)) + value
    }

    private func usageTableText() -> String {
        var usageLine = L.text("ccusage unavailable.", "ccusage okunamadı.")
        if let usage = latestUsage {
            usageLine = L.text(
                "Token cost: today \(LocalCodexUsage.format(usage.today)), this week \(LocalCodexUsage.format(usage.week)), month to date \(LocalCodexUsage.format(usage.month)).",
                "Token cost: bugün \(LocalCodexUsage.format(usage.today)), bu hafta \(LocalCodexUsage.format(usage.week)), ay başından beri \(LocalCodexUsage.format(usage.month))."
            )
        }

        guard !latestCards.isEmpty else {
            return "\(usageLine)\n\(L.text("Account quota is not loaded yet.", "Hesap kotası henüz yüklenmedi."))"
        }

        let summary = totalLimitSummary(for: latestCards)
        let weeklyTotal = poolPercentText(remaining: summary.weeklyRemaining, total: summary.weeklyTotal)
        let accounts = latestCards
            .sorted(by: sortCards)
            .map { "- \(compactAccountName($0.name)): \(L.text("session", "oturum")) \(percentText($0.sessionPercent)), \(L.text("weekly", "haftalık")) \(percentText($0.weeklyPercent))" }
            .joined(separator: "\n")
        let resetTotal = latestCards.compactMap(\.resetCreditsAvailableCount).reduce(0, +)
        let closestReset = earliestResetExpiry(in: latestCards)
            .map { "\(formatExpiry($0.date)) (\(compactAccountName($0.name)))" } ?? "--"

        return L.text(
            "\(usageLine)\nRemaining total: session \(sessionPoolTitle(summary)), weekly \(weeklyTotal). Reset credits: \(resetTotal), nearest expiry: \(closestReset).\nAccount remaining:\n\(accounts)",
            "\(usageLine)\nToplam kalan: oturum \(sessionPoolTitle(summary)), haftalık \(weeklyTotal). Reset hakkı: \(resetTotal), en yakın expire: \(closestReset).\nHesaplarda kalan:\n\(accounts)"
        )
    }

    private func usageLineText(_ usage: LocalUsage?) -> String {
        guard let usage else {
            return L.text("Today -- · Week -- · Month --", "Bugün -- · Hafta -- · Ay --")
        }
        let modelText = usage.models.isEmpty ? "" : " · \(usage.models.joined(separator: ", "))"
        return L.text(
            "Today \(LocalCodexUsage.format(usage.today)) · Week \(LocalCodexUsage.format(usage.week)) · Month \(LocalCodexUsage.format(usage.month))\(modelText)",
            "Bugün \(LocalCodexUsage.format(usage.today)) · Hafta \(LocalCodexUsage.format(usage.week)) · Ay \(LocalCodexUsage.format(usage.month))\(modelText)"
        )
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
        button.contentTintColor = Theme.buttonTint
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
        button.contentTintColor = Theme.buttonTint
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 19).isActive = true
        button.heightAnchor.constraint(equalToConstant: 19).isActive = true
        return button
    }
}

private final class AccountCardView: RoundedView {
    init(card: QuotaCard) {
        super.init(color: Theme.cardBackground, radius: 8, borderColor: Theme.cardBorder)
        translatesAutoresizingMaskIntoConstraints = false
        layer?.shadowColor = Theme.shadow.cgColor
        layer?.shadowOpacity = 0.10
        layer?.shadowRadius = 7
        layer?.shadowOffset = NSSize(width: 0, height: -1)

        let accent = NSView()
        accent.wantsLayer = true
        accent.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.82).cgColor
        accent.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: compactName(card.name))
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.textColor = Theme.primaryText
        name.lineBreakMode = .byTruncatingMiddle
        name.translatesAutoresizingMaskIntoConstraints = false

        let resetCount = NSTextField(labelWithString: resetCountText(card))
        resetCount.font = .systemFont(ofSize: 11, weight: .semibold)
        resetCount.textColor = Theme.primaryText
        resetCount.alignment = .right
        resetCount.lineBreakMode = .byTruncatingMiddle
        resetCount.translatesAutoresizingMaskIntoConstraints = false
        resetCount.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let resetExpiry = NSTextField(labelWithString: resetExpiryText(card))
        resetExpiry.font = .monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        resetExpiry.textColor = Theme.mutedText
        resetExpiry.alignment = .right
        resetExpiry.lineBreakMode = .byTruncatingMiddle
        resetExpiry.translatesAutoresizingMaskIntoConstraints = false
        resetExpiry.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let session = MetricView(title: L.text("Session 5h", "Oturum 5s"), percent: card.sessionPercent, resetSeconds: card.sessionResetSeconds)
        let weekly = MetricView(title: L.text("Weekly", "Haftalık"), percent: card.weeklyPercent, resetSeconds: card.weeklyResetSeconds)
        session.translatesAutoresizingMaskIntoConstraints = false
        weekly.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = Theme.subtleDivider.cgColor
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
        return L.text("Reset \(count)", "Reset \(count) adet")
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
        formatter.locale = Locale(identifier: L.isTurkish ? "tr_TR" : "en_US_POSIX")
        formatter.dateFormat = L.isTurkish ? "d MMM HH:mm" : "MMM d HH:mm"
        return formatter.string(from: date)
    }

}

private final class TotalLimitCardView: RoundedView {
    init(summary: TotalLimitSummary) {
        super.init(color: Theme.cardBackground, radius: 8, borderColor: Theme.border)

        let sessionPercent = percent(remaining: summary.sessionRemaining, total: summary.sessionTotal)
        let weeklyPercent = percent(remaining: summary.weeklyRemaining, total: summary.weeklyTotal)
        let session = TotalMetricView(title: L.text("Session pool", "Oturum havuzu"), value: valueText(sessionPercent), detail: L.text("total remaining", "toplam kalan"), percent: sessionPercent, tint: color(for: sessionPercent))
        let weekly = TotalMetricView(title: L.text("Weekly pool", "Haftalık havuz"), value: valueText(weeklyPercent), detail: L.text("total remaining", "toplam kalan"), percent: weeklyPercent, tint: color(for: weeklyPercent))
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
        guard let percent else { return Theme.mutedText }
        if percent <= 20 { return NSColor(calibratedRed: 1.0, green: 0.31, blue: 0.29, alpha: 1) }
        if percent <= 60 { return NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.25, alpha: 1) }
        return NSColor(calibratedRed: 0.42, green: 0.84, blue: 0.34, alpha: 1)
    }

    private func divider() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = Theme.divider.cgColor
        return view
    }
}

private final class TotalMetricView: RoundedView {
    init(title: String, value: String, detail: String, percent: Int?, tint: NSColor) {
        super.init(color: .clear, radius: 0)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = Theme.secondaryText
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .bold)
        valueLabel.textColor = tint
        valueLabel.alignment = .center
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 9, weight: .medium)
        detailLabel.textColor = Theme.mutedText
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
        titleLabel.textColor = Theme.secondaryText
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let timeLabel = NSTextField(labelWithString: formatDuration(resetSeconds))
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        timeLabel.textColor = Theme.mutedText
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
        guard let percent else { return Theme.mutedText }
        if percent <= 20 { return NSColor(calibratedRed: 1.0, green: 0.31, blue: 0.29, alpha: 1) }
        if percent <= 60 { return NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.25, alpha: 1) }
        return NSColor(calibratedRed: 0.42, green: 0.84, blue: 0.34, alpha: 1)
    }

    private func formatDuration(_ seconds: Int?) -> String {
        guard let seconds, seconds > 0 else { return "--" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if L.isTurkish {
            if days > 0 { return "\(days)g\(hours)s" }
            if hours > 0 { return "\(hours)s\(minutes)d" }
            return "\(max(1, minutes))d"
        }
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
        Theme.progressTrack.setFill()
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
    /// Aggregates ccusage across default ~/.codex and isolated multi-profile homes
    /// (codex-grande, codex-aof, codex-main, …). ccusage only reads one CODEX_HOME per run.
    static func read() -> LocalUsage? {
        let dates = dateKeys()
        let since = min(dates.weekStart, dates.monthStart)
        let homes = codexHomes()
        guard !homes.isEmpty else { return nil }

        var today = 0.0
        var week = 0.0
        var month = 0.0
        var models = Set<String>()
        var anySuccess = false

        for home in homes {
            guard let json = ccusageJSON(since: since, codexHome: home),
                  let rows = json["daily"] as? [[String: Any]] else {
                continue
            }
            anySuccess = true
            for row in rows {
                guard let date = row["date"] as? String,
                      let cost = doubleValue(row["costUSD"]) else { continue }
                if date == dates.today { today += cost }
                if date >= dates.weekStart { week += cost }
                if date >= dates.monthStart { month += cost }
                if date >= dates.weekStart {
                    for model in modelNames(from: row) {
                        models.insert(model)
                    }
                }
            }
        }

        guard anySuccess else { return nil }
        return LocalUsage(today: today, week: week, month: month, models: models.sorted())
    }

    static func format(_ amount: Double) -> String {
        String(format: "$%.2f", amount)
    }

    /// Default Codex home + m365bridge multi-profile homes that actually have sessions.
    private static func codexHomes() -> [String] {
        let fm = FileManager.default
        let userHome = fm.homeDirectoryForCurrentUser.path
        var homes: [String] = []
        var seen = Set<String>()

        func add(_ path: String) {
            let resolved = (path as NSString).standardizingPath
            guard !seen.contains(resolved) else { return }
            var isDir: ObjCBool = false
            // Prefer homes that already have session data (or a config.toml).
            let sessions = (resolved as NSString).appendingPathComponent("sessions")
            let config = (resolved as NSString).appendingPathComponent("config.toml")
            let hasSessions = fm.fileExists(atPath: sessions, isDirectory: &isDir) && isDir.boolValue
            let hasConfig = fm.isReadableFile(atPath: config)
            guard hasSessions || hasConfig else { return }
            seen.insert(resolved)
            homes.append(resolved)
        }

        add("\(userHome)/.codex")

        // m365bridge multi-account CLI profiles (codex-grande, codex-aof, …)
        let bridgeRoots = [
            "\(userHome)/m365bridge-next/codex-cli",
            "\(userHome)/m365bridge-accounts/codex-cli"
        ]
        for root in bridgeRoots {
            guard let children = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for name in children.sorted() {
                add((root as NSString).appendingPathComponent(name))
            }
        }

        // cli-profiles.json may list extra codex_home paths
        let profileFiles = [
            "\(userHome)/m365bridge-next/cli-profiles.json",
            "\(userHome)/m365bridge-accounts/cli-profiles.json"
        ]
        for profilePath in profileFiles {
            guard let data = fm.contents(atPath: profilePath),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let profiles = json["profiles"] as? [[String: Any]] else { continue }
            for profile in profiles {
                if let home = profile["codex_home"] as? String, !home.isEmpty {
                    add(home)
                }
            }
        }

        return homes
    }

    private static func ccusageJSON(since: String, codexHome: String) -> [String: Any]? {
        guard let path = ccusagePath() else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        // Offline + pricingOverrides; lock cost display to fast (upper bound).
        var arguments = [
            "codex", "daily",
            "--json",
            "--offline",
            "--speed", "fast",
            "--timezone", TimeZone.current.identifier,
            "--since", since
        ]
        if let configPath = ccusageConfigPath() {
            arguments += ["--config", configPath]
        }
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        let extraPath = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = "\(extraPath):\(environment["PATH"] ?? "")"
        // Isolated profiles (codex-grande, …) store sessions under their own CODEX_HOME.
        environment["CODEX_HOME"] = codexHome
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

    /// Bundled pricing for models missing from ccusage embedded tables (e.g. gpt-5.6-reasoning).
    private static func ccusageConfigPath() -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var candidates: [String] = []
        if let bundled = Bundle.main.url(forResource: "ccusage", withExtension: "json")?.path {
            candidates.append(bundled)
        }
        candidates.append("\(home)/.config/ccusage/ccusage.json")
        let sourceTree = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/ccusage.json")
            .path
        candidates.append(sourceTree)
        return candidates.first { fm.isReadableFile(atPath: $0) }
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

    private static func modelNames(from row: [String: Any]) -> [String] {
        guard let models = row["models"] as? [String: Any] else { return [] }
        return models.keys.map(normalizedModelName)
    }

    private static func normalizedModelName(_ model: String) -> String {
        let lowercased = model.lowercased()
        if lowercased.hasPrefix("gpt-5.6") { return "GPT-5.6" }
        if lowercased.hasPrefix("gpt-5.5") { return "GPT-5.5" }
        if lowercased.hasPrefix("gpt-5.4") { return "GPT-5.4" }
        if lowercased.contains("fable") { return "FABLE" }
        if lowercased.hasPrefix("claude") { return "CLAUDE" }
        return model.uppercased()
    }
}

// MARK: - Session warmup (open cold 5h windows)

private enum SessionWarmAction {
    case warmed
    case skipped
    case failed
}

private struct SessionWarmItem {
    let account: String
    let action: SessionWarmAction
    let note: String
}

private struct SessionWarmupSummary {
    let results: [SessionWarmItem]
    var warmed: Int { results.filter { $0.action == .warmed }.count }
    var skipped: Int { results.filter { $0.action == .skipped }.count }
    var failed: Int { results.filter { $0.action == .failed }.count }
}

/// Opens cold Codex 5-hour session windows with one minimal Responses request per eligible account.
private final class SessionWarmupAPI {
    private let model = "gpt-5.4-mini"
    /// Primary session window length (5h). used% alone is not enough — timer must actually tick.
    private let sessionWindowSeconds = 18_000
    /// Skip warm only after countdown has moved this many seconds off the full 5h.
    private let progressThresholdSeconds = 120
    private let responsesURL = "https://chatgpt.com/backend-api/codex/responses"
    private let usageURL = "https://chatgpt.com/backend-api/wham/usage"

    func warmEligibleAccounts(completion: @escaping (Result<SessionWarmupSummary, Error>) -> Void) {
        guard let managementKey = UserDefaults.standard.string(forKey: AppConfig.defaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !managementKey.isEmpty else {
            completion(.failure(NSError(
                domain: "GrandeBar",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: L.text("Management key is missing", "Management key eksik")]
            )))
            return
        }

        // Strong self is intentional: keep this helper alive until nested URLSession work finishes.
        apiJSON(path: "/auth-files", managementKey: managementKey) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let json):
                let files = (json["files"] as? [[String: Any]] ?? [])
                    .filter { ($0["disabled"] as? Bool) != true }
                guard !files.isEmpty else {
                    completion(.success(SessionWarmupSummary(results: [])))
                    return
                }

                // Sequential to be gentle on the management proxy / upstream.
                self.warmFiles(files, index: 0, managementKey: managementKey, acc: []) { items in
                    completion(.success(SessionWarmupSummary(results: items)))
                }
            }
        }
    }

    private func warmFiles(
        _ files: [[String: Any]],
        index: Int,
        managementKey: String,
        acc: [SessionWarmItem],
        done: @escaping ([SessionWarmItem]) -> Void
    ) {
        if index >= files.count {
            done(acc)
            return
        }

        let file = files[index]
        let authIndex = (file["auth_index"] as? String) ?? (file["authIndex"] as? String) ?? ""
        let account = (file["account"] as? String) ?? (file["name"] as? String) ?? authIndex
        guard !authIndex.isEmpty else {
            warmFiles(files, index: index + 1, managementKey: managementKey, acc: acc + [
                SessionWarmItem(account: account, action: .skipped, note: L.text("missing auth index", "auth index yok"))
            ], done: done)
            return
        }

        fetchUsage(authIndex: authIndex, managementKey: managementKey) { usageResult in
            switch usageResult {
            case .failure(let error):
                self.warmFiles(files, index: index + 1, managementKey: managementKey, acc: acc + [
                    SessionWarmItem(account: account, action: .failed, note: error.localizedDescription)
                ], done: done)
            case .success(let usage):
                if let skip = self.skipReason(usage: usage) {
                    self.warmFiles(files, index: index + 1, managementKey: managementKey, acc: acc + [
                        SessionWarmItem(account: account, action: .skipped, note: skip)
                    ], done: done)
                    return
                }

                self.sendWarmRequest(
                    authIndex: authIndex,
                    accountId: usage.accountId,
                    managementKey: managementKey
                ) { warmResult in
                    let item: SessionWarmItem
                    switch warmResult {
                    case .failure(let error):
                        item = SessionWarmItem(account: account, action: .failed, note: error.localizedDescription)
                    case .success(let detail):
                        item = SessionWarmItem(account: account, action: .warmed, note: detail)
                    }
                    // Small gap between accounts.
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
                        self.warmFiles(files, index: index + 1, managementKey: managementKey, acc: acc + [item], done: done)
                    }
                }
            }
        }
    }

    private struct UsageProbe {
        let accountId: String?
        let allowed: Bool?
        let limitReached: Bool?
        let usedPercent: Int?
        let sessionResetSeconds: Int?
        let limitType: String?

        /// Seconds already elapsed in the 5h window (nil if reset unknown).
        var elapsedSeconds: Int? {
            guard let reset = sessionResetSeconds else { return nil }
            return max(0, 18_000 - reset)
        }

        /// Timer has actually counted down — not just a stuck "5h00m" label with used=1%.
        func isProgressing(threshold: Int) -> Bool {
            guard let elapsed = elapsedSeconds else { return false }
            return elapsed >= threshold
        }
    }

    private func skipReason(usage: UsageProbe) -> String? {
        if usage.allowed == false {
            let detail = usage.limitType ?? ""
            if detail.contains("credits_depleted") {
                return L.text("locked (credits depleted)", "kilitli (kredi bitmiş)")
            }
            if !detail.isEmpty {
                return L.text("locked (\(detail))", "kilitli (\(detail))")
            }
            return L.text("locked", "kilitli")
        }
        if usage.limitReached == true {
            return L.text("limit reached", "limit dolu")
        }
        // Gate on countdown progress, not used%. Full 5h remaining → still needs warm.
        if usage.isProgressing(threshold: progressThresholdSeconds) {
            let mins = (usage.elapsedSeconds ?? 0) / 60
            let used = usage.usedPercent.map { "\($0)%" } ?? "--"
            return L.text(
                "timer running (~\(mins)m in, used \(used))",
                "sayaç işliyor (~\(mins)dk geçmiş, kullanım \(used))"
            )
        }
        return nil
    }

    private func fetchUsage(authIndex: String, managementKey: String, completion: @escaping (Result<UsageProbe, Error>) -> Void) {
        let payload: [String: Any] = [
            "authIndex": authIndex,
            "method": "GET",
            "url": usageURL,
            "header": [
                "Authorization": "Bearer $TOKEN$",
                "Content-Type": "application/json",
                "User-Agent": "codex_cli_rs/0.76.0"
            ]
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
                let lim = (body["rate_limit"] as? [String: Any]) ?? (body["rateLimit"] as? [String: Any]) ?? [:]
                let pw = (lim["primary_window"] as? [String: Any]) ?? (lim["primaryWindow"] as? [String: Any]) ?? [:]
                let rlt = body["rate_limit_reached_type"]
                let limitType: String?
                if let dict = rlt as? [String: Any] {
                    limitType = dict["type"] as? String
                } else {
                    limitType = rlt as? String
                }
                completion(.success(UsageProbe(
                    accountId: (body["account_id"] as? String) ?? (body["accountId"] as? String),
                    allowed: lim["allowed"] as? Bool,
                    limitReached: (lim["limit_reached"] as? Bool) ?? (lim["limitReached"] as? Bool),
                    usedPercent: self.intValue(pw["used_percent"] ?? pw["usedPercent"]),
                    sessionResetSeconds: self.intValue(pw["reset_after_seconds"] ?? pw["resetAfterSeconds"]),
                    limitType: limitType
                )))
            }
        }
    }

    private func sendWarmRequest(
        authIndex: String,
        accountId: String?,
        managementKey: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        var headers: [String: String] = [
            "Authorization": "Bearer $TOKEN$",
            "Content-Type": "application/json",
            "Accept": "text/event-stream",
            "User-Agent": "codex_cli_rs/0.76.0 (session-warmup)",
            "OpenAI-Beta": "responses=experimental",
            "originator": "codex_cli_rs"
        ]
        if let accountId, !accountId.isEmpty {
            headers["ChatGPT-Account-Id"] = accountId
            headers["chatgpt-account-id"] = accountId
        }

        let body: [String: Any] = [
            "model": model,
            "instructions": "Reply with exactly: ok",
            "input": [
                [
                    "type": "message",
                    "role": "user",
                    "content": [["type": "input_text", "text": "hi"]]
                ]
            ],
            "tools": [] as [Any],
            "tool_choice": "none",
            "parallel_tool_calls": false,
            "store": false,
            "stream": true,
            "include": [] as [Any],
            "reasoning": ["effort": "none"]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let dataString = String(data: data, encoding: .utf8) else {
            completion(.failure(NSError(domain: "GrandeBar", code: 10, userInfo: [NSLocalizedDescriptionKey: L.text("Could not build warm request", "Warm isteği oluşturulamadı")])))
            return
        }

        let payload: [String: Any] = [
            "authIndex": authIndex,
            "method": "POST",
            "url": responsesURL,
            "header": headers,
            "data": dataString
        ]

        apiJSON(path: "/api-call", method: "POST", payload: payload, managementKey: managementKey, timeout: 120) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let json):
                let status = json["status_code"] as? Int ?? 0
                let rawBody = json["body"] as? String ?? ""
                if status < 200 || status >= 300 {
                    let snippet = String(rawBody.prefix(200))
                    completion(.failure(NSError(
                        domain: "GrandeBar",
                        code: status,
                        userInfo: [NSLocalizedDescriptionKey: "HTTP \(status): \(snippet)"]
                    )))
                    return
                }
                let tokens = self.extractTotalTokens(from: rawBody)
                if let tokens {
                    completion(.success(L.text("opened · \(tokens) tok", "açıldı · \(tokens) tok")))
                } else {
                    completion(.success(L.text("opened", "açıldı")))
                }
            }
        }
    }

    private func extractTotalTokens(from sseBody: String) -> Int? {
        for line in sseBody.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]",
                  let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let response = (event["type"] as? String) == "response.completed"
                ? (event["response"] as? [String: Any])
                : (event["response"] as? [String: Any])
            if let response,
               let usage = response["usage"] as? [String: Any],
               let total = intValue(usage["total_tokens"] ?? usage["totalTokens"]) {
                return total
            }
            if let usage = event["usage"] as? [String: Any],
               let total = intValue(usage["total_tokens"] ?? usage["totalTokens"]) {
                return total
            }
        }
        return nil
    }

    private func apiJSON(
        path: String,
        method: String = "GET",
        payload: [String: Any]? = nil,
        managementKey: String,
        timeout: TimeInterval = 60,
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        guard let url = URL(string: "\(AppConfig.apiBase())/v0/management\(path)") else {
            completion(.failure(NSError(domain: "GrandeBar", code: 3, userInfo: [NSLocalizedDescriptionKey: L.text("Base URL is invalid", "Base URL geçersiz")])))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("GrandeBar/0.2-warmup", forHTTPHeaderField: "User-Agent")
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

    private func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return Int(number.doubleValue.rounded()) }
        if let string = value as? String, let number = Double(string) { return Int(number.rounded()) }
        return nil
    }
}

private final class QuotaAPI {
    func fetchQuota(completion: @escaping (Result<[QuotaCard], Error>) -> Void) {
        guard let managementKey = UserDefaults.standard.string(forKey: AppConfig.defaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !managementKey.isEmpty else {
            completion(.failure(NSError(domain: "GrandeBar", code: 1, userInfo: [NSLocalizedDescriptionKey: L.text("Management key is missing", "Management key eksik")])))
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
                        completion(.failure(firstError ?? NSError(domain: "GrandeBar", code: 2, userInfo: [NSLocalizedDescriptionKey: L.text("No quota data returned", "Kota verisi dönmedi")])))
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
                let lim = (body["rate_limit"] as? [String: Any]) ?? (body["rateLimit"] as? [String: Any]) ?? [:]
                let allowed = lim["allowed"] as? Bool
                let limitReached = (lim["limit_reached"] as? Bool) ?? (lim["limitReached"] as? Bool)
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
                        allowed: allowed,
                        limitReached: limitReached,
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
            completion(.failure(NSError(domain: "GrandeBar", code: 3, userInfo: [NSLocalizedDescriptionKey: L.text("Base URL is invalid", "Base URL geçersiz")])))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("GrandeBar/0.2.8", forHTTPHeaderField: "User-Agent")
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

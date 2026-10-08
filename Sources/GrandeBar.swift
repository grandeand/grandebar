import AppKit
import Foundation
import ServiceManagement

private enum AppMode: String, CaseIterable {
    case codex
    case claude

    var title: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        }
    }
}

private enum AppConfig {
    static let modeKey = "appMode"
    static let defaultAPIBase = "http://localhost:8317"
    static let claudeDefaultAPIBase = "http://127.0.0.1:8317"
    static let claudeAPIBaseKey = "claudeApiBase"
    static let claudeManagementKeyKey = "claudeManagementKey"
    static let claudeAutomaticWarmupKey = "claudeAutomaticSessionWarmup"
    static let apiBaseKey = "apiBase"
    static let defaultsKey = "managementKey"
    static let lastRefreshKey = "lastRefreshAt"
    static let autoRefreshMinutesKey = "autoRefreshMinutes"
    static let autoRefreshOptions = [0, 5, 10, 15, 30, 60]
    static let automaticWarmupKey = "automaticSessionWarmup"
    static let appearanceKey = "appearanceMode"
    static let appearanceOptions = ["auto", "light", "dark"]
    static let languageKey = "languageMode"
    static let languageOptions = ["auto", "en", "tr"]

    static func mode() -> AppMode {
        AppMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .codex
    }

    static func setMode(_ mode: AppMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: modeKey)
    }

    static func apiBase() -> String {
        apiBase(for: mode())
    }

    static func apiBase(for mode: AppMode) -> String {
        switch mode {
        case .codex:
            return normalizedBase(UserDefaults.standard.string(forKey: apiBaseKey) ?? defaultAPIBase)
        case .claude:
            return normalizedBase(UserDefaults.standard.string(forKey: claudeAPIBaseKey) ?? claudeDefaultAPIBase)
        }
    }

    static func managementKey(for mode: AppMode) -> String {
        let key = mode == .codex ? defaultsKey : claudeManagementKeyKey
        let saved = (UserDefaults.standard.string(forKey: key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if saved.isEmpty, mode == .claude {
            return localCredential("MANAGEMENT_KEY") ?? ""
        }
        return saved
    }

    /// Reads `~/cliproxyapi/.credentials` written by the local CLIProxyAPI install, if present.
    static func localCredential(_ name: String) -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("cliproxyapi/.credentials").path
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix(name + "=") {
            let value = String(line.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    static func hasManagementKey() -> Bool {
        hasManagementKey(for: mode())
    }

    static func hasManagementKey(for mode: AppMode) -> Bool {
        !managementKey(for: mode).isEmpty
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

    static func automaticWarmupEnabled(for mode: AppMode) -> Bool {
        switch mode {
        case .codex: return UserDefaults.standard.object(forKey: automaticWarmupKey) as? Bool ?? true
        case .claude: return UserDefaults.standard.object(forKey: claudeAutomaticWarmupKey) as? Bool ?? true
        }
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
    /// Between original 315 and the too-wide 372; costs-only footer fits 5-digit $ amounts.
    static let popoverWidth: CGFloat = 325
    static let popoverHeight: CGFloat = 507
    static let modeRowHeight: CGFloat = 22
    static let providerCardHeight: CGFloat = 62
    static let cardWidth: CGFloat = 301
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
    static let claudeAccent = NSColor(calibratedRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
    static var accent: NSColor { AppConfig.mode() == .claude ? claudeAccent : .systemBlue }
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
    /// Claude: label for the weekly row (e.g. "Fable" when only a model-scoped weekly limit exists).
    var weeklyLabel: String? = nil
    /// Claude: replaces the Codex reset-credit lines on the card's top right.
    var headline: String? = nil
    var subline: String? = nil

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
    private var updater: GrandeBarUpdater!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "GrandeBar"
        let iconConfig = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let icon = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "GrandeBar")?.withSymbolConfiguration(iconConfig)
        icon?.isTemplate = true
        statusItem.button?.image = icon
        statusItem.button?.imagePosition = .imageLeading
        applyModeToStatusItem()
        setStatusTitle(" --%\n --%")
        statusItem.button?.toolTip = "GrandeBar"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        quotaViewController = QuotaViewController { [weak self] title, tooltip in
            self?.setStatusTitle(title)
            self?.statusItem.button?.toolTip = tooltip
        }
        quotaViewController.onModeChange = { [weak self] in
            self?.applyModeToStatusItem()
        }

        popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: UI.popoverWidth, height: UI.popoverHeight)
        popover.contentViewController = quotaViewController
        updater = GrandeBarUpdater()
        updater.startAutomaticChecks()

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
        menu.addItem(withTitle: L.text("Check for Updates", "Güncellemeleri Denetle"), action: #selector(checkForUpdates), keyEquivalent: "")
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

    @objc private func checkForUpdates() {
        Task { @MainActor in
            updater.check(manual: true)
        }
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

    /// Claude mode tints the menu bar gauge so the active mode is visible without opening the popover.
    private func applyModeToStatusItem() {
        statusItem.button?.contentTintColor = AppConfig.mode() == .claude ? Theme.claudeAccent : nil
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
    var onModeChange: (() -> Void)?
    private var modeControl: NSSegmentedControl!
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
    private var automaticWarmupTimers: [AppMode: Timer] = [:]
    /// Warm runs for the mode that is not on screen (keeps both modes' 5h windows warm).
    private var backgroundWarmups: [AppMode: SessionWarmupAPI] = [:]
    private var cardsByMode: [AppMode: [QuotaCard]] = [:]
    /// Bumped on mode switch so in-flight refreshes of the previous mode are dropped.
    private var refreshGeneration = 0
    private var wakeObserver: NSObjectProtocol?
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
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            AppMode.allCases.forEach { self?.automaticWarmupCheck(mode: $0) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            for mode in AppMode.allCases where mode != AppConfig.mode() {
                self.automaticWarmupCheck(mode: mode)
            }
        }
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
        headerIcon.contentTintColor = Theme.accent.withAlphaComponent(0.95)
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
        subtitleLabel = NSTextField(labelWithString: L.text("\(AppConfig.mode().title) quota", "\(AppConfig.mode().title) kota"))
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

        modeControl = NSSegmentedControl(labels: AppMode.allCases.map(\.title), trackingMode: .selectOne, target: self, action: #selector(modeChanged))
        modeControl.segmentStyle = .rounded
        modeControl.controlSize = .small
        modeControl.selectedSegment = AppMode.allCases.firstIndex(of: AppConfig.mode()) ?? 0
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        for index in AppMode.allCases.indices {
            modeControl.setWidth((UI.cardWidth - 4) / CGFloat(AppMode.allCases.count), forSegment: index)
        }

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
        root.addSubview(modeControl)
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
            modeControl.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            modeControl.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 9),
            modeControl.heightAnchor.constraint(equalToConstant: UI.modeRowHeight),

            scrollView.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 10),
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

        let mode = AppConfig.mode()
        let generation = refreshGeneration
        QuotaAPI(mode: mode).fetchQuota { [weak self] result in
            DispatchQueue.main.async {
                guard let self, generation == self.refreshGeneration else { return }
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

        let warmup = SessionWarmupAPI(mode: AppConfig.mode())
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
        // A warm run belongs to the visible mode; switching mid-run would mislabel its result.
        modeControl.isEnabled = !isWarming
    }

    @objc private func modeChanged() {
        let index = modeControl.selectedSegment
        guard AppMode.allCases.indices.contains(index) else { return }
        let mode = AppMode.allCases[index]
        guard mode != AppConfig.mode(), !isWarming else { return }

        AppConfig.setMode(mode)
        refreshGeneration += 1
        isRefreshing = false
        lastWarmNewCount = nil
        warmNewClearWorkItem?.cancel()
        latestCards = cardsByMode[mode] ?? []
        latestUsage = nil
        onModeChange?()
        reloadViewForAppearance()
        if latestCards.isEmpty {
            renderIdle()
        }
        refreshQuota()
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
        automaticWarmupTimers.values.forEach { $0.invalidate() }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
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
        let baseField = NSTextField(string: AppConfig.apiBase(for: .codex))
        let keyField = NSSecureTextField(string: UserDefaults.standard.string(forKey: AppConfig.defaultsKey) ?? "")
        let claudeBaseField = NSTextField(string: AppConfig.apiBase(for: .claude))
        let claudeKeyField = NSSecureTextField(string: UserDefaults.standard.string(forKey: AppConfig.claudeManagementKeyKey) ?? "")
        let autoRefreshPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        let appearancePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        let automaticWarmup = NSButton(
            checkboxWithTitle: L.text("Automatic session warmup (Codex)", "Otomatik oturum warmup (Codex)"),
            target: nil,
            action: nil
        )
        automaticWarmup.state = AppConfig.automaticWarmupEnabled(for: .codex) ? .on : .off
        let claudeAutomaticWarmup = NSButton(
            checkboxWithTitle: L.text("Automatic session warmup (Claude)", "Otomatik oturum warmup (Claude)"),
            target: nil,
            action: nil
        )
        claudeAutomaticWarmup.state = AppConfig.automaticWarmupEnabled(for: .claude) ? .on : .off
        let launchAtLogin = NSButton(checkboxWithTitle: L.text("Launch at Login", "Girişte aç"), target: nil, action: nil)
        launchAtLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
        baseField.placeholderString = "https://ai.example.com"
        keyField.placeholderString = L.text("Management key", "Management key")
        claudeBaseField.placeholderString = AppConfig.claudeDefaultAPIBase
        claudeKeyField.placeholderString = AppConfig.localCredential("MANAGEMENT_KEY") != nil
            ? L.text("From ~/cliproxyapi/.credentials", "~/cliproxyapi/.credentials'tan")
            : L.text("Management key", "Management key")
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

        let settingsView = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 390))
        settingsView.appearance = Theme.appAppearance
        let baseLabel = NSTextField(labelWithString: "Codex Base URL")
        let keyLabel = NSTextField(labelWithString: L.text("Codex management key", "Codex management key"))
        let claudeBaseLabel = NSTextField(labelWithString: "Claude Base URL")
        let claudeKeyLabel = NSTextField(labelWithString: L.text("Claude management key", "Claude management key"))
        let autoRefreshLabel = NSTextField(labelWithString: L.text("Auto refresh", "Otomatik yenile"))
        let appearanceLabel = NSTextField(labelWithString: L.text("Appearance", "Görünüm"))
        let languageLabel = NSTextField(labelWithString: L.text("Language", "Dil"))
        baseLabel.frame = NSRect(x: 0, y: 366, width: 340, height: 18)
        baseField.frame = NSRect(x: 0, y: 338, width: 340, height: 24)
        keyLabel.frame = NSRect(x: 0, y: 312, width: 340, height: 18)
        keyField.frame = NSRect(x: 0, y: 284, width: 340, height: 24)
        claudeBaseLabel.frame = NSRect(x: 0, y: 256, width: 340, height: 18)
        claudeBaseField.frame = NSRect(x: 0, y: 228, width: 340, height: 24)
        claudeKeyLabel.frame = NSRect(x: 0, y: 202, width: 340, height: 18)
        claudeKeyField.frame = NSRect(x: 0, y: 174, width: 340, height: 24)
        autoRefreshLabel.frame = NSRect(x: 0, y: 140, width: 150, height: 22)
        autoRefreshPopup.frame = NSRect(x: 156, y: 138, width: 184, height: 26)
        appearanceLabel.frame = NSRect(x: 0, y: 112, width: 150, height: 22)
        appearancePopup.frame = NSRect(x: 156, y: 110, width: 184, height: 26)
        languageLabel.frame = NSRect(x: 0, y: 84, width: 150, height: 22)
        languagePopup.frame = NSRect(x: 156, y: 82, width: 184, height: 26)
        automaticWarmup.frame = NSRect(x: 0, y: 52, width: 340, height: 22)
        claudeAutomaticWarmup.frame = NSRect(x: 0, y: 26, width: 340, height: 22)
        launchAtLogin.frame = NSRect(x: 0, y: 0, width: 340, height: 22)
        [baseLabel, baseField, keyLabel, keyField, claudeBaseLabel, claudeBaseField, claudeKeyLabel, claudeKeyField,
         autoRefreshLabel, autoRefreshPopup, appearanceLabel, appearancePopup, languageLabel, languagePopup,
         automaticWarmup, claudeAutomaticWarmup, launchAtLogin].forEach(settingsView.addSubview)

        let alert = NSAlert()
        alert.messageText = isInitialSetup ? L.text("GrandeBar Setup", "GrandeBar Kurulum") : L.text("GrandeBar Settings", "GrandeBar Ayarlar")
        alert.informativeText = isInitialSetup
            ? L.text("Enter the CLIProxyAPI Management Center URL and management key.", "CLIProxyAPI Management Center URL ve management key gir.")
            : L.text("Panel URLs and management keys are stored here.", "Panel adresleri ve management key'ler burada saklanır.")
        alert.accessoryView = settingsView
        alert.addButton(withTitle: L.text("Save", "Kaydet"))
        alert.addButton(withTitle: L.text("Cancel", "İptal"))
        alert.window.appearance = Theme.appAppearance

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let managementKey = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let claudeManagementKey = claudeKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(AppConfig.normalizedBase(baseField.stringValue), forKey: AppConfig.apiBaseKey)
            UserDefaults.standard.set(managementKey, forKey: AppConfig.defaultsKey)
            UserDefaults.standard.set(AppConfig.normalizedBase(claudeBaseField.stringValue), forKey: AppConfig.claudeAPIBaseKey)
            UserDefaults.standard.set(claudeManagementKey, forKey: AppConfig.claudeManagementKeyKey)
            UserDefaults.standard.set(autoRefreshPopup.selectedItem?.representedObject as? Int ?? 0, forKey: AppConfig.autoRefreshMinutesKey)
            UserDefaults.standard.set(appearancePopup.selectedItem?.representedObject as? String ?? "auto", forKey: AppConfig.appearanceKey)
            UserDefaults.standard.set(languagePopup.selectedItem?.representedObject as? String ?? "auto", forKey: AppConfig.languageKey)
            UserDefaults.standard.set(automaticWarmup.state == .on, forKey: AppConfig.automaticWarmupKey)
            UserDefaults.standard.set(claudeAutomaticWarmup.state == .on, forKey: AppConfig.claudeAutomaticWarmupKey)
            UserDefaults.standard.synchronize()
            reloadViewForAppearance()
            updateAutoRefreshTimer()
            for mode in AppMode.allCases {
                if let cards = cardsByMode[mode] {
                    updateAutomaticWarmupSchedule(mode: mode, cards: cards)
                } else if mode != AppConfig.mode() {
                    automaticWarmupCheck(mode: mode)
                }
            }
            setLaunchAtLogin(launchAtLogin.state == .on)
            if refreshAfterSave && AppConfig.hasManagementKey() {
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
        let mode = AppConfig.mode()
        DispatchQueue.global(qos: .utility).async {
            let usage = mode == .claude ? LocalClaudeUsage.read() : LocalCodexUsage.read()
            DispatchQueue.main.async {
                guard mode == AppConfig.mode() else { return }
                if let usage {
                    self.latestUsage = usage
                    self.usageLabel.stringValue = self.usageLineText(usage)
                } else {
                    self.latestUsage = nil
                    self.usageLabel.stringValue = L.text("Token cost unavailable", "Token maliyeti hesaplanamadı")
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

    private func updateAutomaticWarmupSchedule(mode: AppMode, cards: [QuotaCard]) {
        automaticWarmupTimers[mode]?.invalidate()
        automaticWarmupTimers[mode] = nil
        guard AppConfig.automaticWarmupEnabled(for: mode), AppConfig.hasManagementKey(for: mode), !cards.isEmpty else { return }

        let eligible = cards.filter { !$0.isLocked }
        guard !eligible.isEmpty else { return }

        let hasColdAccount = eligible.contains {
            !Self.isSessionTimerLive(resetSeconds: $0.sessionResetSeconds, threshold: 1)
        }
        let delay: TimeInterval
        if hasColdAccount {
            delay = 1
        } else if let nearestReset = eligible.compactMap(\.sessionResetSeconds).filter({ $0 > 0 }).min() {
            delay = TimeInterval(nearestReset + 120)
        } else {
            delay = 15 * 60
        }
        scheduleAutomaticWarmup(mode: mode, after: delay)
    }

    private func scheduleAutomaticWarmup(mode: AppMode, after delay: TimeInterval) {
        automaticWarmupTimers[mode]?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.automaticWarmupCheck(mode: mode)
        }
        timer.tolerance = min(30, max(1, delay * 0.01))
        RunLoop.main.add(timer, forMode: .common)
        automaticWarmupTimers[mode] = timer
    }

    private func automaticWarmupCheck(mode: AppMode) {
        guard AppConfig.automaticWarmupEnabled(for: mode), AppConfig.hasManagementKey(for: mode) else { return }
        guard mode == AppConfig.mode() else {
            backgroundWarmup(mode: mode)
            return
        }
        guard !isRefreshing, !isWarming else {
            scheduleAutomaticWarmup(mode: mode, after: 30)
            return
        }
        warmSessionsClicked()
    }

    /// Warms and re-schedules a mode that is not on screen without touching the visible cards.
    private func backgroundWarmup(mode: AppMode) {
        guard backgroundWarmups[mode] == nil else { return }
        let warmup = SessionWarmupAPI(mode: mode)
        backgroundWarmups[mode] = warmup
        warmup.warmEligibleAccounts { [weak self] _ in
            QuotaAPI(mode: mode).fetchQuota { result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.backgroundWarmups[mode] = nil
                    switch result {
                    case .success(let cards):
                        self.cardsByMode[mode] = cards
                        self.updateAutomaticWarmupSchedule(mode: mode, cards: cards)
                    case .failure:
                        self.scheduleAutomaticWarmup(mode: mode, after: 15 * 60)
                    }
                }
            }
        }
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

        let mode = AppConfig.mode()
        if cards.isEmpty {
            renderError(L.text("No \(mode.title) credentials found", "\(mode.title) hesabı bulunamadı"))
            return
        }

        latestCards = cards
        cardsByMode[mode] = cards
        updateAutomaticWarmupSchedule(mode: mode, cards: cards)
        subtitleLabel.stringValue = summaryText(for: cards)
        setDetailLine(detailText(for: cards))
        let summary = totalLimitSummary(for: cards)
        let title = menuBarPoolTitle(summary)
        let tooltip = cards.map { "\($0.name): \($0.sessionPercent.map(String.init) ?? "--")% session, \($0.weeklyPercent.map(String.init) ?? "--")% weekly" }.joined(separator: "\n")
        statusUpdate(title, tooltip)

        if mode == .claude {
            let providerView = ProviderSwitchCardView { [weak self] proxy in
                self?.switchClaudeProvider(proxy: proxy)
            }
            stackView.addArrangedSubview(providerView)
            providerView.widthAnchor.constraint(equalToConstant: currentCardWidth()).isActive = true
        }

        let totalView = TotalLimitCardView(summary: summary, weeklyTitle: weeklyPoolTitle(for: cards))
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

    /// Claude accounts without a general weekly limit report a model-scoped one (Fable).
    private func weeklyPoolTitle(for cards: [QuotaCard]) -> String? {
        let labels = Set(cards.compactMap(\.weeklyLabel))
        guard labels.count == 1, let label = labels.first else { return nil }
        return L.text("\(label) pool", "\(label) havuzu")
    }

    private func renderError(_ message: String) {
        clearCards()
        subtitleLabel.stringValue = L.text("Could not load quota", "Kota yüklenemedi")
        setDetailLine(nil)
        statusUpdate(message.contains("IP banned") ? "ban" : "err", message)

        // Keep the provider switch reachable when the proxy is down, so Claude can go back to Official.
        if AppConfig.mode() == .claude {
            let providerView = ProviderSwitchCardView { [weak self] proxy in
                self?.switchClaudeProvider(proxy: proxy)
            }
            stackView.addArrangedSubview(providerView)
            providerView.widthAnchor.constraint(equalToConstant: currentCardWidth()).isActive = true
        }

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
        var rowsHeight = rowCount <= 1
            ? CGFloat(rows) * 96
            : UI.summaryCardHeight + CGFloat(rows - 1) * UI.accountCardHeight
        var gaps = max(0, rows - 1)
        if stackView.arrangedSubviews.contains(where: { $0 is ProviderSwitchCardView }) {
            rowsHeight += UI.providerCardHeight
            gaps += 1
        }
        let contentHeight = rowsHeight + CGFloat(gaps) * stackView.spacing
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
        if AppConfig.mode() == .claude {
            let plans = Array(Set(cards.compactMap(\.headline))).sorted().joined(separator: ", ")
            return L.text("\(cards.count) account · \(plans)", "\(cards.count) hesap · \(plans)")
        }
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
        var usageLine = L.text("Token cost unavailable (incomplete usage or missing model price).", "Token maliyeti hesaplanamadı (eksik kullanım veya model fiyatı).")
        if let usage = latestUsage {
            let modelsSuffix = usage.models.isEmpty
                ? ""
                : L.text(" Models: \(usage.models.joined(separator: ", ")).", " Modeller: \(usage.models.joined(separator: ", ")).")
            usageLine = L.text(
                "Token cost: today \(LocalCodexUsage.format(usage.today)), this week \(LocalCodexUsage.format(usage.week)), month to date \(LocalCodexUsage.format(usage.month)).\(modelsSuffix)",
                "Token cost: bugün \(LocalCodexUsage.format(usage.today)), bu hafta \(LocalCodexUsage.format(usage.week)), ay başından beri \(LocalCodexUsage.format(usage.month)).\(modelsSuffix)"
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
        if AppConfig.mode() == .claude {
            return L.text(
                "\(usageLine)\nClaude remaining total: session \(sessionPoolTitle(summary)), weekly \(weeklyTotal).\nAccount remaining:\n\(accounts)",
                "\(usageLine)\nClaude toplam kalan: oturum \(sessionPoolTitle(summary)), haftalık \(weeklyTotal).\nHesaplarda kalan:\n\(accounts)"
            )
        }
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
        // Keep footer to costs only so 4–5 digit $ amounts always fit; models go in copy summary.
        return L.text(
            "Today \(LocalCodexUsage.format(usage.today)) · Week \(LocalCodexUsage.format(usage.week)) · Month \(LocalCodexUsage.format(usage.month))",
            "Bugün \(LocalCodexUsage.format(usage.today)) · Hafta \(LocalCodexUsage.format(usage.week)) · Ay \(LocalCodexUsage.format(usage.month))"
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
        accent.layer?.backgroundColor = Theme.accent.withAlphaComponent(0.82).cgColor
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
        let weekly = MetricView(title: card.weeklyLabel ?? L.text("Weekly", "Haftalık"), percent: card.weeklyPercent, resetSeconds: card.weeklyResetSeconds)
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
        if let headline = card.headline { return headline }
        let count = card.resetCreditsAvailableCount.map(String.init) ?? "--"
        return L.text("Reset \(count)", "Reset \(count) adet")
    }

    private func resetExpiryText(_ card: QuotaCard) -> String {
        if let subline = card.subline { return subline }
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
    init(summary: TotalLimitSummary, weeklyTitle: String? = nil) {
        super.init(color: Theme.cardBackground, radius: 8, borderColor: Theme.border)

        let sessionPercent = percent(remaining: summary.sessionRemaining, total: summary.sessionTotal)
        let weeklyPercent = percent(remaining: summary.weeklyRemaining, total: summary.weeklyTotal)
        let session = TotalMetricView(title: L.text("Session pool", "Oturum havuzu"), value: valueText(sessionPercent), detail: L.text("total remaining", "toplam kalan"), percent: sessionPercent, tint: color(for: sessionPercent))
        let weekly = TotalMetricView(title: weeklyTitle ?? L.text("Weekly pool", "Haftalık havuz"), value: valueText(weeklyPercent), detail: L.text("total remaining", "toplam kalan"), percent: weeklyPercent, tint: color(for: weeklyPercent))
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
                return nil // A failed profile makes the aggregate incomplete.
            }
            anySuccess = true
            for row in rows {
                guard let date = row["date"] as? String,
                      let cost = doubleValue(row["costUSD"]),
                      cost.isFinite, cost >= 0 else { return nil }
                if date >= since, hasUnpricedUsage(row) {
                    return nil
                }
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
        // Use bundled pricing overrides offline; standard pricing prevents
        // priority service tier records from inflating the displayed cost.
        var arguments = [
            "codex", "daily",
            "--json",
            "--offline",
            "--speed", "standard",
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
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
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

    private static func hasUnpricedUsage(_ row: [String: Any]) -> Bool {
        let input = doubleValue(row["inputTokens"]) ?? 0
        let output = doubleValue(row["outputTokens"]) ?? 0
        let cache = doubleValue(row["cacheReadTokens"]) ?? 0
        let cost = doubleValue(row["costUSD"]) ?? 0
        if cost == 0 && input + output + cache > 0 { return true }
        return false
    }

    private static func modelNames(from row: [String: Any]) -> [String] {
        guard let models = row["models"] as? [String: Any] else { return [] }
        return models.keys.map(normalizedModelName)
    }

    private static func normalizedModelName(_ model: String) -> String {
        let lowercased = model.lowercased()
        if lowercased.hasPrefix("gpt-6.1-sol") { return "GPT-6.1 SOL" }
        if lowercased.hasPrefix("gpt-6-astra") { return "GPT-6 ASTRA" }
        if lowercased.hasPrefix("gpt-6") { return "GPT-6" }
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
    private let model = "gpt-5.6-luna"
    /// Primary session window length (5h). used% alone is not enough — timer must actually tick.
    private let sessionWindowSeconds = 18_000
    /// Skip warm only after countdown has moved this many seconds off the full 5h.
    private let progressThresholdSeconds = 120
    private let responsesURL = "https://chatgpt.com/backend-api/codex/responses"
    private let usageURL = "https://chatgpt.com/backend-api/wham/usage"
    private let mode: AppMode

    init(mode: AppMode) {
        self.mode = mode
    }

    func warmEligibleAccounts(completion: @escaping (Result<SessionWarmupSummary, Error>) -> Void) {
        let managementKey = AppConfig.managementKey(for: mode)
        guard !managementKey.isEmpty else {
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
                    .filter { ClaudeAPI.belongs($0, to: self.mode) }
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
        let account = (file["account"] as? String) ?? (file["email"] as? String) ?? (file["name"] as? String) ?? authIndex
        let authFileName = (file["name"] as? String) ?? ""
        guard !authIndex.isEmpty else {
            warmFiles(files, index: index + 1, managementKey: managementKey, acc: acc + [
                SessionWarmItem(account: account, action: .skipped, note: L.text("missing auth index", "auth index yok"))
            ], done: done)
            return
        }

        fetchUsage(authIndex: authIndex, managementKey: managementKey) { usageResult in
            switch usageResult {
            case .failure(let error):
                self.handleRevokedCredentialIfNeeded(
                    error: error,
                    authFileName: authFileName,
                    managementKey: managementKey
                ) { disabled in
                    let note = disabled
                        ? L.text("OAuth revoked · disabled automatically", "OAuth iptal · otomatik kapatıldı")
                        : error.localizedDescription
                    self.warmFiles(files, index: index + 1, managementKey: managementKey, acc: acc + [
                        SessionWarmItem(account: account, action: disabled ? .skipped : .failed, note: note)
                    ], done: done)
                }
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
                    switch warmResult {
                    case .failure(let error):
                        self.handleRevokedCredentialIfNeeded(
                            error: error,
                            authFileName: authFileName,
                            managementKey: managementKey
                        ) { disabled in
                            let note = disabled
                                ? L.text("OAuth revoked · disabled automatically", "OAuth iptal · otomatik kapatıldı")
                                : error.localizedDescription
                            let item = SessionWarmItem(
                                account: account,
                                action: disabled ? .skipped : .failed,
                                note: note
                            )
                            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
                                self.warmFiles(files, index: index + 1, managementKey: managementKey, acc: acc + [item], done: done)
                            }
                        }
                    case .success(let detail):
                        let item = SessionWarmItem(account: account, action: .warmed, note: detail)
                        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
                            self.warmFiles(files, index: index + 1, managementKey: managementKey, acc: acc + [item], done: done)
                        }
                    }
                }
            }
        }
    }

    private func handleRevokedCredentialIfNeeded(
        error: Error,
        authFileName: String,
        managementKey: String,
        completion: @escaping (Bool) -> Void
    ) {
        let nsError = error as NSError
        let message = nsError.localizedDescription.lowercased()
        guard nsError.code == 401,
              message.contains("token_revoked") || message.contains("invalidated oauth token"),
              !authFileName.isEmpty else {
            completion(false)
            return
        }

        apiJSON(
            path: "/auth-files/status",
            method: "PATCH",
            payload: ["name": authFileName, "disabled": true],
            managementKey: managementKey
        ) { result in
            switch result {
            case .success:
                completion(true)
            case .failure:
                completion(false)
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
        if mode == .claude {
            fetchClaudeUsage(authIndex: authIndex, managementKey: managementKey, completion: completion)
            return
        }
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
        if mode == .claude {
            sendClaudeWarmRequest(authIndex: authIndex, managementKey: managementKey, completion: completion)
            return
        }
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

    private func fetchClaudeUsage(authIndex: String, managementKey: String, completion: @escaping (Result<UsageProbe, Error>) -> Void) {
        let payload: [String: Any] = ["authIndex": authIndex, "method": "GET", "url": ClaudeAPI.usageURL, "header": ClaudeAPI.headers]
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
                let quota = ClaudeQuota.parse(body)
                completion(.success(UsageProbe(
                    accountId: nil,
                    allowed: nil,
                    limitReached: quota.limitReached,
                    usedPercent: quota.sessionRemaining.map { 100 - $0 },
                    sessionResetSeconds: quota.sessionResetSeconds,
                    limitType: nil
                )))
            }
        }
    }

    /// One-token Haiku request: Claude starts the 5h window on the first message.
    private func sendClaudeWarmRequest(authIndex: String, managementKey: String, completion: @escaping (Result<String, Error>) -> Void) {
        let body: [String: Any] = [
            "model": ClaudeAPI.warmModel,
            "max_tokens": 1,
            "system": [["type": "text", "text": "You are Claude Code, Anthropic's official CLI for Claude."]],
            "messages": [["role": "user", "content": "hi"]]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let dataString = String(data: data, encoding: .utf8) else {
            completion(.failure(NSError(domain: "GrandeBar", code: 10, userInfo: [NSLocalizedDescriptionKey: L.text("Could not build warm request", "Warm isteği oluşturulamadı")])))
            return
        }
        var headers = ClaudeAPI.headers
        headers["anthropic-version"] = "2023-06-01"
        headers["anthropic-beta"] = "oauth-2025-04-20,claude-code-20250219"
        headers["x-app"] = "cli"
        let payload: [String: Any] = [
            "authIndex": authIndex,
            "method": "POST",
            "url": ClaudeAPI.messagesURL,
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
                guard (200..<300).contains(status) else {
                    completion(.failure(NSError(domain: "GrandeBar", code: status, userInfo: [NSLocalizedDescriptionKey: "HTTP \(status): \(rawBody.prefix(200))"])))
                    return
                }
                let usage = self.parseJSONString(rawBody)["usage"] as? [String: Any] ?? [:]
                let tokens = (self.intValue(usage["input_tokens"]) ?? 0) + (self.intValue(usage["output_tokens"]) ?? 0)
                completion(.success(tokens > 0 ? L.text("opened · \(tokens) tok", "açıldı · \(tokens) tok") : L.text("opened", "açıldı")))
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
        guard let url = URL(string: "\(AppConfig.apiBase(for: mode))/v0/management\(path)") else {
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
    private let mode: AppMode

    init(mode: AppMode) {
        self.mode = mode
    }

    func fetchQuota(completion: @escaping (Result<[QuotaCard], Error>) -> Void) {
        let managementKey = AppConfig.managementKey(for: mode)
        guard !managementKey.isEmpty else {
            completion(.failure(NSError(domain: "GrandeBar", code: 1, userInfo: [NSLocalizedDescriptionKey: L.text("Management key is missing", "Management key eksik")])))
            return
        }

        // Strong self is intentional: callers create a QuotaAPI per refresh and do not retain it.
        apiJSON(path: "/auth-files", managementKey: managementKey) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let json):
                let files = (json["files"] as? [[String: Any]] ?? [])
                    .filter { ($0["disabled"] as? Bool) != true }
                    .filter { (($0["auth_index"] as? String) ?? ($0["authIndex"] as? String)) != nil }
                    .filter { ClaudeAPI.belongs($0, to: self.mode) }

                let group = DispatchGroup()
                let lock = NSLock()
                var cards: [QuotaCard] = []
                var firstError: Error?

                for file in files {
                    guard let authIndex = (file["auth_index"] as? String) ?? (file["authIndex"] as? String) else { continue }
                    group.enter()
                    let fetch = self.mode == .claude ? self.fetchClaudeUsage : self.fetchCodexUsage
                    fetch(authIndex, file, managementKey) { result in
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

    private func fetchClaudeUsage(authIndex: String, file: [String: Any], managementKey: String, completion: @escaping (Result<QuotaCard, Error>) -> Void) {
        let name = (file["email"] as? String) ?? (file["account"] as? String) ?? (file["name"] as? String) ?? authIndex
        claudeCall(authIndex: authIndex, url: ClaudeAPI.usageURL, managementKey: managementKey) { usageResult in
            switch usageResult {
            case .failure(let error):
                completion(.failure(error))
            case .success(let usage):
                self.claudeCall(authIndex: authIndex, url: ClaudeAPI.profileURL, managementKey: managementKey) { profileResult in
                    let quota = ClaudeQuota.parse(usage)
                    let plan = ClaudeAPI.planLabel((try? profileResult.get()) ?? [:])
                    completion(.success(QuotaCard(
                        name: name,
                        plan: plan,
                        sessionPercent: quota.sessionRemaining,
                        sessionResetSeconds: quota.sessionResetSeconds,
                        weeklyPercent: quota.weeklyRemaining,
                        weeklyResetSeconds: quota.weeklyResetSeconds,
                        resetCreditsAvailableCount: nil,
                        resetCreditExpiries: [],
                        allowed: nil,
                        limitReached: quota.limitReached,
                        updatedAt: Date(),
                        weeklyLabel: quota.weeklyLabel,
                        headline: plan,
                        subline: quota.weeklyResetDate.map(ClaudeAPI.formatDate) ?? "--"
                    )))
                }
            }
        }
    }

    private func claudeCall(authIndex: String, url: String, managementKey: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let payload: [String: Any] = ["authIndex": authIndex, "method": "GET", "url": url, "header": ClaudeAPI.headers]
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
                completion(.success(json["body"] as? [String: Any] ?? self.parseJSONString(json["body"] as? String)))
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
        guard let url = URL(string: "\(AppConfig.apiBase(for: mode))/v0/management\(path)") else {
            completion(.failure(NSError(domain: "GrandeBar", code: 3, userInfo: [NSLocalizedDescriptionKey: L.text("Base URL is invalid", "Base URL geçersiz")])))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("GrandeBar/0.2.10", forHTTPHeaderField: "User-Agent")
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

// MARK: - Claude mode

private enum ClaudeAPI {
    static let usageURL = "https://api.anthropic.com/api/oauth/usage"
    static let profileURL = "https://api.anthropic.com/api/oauth/profile"
    static let messagesURL = "https://api.anthropic.com/v1/messages?beta=true"
    static let warmModel = "claude-haiku-4-5"
    static let headers: [String: String] = [
        "Authorization": "Bearer $TOKEN$",
        "Content-Type": "application/json",
        "anthropic-beta": "oauth-2025-04-20",
        "User-Agent": "claude-cli/2.1.280 (external, cli)"
    ]

    /// Codex mode keeps every non-Claude credential so existing Codex setups behave as before.
    static func belongs(_ file: [String: Any], to mode: AppMode) -> Bool {
        let provider = ((file["provider"] as? String) ?? (file["type"] as? String) ?? "").lowercased()
        return mode == .claude ? provider == "claude" : provider != "claude"
    }

    static func planLabel(_ profile: [String: Any]) -> String {
        let org = profile["organization"] as? [String: Any] ?? [:]
        let account = profile["account"] as? [String: Any] ?? [:]
        let type = (org["organization_type"] as? String ?? "").lowercased()
        let tier = (org["rate_limit_tier"] as? String ?? "").lowercased()
        var label = "Claude"
        if type.contains("team") { label = "Team" }
        else if type.contains("enterprise") { label = "Enterprise" }
        else if (account["has_claude_max"] as? Bool) == true { label = "Max" }
        else if (account["has_claude_pro"] as? Bool) == true { label = "Pro" }
        if tier.contains("max_20x") { label += " 20x" } else if tier.contains("max_5x") { label += " 5x" }
        return label
    }

    static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L.isTurkish ? "tr_TR" : "en_US_POSIX")
        formatter.dateFormat = L.isTurkish ? "d MMM HH:mm" : "MMM d HH:mm"
        return formatter.string(from: date)
    }
}

/// Remaining percentages from `/api/oauth/usage`. Prefers the `limits` array (percent = used)
/// and falls back to the per-window fields (utilization = used).
private struct ClaudeQuota {
    var sessionRemaining: Int?
    var sessionResetSeconds: Int?
    var weeklyRemaining: Int?
    var weeklyResetSeconds: Int?
    var weeklyResetDate: Date?
    /// nil for the general weekly limit; the model name for a model-scoped one.
    var weeklyLabel: String?
    var limitReached = false

    static func parse(_ usage: [String: Any]) -> ClaudeQuota {
        typealias Window = (remaining: Int?, resets: Date?)
        var session: Window?
        var general: Window?
        var scoped: [(label: String, window: Window)] = []

        for limit in usage["limits"] as? [[String: Any]] ?? [] {
            let used = int(limit["percent"])
            let window: Window = (used.map { max(0, min(100, 100 - $0)) }, (limit["resets_at"] as? String).flatMap(date))
            let kind = limit["kind"] as? String ?? ""
            let group = limit["group"] as? String ?? ""
            let model = ((limit["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
            if kind == "session" || group == "session" {
                session = window
            } else if group == "weekly" {
                if let model { scoped.append((model, window)) } else { general = window }
            }
        }

        func legacy(_ key: String) -> Window? {
            guard let window = usage[key] as? [String: Any], let used = int(window["utilization"]) else { return nil }
            return (max(0, min(100, 100 - used)), (window["resets_at"] as? String).flatMap(date))
        }
        session = session ?? legacy("five_hour")
        general = general ?? legacy("seven_day")
        if scoped.isEmpty, let fable = legacy("seven_day_fable") {
            scoped.append(("Fable", fable))
        }

        var quota = ClaudeQuota()
        quota.sessionRemaining = session?.remaining
        quota.sessionResetSeconds = session?.resets.map { max(0, Int($0.timeIntervalSinceNow)) }
        let weekly: Window?
        if let general {
            weekly = general
        } else if let pick = scoped.first(where: { $0.label.lowercased().contains("fable") }) ?? scoped.first {
            weekly = pick.window
            quota.weeklyLabel = pick.label
        } else {
            weekly = nil
        }
        quota.weeklyRemaining = weekly?.remaining
        quota.weeklyResetDate = weekly?.resets
        quota.weeklyResetSeconds = weekly?.resets.map { max(0, Int($0.timeIntervalSinceNow)) }
        let locked = ((usage["five_hour"] as? [String: Any])?["locked_reason"] as? String).map { !$0.isEmpty } ?? false
        quota.limitReached = locked || quota.sessionRemaining == 0 || quota.weeklyRemaining == 0
        return quota
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return Int(number.doubleValue.rounded()) }
        if let string = value as? String, let number = Double(string) { return Int(number.rounded()) }
        return nil
    }

    private static func date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

/// Claude Code cost from `ccusage claude daily`. Online pricing on purpose: the offline table
/// lacks current Claude models and reports $0 for them.
private enum LocalClaudeUsage {
    static func read() -> LocalUsage? {
        let dates = dateKeys()
        let since = min(dates.weekStart, dates.monthStart)
        guard let json = ccusageJSON(since: since),
              let rows = json["daily"] as? [[String: Any]] else { return nil }

        var today = 0.0, week = 0.0, month = 0.0
        var models = Set<String>()
        for row in rows {
            guard let date = row["date"] as? String,
                  let cost = double(row["totalCost"] ?? row["costUSD"]), cost.isFinite, cost >= 0 else { continue }
            if date == dates.today { today += cost }
            if date >= dates.weekStart {
                week += cost
                for breakdown in row["modelBreakdowns"] as? [[String: Any]] ?? [] {
                    if let name = breakdown["modelName"] as? String { models.insert(family(name)) }
                }
            }
            if date >= dates.monthStart { month += cost }
        }
        return LocalUsage(today: today, week: week, month: month, models: models.sorted())
    }

    private static func ccusageJSON(since: String) -> [String: Any]? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.npm-global/bin/ccusage", "/opt/homebrew/bin/ccusage", "/usr/local/bin/ccusage"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["claude", "daily", "--json", "--timezone", TimeZone.current.identifier, "--since", since]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(home)/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(environment["PATH"] ?? "")"
        process.environment = environment
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func family(_ model: String) -> String {
        let lowercased = model.lowercased()
        for name in ["fable", "opus", "sonnet", "haiku"] where lowercased.contains(name) {
            return name.uppercased()
        }
        return model.uppercased()
    }

    private static func dateKeys() -> (today: String, weekStart: String, monthStart: String) {
        let now = Date()
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: now)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? today
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return (formatter.string(from: today), formatter.string(from: weekStart), formatter.string(from: monthStart))
    }

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}

// MARK: - Claude provider switch (Claude Desktop + Claude Code)

private enum ProviderMode {
    case official, proxy, other

    var label: String {
        switch self {
        case .official: return L.text("Official", "Resmi")
        case .proxy: return "CLIProxy"
        case .other: return L.text("Other", "Diğer")
        }
    }
}

/// Writes Claude Desktop's third-party gateway profile (same layout CC Switch uses, under our
/// own profile id) and the Claude Code `env` override. Every file is backed up once before the
/// first change as `<file>.grandebar.bak`.
private enum ClaudeProviderSwitcher {
    static let profileID = "4c1b2a10-5e1d-4000-8000-00000c11b0a1"
    static let profileName = "GrandeBar CLIProxy"
    static let desktopBundleID = "com.anthropic.claudefordesktop"
    private static let gatewayKeys = ["inferenceGatewayApiKey", "inferenceGatewayAuthScheme", "inferenceGatewayBaseUrl", "inferenceProvider", "disableDeploymentModeChooser"]

    // GRANDEBAR_CLAUDE_HOME redirects every write to a sandbox directory for dry runs.
    private static var home: String {
        ProcessInfo.processInfo.environment["GRANDEBAR_CLAUDE_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
    }
    private static var appSupport: String { home + "/Library/Application Support" }
    private static var normalConfig: URL { URL(fileURLWithPath: appSupport + "/Claude/claude_desktop_config.json") }
    private static var threePConfig: URL { URL(fileURLWithPath: appSupport + "/Claude-3p/claude_desktop_config.json") }
    private static var libraryDir: URL { URL(fileURLWithPath: appSupport + "/Claude-3p/configLibrary") }
    private static var profileFile: URL { libraryDir.appendingPathComponent("\(profileID).json") }
    private static var metaFile: URL { libraryDir.appendingPathComponent("_meta.json") }
    private static var codeSettings: URL { URL(fileURLWithPath: home + "/.claude/settings.json") }
    private static var proxyBase: String { AppConfig.apiBase(for: .claude) }

    static func desktopMode() -> ProviderMode {
        guard (readJSON(normalConfig)["deploymentMode"] as? String) == "3p" else { return .official }
        return (readJSON(metaFile)["appliedId"] as? String) == profileID ? .proxy : .other
    }

    static func codeMode() -> ProviderMode {
        let env = readJSON(codeSettings)["env"] as? [String: Any] ?? [:]
        guard let base = env["ANTHROPIC_BASE_URL"] as? String, !base.isEmpty else { return .official }
        return AppConfig.normalizedBase(base) == proxyBase ? .proxy : .other
    }

    /// Proxy client key: first entry of `access.api-keys` via the management API, else the local credentials file.
    static func resolveAPIKey() -> String? {
        let managementKey = AppConfig.managementKey(for: .claude)
        if !managementKey.isEmpty, let url = URL(string: "\(proxyBase)/v0/management/api-keys") {
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
            let semaphore = DispatchSemaphore(value: 0)
            var key: String?
            URLSession.shared.dataTask(with: request) { data, _, _ in
                if let data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    key = (json["api-keys"] as? [String])?.first
                }
                semaphore.signal()
            }.resume()
            _ = semaphore.wait(timeout: .now() + 12)
            if let key, !key.isEmpty { return key }
        }
        return AppConfig.localCredential("API_KEY")
    }

    static func apply(proxy: Bool, apiKey: String?) throws {
        if proxy {
            guard let apiKey, !apiKey.isEmpty else {
                throw error(L.text("Proxy API key not found (management api-keys or ~/cliproxyapi/.credentials).", "Proxy API key bulunamadı (management api-keys veya ~/cliproxyapi/.credentials)."))
            }
            try patch(normalConfig) { $0["deploymentMode"] = "3p" }
            try patch(threePConfig) { $0["deploymentMode"] = "3p" }
            try patch(profileFile, permissions: 0o600) { profile in
                profile["coworkEgressAllowedHosts"] = ["*"]
                profile["disableDeploymentModeChooser"] = true
                profile["inferenceGatewayApiKey"] = apiKey
                profile["inferenceGatewayAuthScheme"] = "bearer"
                profile["inferenceGatewayBaseUrl"] = proxyBase
                profile["inferenceProvider"] = "gateway"
            }
            try patch(metaFile) { meta in
                var entries = meta["entries"] as? [[String: Any]] ?? []
                if let index = entries.firstIndex(where: { ($0["id"] as? String) == profileID }) {
                    entries[index]["name"] = profileName
                } else {
                    entries.append(["id": profileID, "name": profileName])
                }
                meta["entries"] = entries
                meta["appliedId"] = profileID
            }
            try patch(codeSettings) { settings in
                var env = settings["env"] as? [String: Any] ?? [:]
                env["ANTHROPIC_BASE_URL"] = proxyBase
                env["ANTHROPIC_AUTH_TOKEN"] = apiKey
                settings["env"] = env
            }
        } else {
            try patch(normalConfig) { $0["deploymentMode"] = "1p" }
            let fm = FileManager.default
            if fm.fileExists(atPath: threePConfig.path) {
                try patch(threePConfig) { $0["deploymentMode"] = "1p" }
            }
            if fm.fileExists(atPath: metaFile.path) {
                try patch(metaFile) { meta in
                    var entries = meta["entries"] as? [[String: Any]] ?? []
                    entries.removeAll { ($0["id"] as? String) == profileID }
                    meta["entries"] = entries
                    if (meta["appliedId"] as? String) == profileID {
                        if let next = entries.first?["id"] as? String {
                            meta["appliedId"] = next
                        } else {
                            meta.removeValue(forKey: "appliedId")
                        }
                    }
                }
            }
            if fm.fileExists(atPath: profileFile.path) {
                try patch(profileFile, permissions: 0o600) { profile in
                    gatewayKeys.forEach { profile.removeValue(forKey: $0) }
                }
            }
            if fm.fileExists(atPath: codeSettings.path) {
                try patch(codeSettings) { settings in
                    var env = settings["env"] as? [String: Any] ?? [:]
                    if let base = env["ANTHROPIC_BASE_URL"] as? String, AppConfig.normalizedBase(base) == proxyBase {
                        env.removeValue(forKey: "ANTHROPIC_BASE_URL")
                        env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
                    }
                    settings["env"] = env
                }
            }
        }
    }

    static func runningDesktop() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: desktopBundleID).first
    }

    /// Claude Desktop rewrites its config on exit, so it must be closed before patching.
    static func quitDesktopAndWait(timeout: TimeInterval = 20) -> Bool {
        guard let app = runningDesktop() else { return true }
        app.terminate()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if runningDesktop() == nil { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return runningDesktop() == nil
    }

    static func launchDesktop() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: desktopBundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private static func readJSON(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    private static func patch(_ url: URL, permissions: Int? = nil, _ body: (inout [String: Any]) -> Void) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url), !data.isEmpty,
               (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] == nil {
                throw error(L.text("\(url.lastPathComponent) is not valid JSON; left untouched.", "\(url.lastPathComponent) geçerli JSON değil; dokunulmadı."))
            }
            let backup = url.path + ".grandebar.bak"
            if !fm.fileExists(atPath: backup) {
                try? fm.copyItem(atPath: url.path, toPath: backup)
            }
        }
        var object = readJSON(url)
        body(&object)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
        if let permissions {
            try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "GrandeBar", code: 20, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private final class ProviderSwitchCardView: RoundedView {
    private let onChange: (Bool) -> Void
    private let segmented = NSSegmentedControl(labels: [L.text("Official", "Resmi"), "CLIProxy"], trackingMode: .selectOne, target: nil, action: nil)

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init(color: Theme.cardBackground, radius: 8, borderColor: Theme.cardBorder)
        translatesAutoresizingMaskIntoConstraints = false

        let accent = NSView()
        accent.wantsLayer = true
        accent.layer?.backgroundColor = Theme.claudeAccent.withAlphaComponent(0.82).cgColor
        accent.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: L.text("Claude provider", "Claude sağlayıcı"))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Theme.primaryText
        title.translatesAutoresizingMaskIntoConstraints = false

        let desktop = ClaudeProviderSwitcher.desktopMode()
        let code = ClaudeProviderSwitcher.codeMode()
        let state = NSTextField(labelWithString: "Desktop: \(desktop.label) · Code: \(code.label)")
        state.font = .systemFont(ofSize: 10, weight: .medium)
        state.textColor = Theme.mutedText
        state.lineBreakMode = .byTruncatingTail
        state.translatesAutoresizingMaskIntoConstraints = false

        segmented.target = self
        segmented.action = #selector(changed)
        segmented.segmentStyle = .rounded
        segmented.controlSize = .small
        segmented.translatesAutoresizingMaskIntoConstraints = false
        if desktop == .proxy && code == .proxy {
            segmented.selectedSegment = 1
        } else if desktop == .official && code == .official {
            segmented.selectedSegment = 0
        } else {
            segmented.selectedSegment = -1
        }

        [accent, title, state, segmented].forEach(addSubview)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: UI.providerCardHeight),
            accent.leadingAnchor.constraint(equalTo: leadingAnchor),
            accent.topAnchor.constraint(equalTo: topAnchor),
            accent.bottomAnchor.constraint(equalTo: bottomAnchor),
            accent.widthAnchor.constraint(equalToConstant: 1),

            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            title.trailingAnchor.constraint(lessThanOrEqualTo: segmented.leadingAnchor, constant: -8),

            state.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            state.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            state.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),

            segmented.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            segmented.centerYAnchor.constraint(equalTo: title.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func changed() {
        onChange(segmented.selectedSegment == 1)
    }
}

extension QuotaViewController {
    fileprivate func switchClaudeProvider(proxy: Bool) {
        let target = proxy ? "CLIProxy" : L.text("Official account", "Resmi hesap")
        let desktopRunning = ClaudeProviderSwitcher.runningDesktop() != nil

        let alert = NSAlert()
        alert.messageText = L.text("Switch Claude to \(target)", "Claude'u \(target) moduna geçir")
        var info = L.text(
            "Claude Desktop and Claude Code settings will point to \(target).",
            "Claude Desktop ve Claude Code ayarları \(target) olarak yazılacak."
        )
        if desktopRunning {
            info += "\n\n" + L.text(
                "Claude Desktop will quit and reopen. Open chats and Code sessions will be interrupted.",
                "Claude Desktop kapatılıp yeniden açılacak. Açık sohbetler ve Code oturumları yarıda kalır."
            )
        }
        if proxy {
            info += "\n\n" + L.text(
                "In CLIProxy mode Claude Desktop keeps a separate local chat history; claude.ai chats return when you switch back.",
                "CLIProxy modunda Claude Desktop ayrı, yerel bir sohbet geçmişi tutar; claude.ai sohbetleri Resmi'ye dönünce geri gelir."
            )
        }
        info += "\n\n" + L.text(
            "Running Claude Code terminal sessions pick up the change after a restart.",
            "Açık Claude Code terminal oturumları değişikliği yeniden başlatınca alır."
        )
        alert.informativeText = info
        alert.addButton(withTitle: desktopRunning ? L.text("Apply and Restart", "Uygula ve yeniden başlat") : L.text("Apply", "Uygula"))
        alert.addButton(withTitle: L.text("Cancel", "İptal"))
        alert.window.appearance = Theme.appAppearance
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            render(cards: latestCards)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var failure: Error?
            let apiKey = proxy ? ClaudeProviderSwitcher.resolveAPIKey() : nil
            let quitOK = ClaudeProviderSwitcher.quitDesktopAndWait()
            if quitOK {
                do {
                    try ClaudeProviderSwitcher.apply(proxy: proxy, apiKey: apiKey)
                } catch {
                    failure = error
                }
                if desktopRunning {
                    Thread.sleep(forTimeInterval: 1)
                    ClaudeProviderSwitcher.launchDesktop()
                }
            } else {
                failure = NSError(domain: "GrandeBar", code: 21, userInfo: [NSLocalizedDescriptionKey: L.text(
                    "Claude Desktop did not quit; nothing was changed.",
                    "Claude Desktop kapanmadı; hiçbir ayar değişmedi."
                )])
            }
            DispatchQueue.main.async {
                self.render(cards: self.latestCards)
                if let failure {
                    let alert = NSAlert(error: failure)
                    alert.messageText = L.text("Switch failed", "Geçiş yapılamadı")
                    alert.runModal()
                }
            }
        }
    }
}

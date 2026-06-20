import Cocoa
import SwiftUI
import Combine

@main
struct RemindersSpotlight: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        if #available(macOS 14.0, *) {
            Window(String(""), id: "SettingsOpener") {
                SettingsOpenerView()
            }
            .windowResizability(.contentSize)
            .windowStyle(.hiddenTitleBar)
            .defaultSize(width: 0, height: 0)
        }

        Settings {
            SettingsView()
        }
        .commands {
            AppCommands()
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    // swiftlint:disable:next implicitly_unwrapped_optional
    static private(set) var shared: AppDelegate!

    private var sharedAuthorizationErrorMessage: String?
    private var currentMenuBarCount = 0
    private var currentReminderPreview: String?

    // Kept alive for the whole app lifetime so the menu bar counter/preview
    // keep updating even while the window is closed.
    lazy var remindersData = RemindersData()
    private lazy var copyShortcutCoordinator = CopyShortcutCoordinator()

    private var mainPanel: FloatingPanel?
    private var resignObserver: NSObjectProtocol?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var occlusionObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var panelWasVisible = false
    private var globalMouseMoveMonitor: Any?
    private var mouseMoveAnchor: NSPoint = .zero

    lazy var statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        AppDelegate.shared = self

        // This is a menu-bar agent: it must stay resident even with no open
        // windows. Once we order out the hidden Settings-opener window (below),
        // the app would otherwise have no windows and macOS would reap it via
        // automatic termination — so opt out.
        ProcessInfo.processInfo.disableAutomaticTermination("Menu bar agent stays resident")

        configureMenuBarButton()
        configureKeyboardShortcut()

        // Start the data store now so the menu bar count is live before the
        // window is first opened.
        if RemindersService.shared.isAuthorized {
            _ = remindersData
        }

        // The macOS 14+ Settings opener lives in a hidden Window scene that
        // otherwise shows up as a blank tile in Mission Control. Tuck it away.
        hideSettingsOpenerWindow()
    }

    /// Keep the agent alive when its (only, hidden) window is closed/ordered out.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// The `SettingsOpener` Window scene (macOS 14+) opens a 0×0 window at
    /// launch. It only needs to exist to host a notification subscriber — not to
    /// be on screen — but as a real window it shows as an empty tile in Mission
    /// Control and the window switcher. Order it out (the scene/view stays alive,
    /// so opening Settings still works). The scene materializes asynchronously,
    /// so retry briefly until it's found.
    private func hideSettingsOpenerWindow(attempt: Int = 0) {
        var hidden = false
        for window in NSApp.windows where window !== mainPanel {
            let identifier = window.identifier?.rawValue ?? ""
            let isTinyUntitled = window.title.isEmpty
                && window.frame.width < 60 && window.frame.height < 60
            if identifier.contains("SettingsOpener") || isTinyUntitled {
                window.isExcludedFromWindowsMenu = true
                window.orderOut(nil)
                hidden = true
            }
        }
        if !hidden && attempt < 10 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.hideSettingsOpenerWindow(attempt: attempt + 1)
            }
        }
    }

    func updateMenuBarCount(to count: Int) {
        currentMenuBarCount = count
        applyMenuBarButtonAppearance()
    }

    func updateMenuBarReminderPreview(_ title: String?) {
        currentReminderPreview = title
        applyMenuBarButtonAppearance()
    }

    private func applyMenuBarButtonAppearance() {
        let reminderPreview = currentReminderPreview
        let menuBarCount = currentMenuBarCount

        if let reminderPreview {
            let hideCounter = UserPreferences.shared.hideCounterWhenReminderPreviewIsShown
            if !hideCounter && menuBarCount > 0 {
                statusBarItem.button?.title = "\(menuBarCount) · \(reminderPreview)"
            } else {
                statusBarItem.button?.title = reminderPreview
            }
        } else {
            let buttonTitle = menuBarCount > 0 ? String(menuBarCount) : ""
            statusBarItem.button?.title = buttonTitle
        }

        loadMenuBarIcon()
    }
    
    func loadMenuBarIcon() {
        let isContentVisible = currentMenuBarCount > 0 || currentReminderPreview != nil
        let shouldHideIcon = UserPreferences.shared.hideMenuBarIconWhenContentIsShown && isContentVisible
        statusBarItem.button?.image = shouldHideIcon ? nil : UserPreferences.shared.reminderMenuBarIcon.image
    }
    
    private func configureMenuBarButton() {
        loadMenuBarIcon()
        statusBarItem.button?.imagePosition = .imageLeading
        statusBarItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusBarItem.button?.action = #selector(handleStatusBarButtonAction)
    }
    
    private func configureKeyboardShortcut() {
        KeyboardShortcutService.shared.action(for: .openRemindersMenuBar) { [weak self] in
            self?.togglePopover()
        }
    }

    @objc private func handleStatusBarButtonAction() {
        // Clicking the menu bar item shows a dropdown menu (like most menu bar
        // apps). The quick-entry window is opened with the global shortcut
        // (⌥Space) or the menu's "New Reminder" item.
        showStatusBarMenu()
    }

    private func showStatusBarMenu() {
        let menu = RightClickMenuHelper.shared.buildStatusBarMenu()
        statusBarItem.menu = menu
        statusBarItem.button?.performClick(nil)
        statusBarItem.menu = nil
    }

    /// Opens the quick-entry window (used by the global shortcut and the menu's
    /// "New Reminder" item). Requests Reminders access first if needed.
    func openEntryWindow() {
        guard RemindersService.shared.isAuthorized else {
            requestAuthorization()
            return
        }
        if !isMainWindowShown {
            showMainWindow()
        }
    }

    @objc private func togglePopover() {
        guard RemindersService.shared.isAuthorized else {
            requestAuthorization()
            return
        }

        if isMainWindowShown {
            closeMainWindow()
        } else {
            showMainWindow()
        }
    }

    // MARK: - Centered window

    var mainWindow: NSWindow? { mainPanel }

    var isMainWindowShown: Bool { mainPanel?.isVisible == true }

    func closeMainWindow() {
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
            self.spaceObserver = nil
        }
        if let globalMouseMoveMonitor {
            NSEvent.removeMonitor(globalMouseMoveMonitor)
            self.globalMouseMoveMonitor = nil
        }
        mainPanel?.orderOut(nil)
        mainPanel = nil
        NotificationCenter.default.post(name: .mainWindowDidClose, object: nil)
    }

    // MARK: - Dismiss on Mission Control / space change (Spotlight behavior)

    /// When the panel stops being visible to the user — entering Mission Control,
    /// switching Spaces — close it, like Spotlight. We only act once the panel
    /// has actually been seen on screen (`panelWasVisible`), so the brief
    /// not-yet-visible moment during the open animation doesn't self-dismiss it.
    private func handleOcclusionChange() {
        guard let panel = mainPanel, panel.isVisible else { return }
        if panel.occlusionState.contains(.visible) {
            panelWasVisible = true
        } else if panelWasVisible {
            closeMainWindow()
        }
    }

    // MARK: - Click-outside dismissal (Spotlight behavior)

    /// Fired by the global/local mouse-down monitors. Skip while a menu/popover
    /// is tracking (e.g. the in-bar list picker), then defer the actual dismissal
    /// off the event-monitor callback so we never tear the window down mid-dispatch.
    private func outsideClickFired() {
        guard RunLoop.current.currentMode != .eventTracking else { return }
        let point = NSEvent.mouseLocation
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.dismissIfOutside(point) }
        }
    }

    private func dismissIfOutside(_ point: NSPoint) {
        guard let panel = mainPanel, panel.isVisible else { return }
        if panel.frame.contains(point) { return }
        if FilterPanelController.shared.containsScreenPoint(point) { return }
        if let statusWindow = statusBarItem.button?.window, statusWindow.frame.contains(point) {
            return
        }
        closeMainWindow()
    }

    private func showMainWindow() {
        let panel = makeMainPanel()
        mainPanel = panel
        positionCentered(panel)

        // Show as a non-activating overlay (Spotlight-style): the panel becomes
        // key so its text field accepts typing, but we do NOT call
        // NSApp.activate — the app in the foreground keeps its activation, and
        // the panel layers on top instead of swapping the active app.
        panel.makeKeyAndOrderFront(nil)
        // The fade + bounce runs in SwiftUI (SpotlightRoot.onAppear).

        // Refresh reminders on every open so the hover list is never stale, and
        // so it recovers if an earlier load raced EventKit and came back empty.
        panelWasVisible = false
        Task { await remindersData.update() }
        // Fallback arm, in case the occlusion notification doesn't fire on show.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated { self?.panelWasVisible = true }
        }

        // Dismiss when the user switches to another app — but not when focus
        // moves to our own menus/sheets, which keep the app active.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeMainWindow() }
        }

        // Dismiss on a click anywhere outside our UI (Spotlight behavior).
        // Global monitor: clicks in other apps / the desktop. Local monitor:
        // clicks inside our own process but outside the panel (returns the event
        // unchanged so normal interaction still works).
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.outsideClickFired() }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.outsideClickFired() }
            return event
        }

        // Dismiss when the panel stops being visible — entering Mission Control
        // (occlusion) or switching Spaces (Spotlight behavior).
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleOcclusionChange() }
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeMainWindow() }
        }

        // Expand to the full list on mouse movement while open. A global monitor
        // catches movement over other apps / the desktop — which is where the
        // cursor almost always is right after ⌥Space (it was on the keyboard).
        // We intentionally do NOT also route mouse-moved through our own window
        // (no local monitor / acceptsMouseMovedEvents), to avoid per-event
        // hit-testing over the reminders list.
        mouseMoveAnchor = NSEvent.mouseLocation
        globalMouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMovedWhileOpen() }
        }
    }

    /// Fired by the mouse-move monitors. Posts a (throttled) expand cue once the
    /// pointer has traveled a few points from where it was last sampled — so the
    /// list opens as soon as you nudge the mouse, but a dead-still pointer (e.g.
    /// the panel opening under the cursor) doesn't trigger it.
    private func mouseMovedWhileOpen() {
        guard let panel = mainPanel, panel.isVisible else { return }
        let location = NSEvent.mouseLocation
        let dx = location.x - mouseMoveAnchor.x
        let dy = location.y - mouseMoveAnchor.y
        guard (dx * dx + dy * dy) > 25 else { return }   // ~5pt of travel
        mouseMoveAnchor = location
        NotificationCenter.default.post(name: .mainWindowDidDetectMouseMove, object: nil)
    }

    static var collapsedHeight: CGFloat { SpotlightMetrics.collapsedWindowHeight }

    private func makeMainPanel() -> FloatingPanel {
        let rootView = SpotlightRoot {
            SpotlightView()
                .environmentObject(self.remindersData)
                .environmentObject(self.copyShortcutCoordinator)
        }
        let hosting = NSHostingView(rootView: rootView)
        // Don't let the hosting view auto-size the window to its content — we
        // drive the window height ourselves via setMainHeight. Leaving the
        // default (.intrinsicContentSize) makes the two fight each other and
        // crashes with an "Update Constraints in Window" loop on expand.
        hosting.sizingOptions = []

        // Open collapsed (just the entry bar); grows on expand via setMainHeight.
        // Width is the card + chrome margin on both sides (clamped to the screen).
        let width = min(
            SpotlightMetrics.windowWidth,
            mainScreenVisibleFrame().width - MainPopoverSizing.minWidthPadding
        )
        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: AppDelegate.collapsedHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Shadow is drawn in SwiftUI (on the card) so it scales with the pop-in;
        // an AppKit window shadow would snap to the square window bounds instead.
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        // NOTE: no .stationary — that flag exempts the window from Mission
        // Control (it stays floating in place instead of being pulled into the
        // overview), which both keeps it visible during Mission Control and
        // stops its occlusion state from changing. Without it, entering Mission
        // Control occludes the panel and our occlusion observer dismisses it.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        return panel
    }

    /// Animates the panel to a new height, keeping the top edge fixed so it
    /// unfurls downward. Clamped to the usable screen.
    func setMainHeight(_ height: CGFloat) {
        guard let panel = mainPanel else { return }
        let target = min(height, mainScreenVisibleFrame().height - 40)
        guard abs(panel.frame.height - target) > 0.5 else { return }
        var frame = panel.frame
        let topY = frame.maxY
        frame.size.height = target
        frame.origin.y = topY - target
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.11
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func positionCentered(_ panel: NSPanel) {
        let size = panel.frame.size
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let x = visible.midX - size.width / 2
        // Put the CARD's top edge ~18% down from the top of the usable screen —
        // measured to match Spotlight from a side-by-side. The window extends
        // chromeInset higher (shadow margin), so offset the window top by it.
        let cardTopY = visible.maxY - visible.height * 0.18
        let y = (cardTopY + SpotlightMetrics.chromeInset) - size.height
        panel.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }

    // - MARK: Popover sizing

    func setMainPopoverSize(size: NSSize, persist: Bool = false) {
        let clampedSize = clampedMainPopoverSize(size: size)
        mainPanel?.setContentSize(clampedSize)

        if persist {
            UserPreferences.shared.mainPopoverSize = clampedSize
        }
    }

    var mainContentSize: NSSize {
        mainPanel?.contentView?.frame.size
            ?? clampedMainPopoverSize(size: UserPreferences.shared.mainPopoverSize)
    }

    private func mainScreenVisibleFrame() -> NSRect {
        if let screen = statusBarItem.button?.window?.screen {
            return screen.visibleFrame
        }
        return NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
    }

    private func clampedMainPopoverSize(size: NSSize) -> NSSize {
        let screenSize = mainScreenVisibleFrame()

        let maxWidth = (screenSize.width - MainPopoverSizing.minWidthPadding)
            .constrainedTo(min: MainPopoverSizing.minSize.width, max: MainPopoverSizing.maxSize.width)
        let width = size.width.constrainedTo(min: MainPopoverSizing.minSize.width, max: maxWidth)

        let maxHeight = (screenSize.height - MainPopoverSizing.minHeightPadding)
            .constrainedTo(min: MainPopoverSizing.minSize.height, max: MainPopoverSizing.maxSize.height)
        let height = size.height.constrainedTo(min: MainPopoverSizing.minSize.height, max: maxHeight)

        return NSSize(width: width, height: height)
    }

}

// - MARK: Authorization functions

extension AppDelegate: NSAlertDelegate {
    private func requestAuthorization() {
        RemindersService.shared.requestAccess { [weak self] granted, errorMessage in
            if granted {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        _ = self.remindersData
                        self.showMainWindow()
                    }
                }
                return
            }

            print("Access to reminders not granted:", errorMessage ?? "no error description")
            DispatchQueue.main.async {
                self?.sharedAuthorizationErrorMessage = errorMessage
                self?.presentNoAuthorizationAlert()
            }
        }
    }
    
    private func presentNoAuthorizationAlert() {
        let alert = NSAlert()
        alert.messageText = rmbLocalized(.appNoRemindersAccessAlertMessage, arguments: AppConstants.appName)
        let reasonDescription = rmbLocalized(
            .appNoRemindersAccessAlertReasonDescription,
            arguments: AppConstants.appName
        )
        let actionDescription = rmbLocalized(
            .appNoRemindersAccessAlertActionDescription,
            arguments: AppConstants.appName
        )
        alert.informativeText = "\(reasonDescription)\n\(actionDescription)"
        if sharedAuthorizationErrorMessage != nil {
            alert.delegate = self
            alert.showsHelp = true
        }
        
        alert.addButton(withTitle: rmbLocalized(.okButton))
        alert.addButton(withTitle: rmbLocalized(.openSystemPreferencesButton))
        alert.addButton(withTitle: rmbLocalized(.appQuitButton)).hasDestructiveAction = true
        
        NSApp.activate(ignoringOtherApps: true)
        let modalResponse = alert.runModal()
        switch modalResponse {
        case .alertSecondButtonReturn:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
                NSWorkspace.shared.open(url)
            }
        case .alertThirdButtonReturn:
            NSApp.terminate(self)
        default:
            sharedAuthorizationErrorMessage = nil
        }
    }
    
    internal func alertShowHelp(_ alert: NSAlert) -> Bool {
        let helpAlert = NSAlert()
        let errorDescription = sharedAuthorizationErrorMessage ?? "no error description"
        helpAlert.icon = NSImage(systemSymbolName: "calendar.badge.exclamationmark", accessibilityDescription: nil)
        helpAlert.messageText = rmbLocalized(.appNoRemindersAccessAlertMessage, arguments: AppConstants.appName)
        helpAlert.informativeText = "Authorization error: \(errorDescription)"
        helpAlert.runModal()
        
        return true
    }
}

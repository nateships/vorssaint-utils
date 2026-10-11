// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit

/// Shows a small bar of actions next to selected text, or paste tools at the
/// caret of an editable field.
///
/// For a selection, the bar offers a copy that keeps formatting and the
/// command bar's own selection rows. It adds no transform of its own. The
/// paste tools reuse the existing paste, Paste as Plain Text and clipboard
/// history.
///
/// The selection is read through Accessibility only: after a drag or a double
/// or triple click in another app, or when the shortcut is pressed. Nothing is
/// read while the feature is off, and the text never leaves the Mac or reaches
/// disk.
final class SelectionBarService: ObservableObject {
    static let shared = SelectionBarService()

    /// Long enough for the app to update its selection after the release.
    private static let readDelay: TimeInterval = 0.08

    /// What asked for the bar.
    private enum Trigger {
        /// A mouse gesture in another app, pressed at `press` and released at
        /// `release`. A double or triple click that selected nothing asks for
        /// the paste tools.
        case mouse(press: CGPoint?, release: CGPoint, offersPaste: Bool)
        case shortcut

        /// True when an editable field with nothing selected gets the paste tools.
        var offersPaste: Bool {
            switch self {
            case .mouse(_, _, let paste): return paste
            case .shortcut: return true
            }
        }
    }

    private let panel = SelectionBarPanel()
    // The screen capture tools use ids 25 and up, so this id comes after them.
    private let hotkey = QuickToolHotkey(id: 62)
    private var monitor: Any?
    private var pressLocation: CGPoint?
    /// Bumped by every press. A read that finishes after a newer press is
    /// thrown away.
    private var generation = 0
    @Published private(set) var shortcutRegistrationFailed = false

    private init() {
        hotkey.onPress = { [weak self] in self?.summon() }
    }

    func syncWithPreferences() {
        let wanted = AppFeature.selectionBar.isAvailable
            && UserDefaults.standard.bool(forKey: DefaultsKey.selectionBarEnabled)
            && AXIsProcessTrusted()
        guard wanted else {
            suspend()
            return
        }
        start()
        let shortcut = GlobalShortcut.saved(for: DefaultsKey.selectionBarShortcut,
                                            fallback: .selectionBarDefault)
        shortcutRegistrationFailed = !hotkey.sync(
            enabled: UserDefaults.standard.bool(forKey: DefaultsKey.selectionBarShortcutEnabled),
            shortcut: shortcut,
            storageKey: DefaultsKey.selectionBarShortcut)
    }

    func suspend() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        hotkey.unregister()
        pressLocation = nil
        generation += 1
        panel.close()
    }

    private func start() {
        guard monitor == nil else { return }
        // Global only: the bar does not appear inside this app's own windows.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            self?.handle(event)
        }
    }

    private func handle(_ event: NSEvent) {
        // The place of the event, not of the pointer now: the monitor can run
        // after the pointer moved on. Quartz puts the origin at the top left
        // of the main display.
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let location = event.cgEvent.map { CGPoint(x: $0.location.x, y: mainHeight - $0.location.y) }
            ?? NSEvent.mouseLocation
        if event.type == .leftMouseDown {
            pressLocation = location
            generation += 1
            return
        }
        defer { pressLocation = nil }
        let clicksOpen = UserDefaults.standard.bool(forKey: DefaultsKey.selectionBarDoubleClickEnabled)
        guard SelectionBarSupport.isSelectionGesture(clickCount: event.clickCount,
                                                     down: pressLocation,
                                                     up: location,
                                                     includesClicks: clicksOpen) else { return }
        let trigger = Trigger.mouse(press: pressLocation, release: location,
                                    offersPaste: clicksOpen && event.clickCount >= 2)
        let expected = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.readDelay) { [weak self] in
            guard let self, expected == self.generation else { return }
            self.read(for: trigger, expected: expected)
        }
    }

    /// The shortcut: the bar for the selection, or the paste tools at the
    /// caret when nothing is selected.
    private func summon() {
        generation += 1
        panel.close()
        read(for: .shortcut, expected: generation)
    }

    private func read(for trigger: Trigger, expected: Int) {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != getpid(),
              !MouseAppExceptions.shared.excludes(.selectionBar, app: front) else { return }
        let processID = front.processIdentifier
        // Most drags select nothing. Without the paste tools, those drags
        // do not ask for the geometry.
        let detailsForCaret = trigger.offersPaste
        DispatchQueue.global(qos: .userInitiated).async {
            let selection = SelectedTextReader.read(processID: processID, details: true,
                                                    detailsForCaret: detailsForCaret)
            DispatchQueue.main.async {
                guard expected == self.generation, let selection else { return }
                self.present(selection, trigger: trigger)
            }
        }
    }

    private func present(_ selection: SelectedTextReader.Selection, trigger: Trigger) {
        let text = selection.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = SelectionBarSupport.content(text: text, isEditable: selection.isEditable,
                                                  offersPaste: trigger.offersPaste)
        guard content != .nothing else { return }

        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        // Accessibility uses the same top left origin as the window server.
        let bounds = selection.bounds.map {
            ScreenshotSupport.cocoaRect(fromWindowServer: $0, mainScreenHeight: mainHeight)
        }
        let element = selection.elementFrame.map {
            ScreenshotSupport.cocoaRect(fromWindowServer: $0, mainScreenHeight: mainHeight)
        }
        let usableBounds = SelectionBarSupport.isUsable(bounds) ? bounds : nil
        let pointer: CGPoint
        switch trigger {
        case .mouse(let press, let release, _):
            guard SelectionBarSupport.isCurrent(release: release, press: press,
                                                selection: usableBounds ?? element)
            else { return }
            pointer = release
        case .shortcut:
            // The keyboard has no pointer to follow: the bar goes to the
            // selection or the caret, else to the mouse.
            pointer = usableBounds.map { CGPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation
        }
        let actions = content == .selection
            ? selectionActions(for: text, exact: selection.text, isEditable: selection.isEditable,
                               typesOver: !selection.fromTextMarkers)
            : pasteActions()
        panel.show(enabled(actions),
                   selection: usableBounds,
                   pointer: pointer,
                   visible: visibleFrame(containing: pointer))
    }

    private func visibleFrame(containing point: CGPoint) -> CGRect {
        NSScreen.screens.first { $0.frame.contains(point) }?.visibleFrame ?? NSScreen.pointerVisibleFrame
    }

    private func enabled(_ actions: [SelectionBarAction]) -> [SelectionBarAction] {
        let enabled = SelectionBarSupport.enabledActionIDs(
            UserDefaults.standard.stringArray(forKey: DefaultsKey.selectionBarActions))
        return actions.filter { enabled.contains($0.id) }
    }

    private func action(_ id: String, run: @escaping () -> Void) -> SelectionBarAction {
        let tool = SelectionBarTools.tool(id, language: L10n.shared.language)
        return SelectionBarAction(id: id, title: tool.title, symbol: tool.symbol, glyph: tool.glyph, run: run)
    }

    /// `exact` is the selection as the app holds it. The case rows type over
    /// it and keep its spaces and line breaks. `typesOver` is false for a web
    /// page read through a text marker range, as in the command bar.
    private func selectionActions(for text: String, exact: String,
                                  isEditable: Bool, typesOver: Bool) -> [SelectionBarAction] {
        let copy = action("copy") { _ = TransientPaste.shared.forwardCopy() }
        let rows = CommandBarCatalog.selectionEntries(text,
                                                      exactly: exact,
                                                      typesOver: typesOver,
                                                      bar: FeatureStrings.commandBar(L10n.shared.language),
                                                      useInSearch: { _ in })
            .filter { SelectionBarSupport.offers($0.id, isEditable: isEditable) }
            .map { entry in
                // The command bar row copies the count. Here the count is the
                // answer, so the bar shows it and keeps the clipboard as it is.
                guard entry.id == "selection.count" else { return action(entry.id) { entry.run(nil) } }
                return action(entry.id) { QuickToolHUD.show(icon: "number", message: entry.subtitle) }
            }
        // In an editable field, a paste replaces the selection.
        return [copy] + rows + (isEditable ? pasteActions() : [])
    }

    private func pasteActions() -> [SelectionBarAction] {
        let runs: [(String, () -> Void)] = [
            ("paste", { _ = TransientPaste.shared.pasteCurrentContents() }),
            ("pastePlain", { PastePlainService.shared.performPastePlain() }),
            ("clipboardHistory", { ClipboardHistoryService.shared.showHistoryWindow() }),
        ]
        return runs.filter { SelectionBarTools.isOffered($0.0) }.map { action($0.0, run: $0.1) }
    }
}

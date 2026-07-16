import SwiftUI
import EventKit
import Combine
import AppKit

/// The Spotlight-style root: a clean focused search-style bar, plus — on hover —
/// a separate "bubbled-off" card below it listing the reminders.
struct SpotlightView: View {
    @EnvironmentObject var remindersData: RemindersData
    @ObservedObject private var userPreferences = UserPreferences.shared

    @State private var rmbReminder = RmbReminder()
    @State private var expanded = false   // window is grown
    @State private var showList = false   // list card is present
    @State private var collapseWork: DispatchWorkItem?
    @State private var expandWork: DispatchWorkItem?
    @State private var growStartedAt: Date?
    @State private var didCreate = false   // entry morphs into the checkmark
    @State private var createdColor: Color = .green   // checkmark tint = destination list/calendar
    @State private var dismissing = false  // whole panel bubbles off after
    @State private var listShown = true    // list card visible (opacity) vs faded out
    @State private var collapsing = false  // a typing-collapse is in flight
    @State private var eventMode = false   // create a calendar event instead of a reminder
    @State private var eventCalendars: [EKCalendar] = []
    @State private var chosenEventCalendar: EKCalendar?
    @State private var modeSwapFromAbove = false  // drives the mode-swap animation direction
    @State private var keyMonitor: Any?           // local ↑/↓ monitor for mode switching
    @State private var focusTrigger = UUID()   // bump to focus the entry field
    @State private var hintIndex = 0           // rotating placeholder example
    @State private var showNotes = false       // notes section reserves window space
    @State private var notesMounted = false    // notes editor is present
    @State private var notesWork: DispatchWorkItem?
    @State private var notesFocusTrigger = UUID()
    @State private var listScrolled = false    // fades the list's filter/cog once scrolled
    @State private var agendaMode = false       // day agenda (reminders + events), opened with →
    @State private var agendaEverShown = false   // once →'d, the agenda stays mounted so toggling never remounts a List

    private let notesHeight: CGFloat = 104
    // Dashboard push distances. The incoming panel travels farther than the
    // outgoing view (parallax). The incoming's far end coincides with opacity 0,
    // so it's invisible where it would clip the window edge.
    private let dashboardSlideIn: CGFloat = 60
    private let dashboardSlideOut: CGFloat = 26
    private let cardCornerRadius = SpotlightMetrics.cornerRadius
    private let fieldRowHeight = SpotlightMetrics.fieldRowHeight
    private let chipsRowHeight = SpotlightMetrics.chipsRowHeight
    private let listCardHeight = SpotlightMetrics.listCardHeight
    private let cardGap = SpotlightMetrics.cardGap
    /// Transparent margin around the cards — must match the window's, so the
    /// card sits exactly inside the larger window with room for shadow + pop.
    private let chromeInset = SpotlightMetrics.chromeInset

    /// Deterministic window height per state — no layout-driven resizing (that
    /// feedback loop crashed the app on expand). Includes the chrome margin on
    /// top and bottom so the card never reaches the window's clipping edge.
    private var windowHeight: CGFloat {
        if expanded {
            // While expanded the chips row is hidden (see barCard), so the bar is
            // just the field row. Keeping this constant means nothing resizes the
            // window while the list is mounted.
            return fieldRowHeight + cardGap + listCardHeight + chromeInset * 2
        }
        let bar = fieldRowHeight + (rmbReminder.title.isEmpty ? 0 : chipsRowHeight)
        if showNotes {
            return bar + cardGap + notesHeight + chromeInset * 2
        }
        return bar + chromeInset * 2
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Compose / Reminders / Events — the bar plus its browse list.
            VStack(spacing: cardGap) {
                barCard

                if showList {
                    listCard
                        // listShown drives a compositor-only fade for the typing-
                        // collapse (the list stays MOUNTED while it fades, so nothing
                        // reflows). The transition handles the reveal-in.
                        .opacity(listShown ? 1 : 0)
                        .transition(.offset(y: -8).combined(with: .opacity))
                } else if notesMounted {
                    notesCard
                        .transition(.offset(y: -8).combined(with: .opacity))
                }
            }
            .opacity(agendaMode ? 0 : 1)
            // Parallax: the outgoing view slides a shorter distance than the
            // incoming panel, so the transition reads as a layered push (→ pushes
            // Reminders left; ← brings it back from the left).
            .offset(x: agendaMode ? -dashboardSlideOut : 0)
            .allowsHitTesting(!agendaMode)

            // Dashboard — one panel, mounted ALONGSIDE the reminders view (not
            // instead of it) and cross-faded/slid, so → / ← never remount a List or
            // resize the window. Same total height, so it overlays exactly.
            if agendaEverShown && showList {
                dashboardPanel
                    .opacity(agendaMode ? 1 : 0)
                    // → slides it in from the right; ← slides it back out to the right.
                    .offset(x: agendaMode ? 0 : dashboardSlideIn)
                    .allowsHitTesting(agendaMode)
                    .transition(.opacity)   // first reveal (opening from the bar) just fades in
            }
        }
        .opacity(dismissing ? 0 : 1)   // bubble-off fade after a reminder is saved
        // Inset the cards inside the larger window: leaves the chrome margin for
        // the shadow and the pop-in overshoot. Bottom margin comes from the
        // window being chromeInset taller than the content (top-aligned).
        .padding(.horizontal, chromeInset)
        .padding(.top, chromeInset)
        // Fill the window and pin to the top, so the space below the card is always
        // the full chrome inset — room for the drop shadow. (Without maxHeight the
        // shorter content gets centered and the shadow is clipped at the bottom.)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(userPreferences.rmbColorScheme.colorScheme)
        .contentShape(Rectangle())
        .onAppear {
            rmbReminder.calendar = remindersData.calendarForSaving
            // Rebuild the parser shortcut maps from the current calendars +
            // preferences every time the bar opens, so "@" list shortcuts and "#"
            // tag shortcuts are always recognized — even ones pointing at the list
            // that's already selected, and regardless of when the data model last
            // refreshed.
            CalendarParser.updateShared(with: RemindersService.shared.getCalendars())
            TagParser.updateShortcuts()
            EventCalendarParser.updateShared(with: RemindersService.shared.getAllEventCalendars())
            if userPreferences.autoSuggestToday {
                rmbReminder.setIsAutoSuggestingTodayForCreation()
            }
            DispatchQueue.main.async { focusTrigger = UUID() }
            syncHeight()
            installModeKeyMonitor()
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
        // Moving the mouse (anywhere) means you want to browse → show the list.
        .onReceive(NotificationCenter.default.publisher(for: .mainWindowDidDetectMouseMove)) { _ in
            // Composing notes suppresses the ambient browse-on-mouse-move (option a).
            if !expanded && !showNotes { expand() }
        }
        // Quietly rotate the placeholder examples while the field sits empty.
        .onReceive(Timer.publish(every: 2.5, on: .main, in: .common).autoconnect()) { _ in
            advanceHint()
        }
        // Typing means you're committing to writing → reverse the list back out.
        .onChange(of: rmbReminder.title) { _ in
            if expanded && !didCreate { collapse() }
        }
        .onChange(of: expanded) { _ in syncHeight() }
        // Resize for the chips row ONLY when collapsed (no list present). While
        // expanded, typing triggers collapse(), which resizes safely once the
        // list is gone — resizing here would do it WITH the list still mounted
        // (the "Update Constraints in Window" crash).
        .onChange(of: rmbReminder.title.isEmpty) { _ in
            if !expanded { syncHeight() }
        }
        .onChange(of: showNotes) { _ in syncHeight() }
        .onExitCommand {
            // Esc always closes the whole UI (the key monitor handles it while the
            // field is focused; this covers the rest).
            AppDelegate.shared.closeMainWindow()
        }
    }

    // MARK: - Field row

    /// The leading glyph + entry field, factored out of the bar card.
    private var fieldRow: some View {
        HStack(spacing: 14) {
            modeIcon

            ZStack(alignment: .leading) {
                // Custom placeholder so it can animate. It quietly rotates
                // through example phrasings to teach the syntax (passive
                // discoverability), and cross-fades on mode/example change.
                if rmbReminder.title.isEmpty {
                    Text(currentPlaceholder)
                        .font(.system(size: 24, weight: .regular))
                        .foregroundStyle(Color.primary.opacity(0.7))   // Spotlight's placeholder gray
                        .lineLimit(1)
                        .id(placeholderID)
                        .transition(placeholderTransition)
                        .allowsHitTesting(false)
                }

                // AppKit-backed field so parsed tokens can be colored inline.
                // Placeholder stays empty here — the animated SwiftUI overlay
                // above handles it.
                RmbHighlightedTextField(
                    placeholder: "",
                    text: $rmbReminder.title,
                    highlightedTexts: fieldHighlights,
                    maximumNumberOfLines: 1,
                    focusTrigger: $focusTrigger
                )
                .nsFont(.systemFont(ofSize: 24, weight: .regular))
                .caretColor(destinationCaretColor)   // caret follows the destination
                .singleLine()
                .onSubmit(create)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // No trailing control — Spotlight has none. Mouse-move and ⌘↓
            // open the list; Esc / ⌘↓ / typing collapse it.
        }
        .padding(.horizontal, 20)
        .frame(height: fieldRowHeight)
    }

    // MARK: - Bar card

    private var barCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            fieldRow

            // Chips show only in the collapsed (Typing) UI. Gating on !expanded
            // means the bar never reflows (chips appearing) while the list is
            // mounted — that reflow is one of the things that crashes the panel.
            if !rmbReminder.title.isEmpty && !expanded {
                HStack(spacing: 6) {
                    if rmbReminder.hasDueDate {
                        chip("calendar", rmbReminder.date.relativeDateDescription(withTime: rmbReminder.hasTime), .accentColor)
                            .transition(chipTransition)
                    }
                    if eventMode {
                        // Priority, tags and reminder-lists don't apply to events.
                        eventCalendarChip
                            .transition(chipTransition)
                    } else {
                        listPickerChip
                            .transition(chipTransition)
                        if rmbReminder.priority != .none {
                            chip(rmbReminder.priority.rmbSymbol?.name ?? "exclamationmark",
                                 rmbReminder.priority.title,
                                 priorityChipColor(rmbReminder.priority))
                                .transition(chipTransition)
                        }
                        ForEach(rmbReminder.textTagResults.indices, id: \.self) { index in
                            chip(RmbSymbol.hashtag.name, rmbReminder.textTagResults[index].tag.name, .rmbColor(.tagHighlight))
                                .transition(chipTransition)
                        }
                    }
                    // Recurrence applies to both reminders and events.
                    if let recurrence = recurrenceMatch {
                        chip("repeat", recurrence.label, .orange)
                            .transition(chipTransition)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .frame(height: chipsRowHeight, alignment: .top)
                // Spring chips in/out as tokens are parsed. Keyed on the chip *set*
                // so it fires only when a chip appears/disappears, not on every
                // keystroke that merely changes a chip's text.
                .animation(.spring(response: 0.32, dampingFraction: 0.8), value: chipSignature)
            }
        }
        // On save the entry collapses toward the center (where the checkmark
        // blooms from), so the reminder reads as morphing into the checkmark.
        .scaleEffect(didCreate ? 0.35 : 1, anchor: .center)
        .opacity(didCreate ? 0 : 1)
        .background(cardSurface)
        .overlay {
            if didCreate {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 36, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, createdColor)
                    // Blooms in from a point; then on dismiss keeps growing as the
                    // whole panel fades — the "bubble off".
                    .scaleEffect(dismissing ? 1.3 : 1.0)
                    .transition(.scale(scale: 0.45).combined(with: .opacity))
            }
        }
    }

    // MARK: - List card

    private var listCard: some View {
        Group {
            if eventMode {
                UpcomingEventsView()
                    .transition(modeSwapTransition)
            } else {
                ContentView(scrolledDown: $listScrolled)
                    .overlay(alignment: .topTrailing) {
                        HStack(spacing: 2) {
                            FilterReminderListButton()
                            OpenSettingButton()
                        }
                        // Trailing inset clears the list's scroll bar; top inset keeps
                        // the icons in line with the first section heading.
                        .padding(.trailing, 20)
                        .padding(.top, 16)
                        // Fade out once the list is scrolled, so they don't sit over
                        // the entries scrolling underneath.
                        .opacity(listScrolled ? 0 : 1)
                        .animation(.easeInOut(duration: 0.18), value: listScrolled)
                    }
                    .transition(modeSwapTransition)
            }
        }
        .frame(height: listCardHeight)
        // Clip the scrolling content (and its scroll bar) to the rounded card so
        // nothing pokes past the corners. The shadow lives on cardSurface behind
        // this, so it stays unclipped.
        .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
        .background(cardSurface)
    }

    // MARK: - Dashboard panel (→)

    /// One unified panel for the day agenda: a "View Upcoming Events" header over
    /// the agenda list, in a single surface. It's kept MOUNTED alongside the
    /// Reminders view (see `body`) and cross-faded, so toggling never remounts a
    /// List or resizes the window.
    private var dashboardPanel: some View {
        TagPlannerView()
            .frame(height: fieldRowHeight + cardGap + listCardHeight)
            .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
            .background(cardSurface)
    }

    // MARK: - Notes card

    private var notesBinding: Binding<String> {
        Binding(
            get: { rmbReminder.notes ?? "" },
            set: { rmbReminder.notes = $0.isEmpty ? nil : $0 }
        )
    }

    private var notesCard: some View {
        RmbHighlightedTextField(
            placeholder: String("Notes"),
            text: notesBinding,
            maximumNumberOfLines: 4,
            allowNewLineAndTab: true,
            focusTrigger: $notesFocusTrigger
        )
        .nsFont(.systemFont(ofSize: 14))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(height: notesHeight)
        .background(cardSurface)
    }

    /// Frosted, rounded, hairline-bordered surface — Spotlight's panel look.
    /// The drop shadow sits on the blur itself. (We deliberately do NOT cast it
    /// from an opaque shape behind the blur: while the panel fades in, the blur
    /// is semi-transparent, so a fill behind it bleeds through and the card reads
    /// as dark until the fade completes.)
    private var cardSurface: some View {
        let shape = RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
        return VisualEffectBlur()
            .clipShape(shape)
            // One fine hairline defines the edge…
            .overlay(shape.strokeBorder(Color.primary.opacity(0.3), lineWidth: 0.75))
            // …and behind it a single soft, diffuse shadow — no tight dark band
            // hugging the edge. Diffuse enough to feel like Spotlight's, but small
            // enough to fade fully inside the chrome margin so it never clips.
            .shadow(color: .black.opacity(0.14), radius: 16, x: 0, y: 3)
    }

    /// The leading glyph is the mode switcher: a Reminders-style checkbox
    /// (default) or a calendar for a new event. Click to switch (mouse), or use
    /// the ↑/↓ arrows (keyboard) — see the key monitor in onAppear. The icon swaps
    /// with a small vertical slide + fade in the arrow's direction.
    ///
    /// Both symbols are rounded squares of matching footprint, so neither leans
    /// left/right relative to the other when swapping (a wide symbol like
    /// `checklist` extends further left and reads as a sideways shift).
    private var modeIcon: some View {
        Button {
            // Clicking flips to the other mode; animate as if it came from the
            // direction it's moving toward (event below, reminder above).
            switchMode(toEvent: !eventMode, fromAbove: eventMode)
        } label: {
            ZStack {
                Image(systemName: eventMode ? "calendar" : "checkmark.square")
                    .font(.system(size: 23, weight: .regular))   // matches Spotlight's leading-glyph weight/size
                    .foregroundStyle(Color.primary.opacity(0.7))
                    .frame(width: 26, height: 26, alignment: .center)
                    .id(eventMode)
                    .transition(modeSwapTransition)
            }
            .frame(width: 26, height: 28)
            .clipped()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(eventMode ? String("New calendar event — ↑/↓ or click to switch")
                        : String("New reminder — ↑/↓ or click to switch"))
    }

    /// Vertical slide + fade used when swapping between Reminder and Event. The
    /// direction follows `modeSwapFromAbove` so it tracks the ↑/↓ key pressed.
    private var modeSwapTransition: AnyTransition {
        let offset: CGFloat = 7
        return .asymmetric(
            insertion: .offset(y: modeSwapFromAbove ? -offset : offset).combined(with: .opacity),
            removal: .offset(y: modeSwapFromAbove ? offset : -offset).combined(with: .opacity)
        )
    }

    // MARK: - Rotating placeholder

    /// Example phrasings the empty placeholder cycles through — index 0 is the
    /// plain prompt, the rest demonstrate one capability each.
    private var placeholderExamples: [String] {
        eventMode
            ? ["Create Event", "Create Event tomorrow 12–1pm", "Create Event every weekday", "Create Event @work"]
            : ["Create Reminder", "Create Reminder tomorrow at 4", "Create Reminder every month", "Create Reminder !!", "Create Reminder @personal"]
    }

    private var currentPlaceholder: String {
        let examples = placeholderExamples
        return examples[hintIndex % examples.count]
    }

    private var placeholderID: String { "\(eventMode)-\(hintIndex)" }

    /// Gentle vertical "ticker" — the new line rises in as the old rises out.
    private var placeholderTransition: AnyTransition {
        .asymmetric(
            insertion: .offset(y: 9).combined(with: .opacity),
            removal: .offset(y: -9).combined(with: .opacity)
        )
    }

    private func advanceHint() {
        guard rmbReminder.title.isEmpty, !expanded else { return }
        withAnimation(.easeInOut(duration: 0.45)) {
            hintIndex += 1
        }
    }

    private func handleArrowKey(up: Bool) {
        // Either arrow toggles between the two modes; the arrow only sets the
        // animation direction.
        switchMode(toEvent: !eventMode, fromAbove: up)
    }

    private func performUndo() {
        UndoCoordinator.shared.performUndo()
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    private func switchMode(toEvent: Bool, fromAbove: Bool) {
        guard toEvent != eventMode else { return }
        modeSwapFromAbove = fromAbove
        let apply = {
            hintIndex = 0   // show the new mode's base prompt first
            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                eventMode = toEvent
            }
            if toEvent {
                ensureCalendarAccess()
            }
        }
        // Swap in place. The window height is identical in both modes, so switching
        // never resizes the window — even while the list is expanded — so the old
        // resize-crash risk doesn't apply. Keep the browse list open and let its
        // contents cross-fade to the new mode.
        apply()
    }

    /// Watches for ↑/↓ while the Spotlight panel is focused and uses them to swap
    /// between Reminder and Event mode. Scoped to the FloatingPanel so it never
    /// eats arrow keys in Settings or other windows.
    private func installModeKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window is FloatingPanel else { return event }
            // While a reminder title is being edited inline in the list, let its
            // field handle every key (Return commits, arrows move the caret) instead
            // of the panel's browse shortcuts.
            if InlineTitleEditState.shared.isEditing { return event }
            // Esc → close the whole UI (one press), even when the text view would
            // otherwise swallow it.
            if event.keyCode == 53 {
                AppDelegate.shared.closeMainWindow()
                return nil
            }
            // ⌘Z → undo the last save/completion. Only when not mid-typing (empty
            // field or browsing), so it doesn't clobber the field's own text-undo.
            if event.modifierFlags.contains(.command), event.keyCode == 6 {
                if (rmbReminder.title.isEmpty || expanded), UndoCoordinator.shared.canUndo {
                    performUndo()
                    return nil
                }
                return event
            }
            // ⌘↩ → save and keep the bar open for the next entry (multi-add).
            if event.modifierFlags.contains(.command),
               event.keyCode == 36 || event.keyCode == 76 {
                createAndContinue()
                return nil
            }
            // ⌘↓ → toggle the browse list (keyboard equivalent of mouse-move).
            if event.modifierFlags.contains(.command), event.keyCode == 125 {
                toggleList()
                return nil
            }
            // ⇥ Tab → toggle the notes section (compose detail).
            if event.keyCode == 48 {
                toggleNotes()
                return nil
            }
            // → open the day agenda (only from an empty field, where → wouldn't be
            //   moving a caret); ← backs out of it.
            if event.keyCode == 124 {   // right arrow
                if rmbReminder.title.isEmpty && !agendaMode {
                    openAgenda()
                    return nil
                }
                return event
            }
            if event.keyCode == 123 {   // left arrow
                if agendaMode {
                    closeAgenda()
                    return nil
                }
                return event
            }
            if expanded {
                // The agenda has no reminder⇄event switching — leave ↑/↓ alone.
                if agendaMode { return event }
                // Browsing (nudged open): ↑/↓ switch Reminders ⇄ Calendar in place.
                // The expanded list is mouse-driven now, so arrows/Return are no
                // longer captured for list navigation.
                if event.keyCode == 125 || event.keyCode == 126 {
                    handleArrowKey(up: event.keyCode == 126)
                    return nil
                }
                return event
            } else if showNotes {
                // Composing notes: let the notes editor handle ↑/↓/↩ (multi-line).
                return event
            } else {
                // Typing: ↑/↓ switch reminder ⇄ event mode (↩ falls through to save).
                if event.keyCode == 125 || event.keyCode == 126 {
                    handleArrowKey(up: event.keyCode == 126)
                    return nil
                }
            }
            return event
        }
    }

    private func ensureCalendarAccess() {
        if RemindersService.shared.isCalendarAuthorized {
            loadEventCalendars()
        } else {
            RemindersService.shared.requestCalendarAccess { granted, _ in
                DispatchQueue.main.async {
                    if granted {
                        loadEventCalendars()
                    } else {
                        // No Calendar access — fall back to reminder mode.
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                            eventMode = false
                        }
                    }
                }
            }
        }
    }

    private var listPickerChip: some View {
        let calendar = parsedOrChosenCalendar
        let tint = calendar.map { Color($0.color) } ?? .secondary
        return Menu {
            ForEach(remindersData.availableCalendars, id: \.calendarIdentifier) { calendar in
                Button(calendar.title) {
                    rmbReminder.calendar = calendar
                    rmbReminder.textCalendarResult = CalendarParser.TextCalendarResult()
                }
            }
        } label: {
            chipLabel("line.3.horizontal", calendar?.title ?? "List", tint)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .modifier(ColoredChipBackground(tint: tint))
    }

    private var eventCalendarChip: some View {
        let calendar = effectiveEventCalendar
        let tint = calendar.map { Color($0.color) } ?? .secondary
        return Menu {
            ForEach(eventCalendars, id: \.calendarIdentifier) { calendar in
                Button(calendar.title) { chosenEventCalendar = calendar }
            }
        } label: {
            chipLabel("calendar", calendar?.title ?? "Calendar", tint)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .modifier(ColoredChipBackground(tint: tint))
    }

    private func loadEventCalendars() {
        eventCalendars = RemindersService.shared.getEventCalendars()
        let stillValid = eventCalendars.contains { $0.calendarIdentifier == chosenEventCalendar?.calendarIdentifier }
        if !stillValid {
            chosenEventCalendar = RemindersService.shared.getDefaultEventCalendar()
        }
    }

    /// A `@key` calendar shortcut parsed from the title (event mode only).
    private var eventShortcutMatch: EventCalendarParser.Match? {
        guard eventMode else { return nil }
        return EventCalendarParser.match(in: rmbReminder.title)
    }

    /// Calendar a new event lands in: a typed `@` shortcut wins, then the
    /// manually-chosen calendar, then the system default.
    private var effectiveEventCalendar: EKCalendar? {
        eventShortcutMatch?.calendar ?? chosenEventCalendar ?? RemindersService.shared.getDefaultEventCalendar()
    }

    /// An "every …" recurrence parsed from the title — applies to both reminders
    /// and events.
    private var recurrenceMatch: RecurrenceParser.Match? {
        RecurrenceParser.match(in: rmbReminder.title)
    }

    /// The destination list/calendar's color (as NSColor) — tints the caret so the
    /// bar subtly reflects where the entry is headed.
    private var destinationCaretColor: NSColor {
        let calendar = eventMode ? effectiveEventCalendar : parsedOrChosenCalendar
        return calendar?.color ?? .controlAccentColor
    }

    /// Token highlights colored inline in the field. In event mode the relevant
    /// tokens are the date, the "@" calendar shortcut (in that calendar's color),
    /// and the "every …" recurrence; reminder mode uses the model's own set
    /// (date / list / priority / tags).
    private var fieldHighlights: [RmbHighlightedTextField.HighlightedText] {
        var highlights: [RmbHighlightedTextField.HighlightedText]
        if eventMode {
            highlights = rmbReminder.textDateResult.highlightedTexts
            if let shortcut = eventShortcutMatch {
                let color = shortcut.calendar.color ?? .secondaryLabelColor
                highlights.append(.init(range: shortcut.range, color: color))
            }
        } else {
            highlights = rmbReminder.highlightedTexts
        }
        // Recurrence applies in both modes.
        if let recurrence = recurrenceMatch {
            for range in recurrence.ranges {
                highlights.append(.init(range: range, color: .systemOrange))
            }
        }
        return highlights
    }

    /// Pop chips in/out from a slightly shrunk, faded state.
    private var chipTransition: AnyTransition {
        .scale(scale: 0.55).combined(with: .opacity)
    }

    /// Changes only when the *set* of chips changes (a chip added/removed or a
    /// priority level change), so the spring fires then rather than on every
    /// keystroke. See the chips row's `.animation(value:)`.
    private var chipSignature: String {
        "\(eventMode)|\(rmbReminder.hasDueDate)|\(rmbReminder.priority.rawValue)|\(rmbReminder.textTagResults.count)|\(recurrenceMatch != nil)"
    }

    private func chip(_ icon: String, _ text: String, _ tint: Color) -> some View {
        chipLabel(icon, text, tint)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.opacity(0.14)))
    }

    /// The chip's icon + text only (no background). Used directly as a Menu label
    /// so the colored squircle can be applied to the Menu itself — the borderless
    /// menu style otherwise swallows a background set on its label.
    private func chipLabel(_ icon: String, _ text: String, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text).lineLimit(1)
        }
        .font(.system(size: 12))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func priorityChipColor(_ priority: EKReminderPriority) -> Color {
        switch priority {
        case .high:
            return .red
        case .medium:
            return .orange
        case .low:
            return Color(.systemYellow)
        default:
            return .secondary
        }
    }

    // MARK: - Expand / collapse

    private func syncHeight() {
        DispatchQueue.main.async { AppDelegate.shared.setMainHeight(windowHeight) }
    }

    // Grow the (list-free) window first, THEN reveal the list — the window must
    // never resize while a List is inside it (that triggers the Update
    // Constraints loop crash). Tuned to feel as quick as the main bubble's pop-in.
    private func expand() {
        guard !expanded else { return }
        collapseWork?.cancel()
        collapsing = false
        listScrolled = false   // a freshly opened list starts at the top
        listShown = true
        growStartedAt = Date()
        withAnimation(.easeOut(duration: 0.11)) { expanded = true }
        scheduleListReveal()
    }

    // MARK: - Day agenda (→)

    /// The Reminders ⇄ Dashboard push. A snappy, well-damped spring: quick, almost
    /// no overshoot (so the horizontal slide doesn't bounce), and interruptible —
    /// reversing mid-slide re-targets smoothly, which is what makes fast toggling
    /// feel native.
    private var dashboardPush: Animation { .spring(response: 0.34, dampingFraction: 0.86) }

    /// → opens the day's agenda (today's reminders + calendar events). Grows the
    /// window first if it's collapsed; if the browse list is already up the content
    /// swaps in place (window height is identical, so nothing resizes).
    private func openAgenda() {
        guard !agendaMode else { return }
        agendaEverShown = true   // mount the agenda for the rest of the session
        // Leave whatever mode you were in (Reminders or Calendar) UNTOUCHED
        // underneath the dashboard — don't flip it. That keeps the bar text from
        // flickering to "Create Reminder", and makes ← return you to the same view
        // (Reminders or Calendar) you opened the dashboard from.
        withAnimation(dashboardPush) {
            agendaMode = true
        }
        if !expanded { expand() }
    }

    /// ← returns to the Reminders list. It's a pure in-place push (both lists stay
    /// mounted, the window doesn't resize), so Reminders ⇄ Dashboard can be toggled
    /// as fast as you like. Esc / ⌘↓ close the panel entirely.
    private func closeAgenda() {
        guard agendaMode else { return }
        withAnimation(dashboardPush) { agendaMode = false }
    }

    // MARK: - Notes (compose detail) — mutually exclusive with the browse list.

    /// Tab. Browse → compose: collapse the list first, then open notes.
    private func toggleNotes() {
        if showNotes {
            closeNotes()
        } else if expanded {
            collapse(then: { openNotes() })
        } else {
            openNotes()
        }
    }

    /// ⌘↓. Compose → browse: close notes first; otherwise toggle the list.
    private func toggleList() {
        if expanded {
            collapse()
        } else if showNotes {
            closeNotes()
        } else {
            expand()
        }
    }

    private func openNotes() {
        showNotes = true   // reserve space (window grows first, via onChange → syncHeight)
        notesWork?.cancel()
        // Mount the editor only AFTER the window has grown — mounting an AppKit
        // text view mid-resize is exactly what crashed the old cheat sheet.
        let work = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.14)) { notesMounted = true }
            notesFocusTrigger = UUID()
        }
        notesWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
    }

    private func closeNotes() {
        notesWork?.cancel()
        // Unmount the editor BEFORE the window shrinks (syncHeight is async, so it
        // lands after this render commits the unmount).
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { notesMounted = false }
        showNotes = false
        focusTrigger = UUID()   // focus back to the title
    }

    /// Mounts the list once the window has finished growing. Safe to call
    /// repeatedly — it always waits out whatever remains of the grow, so the
    /// List is never present while the window resizes, and overlapping hover
    /// events can't cancel the reveal and strand a grown-but-empty panel.
    private func scheduleListReveal() {
        guard expanded, !showList else { return }
        expandWork?.cancel()
        let growDuration = 0.13
        let elapsed = growStartedAt.map { Date().timeIntervalSince($0) } ?? growDuration
        let remaining = max(0, growDuration - elapsed)
        let work = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.12)) { showList = true }
        }
        expandWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
    }

    private func collapse(then completion: (() -> Void)? = nil) {
        expandWork?.cancel()
        guard expanded, !collapsing else { return }   // ignore re-fires (rapid typing)
        collapsing = true

        // Phase 2: list is now invisible → unmount it and shrink the window. The
        // unmount is forced non-animated (disablesAnimations) so the listCard's
        // reveal .transition can't replay on removal and keep it mounted during
        // the resize. The window resize is deferred (syncHeight uses async), so it
        // lands after SwiftUI has committed the unmount → never resizes with a
        // List mounted. Chips reappear here (now collapsed), with no List present.
        let finish = {
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) {
                showList = false
                listShown = true
                agendaMode = false   // leaving the browse list also leaves the agenda
            }
            withAnimation(.easeOut(duration: 0.18)) { expanded = false }
            collapsing = false
            // The list is fully unmounted here — safe for callers to swap the
            // card's contents (e.g. switch reminder ⇄ event mode).
            completion?()
        }

        // Phase 1: fade the list out IN PLACE — compositor-only (opacity), list
        // stays MOUNTED, nothing reflows or resizes while it's up.
        if #available(macOS 14.0, *) {
            withAnimation(.easeOut(duration: 0.14)) { listShown = false } completion: { finish() }
        } else {
            withAnimation(.easeOut(duration: 0.14)) { listShown = false }
            let work = DispatchWorkItem { finish() }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.17, execute: work)
        }
    }

    // MARK: - Derived state

    private var parsedOrChosenCalendar: EKCalendar? {
        rmbReminder.textCalendarResult.calendar ?? rmbReminder.calendar ?? remindersData.calendarForSaving
    }

    // MARK: - Create (mirrors ReminderEditView's save)

    private func create() {
        guard canSaveCurrentEntry else { return }

        // The success checkmark blooms in the destination's color — capture it now,
        // before the save path can reset the entry.
        createdColor = Color(nsColor: destinationCaretColor)

        // Begin the morph FIRST: rewriting rmbReminder.title in the save path would
        // otherwise trip the typing→collapse handler, and didCreate guards it.
        withAnimation(.spring(response: 0.36, dampingFraction: 0.74)) { didCreate = true }

        saveCurrentEntry()

        // Linger on the checkmark a beat, then the panel bubbles off.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.52) {
            withAnimation(.easeInOut(duration: 0.24)) { dismissing = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.74) {
            AppDelegate.shared.closeMainWindow()
        }
    }

    /// ⌘↩ — save the current entry and keep the bar open, cleared, for the next
    /// one (multi-add).
    private func createAndContinue() {
        guard canSaveCurrentEntry else { return }
        saveCurrentEntry()
        resetForNextEntry()
    }

    private var canSaveCurrentEntry: Bool {
        guard !finalTitle().isEmpty else { return false }
        if eventMode {
            return RemindersService.shared.isCalendarAuthorized && effectiveEventCalendar != nil
        }
        return parsedOrChosenCalendar != nil
    }

    /// Writes the current entry to Reminders or Calendar (no animation / dismiss).
    private func saveCurrentEntry() {
        let title = finalTitle()
        if eventMode {
            guard let calendar = effectiveEventCalendar else { return }
            // Best-effort duration from a parsed range ("12–1pm"); recurrence from
            // "every …". Priority/tags are parsed too but don't apply to events.
            let duration = DateParser.shared.getDate(from: rmbReminder.title)?.duration ?? 0
            let created = RemindersService.shared.createNewEvent(
                title: title,
                date: rmbReminder.date,
                hasTime: rmbReminder.hasTime,
                duration: duration,
                recurrence: recurrenceMatch?.rule,
                notes: rmbReminder.notes,
                in: calendar
            )
            if let created {
                UndoCoordinator.shared.register {
                    RemindersService.shared.remove(event: created)
                }
            }
        } else {
            guard let calendar = parsedOrChosenCalendar else { return }
            // A repeating reminder needs a due date to anchor the recurrence.
            if recurrenceMatch != nil && !rmbReminder.hasDueDate {
                rmbReminder.hasDueDate = true
            }
            rmbReminder.prepareToSave()
            rmbReminder.title = title
            rmbReminder.calendar = calendar
            let created = RemindersService.shared.createNew(with: rmbReminder, in: calendar, recurrence: recurrenceMatch?.rule)
            remindersData.calendarForSaving = calendar
            UndoCoordinator.shared.register {
                RemindersService.shared.remove(reminder: created)
                NotificationCenter.default.post(name: .remindersDataShouldUpdate, object: nil)
            }
        }
        SoundService.shared.playSuccessFeedback()
    }

    private func resetForNextEntry() {
        notesWork?.cancel()
        notesMounted = false
        showNotes = false
        rmbReminder = RmbReminder()
        rmbReminder.calendar = remindersData.calendarForSaving
        if userPreferences.autoSuggestToday {
            rmbReminder.setIsAutoSuggestingTodayForCreation()
        }
        DispatchQueue.main.async { focusTrigger = UUID() }
    }

    private func finalTitle() -> String {
        var title = rmbReminder.title
        if let priorityRange = Range(rmbReminder.textPriorityResult.highlightedText.range, in: title) {
            title.replaceSubrange(priorityRange, with: "")
        }
        if userPreferences.removeParsedDateFromTitle {
            for dateString in rmbReminder.textDateResult.strings {
                title = title.replacingOccurrences(of: dateString, with: "")
            }
        }
        title = title.replacingOccurrences(of: rmbReminder.textCalendarResult.string, with: "")
        for tagResult in rmbReminder.textTagResults.sorted(by: { $0.string.count > $1.string.count }) {
            title = title.replacingOccurrences(of: tagResult.string, with: "")
        }
        // In event mode, also strip the parsed "@" calendar-shortcut token and any
        // "every …" recurrence phrase (neither is a reminder-list token, so the
        // line above won't have removed them).
        if let eventToken = eventShortcutMatch?.string {
            title = title.replacingOccurrences(of: eventToken, with: "")
        }
        if let recurrence = recurrenceMatch {
            for token in recurrence.strings {
                title = title.replacingOccurrences(of: token, with: "")
            }
        }
        return title.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Upcoming events list (Calendar mode)

/// The expanded card in Calendar mode: upcoming events grouped by day, each
/// color-coded by its calendar.
private struct UpcomingEventsView: View {
    @ObservedObject private var userPreferences = UserPreferences.shared
    @State private var allEvents: [EKEvent] = []
    @State private var eventCalendars: [EKCalendar] = []
    @State private var selectedIndex = -1   // keyboard selection; -1 = none (no event pre-highlighted on open)

    /// Events minus any calendars the user has hidden via the filter.
    private var events: [EKEvent] {
        let hidden = Set(userPreferences.hiddenEventCalendarIdentifiers)
        guard !hidden.isEmpty else { return allEvents }
        return allEvents.filter { event in
            guard let id = event.calendar?.calendarIdentifier else { return true }
            return !hidden.contains(id)
        }
    }

    private var selectedEvent: EKEvent? {
        events.indices.contains(selectedIndex) ? events[selectedIndex] : nil
    }

    private var groupedByDay: [(day: Date, events: [EKEvent])] {
        let byDay = Dictionary(grouping: events) { Calendar.current.startOfDay(for: $0.startDate) }
        return byDay.keys.sorted().map { (day: $0, events: byDay[$0] ?? []) }
    }

    var body: some View {
        content
            // Float the filter + cog in line with the first day heading (matching
            // the Reminders view), inset from the right so the scroll bar doesn't
            // overlap them.
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 2) {
                    EventCalendarFilterButton(calendars: eventCalendars)
                        .disabled(eventCalendars.isEmpty)
                    OpenSettingButton()
                }
                .padding(.trailing, 20)
                .padding(.top, 16)   // align with the first day heading, like the Reminders view
            }
            .onAppear {
                allEvents = RemindersService.shared.getUpcomingEvents()
                eventCalendars = RemindersService.shared.getAllEventCalendars()
                selectedIndex = -1
            }
            .onReceive(NotificationCenter.default.publisher(for: .panelNavigateUp)) { _ in
                moveSelection(-1)
            }
            .onReceive(NotificationCenter.default.publisher(for: .panelNavigateDown)) { _ in
                moveSelection(1)
            }
            .onReceive(NotificationCenter.default.publisher(for: .panelActivateSelection)) { _ in
                if let event = selectedEvent { openInCalendar(event) }
            }
    }

    private func moveSelection(_ delta: Int) {
        guard !events.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), events.count - 1)
    }

    @ViewBuilder private var content: some View {
        if events.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(.tertiary)
                Text(String("No upcoming events"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Same List + CalendarTitle section headers as the Reminders view, so
            // the date headings match and the floating toolbar clears the rows the
            // same way it does there.
            ScrollViewReader { proxy in
                List {
                    ForEach(groupedByDay, id: \.day) { group in
                        Section(
                            header: CalendarTitle(title: dayLabel(group.day), color: .rmbColor(.upcomingSectionTitle))
                        ) {
                            ForEach(group.events, id: \.self) { event in
                                eventRow(event, isSelected: event === selectedEvent)
                                    .id(event)
                            }
                        }
                        .modifier(ListSectionModifier())
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .padding(.top, 12)      // match the Reminders list: first heading + scroll bar start
                .padding(.bottom, 10)
                .onChange(of: selectedIndex) { _ in
                    if let event = selectedEvent {
                        withAnimation { proxy.scrollTo(event, anchor: .center) }
                    }
                }
            }
        }
    }

    private func eventRow(_ event: EKEvent, isSelected: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color(for: event))
                .frame(width: 3)
                .frame(maxHeight: .infinity)   // stretch to the row's full height
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(event.title ?? String("(No Title)"))
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(timeLabel(event))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let location = trimmed(event.location) {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let calendarTitle = event.calendar?.title {
                    Text(calendarTitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let notes = trimmed(event.notes) {
                    Text(notes)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(isSelected ? 0.16 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { openInCalendar(event) }
        .help(String("Double-click to open in Calendar"))
    }

    /// Trimmed non-empty string, or nil.
    private func trimmed(_ string: String?) -> String? {
        guard let value = string?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    /// Opens the system Calendar app focused on this event, then dismisses the bar.
    private func openInCalendar(_ event: EKEvent) {
        if let url = URL(string: "ical://ekevent/\(event.calendarItemIdentifier)?method=show&options=more") {
            NSWorkspace.shared.open(url)
        }
        AppDelegate.shared.closeMainWindow()
    }

    private func color(for event: EKEvent) -> Color {
        if let cgColor = event.calendar?.color {
            return Color(cgColor)
        }
        return .gray
    }

    private func timeLabel(_ event: EKEvent) -> String {
        if event.isAllDay { return String("All day") }
        return event.startDate.formatted(date: .omitted, time: .shortened)
    }

    private func dayLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return String("Today") }
        if calendar.isDateInTomorrow(day) { return String("Tomorrow") }
        return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

// MARK: - Tag Planner (→)

/// The → Planner: reminders grouped under chosen tags as collapsible sections,
/// with a compact Momentum strip pinned at the bottom. Rows are real
/// `ReminderItemView`s, so complete / swipe-to-postpone / edit all work here.
private struct TagPlannerView: View {
    @ObservedObject private var userPreferences = UserPreferences.shared
    @State private var tagLists: [TagReminderList] = []
    @State private var allTags: [Tag] = []
    @State private var completedToday = 0
    @State private var streak = 0
    @State private var loaded = false
    @State private var appHasPopoverOpen = false
    @State private var hoveredSectionID: String?

    /// The tags to show as sections: the user's chosen ones (in their order), or —
    /// if they haven't curated any — every tag they have.
    private var displayedTagLists: [TagReminderList] {
        guard !userPreferences.plannerTags.isEmpty else { return tagLists }
        return userPreferences.plannerTags.compactMap { name in
            tagLists.first { $0.tag.name.lowercased() == name.lowercased() }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            momentumStrip
        }
        .environment(\.appHasPopoverOpen, $appHasPopoverOpen)
        .environmentObject(CopyShortcutCoordinator())
        .onAppear(perform: load)
        .onReceive(NotificationCenter.default.publisher(for: .remindersDataShouldUpdate)) { _ in load() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(String("Planner"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer()
            tagMenu
            OpenSettingButton()
        }
        .padding(.horizontal, 20)
        .frame(height: SpotlightMetrics.fieldRowHeight)
    }

    private var tagMenu: some View {
        Menu {
            if allTags.isEmpty {
                Text(String("No tags yet"))
            } else {
                Section(String("Plan by")) {
                    ForEach(allTags) { tag in
                        Toggle(isOn: binding(for: tag)) { Text("# \(tag.name)") }
                    }
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String("Choose which tags to plan by"))
    }

    private func binding(for tag: Tag) -> Binding<Bool> {
        Binding(
            get: {
                userPreferences.plannerTags.isEmpty
                    || userPreferences.plannerTags.contains { $0.lowercased() == tag.name.lowercased() }
            },
            set: { include in
                // First explicit choice starts from "everything", then edits from there.
                var tags = userPreferences.plannerTags.isEmpty ? allTags.map(\.name) : userPreferences.plannerTags
                if include {
                    if !tags.contains(where: { $0.lowercased() == tag.name.lowercased() }) {
                        tags.append(tag.name)
                    }
                } else {
                    tags.removeAll { $0.lowercased() == tag.name.lowercased() }
                }
                userPreferences.plannerTags = tags
            }
        )
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if loaded && displayedTagLists.isEmpty {
            emptyState
        } else {
            List {
                ForEach(displayedTagLists) { list in
                    let collapsed = isCollapsed(list)
                    Section(header: sectionHeader(list, collapsed: collapsed)) {
                        if !collapsed {
                            if list.reminders.isEmpty {
                                Text(String("Nothing here yet"))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.tertiary)
                            }
                            ForEach(list.reminders) { item in
                                ReminderItemView(reminderItem: item, showCalendarTitle: true)
                            }
                        }
                    }
                    .modifier(ListSectionModifier())
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .padding(.top, 8)
            .padding(.bottom, 6)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "number")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.tertiary)
            Text(String("Tag reminders with # to plan by tag"))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 30)
    }

    private func sectionHeader(_ list: TagReminderList, collapsed: Bool) -> some View {
        let color = Color.rmbColor(.tagHighlight)
        return HStack(spacing: 6) {
            Button {
                toggleCollapse(list)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(color.opacity(0.85))
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                    Text("# \(list.tag.name)")
                        .font(.headline)
                        .foregroundColor(color)
                    Text("\(list.reminders.count)")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            // Reorder controls — revealed on hover, write the order into plannerTags.
            HStack(spacing: 3) {
                Button { moveTag(list, by: -1) } label: {
                    Image(systemName: "chevron.up").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .disabled(isFirst(list))
                Button { moveTag(list, by: 1) } label: {
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .disabled(isLast(list))
            }
            .foregroundStyle(.secondary)
            .opacity(hoveredSectionID == list.id ? 1 : 0)
            .help(String("Reorder this section"))
        }
        .onHover { hovering in
            if hovering {
                hoveredSectionID = list.id
            } else if hoveredSectionID == list.id {
                hoveredSectionID = nil
            }
        }
    }

    private func isFirst(_ list: TagReminderList) -> Bool { displayedTagLists.first?.id == list.id }
    private func isLast(_ list: TagReminderList) -> Bool { displayedTagLists.last?.id == list.id }

    /// Move a tag section up or down. Seeds `plannerTags` from the current display
    /// order the first time (when nothing's been curated yet), then reorders it.
    private func moveTag(_ list: TagReminderList, by offset: Int) {
        var order = userPreferences.plannerTags.isEmpty
            ? displayedTagLists.map(\.tag.name)
            : userPreferences.plannerTags
        guard let index = order.firstIndex(where: { $0.lowercased() == list.tag.name.lowercased() }) else { return }
        let target = index + offset
        guard target >= 0, target < order.count else { return }
        order.swapAt(index, target)
        withAnimation(.easeInOut(duration: 0.2)) {
            userPreferences.plannerTags = order
        }
    }

    // MARK: Momentum strip

    private var momentumStrip: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(streak > 0 ? Color.orange : Color.secondary)
                Text("\(streak)").font(.system(size: 14, weight: .semibold))
                Text(String("day streak")).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                Text("\(completedToday)").font(.system(size: 14, weight: .semibold))
                Text(String("done today")).font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 46)
    }

    // MARK: Collapse (persisted, shared prefs; distinct "planner-" keys)

    private func collapseKey(_ list: TagReminderList) -> String { "planner-\(list.id)" }

    private func isCollapsed(_ list: TagReminderList) -> Bool {
        userPreferences.collapsedReminderSections.contains(collapseKey(list))
    }

    private func toggleCollapse(_ list: TagReminderList) {
        let key = collapseKey(list)
        withAnimation(.easeInOut(duration: 0.2)) {
            if let index = userPreferences.collapsedReminderSections.firstIndex(of: key) {
                userPreferences.collapsedReminderSections.remove(at: index)
            } else {
                userPreferences.collapsedReminderSections.append(key)
            }
        }
    }

    // MARK: Load

    private func load() {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let since = calendar.date(byAdding: .day, value: -60, to: startOfToday) ?? startOfToday
        Task {
            let tags = await RemindersService.shared.getAllTags()
            let lists = await RemindersService.shared.getReminders(byTags: tags, calendarIdentifiers: nil)
            let done = await RemindersService.shared.getCompletedReminders(since: since)
            await MainActor.run {
                allTags = tags
                tagLists = lists
                computeMomentum(done, startOfToday: startOfToday)
                loaded = true
            }
        }
    }

    private func computeMomentum(_ done: [EKReminder], startOfToday: Date) {
        let calendar = Calendar.current
        completedToday = done.filter {
            guard let date = $0.completionDate else { return false }
            return calendar.isDate(date, inSameDayAs: startOfToday)
        }.count

        var completedDays = Set<Date>()
        for reminder in done {
            if let date = reminder.completionDate {
                completedDays.insert(calendar.startOfDay(for: date))
            }
        }
        // Count consecutive completed days ending today (or yesterday, so the streak
        // stays "alive" before you've finished anything today).
        var day = completedDays.contains(startOfToday)
            ? startOfToday
            : (calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday)
        var count = 0
        while completedDays.contains(day) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        streak = count
    }
}

// MARK: - Calendar filter (Calendar mode)

/// Filter-circle toolbar button whose menu toggles which calendars appear in the
/// agenda. Highlighted while any calendar is hidden.
private struct EventCalendarFilterButton: View {
    @ObservedObject private var userPreferences = UserPreferences.shared
    let calendars: [EKCalendar]

    var body: some View {
        Menu {
            ForEach(calendars, id: \.calendarIdentifier) { calendar in
                Toggle(calendar.title, isOn: binding(for: calendar))
            }
        } label: {
            ToolbarButtonLabel {
                Image(rmbSymbol: .filterCircle)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .modifier(ToolbarButtonModifier(isActive: !userPreferences.hiddenEventCalendarIdentifiers.isEmpty))
        .help(String("Filter calendars"))
    }

    private func binding(for calendar: EKCalendar) -> Binding<Bool> {
        Binding(
            get: { !userPreferences.hiddenEventCalendarIdentifiers.contains(calendar.calendarIdentifier) },
            set: { shown in
                if shown {
                    userPreferences.hiddenEventCalendarIdentifiers.removeAll { $0 == calendar.calendarIdentifier }
                } else if !userPreferences.hiddenEventCalendarIdentifiers.contains(calendar.calendarIdentifier) {
                    userPreferences.hiddenEventCalendarIdentifiers.append(calendar.calendarIdentifier)
                }
            }
        )
    }
}

/// Soft colored squircle behind the list / calendar preview chips — applied to
/// the Menu itself so the borderless menu style can't drop it. Just a gentle
/// fill (no hard outline), matching the other chips' softness.
private struct ColoredChipBackground: ViewModifier {
    let tint: Color

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(tint.opacity(0.18))
            )
    }
}

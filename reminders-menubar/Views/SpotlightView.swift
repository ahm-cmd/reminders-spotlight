import SwiftUI
import EventKit
import Combine

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
    @State private var dismissing = false  // whole panel bubbles off after
    @State private var listShown = true    // list card visible (opacity) vs faded out
    @State private var collapsing = false  // a typing-collapse is in flight
    @FocusState private var fieldFocused: Bool

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
        return bar + chromeInset * 2
    }

    var body: some View {
        VStack(spacing: cardGap) {
            barCard

            if showList {
                listCard
                    // listShown drives a compositor-only fade for the typing-
                    // collapse (the list stays MOUNTED while it fades, so nothing
                    // reflows). The transition handles the reveal-in.
                    .opacity(listShown ? 1 : 0)
                    .transition(.offset(y: -8).combined(with: .opacity))
            }
        }
        .opacity(dismissing ? 0 : 1)   // bubble-off fade after a reminder is saved
        // Inset the cards inside the larger window: leaves the chrome margin for
        // the shadow and the pop-in overshoot. Bottom margin comes from the
        // window being chromeInset taller than the content (top-aligned).
        .padding(.horizontal, chromeInset)
        .padding(.top, chromeInset)
        .frame(maxWidth: .infinity, alignment: .top)
        .preferredColorScheme(userPreferences.rmbColorScheme.colorScheme)
        .contentShape(Rectangle())
        .onAppear {
            rmbReminder.calendar = remindersData.calendarForSaving
            if userPreferences.autoSuggestToday {
                rmbReminder.setIsAutoSuggestingTodayForCreation()
            }
            DispatchQueue.main.async { fieldFocused = true }
            syncHeight()
        }
        // Moving the mouse (anywhere) means you want to browse → show the list.
        .onReceive(NotificationCenter.default.publisher(for: .mainWindowDidDetectMouseMove)) { _ in
            if !expanded { expand() }
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
        .onExitCommand {
            if expanded { collapse() } else { AppDelegate.shared.closeMainWindow() }
        }
    }

    // MARK: - Bar card

    private var barCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.secondary)

                TextField(String("Set a Reminder"), text: $rmbReminder.title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 26, weight: .regular))
                    .focused($fieldFocused)
                    .onSubmit(create)

                Button { expanded ? collapse() : expand() } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .frame(height: fieldRowHeight)

            // Chips show only in the collapsed (Typing) UI. Gating on !expanded
            // means the bar never reflows (chips appearing) while the list is
            // mounted — that reflow is one of the things that crashes the panel.
            if !rmbReminder.title.isEmpty && !expanded {
                HStack(spacing: 6) {
                    if rmbReminder.hasDueDate {
                        chip("calendar", rmbReminder.date.relativeDateDescription(withTime: rmbReminder.hasTime), .accentColor)
                    }
                    listPickerChip
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .frame(height: chipsRowHeight, alignment: .top)
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
                    .foregroundStyle(.white, .green)
                    // Blooms in from a point; then on dismiss keeps growing as the
                    // whole panel fades — the "bubble off".
                    .scaleEffect(dismissing ? 1.3 : 1.0)
                    .transition(.scale(scale: 0.2).combined(with: .opacity))
            }
        }
    }

    // MARK: - List card

    private var listCard: some View {
        ContentView()
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 2) {
                    FilterReminderListButton()
                    OpenSettingButton()
                }
                .padding(.trailing, 12)
                .padding(.top, 6)
            }
            .frame(height: listCardHeight)
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
            .overlay(shape.strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.22), radius: 16, x: 0, y: 6)
    }

    private var listPickerChip: some View {
        Menu {
            ForEach(remindersData.availableCalendars, id: \.calendarIdentifier) { calendar in
                Button(calendar.title) {
                    rmbReminder.calendar = calendar
                    rmbReminder.textCalendarResult = CalendarParser.TextCalendarResult()
                }
            }
        } label: {
            let calendar = parsedOrChosenCalendar
            chip("line.3.horizontal", calendar?.title ?? "List", calendar.map { Color($0.color) } ?? .secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func chip(_ icon: String, _ text: String, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text).lineLimit(1)
        }
        .font(.system(size: 12))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.opacity(0.14)))
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
        listShown = true
        growStartedAt = Date()
        withAnimation(.easeOut(duration: 0.11)) { expanded = true }
        scheduleListReveal()
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

    private func collapse() {
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
            }
            withAnimation(.easeOut(duration: 0.18)) { expanded = false }
            collapsing = false
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
        let title = finalTitle()
        guard !title.isEmpty, let calendar = parsedOrChosenCalendar else { return }

        // Begin the morph FIRST: rewriting rmbReminder.title below would otherwise
        // trip the typing→collapse handler, and didCreate guards it.
        fieldFocused = false
        withAnimation(.spring(response: 0.34, dampingFraction: 0.62)) { didCreate = true }

        rmbReminder.prepareToSave()
        rmbReminder.title = title
        rmbReminder.calendar = calendar
        RemindersService.shared.createNew(with: rmbReminder, in: calendar)
        remindersData.calendarForSaving = calendar

        // Linger on the checkmark a beat, then the panel bubbles off.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.52) {
            withAnimation(.easeIn(duration: 0.22)) { dismissing = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.74) {
            AppDelegate.shared.closeMainWindow()
        }
    }

    private func finalTitle() -> String {
        var title = rmbReminder.title
        if let priorityRange = Range(rmbReminder.textPriorityResult.highlightedText.range, in: title) {
            title.replaceSubrange(priorityRange, with: "")
        }
        if userPreferences.removeParsedDateFromTitle {
            title = title.replacingOccurrences(of: rmbReminder.textDateResult.string, with: "")
        }
        title = title.replacingOccurrences(of: rmbReminder.textCalendarResult.string, with: "")
        for tagResult in rmbReminder.textTagResults.sorted(by: { $0.string.count > $1.string.count }) {
            title = title.replacingOccurrences(of: tagResult.string, with: "")
        }
        return title.trimmingCharacters(in: .whitespaces)
    }
}

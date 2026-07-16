import SwiftUI
import EventKit
import Combine
import AppKit

/// Set while a reminder title is being edited inline in the list, so the panel's
/// global key monitor knows to leave Return / arrow keys to the text field.
@MainActor
final class InlineTitleEditState {
    static let shared = InlineTitleEditState()
    var isEditing = false
    private init() {}
}

@MainActor
struct ReminderItemView: View {
    @EnvironmentObject private var copyCoordinator: CopyShortcutCoordinator
    @Environment(\.appHasPopoverOpen) private var appHasPopoverOpen
    @ObservedObject private var userPreferences = UserPreferences.shared

    var reminderItem: ReminderItem
    var showCalendarTitle = false
    var isKeyboardSelected = false

    @State private var reminderItemIsHovered = false
    @State private var showingEditPopover = false
    @State private var showingRemoveAlert = false
    @State private var showingCopiedToast = false
    @State private var isPendingCompletion = false
    @State private var dateInvalidation = Date()
    @State private var dueDateExpirationCancellable: AnyCancellable?
    @State private var copiedToastDismissWork: DispatchWorkItem?
    @State private var isEditingTitle = false
    @State private var editedTitle = ""
    @FocusState private var titleFieldFocused: Bool

    // Click-drag-to-postpone. Dragging the row left reveals the delay menu; works
    // with a mouse (unlike the trackpad-only native swipe actions).
    @State private var swipeOpen = false
    @State private var swipeDragW: CGFloat = 0
    @State private var swipeCommitted = false
    private let postponeRevealWidth: CGFloat = 150
    private var swipeSpring: Animation { .spring(response: 0.3, dampingFraction: 0.82) }

    var body: some View {
        if reminderItem.reminder.calendar == nil {
            // On macOS 12 the calendar may be nil during delete operation.
            // Returning Empty to avoid issues since calendar is a force unwrap.
            EmptyView()
        } else {
            mainReminderItemView()
        }
    }

    @ViewBuilder
    private func mainReminderItemView() -> some View {
        // Compute each (reflection-backed / formatter-backed) value once per
        // render instead of re-deriving them in multiple places below.
        let tagNames = currentTagNames()
        let dateDescription = reminderItem.reminder.relativeDateDescription
        let hasDueDate = dateDescription != nil
        let showExternalLinks = userPreferences.showExternalLinksInReminderItem
        let attachedUrl = showExternalLinks ? reminderItem.reminder.attachedUrl : nil
        let mailUrl = showExternalLinks ? reminderItem.reminder.mailUrl : nil
        let shouldShowExternalLinks = showExternalLinks && (attachedUrl != nil || mailUrl != nil)

        HStack(alignment: .top) {
            ReminderCompleteButton(reminderItem: reminderItem, isPendingCompletion: $isPendingCompletion)

            VStack(spacing: 4) {
                reminderTitleRow(showCalendarTitleInline: showCalendarTitle && !hasDueDate && !shouldShowExternalLinks)

                if let notes = reminderItem.reminder.notes?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !notes.isEmpty {
                    Text(notes)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 8)
                }

                if #available(macOS 12, *), !tagNames.isEmpty {
                    ReminderTagsView(tagNames: tagNames)
                }

                if let dateDescription {
                    HStack(alignment: .bottom) {
                        ReminderDateDescriptionView(
                            dateDescription: dateDescription,
                            isExpired: reminderItem.reminder.isExpired,
                            hasRecurrenceRules: reminderItem.reminder.hasRecurrenceRules,
                            recurrenceRules: reminderItem.reminder.recurrenceRules
                        )
                        .id(dateInvalidation)

                        if showCalendarTitle {
                            calendarTitleText()
                        }
                    }
                    .padding(.trailing, 8)
                }

                if shouldShowExternalLinks {
                    HStack(alignment: .bottom) {
                        ReminderExternalLinksView(
                            attachedUrl: attachedUrl,
                            mailUrl: mailUrl,
                            isCompact: true
                        )

                        if showCalendarTitle && !hasDueDate {
                            calendarTitleText()
                        }
                    }
                    .padding(.trailing, 8)
                }

            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(isPendingCompletion || reminderItem.reminder.isCompleted ? 0.6 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isPendingCompletion)
            .allowsHitTesting(!isPendingCompletion && !appHasPopoverOpen.wrappedValue)
            .onTapGesture {
                if isEditingTitle { return }
                if swipeOpen {
                    withAnimation(swipeSpring) { swipeOpen = false }
                } else {
                    showingEditPopover = true
                }
            }
        }
        .onHover { isHovered in
            reminderItemIsHovered = isHovered
            if isHovered {
                copyCoordinator.setHovered(reminderId: reminderItem.id) {
                    copyReminderToClipboard()
                }
            } else {
                copyCoordinator.clearIfCurrent(reminderId: reminderItem.id)
            }
        }
        .onDisappear {
            copiedToastDismissWork?.cancel()
            showingCopiedToast = false
            copyCoordinator.clearIfCurrent(reminderId: reminderItem.id)
            if isEditingTitle { InlineTitleEditState.shared.isEditing = false }
        }
        // Even breathing room inside the selection highlight so it reads as a
        // generous pill wrapping the whole row (a row divider used to sit inside
        // the highlight and made it look lopsided).
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(isKeyboardSelected ? 0.12 : 0))
                // Extend horizontally too, so it doesn't line up flush with the
                // complete-circle.
                .padding(.horizontal, -6)
        )
        // Space between entries.
        .padding(.bottom, 6)
        .padding(.leading, reminderItem.isChild ? 22 : 0)
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            dateInvalidation = Date()
        }
        .onAppear {
            subscribeToDueDateExpiration()
        }
        .onChange(of: reminderItem) { _ in
            subscribeToDueDateExpiration()
        }
        .onChange(of: showingEditPopover) { isOpen in
            appHasPopoverOpen.wrappedValue = isOpen
        }
        // Click-drag the row to the left to reveal the delay menu (1 hr / 1 day /
        // 1 week). Custom gesture so it works with a mouse, with a soft-edged reveal.
        .modifier(PostponeSwipeModifier(
            open: $swipeOpen,
            dragW: $swipeDragW,
            committed: $swipeCommitted,
            revealWidth: postponeRevealWidth,
            onPostpone: { component, value in postpone(component, value) }
        ))

        ForEach(reminderItem.childReminders) { reminderItem in
            ReminderItemView(reminderItem: reminderItem)
        }
    }

    private func currentTagNames() -> [String] {
        // Cached on the snapshot at construction — reading the tags uses private
        // selector reflection, far too expensive to redo on every row render.
        return reminderItem.tagNames
    }

    private func reminderTitleText() -> Text {
        // LocalizedStringKey renders any markdown in the title. We intentionally
        // don't run NSDataDetector here: it was scanned per row on every render
        // and its result was discarded (.toDetectedLinkAttributedString returned
        // the plain string), so it was pure CPU waste.
        let titleText = Text(LocalizedStringKey(reminderItem.reminder.title))

        guard let prioritySymbol = reminderItem.reminder.ekPriority.rmbSymbol else {
            return titleText
        }

        return Text(Image(rmbSymbol: prioritySymbol))
            .foregroundColor(Color(reminderItem.reminder.calendar.color))
        + Text(verbatim: " ")
        + titleText
    }

    @ViewBuilder
    private func reminderTitleRow(showCalendarTitleInline: Bool) -> some View {
        ZStack(alignment: .topTrailing) {
            if isEditingTitle {
                // Edit the title in place: single-click swaps the label for a field,
                // Return / clicking away commits.
                TextField("", text: $editedTitle)
                    .textFieldStyle(.plain)
                    .focused($titleFieldFocused)
                    .onSubmit { commitTitleEdit() }
                    .onChange(of: titleFieldFocused) { focused in
                        if !focused { commitTitleEdit() }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 22)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    reminderTitleText()
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { beginTitleEdit() }

                    // With no date/links row to anchor to, the list name rides on the
                    // title line rather than dropping to a wasteful extra row.
                    if showCalendarTitleInline {
                        calendarTitleText()
                    }
                }
                .padding(.trailing, 22)
            }

            trailingIndicator()
        }
        .alert(isPresented: $showingRemoveAlert) {
            removeReminderAlert(for: reminderItem.reminder)
        }
    }

    private func beginTitleEdit() {
        editedTitle = reminderItem.reminder.title
        isEditingTitle = true
        InlineTitleEditState.shared.isEditing = true
        DispatchQueue.main.async { titleFieldFocused = true }
    }

    private func commitTitleEdit() {
        guard isEditingTitle else { return }
        isEditingTitle = false
        InlineTitleEditState.shared.isEditing = false
        let trimmed = editedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != reminderItem.reminder.title else { return }
        reminderItem.reminder.title = trimmed
        RemindersService.shared.save(reminder: reminderItem.reminder)
    }

    /// Push this reminder's due date out by a fixed interval — the swipe-to-postpone
    /// quick actions. Anchors off the current due date (or now if it has none).
    private func postpone(_ component: Calendar.Component, _ value: Int) {
        let reminder = reminderItem.reminder
        // An hour offset only makes sense from a clock time. If the reminder has no
        // time (date-only, so its due date resolves to midnight), "+1 hour" off
        // midnight would land at 1 AM — anchor to now instead so it means "an hour
        // from now". Day/week keep whatever the reminder already had.
        let hourFromUntimed = component == .hour && !reminder.hasTime
        let base = hourFromUntimed ? Date() : (reminder.dueDateComponents?.date ?? Date())
        guard let newDate = Calendar.current.date(byAdding: component, value: value, to: base) else { return }
        let withTime = component == .hour ? true : reminder.hasTime
        reminder.removeDueDateAndAlarms()
        reminder.addDueDateAndAlarm(for: newDate, withTime: withTime)
        RemindersService.shared.save(reminder: reminder)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    @ViewBuilder
    private func trailingIndicator() -> some View {
        if showingCopiedToast {
            HStack(spacing: 4) {
                Image(rmbSymbol: .checkmark)
                Text(rmbLocalized(.copiedToastMessage))
            }
            .font(.footnote.weight(.semibold))
            .foregroundColor(.rmbColor(.successIndicator))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.rmbColor(.buttonHover))
            )
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.3), value: showingCopiedToast)
            .allowsHitTesting(false)
        } else {
            ReminderEllipsisMenuView(
                showingEditPopover: $showingEditPopover,
                showingRemoveAlert: $showingRemoveAlert,
                onCopyReminder: { copyReminderToClipboard() },
                reminder: reminderItem.reminder,
                reminderHasChildren: reminderItem.hasChildren
            )
            .opacity(shouldShowEllipsisButton() ? 1 : 0)
            .popover(isPresented: $showingEditPopover, arrowEdge: .trailing) {
                ReminderEditView(
                    isPresented: $showingEditPopover,
                    reminder: reminderItem.reminder,
                    reminderHasChildren: reminderItem.hasChildren
                )
            }
        }
    }

    @ViewBuilder
    private func calendarTitleText() -> some View {
        Text(reminderItem.reminder.calendar.title)
            .font(.footnote)
            .foregroundColor(.secondary)
            .fixedSize()
    }

    private func subscribeToDueDateExpiration() {
        dueDateExpirationCancellable?.cancel()
        guard reminderItem.reminder.hasTime,
              let dueDate = reminderItem.reminder.dueDateComponents?.date,
              dueDate.timeIntervalSinceNow > 0 else {
            return
        }

        dueDateExpirationCancellable = Just(())
            .delay(for: .seconds(dueDate.timeIntervalSinceNow), scheduler: RunLoop.main)
            .sink { _ in
                dateInvalidation = Date()
            }
    }

    private func shouldShowEllipsisButton() -> Bool {
        guard !showingCopiedToast else { return false }
        let hoverWithNoPopoverOpen = reminderItemIsHovered && !appHasPopoverOpen.wrappedValue
        return !isPendingCompletion && (hoverWithNoPopoverOpen || showingEditPopover)
    }

    private func copyReminderToClipboard() {
        guard !isPendingCompletion, !showingEditPopover, !appHasPopoverOpen.wrappedValue else { return }
        ReminderCopyService.copyReminder(reminderItem.reminder)
        showingCopiedToast = true

        copiedToastDismissWork?.cancel()
        let work = DispatchWorkItem { showingCopiedToast = false }
        copiedToastDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
}

/// Click-drag-to-postpone. Dragging a reminder row to the left slides it aside and
/// reveals a delay menu (1 hr / 1 day / 1 week). Uses a plain `DragGesture` so it
/// works with a mouse, not just a trackpad swipe. Apple touches:
///   • release short and it springs back (with a little bounce);
///   • the menu's trailing corners are rounded, not sharp;
///   • dragging past the full reveal keeps stretching the last option ("1 wk")
///     with the mouse — elastic, so the menu doesn't feel hard-capped.
/// Row and menu are always edge-to-edge (no overlap), and the menu fades in with a
/// soft shadow at the seam so the reveal reads as the row lifting away.
private struct PostponeSwipeModifier: ViewModifier {
    @Binding var open: Bool
    @Binding var dragW: CGFloat
    @Binding var committed: Bool
    let revealWidth: CGFloat
    let onPostpone: (Calendar.Component, Int) -> Void

    private var buttonWidth: CGFloat { revealWidth / 3 }
    private let maxOverdrag: CGFloat = 100
    // A touch of bounce on the settle, so a short release springs back with life.
    private var settleSpring: Animation { .spring(response: 0.32, dampingFraction: 0.72) }

    func body(content: Content) -> some View {
        let base: CGFloat = open ? -revealWidth : 0
        let offset = elasticOffset(base + dragW)
        let overdrag = max(0, -offset - revealWidth)   // extra drag past the full reveal
        let menuWidth = revealWidth + overdrag
        let progress = Double(min(1, -offset / revealWidth))

        return ZStack(alignment: .trailing) {
            actions(overdrag: overdrag)
                .frame(width: menuWidth)
                // Rounded trailing corners (the panel-edge side); the leading side
                // stays flush against the row.
                .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 16, topTrailingRadius: 16, style: .continuous))
                // Sits off the right edge when closed; slides in exactly as far as
                // the row slides away, so the two are always edge-to-edge. Past full
                // reveal this stays pinned to the trailing edge and just widens.
                .offset(x: menuWidth + offset)
                .opacity(progress)   // fade in as it's revealed — softens the reveal

            content
                .offset(x: offset)
        }
        .clipped()
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 10)
                .onChanged { value in
                    if !committed {
                        // Commit to a horizontal swipe once, so a vertical-ish drag
                        // doesn't jitter the row.
                        guard abs(value.translation.width) > 6,
                              abs(value.translation.width) > abs(value.translation.height) else { return }
                        committed = true
                    }
                    dragW = value.translation.width
                }
                .onEnded { value in
                    let wasCommitted = committed
                    committed = false
                    guard wasCommitted else { return }
                    let projected = min(0, (open ? -revealWidth : 0) + value.translation.width)
                    withAnimation(settleSpring) {
                        open = projected < -revealWidth * 0.4   // past 40% → snap open
                        dragW = 0
                    }
                }
        )
    }

    /// Tracks the drag 1:1 up to the full reveal, then rubber-bands (resistance +
    /// a cap) so dragging further keeps stretching the last option elastically.
    private func elasticOffset(_ raw: CGFloat) -> CGFloat {
        let leftward = min(0, raw)
        guard leftward < -revealWidth else { return leftward }
        let over = (-leftward - revealWidth) * 0.55
        return -revealWidth - min(over, maxOverdrag)
    }

    private func actions(overdrag: CGFloat) -> some View {
        HStack(spacing: 0) {
            button("clock", String("1 hr"), .gray, width: buttonWidth) { onPostpone(.hour, 1) }
            button("sun.max", String("1 day"), .blue, width: buttonWidth) { onPostpone(.day, 1) }
            // The trailing option absorbs the over-drag, so it follows the mouse.
            button("calendar", String("1 wk"), .indigo, width: buttonWidth + overdrag) { onPostpone(.weekOfYear, 1) }
        }
        // A soft shadow at the seam (where the row's edge meets the menu) so the
        // boundary isn't a hard line.
        .overlay(alignment: .leading) {
            LinearGradient(colors: [.black.opacity(0.18), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: 12)
                .allowsHitTesting(false)
        }
    }

    private func button(_ icon: String, _ title: String, _ tint: Color, width: CGFloat, action: @escaping () -> Void) -> some View {
        Button {
            action()
            withAnimation(settleSpring) { open = false }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .foregroundStyle(.white)
            .background(tint)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    var reminder: EKReminder {
        let calendar = EKCalendar(for: .reminder, eventStore: .init())
        calendar.color = .systemTeal

        let reminder = EKReminder(eventStore: .init())
        reminder.title = "Look for awesome projects on GitHub"
        reminder.isCompleted = false
        reminder.calendar = calendar
        reminder.addDueDateAndAlarm(for: Date().addingTimeInterval(86_400), withTime: false)

        return reminder
    }
    let reminderItem = ReminderItem(for: reminder)

    ReminderItemView(reminderItem: reminderItem)
        .environmentObject(CopyShortcutCoordinator())
}

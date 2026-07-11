import SwiftUI
import EventKit
import Combine

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
                reminderTitleRow()

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

                if showCalendarTitle && !hasDueDate && !shouldShowExternalLinks {
                    HStack {
                        Spacer()

                        calendarTitleText()
                    }
                    .padding(.trailing, 8)
                }

                Divider()
                    .padding(.top, 2)
                    .opacity(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(isPendingCompletion || reminderItem.reminder.isCompleted ? 0.6 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isPendingCompletion)
            .allowsHitTesting(!isPendingCompletion && !appHasPopoverOpen.wrappedValue)
            .onTapGesture {
                if !isEditingTitle { showingEditPopover = true }
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
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(isKeyboardSelected ? 0.12 : 0))
                // Extend past the row so the highlight doesn't line up flush with
                // the leading edge of the complete-circle.
                .padding(.horizontal, -6)
        )
        .padding(.bottom, 2)
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
    private func reminderTitleRow() -> some View {
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
                reminderTitleText()
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 22)
                    .contentShape(Rectangle())
                    .onTapGesture { beginTitleEdit() }
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

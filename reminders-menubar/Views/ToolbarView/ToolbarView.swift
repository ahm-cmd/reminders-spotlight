import SwiftUI

struct ToolbarView: View {
    @EnvironmentObject var remindersData: RemindersData

    var body: some View {
        HStack(spacing: 4) {
            Spacer()

            FilterReminderListButton()
                .disabled(remindersData.availableCalendars.isEmpty)

            OpenSettingButton()
        }
        .padding(.top, 10)
        .padding(.trailing, 10)
        .padding(.leading, 14)
        .padding(.bottom, 6)
    }
}

#Preview {
    ToolbarView()
        .environmentObject(RemindersData())
}

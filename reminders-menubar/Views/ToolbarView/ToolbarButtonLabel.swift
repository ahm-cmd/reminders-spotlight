import SwiftUI

struct ToolbarButtonLabel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        // A fixed square so the hover highlight (drawn by ToolbarButtonModifier,
        // sized to this view) matches the icon exactly and doesn't overflow.
        content
            .font(.system(size: 15))
            .frame(width: 28, height: 28)
    }
}

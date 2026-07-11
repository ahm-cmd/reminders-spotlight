import SwiftUI

struct ToolbarButtonModifier: ViewModifier {
    var isActive = false
    @State private var isHovered = false

    func body(content: Content) -> some View {
        return content
            .buttonStyle(.borderless)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            // Background is sized to the (fixed 28x28) label, so the highlight
            // hugs the icon instead of bleeding past it.
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.rmbColor(.buttonHover))
                    .opacity((isHovered || isActive) ? 1 : 0)
            )
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

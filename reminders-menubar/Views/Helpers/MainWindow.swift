import AppKit
import SwiftUI

/// A borderless panel that can still become key (so its text fields / type-to-
/// create work). This is the centered, Spotlight-style window.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// A behind-window blur, exposed to SwiftUI for the panel's frosted backdrop.
struct VisualEffectBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// The Spotlight-style "pop in": the content appears slightly LARGER than final,
/// dips a touch SMALLER, then settles to full size, fading in over the first
/// part of the move — like macOS Spotlight. The scale is purely cosmetic (the
/// hosting view has sizingOptions = [], so it never drives window size) and runs
/// before the list is shown, so it can't touch the resize-while-List path.
/// Anchored at .top because the window pins its top edge.
struct SpotlightRoot<Content: View>: View {
    @State private var animate = false
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if #available(macOS 14.0, *) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .keyframeAnimator(initialValue: PopValues(), trigger: animate) { view, value in
                    view
                        .scaleEffect(value.scale, anchor: .top)
                        .opacity(value.opacity)
                } keyframes: { _ in
                    KeyframeTrack(\.scale) {
                        CubicKeyframe(0.97, duration: 0.13)   // 1.04 → 0.97 (dip)
                        SpringKeyframe(1.0, duration: 0.15, spring: .init(response: 0.18, dampingRatio: 0.6))
                    }
                    KeyframeTrack(\.opacity) {
                        LinearKeyframe(1.0, duration: 0.10)
                        LinearKeyframe(1.0, duration: 0.18)
                    }
                }
                .onAppear { animate = true }
        } else {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .scaleEffect(animate ? 1.0 : 0.96, anchor: .top)
                .opacity(animate ? 1 : 0)
                .onAppear {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.62)) { animate = true }
                }
        }
    }

    /// Keyframe state. `scale` starts at 1.04 so the first frame is already
    /// slightly oversized (the "pop"); the timeline dips it to 0.97 then settles to 1.0.
    private struct PopValues {
        var scale: CGFloat = 1.04
        var opacity: CGFloat = 0.0
    }
}

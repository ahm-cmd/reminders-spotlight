import Foundation

enum MainPopoverSizing {
    // Matches macOS Spotlight's width.
    static let defaultSize = NSSize(width: 680, height: 460)
    static let minSize = NSSize(width: 240, height: 300)
    static let maxSize = NSSize(width: 820, height: 1_000)
    static let minWidthPadding: CGFloat = 80
    static let minHeightPadding: CGFloat = 120
}

/// Geometry shared between the SwiftUI card layout (`SpotlightView`) and the
/// AppKit window that hosts it (`AppDelegate`), so the two can never disagree.
///
/// The window is deliberately LARGER than the visible card — by `chromeInset`
/// on every side. That transparent margin is room for two things: the drop
/// shadow, and the pop-in's brief scale overshoot (1.04). Without it, scaling
/// the card past 1.0 pushes its rounded corners outside the window's *square*
/// content bounds, which clips them to 90° for the first frames of the
/// animation (the "popping in inside a rectangle" artifact).
enum SpotlightMetrics {
    /// The visible card width — macOS Spotlight's field width.
    static let cardWidth: CGFloat = 680
    /// The entry-bar height — Spotlight's search-field height.
    static let fieldRowHeight: CGFloat = 64
    static let chipsRowHeight: CGFloat = 36
    static let listCardHeight: CGFloat = 420
    static let cardGap: CGFloat = 8
    /// Spotlight's continuous corner radius (measured ~18pt from a side-by-side).
    static let cornerRadius: CGFloat = 18
    /// Transparent margin around the card (shadow + pop-in overshoot room).
    static let chromeInset: CGFloat = 28

    /// Full window width = card + margin on both sides.
    static var windowWidth: CGFloat { cardWidth + chromeInset * 2 }
    /// Window height when only the entry bar is shown.
    static var collapsedWindowHeight: CGFloat { fieldRowHeight + chromeInset * 2 }
}

import SwiftUI

struct RmbHighlightedTextField: NSViewRepresentable {
    struct HighlightedText {
        let range: NSRange
        let color: NSColor
    }

    let placeholder: String
    var text: Binding<String>
    var highlightedTexts: [HighlightedText]
    var textContainerDynamicHeight: Binding<CGFloat>?
    var maximumNumberOfLines: Int
    var allowNewLineAndTab: Bool
    var focusTrigger: Binding<UUID>?

    private var textFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    private var caretColor: NSColor?
    private var singleLine = false
    private var onSubmit: (() -> Void)?
    private var isInitialCharValidToAutoComplete: ((_ initialChar: String?) -> Bool)?
    private var autoCompleteSuggestions: ((_ initialChar: String?, _ typingWord: String) -> [String])?

    init(
        placeholder: String,
        text: Binding<String>,
        highlightedTexts: [HighlightedText] = [],
        textContainerDynamicHeight: Binding<CGFloat>? = nil,
        maximumNumberOfLines: Int = 3,
        allowNewLineAndTab: Bool = false,
        focusTrigger: Binding<UUID>? = nil
    ) {
        self.placeholder = placeholder
        self.text = text
        self.highlightedTexts = highlightedTexts
        self.textContainerDynamicHeight = textContainerDynamicHeight
        self.maximumNumberOfLines = maximumNumberOfLines
        self.allowNewLineAndTab = allowNewLineAndTab
        self.focusTrigger = focusTrigger
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = PlaceholderNSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? PlaceholderNSTextView else {
            return scrollView
        }

        textView.placeholder = placeholder
        textView.shouldFocus = focusTrigger != nil
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.backgroundColor = .clear
        textView.font = textFont
        textView.delegate = context.coordinator
        if let caretColor {
            textView.insertionPointColor = caretColor
        }

        if singleLine {
            // One line, no wrapping (long text scrolls horizontally), and text
            // pinned to the left edge so it lines up with an external placeholder.
            scrollView.drawsBackground = false
            scrollView.borderType = .noBorder
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
            scrollView.verticalScrollElasticity = .none
            textView.isHorizontallyResizable = true
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.textContainerInset = .zero
            if let container = textView.textContainer {
                container.widthTracksTextView = false
                container.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                container.lineFragmentPadding = 0
                container.maximumNumberOfLines = 1
            }
        } else {
            // Multi-line: use an overlay, auto-hiding scroller so a track isn't
            // parked in the field before there's anything to scroll.
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.scrollerStyle = .overlay

            if textContainerDynamicHeight == nil {
                // Fixed-height scrolling box (the notes card). Match the app's
                // chrome — transparent + borderless — and give the text room top
                // and bottom so the last line isn't flush against the edge (which
                // read as being cut off when scrolled).
                scrollView.drawsBackground = false
                scrollView.borderType = .noBorder
                scrollView.verticalScrollElasticity = .none
                textView.textContainerInset = NSSize(width: 4, height: 6)
                textView.textContainer?.lineFragmentPadding = 0
            }
        }

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else {
            return
        }

        context.coordinator.parent = self

        if let caretColor {
            textView.insertionPointColor = caretColor
        }

        if singleLine, let layoutManager = textView.layoutManager {
            // Center the single line vertically within the field's height.
            let lineHeight = layoutManager.defaultLineHeight(for: textFont)
            let inset = max(0, (nsView.bounds.height - lineHeight) / 2)
            if abs(textView.textContainerInset.height - inset) > 0.5 {
                textView.textContainerInset = NSSize(width: 0, height: inset)
            }
        }

        let selectedRange = textView.selectedRange()
        let updatedText = text.wrappedValue
        let updatedTextLength = (updatedText as NSString).length
        let selectionLocation = min(selectedRange.location, updatedTextLength)
        let selectionLength = min(selectedRange.length, updatedTextLength - selectionLocation)

        textView.textStorage?.setAttributedString(getAttributedString(from: updatedText))
        textView.setSelectedRange(NSRange(location: selectionLocation, length: selectionLength))

        if let trigger = focusTrigger?.wrappedValue,
           trigger != context.coordinator.lastFocusTrigger {
            context.coordinator.lastFocusTrigger = trigger
            if nsView.window?.firstResponder != textView {
                nsView.window?.makeFirstResponder(textView)
            }
            textView.setSelectedRange(NSRange(location: updatedTextLength, length: 0))
        }

        textView.scrollRangeToVisible(NSRange(location: updatedTextLength, length: 0))

        adjustDynamicHeight(for: textView, context: context)
    }

    private func adjustDynamicHeight(for textView: NSTextView, context: Context) {
        var newHeight: CGFloat = 48.0
        if let layoutManager = textView.layoutManager,
           let textContainer = textView.textContainer {
            let maxHeight = layoutManager.defaultLineHeight(for: textFont) * CGFloat(maximumNumberOfLines)
            newHeight = min(layoutManager.usedRect(for: textContainer).height, maxHeight)
        }

        DispatchQueue.main.async {
            context.coordinator.parent.textContainerDynamicHeight?.wrappedValue = newHeight
        }
    }

    private func getAttributedString(from text: String) -> NSMutableAttributedString {
        let fullRange = text.fullRange

        let attributedString = NSMutableAttributedString(string: text)
        attributedString.beginEditing()
        attributedString.addAttribute(
            .font,
            value: textFont,
            range: fullRange
        )
        attributedString.addAttribute(
            .foregroundColor,
            value: NSColor.labelColor,
            range: fullRange
        )
        for highlightedText in highlightedTexts {
            attributedString.addAttribute(
                .foregroundColor,
                value: highlightedText.color,
                range: highlightedText.range
            )
        }
        attributedString.endEditing()

        return attributedString
    }

    func makeCoordinator() -> Coordinator {
        return Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate, NSTextDelegate {
        var parent: RmbHighlightedTextField

        var isAutoCompleting = false
        var isDeletePressed = false
        var lastFocusTrigger: UUID?

        init(_ parent: RmbHighlightedTextField) {
            self.parent = parent
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.deleteBackward(_:)),
                 #selector(NSResponder.deleteForward(_:)):
                isDeletePressed = true
                return false
            case #selector(NSResponder.insertNewline(_:)):
                return handleNewline()
            default:
                return false
            }
        }

        private func handleNewline() -> Bool {
            let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .shift, .control]
            let modifiers = NSApp.currentEvent?.modifierFlags.intersection(relevantModifiers) ?? []

            if parent.allowNewLineAndTab, !modifiers.isEmpty {
                return false
            }

            guard let onSubmit = parent.onSubmit else {
                return false
            }

            onSubmit()
            return true
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            guard let replacementString else {
                return true
            }

            if !parent.allowNewLineAndTab && (replacementString == "\n" || replacementString == "\t") {
                return false
            }

            return true
        }

        func textDidChange(_ obj: Notification) {
            guard let textView = obj.object as? NSTextView else {
                return
            }

            if parent.text.wrappedValue == textView.string {
                // NOTE: When auto-completing the text may not have differences.
                // We change the parent text to trigger the updateNSView.
                parent.text.wrappedValue += " "
            }

            parent.text.wrappedValue = textView.string

            if isDeletePressed {
                isDeletePressed = false
                return
            }

            if !isAutoCompleting {
                isAutoCompleting = true
                textView.complete(nil)
                isAutoCompleting = false
            }
        }

        func textView(
            _ textView: NSTextView,
            completions words: [String],
            forPartialWordRange charRange: NSRange,
            indexOfSelectedItem index: UnsafeMutablePointer<Int>?
        ) -> [String] {
            guard let autoCompleteSuggestions = parent.autoCompleteSuggestions else {
                return []
            }

            let typingWord = textView.string.substring(in: charRange)
            guard !typingWord.isEmpty,
                  isValidToAutocomplete(textView.string, charRange: charRange) else {
                return []
            }

            let initialChar = textView.string[safe: charRange.lowerBound - 1]
            return autoCompleteSuggestions(initialChar, typingWord)
        }

        private func isValidToAutocomplete(_ string: String, charRange: NSRange) -> Bool {
            guard let isInitialCharValidToAutoComplete = parent.isInitialCharValidToAutoComplete else {
                return false
            }

            let initialChar = string[safe: charRange.lowerBound - 1]
            let beforeInitialChar = string[safe: charRange.lowerBound - 2]

            return isInitialCharValidToAutoComplete(initialChar)
            && (beforeInitialChar == " " || beforeInitialChar == nil)
        }
    }
}

extension RmbHighlightedTextField {
    func onSubmit(_ onSubmit: @escaping () -> Void) -> RmbHighlightedTextField {
        var view = self
        view.onSubmit = onSubmit
        return view
    }

    func autoComplete(
        isInitialCharValid: @escaping (_ initialChar: String?) -> Bool,
        suggestions: @escaping (_ initialChar: String?, _ typingWord: String) -> [String]
    ) -> RmbHighlightedTextField {
        var view = self
        view.isInitialCharValidToAutoComplete = isInitialCharValid
        view.autoCompleteSuggestions = suggestions
        return view
    }

    func fontStyle(_ fontStyle: NSFont.TextStyle) -> RmbHighlightedTextField {
        var view = self
        view.textFont = .preferredFont(forTextStyle: fontStyle)
        return view
    }

    func nsFont(_ font: NSFont) -> RmbHighlightedTextField {
        var view = self
        view.textFont = font
        return view
    }

    func caretColor(_ color: NSColor?) -> RmbHighlightedTextField {
        var view = self
        view.caretColor = color
        return view
    }

    func singleLine(_ enabled: Bool = true) -> RmbHighlightedTextField {
        var view = self
        view.singleLine = enabled
        return view
    }
}

private class PlaceholderNSTextView: NSTextView {
    var placeholder: String = ""
    var shouldFocus: Bool = false

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        guard string.isEmpty, !placeholder.isEmpty else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        // Draw once at the same origin the text/caret uses (container inset +
        // line-fragment padding), in the view's own coordinates. Drawing into the
        // passed-in dirty `rect` instead left a copy of the placeholder at every
        // scroll offset (the "duplicated Notes" artifact) and misplaced it.
        let padding = textContainer?.lineFragmentPadding ?? 0
        let origin = CGPoint(x: textContainerInset.width + padding,
                             y: textContainerInset.height)
        placeholder.draw(at: origin, withAttributes: attributes)
    }

    override func viewDidMoveToWindow() {
        if shouldFocus {
            window?.makeFirstResponder(self)
        }
    }
}

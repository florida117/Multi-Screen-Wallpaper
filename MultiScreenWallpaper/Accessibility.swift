import AppKit

/// System accessibility preferences the UI reacts to, plus the VoiceOver
/// announcement helper. Centralised so the AppKit canvas and the SwiftUI chrome
/// read the same values and stay visually consistent.
enum Accessibility {

    // MARK: - System display preferences

    /// "Increase contrast" — draw solid, thicker, fully-opaque decorations.
    static var increaseContrast: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    /// "Reduce transparency" — replace translucent overlays with opaque fills.
    static var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    static var isVoiceOverEnabled: Bool {
        NSWorkspace.shared.isVoiceOverEnabled
    }

    /// True when overlays should be drawn opaque rather than translucent.
    static var prefersOpaqueOverlays: Bool { increaseContrast || reduceTransparency }

    static func observeDisplayOptions(_ observer: Any, selector: Selector) {
        NSWorkspace.shared.notificationCenter.addObserver(
            observer, selector: selector,
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    static func stopObservingDisplayOptions(_ observer: Any) {
        NSWorkspace.shared.notificationCenter.removeObserver(
            observer, name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    // MARK: - Announcements

    /// Speak `message` through VoiceOver without moving focus, so status changes
    /// that are only shown visually still reach screen reader users. A no-op when
    /// VoiceOver is off, so callers never need to check first.
    static func announce(_ message: String, priority: NSAccessibilityPriorityLevel = .medium) {
        guard isVoiceOverEnabled, !message.isEmpty else { return }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: priority.rawValue])
    }

    // MARK: - Formatting

    /// A system font at the point size the user's preferred `style` currently
    /// uses, so hand-drawn canvas text follows the system text-size setting
    /// instead of being pinned to a hard-coded size.
    static func font(forTextStyle style: NSFont.TextStyle, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: style).pointSize, weight: weight)
    }

    /// Fractions read poorly aloud; percentages read well.
    static func percent(_ fraction: CGFloat) -> Int {
        Int((fraction * 100).rounded())
    }
}

import Foundation

/// Observable state for the composer input overlay.
/// Created when the composer is shown, nilled out when hidden.
/// Draft text is preserved externally so it survives show/hide cycles.
final class ComposerState: ObservableObject {
    @Published var text: String
    /// Whether the slash completion popup is visible.
    @Published var showCompletion: Bool = false
    /// Current filter string for slash completion (without the leading /).
    @Published var completionFilter: String = ""
    /// Currently selected index in the completion list.
    @Published var completionSelectedIndex: Int = 0

    init(text: String = "") {
        self.text = text
    }
}

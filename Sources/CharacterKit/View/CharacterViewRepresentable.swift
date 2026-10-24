import SwiftUI

/// A ``CharacterView`` in SwiftUI. The character is the model: keep it alive (e.g. in `@State`)
/// and set its state, expression and the rest on it directly.
///
/// ```swift
/// @State private var robot = IronGiantCharacter(seed: 0.3)
/// var body: some View {
///     CharacterViewRepresentable(character: robot)
///         .frame(width: 240, height: 300)
/// }
/// ```
public struct CharacterViewRepresentable: NSViewRepresentable {
    public let character: any CharacterRenderer
    public var isInteractive: Bool
    public var preferredBox: CGFloat?
    public var forcedBudget: RenderBudget?
    public var onClick: (() -> Void)?
    /// Called once with the view, to reach its pacer, stats or hit-testing.
    public var onMake: ((CharacterView) -> Void)?

    public init(character: any CharacterRenderer, isInteractive: Bool = true, preferredBox: CGFloat? = nil, forcedBudget: RenderBudget? = nil, onClick: (() -> Void)? = nil, onMake: ((CharacterView) -> Void)? = nil) {
        self.character = character
        self.isInteractive = isInteractive
        self.preferredBox = preferredBox
        self.forcedBudget = forcedBudget
        self.onClick = onClick
        self.onMake = onMake
    }

    public func makeNSView(context: Context) -> CharacterView {
        let view = CharacterView(character: character)
        update(view)
        onMake?(view)
        return view
    }

    public func updateNSView(_ view: CharacterView, context: Context) {
        update(view)
    }

    private func update(_ view: CharacterView) {
        view.isInteractive = isInteractive
        if view.preferredBox != preferredBox { view.preferredBox = preferredBox }
        if view.pacer.forcedBudget != forcedBudget { view.pacer.forcedBudget = forcedBudget }
        let onClick = onClick
        view.onClick = onClick.map { f in { _ in f() } }
    }
}

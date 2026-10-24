/// Characters by id, so data (Buddy's character packs) can name the renderer it wants.
@MainActor
public enum CharacterRegistry {
    private static var types: [String: any CharacterRenderer.Type] = [:]

    /// Make `type` available under its ``CharacterRenderer/characterID``.
    public static func register(_ type: any CharacterRenderer.Type) {
        types[type.characterID] = type
    }

    /// A new character for `id`, or nil when none is registered under it.
    public static func make(_ id: String, seed: Double) -> (any CharacterRenderer)? {
        types[id].map { $0.init(seed: seed) }
    }

    public static var registeredIDs: [String] {
        types.keys.sorted()
    }
}

// The words every character understands. They are shared, so a character pack,
// Buddy's event mapping and the LLM's expression cues stay the same when the
// character changes; each character decides how it acts them out.

/// What the character is doing. Every character has a motion and a face for each.
public enum CharacterState: String, CaseIterable, Hashable, Sendable, Codable {
    case idle
    case thinking
    case searching
    case listening
    case speaking
    case working
    case happy
    case error
    case sleeping
}

/// How the character feels: a face that replaces the state's own and keeps the state's motion.
///
/// An open set. Every character accepts the ``core`` expressions, mapping each to its nearest
/// face when it has no exact one, and may add its own. String-backed, so packs and LLM cues are
/// plain data.
public struct CharacterExpression: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    public static let neutral: Self = "neutral"
    public static let curious: Self = "curious"
    public static let happy: Self = "happy"
    public static let joyful: Self = "joyful"
    public static let sad: Self = "sad"
    public static let sheepish: Self = "sheepish"
    public static let sleepy: Self = "sleepy"
    public static let suspicious: Self = "suspicious"
    public static let content: Self = "content"
    public static let surprised: Self = "surprised"
    public static let afraid: Self = "afraid"
    public static let determined: Self = "determined"
    public static let angry: Self = "angry"
    public static let attack: Self = "attack"
    public static let defense: Self = "defense"
    public static let peaceful: Self = "peaceful"
    public static let asleep: Self = "asleep"

    /// The expressions every character accepts, in a stable order.
    public static let core: [Self] = [
        .neutral, .curious, .happy, .joyful, .sad, .sheepish, .sleepy, .suspicious, .content,
        .surprised, .afraid, .determined, .angry, .attack, .defense, .peaceful, .asleep,
    ]
}

/// Something the character does once, over whatever it is doing.
///
/// An open set, like ``CharacterExpression``: every character accepts the ``core`` actions and
/// may add its own.
public struct CharacterAction: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    public static let blink: Self = "blink"
    public static let nod: Self = "nod"
    public static let shake: Self = "shake"
    public static let hmm: Self = "hmm"
    public static let laugh: Self = "laugh"
    public static let surprise: Self = "surprise"
    public static let wake: Self = "wake"
    /// Guard: the Iron Giant's eyes go red for ``ActionOptions/hold``, and back.
    public static let defense: Self = "defense"

    /// The actions every character accepts, in a stable order.
    public static let core: [Self] = [.blink, .nod, .shake, .hmm, .laugh, .surprise, .wake, .defense]
}

public struct ActionOptions: Sendable, Hashable {
    /// For actions that hold a pose (`defense`): how long. `nil` takes the character's default.
    public var hold: Duration?

    public init(hold: Duration? = nil) {
        self.hold = hold
    }
}

/// How an action ended.
public enum ActionOutcome: Sendable, Hashable {
    /// It played to its end, or the character was still and had nothing to play it on.
    case completed
    /// Another action cut it short.
    case interrupted
    /// The character does not know this action.
    case unsupported
}

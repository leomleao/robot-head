import Foundation
import Testing
@testable import CharacterKit

@Suite struct VocabularyTests {
    @Test func coreSetsMatchTheTypeScriptOnes() {
        #expect(CharacterState.allCases.map(\.rawValue) == ["idle", "thinking", "searching", "listening", "speaking", "working", "happy", "error", "sleeping"])
        #expect(CharacterExpression.core.map(\.rawValue) == ["neutral", "curious", "happy", "joyful", "sad", "sheepish", "sleepy", "suspicious", "content", "surprised", "afraid", "determined", "angry", "attack", "defense", "peaceful", "asleep"])
        #expect(CharacterAction.core.map(\.rawValue) == ["blink", "nod", "shake", "hmm", "laugh", "surprise", "wake", "defense"])
    }

    @Test func expressionsAreOpenAndCodableAsPlainStrings() throws {
        let custom: CharacterExpression = "binoculars"
        let data = try JSONEncoder().encode([CharacterExpression.happy, custom])
        #expect(String(decoding: data, as: UTF8.self) == #"["happy","binoculars"]"#)
        #expect(try JSONDecoder().decode([CharacterExpression].self, from: data) == [.happy, custom])
    }

    @Test func hexColours() {
        #expect(CharacterColor(hex: "#3c373f")?.hex == "#3c373f")
        #expect(CharacterColor(hex: "fff")?.hex == "#ffffff")
        #expect(CharacterColor(hex: "#12345") == nil)
        #expect(CharacterColor(hex: "red") == nil)
    }
}

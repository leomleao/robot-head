import Testing
@testable import IronGiant

@Suite struct ModelDataTests {
    @Test func modelIsPresent() {
        #expect(!ModelData.full.head.pos.isEmpty)
        #expect(!ModelData.low.jaw.tri.isEmpty)
        #expect(ModelData.eyes.count == 2)
    }
}

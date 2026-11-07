import Testing
@testable import Minnas

@Suite struct SmokeTests {
    @Test func defaultModelIsLargeV3() {
        #expect(TranscriptionModel.default == .largeV3)
    }
}

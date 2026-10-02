import Foundation
import Testing
@testable import StandLockCore

@Suite("Language Resolution")
struct LanguageResolutionTests {

    @Test func explicitSelectionWins() {
        #expect(resolveLanguage(selection: "tr", available: ["en", "tr"], systemPreferred: ["en"]) == "tr")
    }

    @Test func unavailableSelectionFallsBackToSystem() {
        #expect(resolveLanguage(selection: "de", available: ["en", "tr"], systemPreferred: ["tr"]) == "tr")
    }

    @Test func systemRegionTagMatchesByLanguageCode() {
        #expect(resolveLanguage(selection: nil, available: ["en", "tr"], systemPreferred: ["tr-TR", "en"]) == "tr")
    }

    @Test func noSystemMatchFallsBackToEnglish() {
        #expect(resolveLanguage(selection: nil, available: ["en", "tr"], systemPreferred: ["ja", "fr"]) == "en")
    }

    @Test func emptyAvailableFallsBackToEnglish() {
        #expect(resolveLanguage(selection: nil, available: [], systemPreferred: ["tr"]) == "en")
    }

    @Test func selectionWithRegionTagMatchesByLanguageCode() {
        #expect(resolveLanguage(selection: "tr-TR", available: ["en", "tr"], systemPreferred: ["en"]) == "tr")
    }

    @Test func simplifiedChineseRegionMatchesHans() {
        let available = ["en", "tr", "zh-Hans"]
        #expect(resolveLanguage(selection: nil, available: available, systemPreferred: ["zh-Hans-CN"]) == "zh-Hans")
        #expect(resolveLanguage(selection: nil, available: available, systemPreferred: ["zh-CN", "en"]) == "zh-Hans")
        #expect(resolveLanguage(selection: "zh-Hans", available: available, systemPreferred: ["en"]) == "zh-Hans")
    }

    @Test func traditionalChineseDoesNotMatchHans() {
        let available = ["en", "tr", "zh-Hans"]
        #expect(resolveLanguage(selection: nil, available: available, systemPreferred: ["zh-Hant-TW", "en"]) == "en")
        #expect(resolveLanguage(selection: nil, available: available, systemPreferred: ["zh-TW"]) == "en")
        #expect(resolveLanguage(selection: "zh-Hant", available: available, systemPreferred: ["tr"]) == "tr")
    }
}

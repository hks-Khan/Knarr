import Testing
import KnarrCore
@testable import KnarrUI

/// The header meters are labeled ("Claude 76%"), never a bare "~76%": the number, the bar and the warning come from the headline.
@MainActor struct UsageMeterTests {
    @Test func aHeadlineFillsItsShare() {
        let parsed = UsageMeter.parse(headline: "76%")
        #expect(parsed.value == "76%")
        #expect(parsed.fraction == 0.76)
        #expect(!parsed.stale)
    }

    @Test func anOldReadingKeepsTheNumberAndDropsTheTilde() {
        let parsed = UsageMeter.parse(headline: "~43%")
        #expect(parsed.value == "43%")
        #expect(parsed.fraction == 0.43)
        #expect(parsed.stale)
    }

    @Test func aMissingOrResetReadingHasNoBar() {
        for headline in ["--", "초기화"] {
            let parsed = UsageMeter.parse(headline: headline)
            #expect(parsed.value == headline)
            #expect(parsed.fraction == nil)
        }
    }

    @Test func aProviderNearItsLimitWarns() {
        #expect(UsageMeter.provider("Claude", headline: "20%").warn)
        #expect(!UsageMeter.provider("Claude", headline: "21%").warn)
        #expect(!UsageMeter.provider("Codex", headline: "--").warn)
    }

    @Test func contextWarnsWhenAlmostFull() throws {
        func meter(_ tokens: Double) throws -> UsageMeter {
            let usage = try #require(ContextUsage(state: .object(["contextUsage": .object(["tokens": .number(tokens), "contextWindow": .number(100_000)])])))
            return UsageMeter.context(usage)
        }
        let full = try meter(98_000)
        #expect(full.label == "컨텍스트" && full.value == "98%" && full.warn)
        #expect(try !meter(85_000).warn)
    }
}

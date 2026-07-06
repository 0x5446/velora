import Testing
@testable import Velora

@Test func defaultWarmLatencyBudgetsPass() {
    let reports = LatencyBudget.defaultScenarios.map(LatencyBudget.report)
    let allWarmPathsPass = reports.allSatisfy { $0.passesWarmPath }

    #expect(allWarmPathsPass)
}

@Test func defaultColdPathsDoNotPassAsNormalInputPath() {
    let reports = LatencyBudget.defaultScenarios.map(LatencyBudget.report)
    let allColdPathsFail = reports.allSatisfy { !$0.passesColdPath }

    #expect(allColdPathsFail)
}

@Test func macTranslateBudgetKeepsReleasePathUnderTarget() throws {
    let scenario = try #require(
        LatencyBudget.defaultScenarios.first { $0.name == "macos_translate_fast_path" }
    )

    let report = LatencyBudget.report(for: scenario)

    #expect(report.estimatedP50MS == 864)
    #expect(report.estimatedP95MS == 1_264)
    #expect(report.estimatedP50MS <= report.targetP50MS)
    #expect(report.estimatedP95MS <= report.targetP95MS)
    #expect(report.criticalPathMS["compose_bilingual"] == 420)
}

@Test func macInputBudgetKeepsReleasePathUnderTarget() throws {
    let scenario = try #require(
        LatencyBudget.defaultScenarios.first { $0.name == "macos_input_fast_path" }
    )

    let report = LatencyBudget.report(for: scenario)

    #expect(report.estimatedP50MS <= 800)
    #expect(report.estimatedP95MS <= 1_300)
    #expect(report.criticalPathMS["compose"] == 250)
}

@Test func preReleaseWorkIncludesContextHotwordsAndStreamingASR() {
    let preReleaseNames = Set(LatencyBudget.commonPreReleaseStages.map(\.name))

    #expect(preReleaseNames.contains("context_capture"))
    #expect(preReleaseNames.contains("hotword_rank"))
    #expect(preReleaseNames.contains("streaming_asr_partial"))
    #expect(preReleaseNames.contains("speculative_compose"))
}

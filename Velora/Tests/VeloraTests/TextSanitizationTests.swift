import Foundation
import Testing
@testable import Velora

@Test func textSanitizerRemovesTerminalControlCharacters() {
    let text = "abc\u{0}def\u{1B}[31m red\u{7F}\nnext"

    #expect(VeloraTextSanitizer.contextText(text) == "abc def [31m red \nnext")
    #expect(VeloraTextSanitizer.promptPhrase(text) == "abc def [31m red next")
    #expect(VeloraTextSanitizer.containsProcessUnsafeCharacters(text))
}

#if os(macOS)
@Test func localProcessRejectsUnsafeExecutablePathBeforeLaunch() async throws {
    do {
        _ = try await LocalProcess.run(executablePath: "/bin/echo\u{0}", arguments: [])
        Issue.record("Expected invalid executable path to throw.")
    } catch PipelineError.asrUnavailable(let reason) {
        #expect(reason == "local_process_invalid_executable")
    }
}

@Test func localProcessRejectsUnsafeArgumentsBeforeLaunch() async throws {
    do {
        _ = try await LocalProcess.run(executablePath: "/bin/echo", arguments: ["hello\u{0}world"])
        Issue.record("Expected invalid argument to throw.")
    } catch PipelineError.asrUnavailable(let reason) {
        #expect(reason == "local_process_invalid_argument")
    }
}

@Test func localProcessDropsUnsafeEnvironmentEntries() async throws {
    let result = try await LocalProcess.run(
        executablePath: "/usr/bin/env",
        arguments: [],
        environment: [
            "VELORA_TEST_ENV": "ok",
            "BAD\u{0}KEY": "key",
            "BAD_VALUE": "a\u{0}b",
        ]
    )

    #expect(result.exitCode == 0)
    #expect(result.standardOutput.contains("VELORA_TEST_ENV=ok"))
    #expect(!result.standardOutput.contains("BAD_VALUE="))
}
#endif

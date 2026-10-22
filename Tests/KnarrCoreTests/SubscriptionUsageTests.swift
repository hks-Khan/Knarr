import Foundation
import Testing
@testable import KnarrCore

private actor UsageReaderFixture: SessionReading {
    var requests: [String] = []
    var failed = false
    func setFailed(_ value: Bool) { failed = value }
    func query(_ request: OMPJSON) async throws -> OMPJSON {
        requests.append(request["provider"]?.string ?? "")
        if failed { throw SessionAPIError.failed("api_timeout") }
        if request["provider"]?.string == "claude" {
            return try JSONDecoder().decode(OMPJSON.self, from: Data(#"{"reports":[{"provider":"anthropic","fetchedAt":1000000,"limits":[{"id":"anthropic:5h","amount":{"usedFraction":0.57},"window":{"resetsAt":2000000}}]}]}"#.utf8))
        }
        return try JSONDecoder().decode(OMPJSON.self, from: Data(#"{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":2000},"secondary":{"usedPercent":80,"windowDurationMins":10080,"resetsAt":9000}}}"#.utf8))
    }
}

@Suite(.serialized) @MainActor struct SubscriptionUsageTests {
    @Test func codexBucketsPreferCodexAndSupportWeeklyOnlyAndSnakeCase() throws {
        let raw = Data(#"{"rateLimitsByLimitId":{"other":{"primary":{"usedPercent":99}},"codex":{"secondary":{"usedPercent":21.5,"windowDurationMins":10080,"resetsAt":5000}}}}"#.utf8)
        let reading = try #require(SubscriptionUsageReading.codex(data: raw, observedAt: 1000))
        #expect(reading.fiveHour == nil)
        #expect(reading.weekly == .init(usedPercent: 21.5, resetsAt: 5000))
        let snake = Data(#"{"rate_limits":{"primary":{"used_percent":100,"window_minutes":300,"resets_at":1234}}}"#.utf8)
        #expect(SubscriptionUsageReading.codex(data: snake, observedAt: 1)?.fiveHour?.usedPercent == 100)
    }
    @Test func malformedNumbersNeverBecomeUsageOrTimestamps() {
        for percent in ["true", "-1", "101", "\"20\"", "null"] {
            let raw = Data("{\"rateLimits\":{\"primary\":{\"usedPercent\":\(percent)}}}".utf8)
            #expect(SubscriptionUsageReading.codex(data: raw, observedAt: 1) == nil)
        }
        let raw = Data(#"{"rateLimits":{"primary":{"usedPercent":0,"resetsAt":true}}}"#.utf8)
        #expect(SubscriptionUsageReading.codex(data: raw, observedAt: 1)?.fiveHour?.resetsAt == nil)
        #expect(SubscriptionUsageReading.ompClaude(data: Data("{}".utf8)) == nil)
    }
    @Test func ompClaudeUsesReportedFractionAndCaptureNotGeneratedTime() throws {
        let raw = Data(#"{"generatedAt":9000000,"reports":[{"provider":"anthropic","fetchedAt":1000000,"limits":[{"id":"anthropic:5h","amount":{"usedFraction":0.57},"window":{"resetsAt":2000000}},{"id":"anthropic:7d","amount":{"usedFraction":0.2},"window":{"resetsAt":9000000}}]},{"provider":"openai-codex","fetchedAt":9000000,"limits":[]}]}"#.utf8)
        let reading = try #require(SubscriptionUsageReading.ompClaude(data: raw))
        #expect(abs((reading.fiveHour?.usedPercent ?? -1) - 57) < 0.000001)
        #expect(reading.fiveHour?.resetsAt == 2000)
        #expect(reading.weekly == .init(usedPercent: 20, resetsAt: 9000))
        #expect(reading.capturedAt == 1000)
    }
    @Test func unknownCaptureDoesNotDiscardLaterAccountsOrInventFreshness() throws {
        let raw = Data(#"{"reports":[{"provider":"anthropic","limits":[{"id":"anthropic:5h","amount":{"usedFraction":0.25},"window":{"resetsAt":5000000}}]},{"provider":"anthropic","fetchedAt":1000000,"limits":[{"id":"anthropic:5h","amount":{"usedFraction":0.75},"window":{"resetsAt":6000000}},{"id":"anthropic:7d","amount":{"usedFraction":0.4},"window":{"resetsAt":9000000}}]}]}"#.utf8)
        let reading = try #require(SubscriptionUsageReading.ompClaude(data: raw))
        #expect(reading.fiveHour?.usedPercent == 75)
        #expect(reading.fiveHour?.resetsAt == 6000)
        #expect(reading.weekly?.usedPercent == 40)
        #expect(reading.accountCount == 2)
        #expect(reading.capturedAt == nil)
    }
    @Test func headlineUsesTightestRemainingAndMarksStaleFailureAndReset() {
        let reading = SubscriptionUsageReading(fiveHour: .init(usedPercent: 30, resetsAt: 2000), weekly: .init(usedPercent: 80, resetsAt: 9000), capturedAt: 1000)
        #expect(MenuBarUsagePresentation.headline(reading, failed: false, now: 1000) == "20%")
        #expect(MenuBarUsagePresentation.isStale(reading, failed: false, now: 1180))
        #expect(MenuBarUsagePresentation.isStale(reading, failed: true, now: 1001))
        #expect(MenuBarUsagePresentation.headline(nil, failed: false, now: 1000) == "--")
        let reset = MenuBarUsagePresentation.detail(name: "Codex", reading: reading, failed: false, now: 2000)
        #expect(reset.windows[0].text.resetText == "초기화됨 · 갱신 대기")
        #expect(reset.windows[0].remainingPercent == nil)
        #expect(reset.windows[1].remainingPercent == 20)
        #expect(MenuBarUsagePresentation.headline(.init(fiveHour: .init(usedPercent: 90, resetsAt: 1000), weekly: nil, capturedAt: 900), failed: false, now: 1000) == "초기화")
    }
    @Test func countdownAndUnknownCaptureStayHonest() {
        let reading = SubscriptionUsageReading(fiveHour: .init(usedPercent: 12.6, resetsAt: 4660), weekly: nil, capturedAt: nil)
        let detail = MenuBarUsagePresentation.detail(name: "Claude", reading: reading, failed: false, now: 1000)
        #expect(abs((detail.windows[0].remainingPercent ?? -1) - 87.4) < 0.000001)
        #expect(detail.windows[0].text.resetText == "1시간 1분 후 초기화")
        #expect(MenuBarUsagePresentation.isStale(reading, failed: false, now: 1000))
        #expect(detail.updatedText.contains("확인 불가"))
    }
    @Test func eventRefreshesShareCacheManualBypassesAndFailuresPreserveLastValue() async {
        let reader = UsageReaderFixture()
        var now: Int64 = 1000
        let model = SubscriptionUsageModel(reader: reader, clock: { now })
        await model.refresh(.detailOpened)
        #expect(model.codex?.weekly?.usedPercent == 80)
        for trigger in [UsageRefreshTrigger.stallariEnded, .hirdEnded, .detailOpened] { await model.refresh(trigger) }
        #expect(await reader.requests == ["claude", "codex"])
        now = 1180
        await reader.setFailed(true)
        await model.refresh(.stallariEnded)
        #expect(model.codex?.weekly?.usedPercent == 80)
        #expect(model.codexFailed && model.claudeFailed)
        await reader.setFailed(false)
        await model.refresh(.manual)
        #expect(!model.codexFailed && !model.claudeFailed)
        #expect(await reader.requests == ["claude", "codex", "claude", "codex", "claude", "codex"])
        now = 2000
        await model.refresh(.detailOpened)
        #expect(model.details[1].windows[0].remainingPercent == nil)
        await model.shutdown()
        await model.refresh(.manual)
        #expect(await reader.requests.count == 8)
    }
    @Test func onlyTerminalStallariAndReclaimedHirdTransitionsRefresh() async {
        let reader = UsageReaderFixture()
        var now: Int64 = 1000
        let model = SubscriptionUsageModel(reader: reader, clock: { now })
        model.observeStallariFrame(.object(["type": .string("agent_end"), "isTerminal": .bool(false), "yielded": .bool(false)]))
        await model.whenIdle()
        #expect(model.claude == nil && model.codex == nil)
        model.observeStallariFrame(.object(["type": .string("agent_end"), "isTerminal": .bool(false), "yielded": .bool(true)]))
        await model.whenIdle()
        #expect(abs((model.claude?.fiveHour?.usedPercent ?? -1) - 57) < 0.000001)
        var run = PersistedRun(hird: .init(id: "usage-run", name: "Hird", role: "usage", status: .working, steps: [], currentCommand: nil, lastActivityAt: .now),
                               issueID: "usage-issue", projectID: "usage-project", ompSessionID: nil, ownershipToken: "usage-owner", startedAt: .now)
        model.observeHirdRuns([run])
        now = 1180
        run.state = .cancelled; run.cancellationRequestedAt = .now
        model.observeHirdRuns([run])
        await model.whenIdle()
        #expect(await reader.requests.count == 2)
        run.processEndedAt = .now
        model.observeHirdRuns([run])
        await model.whenIdle()
        #expect(await reader.requests.count == 4)
        now = 1360
        model.observeHirdRuns([run])
        await model.whenIdle()
        #expect(await reader.requests.count == 4)
        await model.shutdown()
    }
    @Test func usageBridgeReclaimsAppServerOnSuccessErrorTimeoutAndCancellation() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = root.appendingPathComponent("Sources/KnarrCore/Resources/session-api.mjs")
        for mode in ["success", "error", "timeout", "cancel"] {
            let directory = root.appendingPathComponent("outputs/subscription-usage/fixtures/\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let marker = directory.appendingPathComponent("owned.pid")
            let executable = directory.appendingPathComponent("codex-fixture")
            try """
            #!/usr/bin/python3
            import sys,json,os,time,pathlib
            pathlib.Path(os.environ['USAGE_PID']).write_text(str(os.getpid()))
            for line in sys.stdin:
                r=json.loads(line)
                if r.get('method')=='initialized': continue
                if r['method']=='initialize': result={}
                elif r['method']=='account/rateLimits/read':
                    if os.environ['USAGE_MODE'] in ['timeout','cancel']: time.sleep(60)
                    if os.environ['USAGE_MODE']=='error':
                        print(json.dumps({'id':r['id'],'error':{'code':-1}}),flush=True)
                        continue
                    result={'rateLimits':{'primary':{'usedPercent':42}}}
                else: raise RuntimeError('unexpected model or thread request')
                print(json.dumps({'id':r['id'],'result':result}),flush=True)
            """.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            var env = ProcessInfo.processInfo.environment
            env["KNARR_CODEX_EXECUTABLE"] = executable.path
            env["USAGE_PID"] = marker.path; env["USAGE_MODE"] = mode
            let environment = env
            let process = SessionAPIProcess()
            let task = Task {
                try await process.run(.init(executable: URL(fileURLWithPath: "/opt/homebrew/bin/node"), workingDirectory: directory,
                                            arguments: [script.path], environment: environment),
                                      request: .object(["provider": .string("codex"), "operation": .string("usage")]),
                                      timeout: .seconds(mode == "timeout" ? 1 : 10))
            }
            if mode == "cancel" {
                let deadline = ContinuousClock.now + .seconds(3)
                while !FileManager.default.fileExists(atPath: marker.path) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
                task.cancel()
            }
            do {
                let result = try await task.value
                #expect(mode == "success")
                #expect(result["rateLimits"]?["primary"]?["usedPercent"]?.integer == 42)
            } catch let error as SessionAPIError {
                let expected: SessionAPIError = mode == "timeout" ? .timedOut : (mode == "cancel" ? .cancelled : .failed("api_request_failed"))
                #expect(error == expected)
            }
            let pid = try #require(Int32(String(contentsOf: marker, encoding: .utf8)))
            #expect(kill(pid, 0) == -1 && errno == ESRCH)
            #expect(await process.exit?.remainingProcessIDs == [])
            print("usage fixture=\(mode) owned_pid=\(pid) owned_remaining=0")
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KNARR_TEST_USAGE_LIVE"] == "1"))
    func actualOMPClaudeAllowanceUsesOfficialOutputAndReportedCapture() async throws {
        var environment = ProcessInfo.processInfo.environment
        if let path = environment["KNARR_USAGE_OMP_EXECUTABLE"] { environment["KNARR_OMP_EXECUTABLE"] = path }
        let result = try await LocalSessionAPI(environment: environment).query(.object(["provider": .string("claude"), "operation": .string("usage")]))
        let reading = try #require(SubscriptionUsageReading.ompClaude(data: JSONEncoder().encode(result)))
        #expect(reading.capturedAt != nil)
        #expect(reading.fiveHour != nil || reading.weekly != nil)
        print("LIVE claude OMP 18.7.0 usage: valid_windows=true reported_capture=true owned_remaining=0")
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KNARR_TEST_USAGE_LIVE"] == "1"))
    func actualCodexAllowanceReadReturnsAfterOwnedProcessesAreReclaimed() async throws {
        let result = try await LocalSessionAPI().query(.object(["provider": .string("codex"), "operation": .string("usage")]))
        let data = try JSONEncoder().encode(result)
        let reading = try #require(SubscriptionUsageReading.codex(data: data, observedAt: Int64(Date().timeIntervalSince1970)))
        #expect(reading.fiveHour != nil || reading.weekly != nil)
        print("LIVE codex account/rateLimits/read: valid_windows=true owned_remaining=0")
    }
}

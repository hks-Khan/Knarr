import Foundation
import Testing
@testable import KnarrCore

private actor ActivityEvents {
    var states: [HirdActivity] = []
    /// Ordinary progress lines (verification, todo refresh, diagnostics) stay one per event;
    /// the interval only limits activity state writes.
    var lines: [String] = []
    func add(_ update: HirdUpdate) {
        switch update.payload {
        case .activityState(let activity, _): states.append(activity)
        case .activity(let line, _, _): lines.append(line.text)
        default: break
        }
    }
}

@Suite(.serialized) struct HirdActivityTests {
    private static func message(_ event: String) -> OMPJSON {
        .object(["type": .string("message_update"), "messageId": .string("msg"), "message": .object(["role": .string("assistant")]),
                 "assistantMessageEvent": .object(["type": .string(event), "contentIndex": .number(0)])])
    }
    private static func tool(_ name: String, _ call: String, _ args: [String: OMPJSON]) -> OMPJSON {
        .object(["type": .string("tool_execution_start"), "toolName": .string(name), "toolCallId": .string(call), "args": .object(args)])
    }
    private static func barrier(_ f: HirdFixture, _ number: Int) async throws -> PersistenceSnapshot {
        await f.rpc.frame(.object(["type": .string("extension_ui_request"), "id": .string("activity-barrier-\(number)"),
                                  "method": .string("input"), "title": .string("수신 순서 경계")]))
        for _ in 0..<500 {
            let snapshot = try await f.repository.snapshot()
            if snapshot.questions.count == number { return snapshot }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw HirdError.staleRun
    }

    private static func end(_ name: String, _ call: String, exit: Int? = nil) -> OMPJSON {
        var details: [String: OMPJSON] = [:]
        if let exit { details["exitCode"] = .number(Double(exit)) }
        return .object(["type": .string("tool_execution_end"), "toolName": .string(name), "toolCallId": .string(call),
                        "result": .object(["details": .object(details),
                                           "content": .array([.object(["type": .string("text"), "text": .string("OK")])])])])
    }

    @Test func syntheticFramesTurnThinkingReadThinkingEditBashTextIntoOrderedStates() async throws {
        let f = try await HirdFixture.make(), events = ActivityEvents()
        let task = Task { try await f.adapter.start(f.run) { update in
            await events.add(update); return try await f.sink(update)
        } }
        do {
            try await HirdVerificationRetryTests.awaitPrompts(1, f)
            // 생각 → 읽기 → 생각 → 편집 → 명령 → 작성. 도구 시작/종료 프레임을 사이에 둔다.
            await f.rpc.frame(Self.message("thinking_start"))
            let first = try #require(try await Self.barrier(f, 1).runs.first { $0.id == f.run.id }?.hird)
            #expect(first.currentActivity?.kind == .thinking)
            for _ in 0..<5 { await f.rpc.frame(Self.message("thinking_delta")) }
            await f.rpc.frame(Self.tool("read", "r1", ["path": .string("/tmp/work/README.md")]))
            await f.rpc.frame(Self.end("read", "r1"))
            await f.rpc.frame(Self.tool("read", "r2", ["path": .string("/tmp/work/README.md")]))
            let afterRead = try #require(try await Self.barrier(f, 2).runs.first { $0.id == f.run.id }?.hird)
            // 종료 뒤 재시작은 별도 활동이며, 반복 thinking delta만 같은 상태로 합친다.
            #expect(afterRead.recentActivities?.map(\.kind) == [.thinking, .read, .idle, .read])
            #expect(afterRead.currentActivity?.target == "README.md")
            await f.rpc.frame(Self.end("read", "r2"))
            await f.rpc.frame(Self.message("thinking_delta"))
            await f.rpc.frame(Self.tool("edit", "e1", ["path": .string("/tmp/work/Sources/Panel.swift")]))
            await f.rpc.frame(Self.end("edit", "e1"))
            let afterEdit = try #require(try await Self.barrier(f, 3).runs.first { $0.id == f.run.id }?.hird)
            #expect(afterEdit.recentActivities?.map(\.kind) == [.read, .idle, .thinking, .edit, .idle])
            await f.rpc.frame(Self.tool("bash", "b1", ["command": .string("swift test --filter PanelTests")]))
            // 실행 중인 명령은 도구가 끝날 때까지 currentCommand로 남는다.
            let duringBash = try #require(try await Self.barrier(f, 4).runs.first { $0.id == f.run.id }?.hird)
            #expect(duringBash.currentActivity?.displayText == "명령 실행 · swift test --filter PanelTests")
            #expect(duringBash.currentCommand == "swift test --filter PanelTests")
            await f.rpc.frame(Self.end("bash", "b1", exit: 0))
            await f.rpc.frame(Self.message("text_delta"))
            await f.rpc.frame(Self.message("text_end"))
            let settled = try await Self.barrier(f, 5)
            let afterText = try #require(settled.runs.first { $0.id == f.run.id }?.hird)
            // 최근 목록은 5개로 제한되므로 가장 오래된 상태부터 밀려난다.
            #expect(afterText.recentActivities?.map(\.kind) == [.edit, .idle, .command, .idle, .writing])
            #expect(afterText.currentActivity?.kind == .writing)
            #expect(afterText.currentActivity?.displayText == "답변 작성 중")
            let ledger = settled.issues.first?.events.map(\.text).filter {
                ["생각 중", "답변 작성 중"].contains($0) || $0.hasPrefix("읽는 중") || $0.hasPrefix("편집 중") || $0.hasPrefix("명령 실행")
            } ?? []
            #expect(ledger == ["생각 중", "읽는 중 · README.md", "읽는 중 · README.md", "생각 중", "편집 중 · Panel.swift", "명령 실행 · swift test --filter PanelTests", "답변 작성 중"])
            #expect(await events.states.map(\.kind) == [.thinking, .read, .idle, .read, .idle, .thinking, .edit, .idle, .command, .idle, .writing])
            #expect(first.lastActivityAt < afterText.lastActivityAt)
            await f.adapter.cancel(f.run.id); _ = await task.result
            try await f.cleanup()
        } catch {
            await f.adapter.cancel(f.run.id); _ = await task.result
            try await f.cleanup(); throw error
        }
    }

    /// Drives the same six-transition burst through one adapter and returns every activity row.
    private static func burst(_ f: HirdFixture, _ events: ActivityEvents) async throws -> (page: Int, rows: [String]) {
        await f.rpc.frame(message("thinking_start"))
        await f.rpc.frame(tool("read", "r1", ["path": .string("/tmp/work/A.swift")]))
        await f.rpc.frame(tool("edit", "e1", ["path": .string("/tmp/work/B.swift")]))
        await f.rpc.frame(tool("grep", "g1", ["pattern": .string("needle")]))
        await f.rpc.frame(tool("bash", "b1", ["command": .string("swift build")]))
        await f.rpc.frame(message("text_delta"))
        let snapshot = try await barrier(f, 1)
        return (snapshot.issues.first?.events.count ?? 0, snapshot.issues.first?.events.map(\.text) ?? [])
    }

    @Test func rapidAlternatingStatesWriteAtMostOncePerIntervalAndKeepTheLastOne() async throws {
        let f = try await HirdFixture.make(activityInterval: 0.5), events = ActivityEvents()
        let task = Task { try await f.adapter.start(f.run) { update in
            await events.add(update); return try await f.sink(update)
        } }
        func activityRows(_ snapshot: PersistenceSnapshot) -> [String] {
            snapshot.issues.first?.events.map(\.text).filter {
                ["생각 중", "답변 작성 중"].contains($0) || $0.hasPrefix("읽는 중") || $0.hasPrefix("편집 중")
                    || $0.hasPrefix("검색 중") || $0.hasPrefix("명령 실행") || $0.hasPrefix("하위 작업")
            } ?? []
        }
        do {
            try await HirdVerificationRetryTests.awaitPrompts(1, f)
            // 6개의 서로 다른 상태가 간격 안에서 연달아 도착한다.
            await f.rpc.frame(Self.message("thinking_start"))
            await f.rpc.frame(Self.tool("read", "r1", ["path": .string("/tmp/work/A.swift")]))
            await f.rpc.frame(Self.tool("edit", "e1", ["path": .string("/tmp/work/B.swift")]))
            await f.rpc.frame(Self.tool("grep", "g1", ["pattern": .string("needle")]))
            await f.rpc.frame(Self.tool("bash", "b1", ["command": .string("swift build")]))
            await f.rpc.frame(Self.message("text_delta"))
            let burst = try await Self.barrier(f, 1)
            // 간격 안에서는 첫 상태만 기록되고 나머지는 보류된다.
            #expect(activityRows(burst).count <= 2)
            // 진행·검증 이벤트는 간격 제한 대상이 아니다: 활동 상태만 간격으로 묶인다.
            let progressLines = await events.lines
            #expect(progressLines.allSatisfy { !$0.contains("생각 중") && !$0.contains("답변 작성 중") })
            let last = "답변 작성 중"
            // 간격이 끝나면 마지막 상태가 반드시 기록된다(trailing flush), 그 사이 추가 쓰기는 없다.
            var settled = burst
            for _ in 0..<100 {
                settled = try await f.repository.snapshot()
                if settled.runs.first?.hird.currentActivity?.kind == .writing { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(settled.runs.first { $0.id == f.run.id }?.hird.currentActivity?.displayText == last)
            #expect(activityRows(settled).count <= 2)
            #expect(activityRows(settled).last == last)
            // 같은 프레임 폭주를 제한 없는 어댑터에 보내면 모든 전환이 각각 기록된다.
            // 간격 제한이 사라지면 두 경우의 행 수가 같아져 이 비교가 깨진다.
            let control = try await HirdFixture.make(activityInterval: 0)
            let controlTask = Task { try await control.adapter.start(control.run) { update in
                await events.add(update); return try await control.sink(update)
            } }
            do {
                try await HirdVerificationRetryTests.awaitPrompts(1, control)
                let unthrottled = try await Self.burst(control, events)
                #expect(activityRows(try await control.repository.snapshot()).count > activityRows(settled).count)
                #expect(unthrottled.rows.contains("답변 작성 중"))
                await control.adapter.cancel(control.run.id); _ = await controlTask.result
                try await control.cleanup()
            } catch {
                await control.adapter.cancel(control.run.id); _ = await controlTask.result
                try await control.cleanup(); throw error
            }
            // 간격이 지난 뒤의 전환은 즉시 반영된다.
            await f.rpc.frame(Self.tool("read", "r9", ["path": .string("/tmp/work/C.swift")]))
            var immediate = settled
            for _ in 0..<100 {
                immediate = try await f.repository.snapshot()
                if immediate.runs.first?.hird.currentActivity?.target == "C.swift" { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(immediate.runs.first { $0.id == f.run.id }?.hird.currentActivity?.displayText == "읽는 중 · C.swift")
            let countBeforeCancel = activityRows(immediate).count
            await f.adapter.cancel(f.run.id); _ = await task.result
            // 취소는 보류 상태와 예약 타이머를 남기지 않는다.
            try await Task.sleep(for: .milliseconds(700))
            #expect(activityRows(try await f.repository.snapshot()).count == countBeforeCancel)
            try await f.cleanup()
        } catch {
            await f.adapter.cancel(f.run.id); _ = await task.result
            try await f.cleanup(); throw error
        }
    }

    @Test func cancelAndCompletionDoNotLeaveAQueuedActivityWrite() async throws {
        let f = try await HirdFixture.make(activityInterval: 2), events = ActivityEvents()
        let task = Task { try await f.adapter.start(f.run) { update in
            await events.add(update); return try await f.sink(update)
        } }
        do {
            try await HirdVerificationRetryTests.awaitPrompts(1, f)
            await f.rpc.frame(Self.message("thinking_start"))
            await f.rpc.frame(Self.tool("read", "r1", ["path": .string("/tmp/work/A.swift")]))
            await f.rpc.frame(Self.tool("edit", "e1", ["path": .string("/tmp/work/B.swift")]))
            _ = try await Self.barrier(f, 1)
            let before = try await f.repository.snapshot()
            #expect(before.runs.first?.hird.currentActivity?.kind == .thinking)
            func activityRows(_ snapshot: PersistenceSnapshot) -> [String] {
                snapshot.issues.first?.events.map(\.text).filter {
                    ["생각 중", "답변 작성 중"].contains($0) || $0.hasPrefix("읽는 중") || $0.hasPrefix("편집 중")
                        || $0.hasPrefix("검색 중") || $0.hasPrefix("명령 실행") || $0.hasPrefix("하위 작업")
                } ?? []
            }
            await f.adapter.cancel(f.run.id)
            _ = await task.result
            // 취소는 보류 상태와 예약 flush를 버린다. 간격이 지나도 새 행이 생기지 않는다.
            try await Task.sleep(for: .milliseconds(2500))
            let after = try await f.repository.snapshot()
            #expect(after.runs.first?.hird.currentActivity?.kind == .thinking)
            // 취소 자체의 원장 행은 늘 수 있지만, 보류된 활동 행은 추가되지 않는다.
            #expect(activityRows(after) == activityRows(before))
            #expect(activityRows(after) == ["생각 중"])
            #expect(await events.states.map(\.kind) == [.thinking])
            #expect(await f.adapter.terminationConfirmed(f.run.id))
            try await f.cleanup()
        } catch {
            await f.adapter.cancel(f.run.id); _ = await task.result
            try await f.cleanup(); throw error
        }
    }

    @Test func completionFlushesTheHeldBackStateBeforeArchiving() async throws {
        let f = try await HirdFixture.make(activityInterval: 2), events = ActivityEvents()
        let task = Task { try await f.adapter.start(f.run) { update in
            await events.add(update); return try await f.sink(update)
        } }
        do {
            try await HirdVerificationRetryTests.awaitPrompts(1, f)
            await f.rpc.frame(Self.message("thinking_start"))
            await f.rpc.frame(Self.tool("read", "r1", ["path": .string("/tmp/work/A.swift")]))
            // Prompt completion arrives inside the interval; the pending read state must still land.
            await f.rpc.frame(HirdVerificationRetryTests.end(1))
            var snapshot = try await f.repository.snapshot()
            for _ in 0..<200 {
                snapshot = try await f.repository.snapshot()
                if snapshot.runs.first?.hird.currentActivity?.kind == .read { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(snapshot.runs.first { $0.id == f.run.id }?.hird.currentActivity?.displayText == "읽는 중 · A.swift")
            #expect(snapshot.issues.first?.events.contains { $0.text == "읽는 중 · A.swift" } == true)
            await f.adapter.cancel(f.run.id); _ = await task.result
            try await f.cleanup()
        } catch {
            await f.adapter.cancel(f.run.id); _ = await task.result
            try await f.cleanup(); throw error
        }
    }

    @Test func coalescerKeepsTheNewestStateAndNeverWritesTwicePerInterval() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var pacer = HirdActivityCoalescer(interval: 1)
        let thinking = HirdActivity(kind: .thinking, at: start)
        let read = HirdActivity(kind: .read, target: "A.swift", at: start)
        let edit = HirdActivity(kind: .edit, target: "B.swift", at: start)
        // 첫 상태는 즉시 기록된다.
        #expect(pacer.offer(thinking, at: start)?.kind == .thinking)
        // 같은 상태의 반복 delta는 아무것도 만들지 않는다.
        #expect(pacer.offer(thinking, at: start.addingTimeInterval(0.1)) == nil)
        #expect(pacer.pending == nil)
        // 간격 안의 새 상태는 보류되고, 더 새 상태가 오면 그것으로 대체된다.
        #expect(pacer.offer(read, at: start.addingTimeInterval(0.2)) == nil)
        #expect(pacer.offer(edit, at: start.addingTimeInterval(0.3)) == nil)
        #expect(pacer.pending?.kind == .edit)
        #expect(pacer.deadline == start.addingTimeInterval(1))
        // 대기 중 반복은 그대로 하나의 보류 상태다.
        #expect(pacer.offer(edit, at: start.addingTimeInterval(0.4)) == nil)
        #expect(pacer.pending?.kind == .edit)
        // 다시 기록된 상태로 돌아오면 보류 상태는 낡은 것이므로 버린다.
        #expect(pacer.offer(thinking, at: start.addingTimeInterval(0.45)) == nil)
        #expect(pacer.pending == nil)
        // 간격이 끝나면 보류된 최신 상태를 쓴다.
        #expect(pacer.offer(read, at: start.addingTimeInterval(0.9)) == nil)
        #expect(pacer.flush(at: start.addingTimeInterval(1))?.kind == .read)
        #expect(pacer.flush(at: start.addingTimeInterval(1.2)) == nil)
        #expect(pacer.offer(edit, at: start.addingTimeInterval(1.05)) == nil)
        #expect(pacer.pending?.kind == .edit)
        #expect(pacer.flush(at: start.addingTimeInterval(1.5))?.kind == .edit)
        // 질문 대기는 사람이 기다리는 상태라 간격을 기다리지 않는다.
        #expect(pacer.offer(HirdActivity(kind: .waitingQuestion, at: start), at: start.addingTimeInterval(1.1))?.kind == .waitingQuestion)
        #expect(pacer.offer(read, at: start.addingTimeInterval(1.15)) == nil)
        pacer.discardPending()
        #expect(pacer.pending == nil)
        #expect(pacer.flush(at: start) == nil)
        #expect(pacer.interval == 1)
    }

    @Test func repeatedDeltasAndTheSameToolDoNotAddRecordsOrRefreshSilence() async throws {
        let f = try await HirdFixture.make(), events = ActivityEvents()
        let task = Task { try await f.adapter.start(f.run) { update in
            await events.add(update); return try await f.sink(update)
        } }
        do {
            try await HirdVerificationRetryTests.awaitPrompts(1, f)
            await f.rpc.frame(Self.message("thinking_start"))
            _ = try #require(try await Self.barrier(f, 1).runs.first { $0.id == f.run.id }?.hird)
            try await Task.sleep(for: .milliseconds(30))
            for _ in 0..<20 { await f.rpc.frame(Self.message("thinking_delta")) }
            await f.rpc.frame(Self.tool("read", "r1", ["path": .string("/tmp/work/README.md")]))
            await f.rpc.frame(Self.tool("read", "r2", ["path": .string("/tmp/work/README.md")]))
            let settled = try await Self.barrier(f, 2)
            let afterRead = try #require(settled.runs.first { $0.id == f.run.id }?.hird)
            #expect(afterRead.recentActivities?.map(\.kind) == [.thinking, .read])
            // 같은 read 호출과 같은 상태의 delta는 새 행도, 새 시각도 만들지 않는다.
            try await Task.sleep(for: .milliseconds(30))
            await f.rpc.frame(Self.tool("read", "r3", ["path": .string("/tmp/work/README.md")]))
            for _ in 0..<10 { await f.rpc.frame(Self.message("thinking_delta")) }
            // thinking deltas are a real transition away from read, so only the repeat read is inert.
            let third = try await Self.barrier(f, 3)
            let hird = try #require(third.runs.first { $0.id == f.run.id }?.hird)
            #expect(hird.recentActivities?.map(\.kind) == [.thinking, .read, .thinking])
            let ledger = third.issues.first?.events.filter { $0.text == "생각 중" || $0.text.hasPrefix("읽는 중") } ?? []
            #expect(ledger.count == 3)
            #expect(ledger.filter { $0.text.hasPrefix("읽는 중") }.count == 1)
            #expect(await events.states.count == 3)
            #expect(afterRead.currentActivity?.target == "README.md")
            await f.adapter.cancel(f.run.id); _ = await task.result
            try await f.cleanup()
        } catch {
            await f.adapter.cancel(f.run.id); _ = await task.result
            try await f.cleanup(); throw error
        }
    }

    /// Polls the saved run until `condition` holds, so a state is observed without inserting a
    /// question (the barrier helper would flip the run to waiting on a person).
    private static func waitFor(_ f: HirdFixture, _ label: String,
                                _ condition: (HirdRun) -> Bool) async throws -> HirdRun {
        for _ in 0..<300 {
            if let hird = try await f.repository.snapshot().runs.first(where: { $0.id == f.run.id })?.hird,
               condition(hird) { return hird }
            try await Task.sleep(for: .milliseconds(10))
        }
        let hird = try #require(try await f.repository.snapshot().runs.first { $0.id == f.run.id }?.hird)
        Issue.record("상태가 \(label)(으)로 바뀌지 않았어요: \(hird.activityLine(now: .now).displayText)")
        return hird
    }

    private static func lifecycle(_ id: String, _ status: String) -> OMPJSON {
        .object(["type": .string("subagent_lifecycle"), "payload": .object([
            "id": .string(id), "index": .number(0), "agent": .string("task"), "agentSource": .string("builtin"),
            "name": .string(id), "status": .string(status), "parentToolCallId": .string("spawn")])])
    }

    @Test func reasoningTextIsNeverStoredAndQuestionsAndChildrenTurnIntoLines() async throws {
        let f = try await HirdFixture.make(), events = ActivityEvents()
        let task = Task { try await f.adapter.start(f.run) { update in
            await events.add(update); return try await f.sink(update)
        } }
        do {
            try await HirdVerificationRetryTests.awaitPrompts(1, f)
            let secret = "내부 추론 원문입니다"
            // A thinking delta carries its text in the frame; none of it may reach storage.
            await f.rpc.frame(.object(["type": .string("message_update"), "messageId": .string("msg"),
                "message": .object(["role": .string("assistant")]),
                "assistantMessageEvent": .object(["type": .string("thinking_delta"), "contentIndex": .number(0),
                                                  "delta": .string(secret), "thinking": .string(secret)])]))
            _ = try await Self.waitFor(f, "생각 중") { $0.currentActivity?.kind == .thinking }
            // 하위 작업 두 개가 시작되면 개수 상태가 되고, 하나가 끝나면 1개로 줄어든다.
            await f.rpc.frame(Self.lifecycle("child-a", "started"))
            await f.rpc.frame(Self.lifecycle("child-b", "started"))
            let two = try await Self.waitFor(f, "하위 작업 2개") { $0.currentActivity?.count == 2 }
            #expect(two.currentActivity?.displayText == "하위 작업 2개")
            #expect(two.currentCommand == "하위 작업 2개 진행 중")
            await f.rpc.frame(Self.lifecycle("child-a", "completed"))
            let one = try await Self.waitFor(f, "하위 작업 1개") { $0.currentActivity?.count == 1 }
            #expect(one.currentActivity?.displayText == "하위 작업 1개")
            #expect(one.currentCommand == "하위 작업 1개 진행 중")
            // 질문이 오면 사람을 기다리는 상태가 다른 상태보다 우선한다.
            await f.rpc.frame(.object(["type": .string("extension_ui_request"), "id": .string("activity-question"),
                                       "method": .string("select"), "title": .string("어느 쪽으로 갈까요"),
                                       "options": .array([.string("A"), .string("B")])]))
            let asked = try await Self.waitFor(f, "질문 대기") {
                if case .waitingOnHuman = $0.status { return true }
                return false
            }
            #expect(asked.activityLine(now: .now).displayText == "질문 답변 대기")
            let snapshot = try await f.repository.snapshot()
            // 생각 본문은 이벤트·활동 원장·저장된 활동 어디에도 남지 않는다.
            let stored = [
                snapshot.issues.first?.events.map { $0.text + "|" + ($0.detail ?? "") }.joined(separator: "\n") ?? "",
                asked.recentActivities?.compactMap(\.target).joined(separator: "\n") ?? "",
                String(decoding: try JSONEncoder().encode(asked), as: UTF8.self)
            ].joined(separator: "\n")
            #expect(!stored.contains(secret))
            #expect(await events.states.allSatisfy { $0.kind != .writing })
            await f.adapter.cancel(f.run.id); _ = await task.result
            try await f.cleanup()
        } catch {
            await f.adapter.cancel(f.run.id); _ = await task.result
            try await f.cleanup(); throw error
        }
    }

    @Test func toolCompletionRestoresTheRemainingActivityWithoutAnotherPrompt() async throws {
        let f = try await HirdFixture.make(activityInterval: 0)
        let task = Task { try await f.adapter.start(f.run, emit: f.sink) }
        do {
            try await HirdVerificationRetryTests.awaitPrompts(1, f)
            await f.rpc.frame(Self.tool("read", "still-reading", ["path": .string("/tmp/task/Panel.swift")]))
            await f.rpc.frame(Self.tool("grep", "search-1", ["pattern": .string("progress")]))
            _ = try await Self.barrier(f, 1)
            await f.rpc.frame(Self.end("grep", "search-1"))
            let remaining = try #require(try await Self.barrier(f, 2).runs.first { $0.id == f.run.id }?.hird)
            #expect(remaining.currentActivity?.kind == .read)
            #expect(remaining.currentActivity?.target == "Panel.swift")
            await f.rpc.frame(Self.end("read", "still-reading"))
            let ended = try #require(try await Self.barrier(f, 3).runs.first { $0.id == f.run.id }?.hird)
            #expect(ended.currentActivity?.kind == .idle)
            #expect(ended.currentCommand == nil)
            await f.rpc.frame(Self.tool("grep", "search-2", ["pattern": .string("progress")]))
            let restarted = try #require(try await Self.barrier(f, 4).runs.first { $0.id == f.run.id }?.hird)
            #expect(restarted.currentActivity?.kind == .search)
            #expect(await f.rpc.requests.filter { $0.0 == "prompt" }.count == 1)
            await f.adapter.cancel(f.run.id); _ = await task.result
            try await f.cleanup()
        } catch {
            await f.adapter.cancel(f.run.id); _ = await task.result
            try await f.cleanup(); throw error
        }
    }

    @Test func toolStatesBecomeOneHumanLineEach() {
        func line(_ name: String, _ arguments: [String: OMPJSON]) -> String {
            HirdActivity.tool(name, arguments: .object(arguments), at: .now).displayText
        }
        #expect(HirdActivity(kind: .thinking).displayText == "생각 중")
        #expect(HirdActivity(kind: .writing).displayText == "답변 작성 중")
        #expect(line("read", ["path": .string("/a/b/c/Sources/Panel.swift")]) == "읽는 중 · Panel.swift")
        #expect(line("edit", ["path": .string("/a/b/Panel.swift")]) == "편집 중 · Panel.swift")
        #expect(line("write", ["file_path": .string("Tests/PanelTests.swift")]) == "편집 중 · PanelTests.swift")
        #expect(line("grep", ["pattern": .string("currentCommand")]) == "검색 중 · currentCommand")
        #expect(line("bash", ["command": .string("swift test --filter HirdActivityTests")]) == "명령 실행 · swift test --filter HirdActivityTests")
        #expect(line("todo", [:]) == "명령 실행 · todo")
        #expect(line("ask", [:]) == "질문 답변 대기")
        #expect(line("task", [:]) == "하위 작업 1개")
        #expect(HirdActivity(kind: .subagents, count: 3).displayText == "하위 작업 3개")
        #expect(HirdActivity(kind: .waitingQuestion).displayText == "질문 답변 대기")
        #expect(HirdActivity(kind: .idle).displayText == "대기 중")
        let long = HirdActivity.tool("bash", arguments: .object(["command": .string(String(repeating: "swift test ", count: 20))]), at: .now)
        #expect(long.target?.contains("…") == true)
        #expect((long.target?.count ?? 0) <= 48)
        #expect(long.target?.hasPrefix("swift test") == true)
    }

    @Test func waitingForAPersonWinsAndLegacyRunsDeriveALineFromTheirCommand() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var waiting = HirdRun(id: "w", name: "Hird", role: "x", status: .waitingOnHuman(since: now.addingTimeInterval(-60)),
                              steps: [], currentCommand: "read", lastActivityAt: now)
        #expect(waiting.activityLine(now: now).kind == .waitingQuestion)
        waiting.currentActivity = .init(kind: .read, target: "Panel.swift", at: now)
        #expect(waiting.activityLine(now: now).displayText == "질문 답변 대기")
        let legacy = HirdRun(id: "l", name: "Hird", role: "x", status: .working, steps: [],
                             currentCommand: "swift test", lastActivityAt: now)
        #expect(legacy.activityLine(now: now).displayText == "명령 실행 · swift test")
        #expect(legacy.recentActivityLines().count == 1)
    }

    @Test func runsSavedBeforeActivityExistedStillDecode() throws {
        let legacy = """
            {"id":{"rawValue":"old"},"name":"Hird","role":"고치기","status":{"working":{}},"steps":[],
             "lastActivityAt":770000000,"currentCommand":"swift test"}
            """
        let run = try JSONDecoder().decode(HirdRun.self, from: Data(legacy.utf8))
        #expect(run.currentActivity == nil)
        #expect(run.recentActivities == nil)
        #expect(run.activityLine(now: .now).displayText == "명령 실행 · swift test")
    }
}

@MainActor @Suite struct HirdActivitySampleTests {
    @Test func designSampleExposesCurrentAndRecentStates() {
        let store = SampleKnarrStore(designScene: .issues)
        let issue = store.issues.first { $0.id == SampleKnarrStore.designDrawerIssue }
        let hird = issue?.hirds.first { $0.status == .working }
        #expect(hird?.currentActivity?.kind == .thinking)
        #expect(hird?.recentActivities?.count == 3)
        #expect(issue?.hirds.first { $0.id == "h1" }?.currentActivity?.displayText == "생각 중")
    }
}

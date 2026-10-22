import Foundation
import Testing
@testable import KnarrCore

@Suite(.serialized) @MainActor struct ConversationThreadTests {
    @Test func phoneThreadSubmissionPropagatesAdmissionFailure() async throws {
        let f = try await LiveFixture.make()
        do {
            await #expect(throws: (any Error).self) {
                try await f.store.sendToThread("missing-phone-thread", text: "must remain pending", project: nil, attachments: [])
            }
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func phoneMainSubmissionIsDurableBeforeItReturns() async throws {
        let f = try await LiveFixture.make()
        do {
            try await f.store.sendToThread(ConversationThread.defaultID, text: "durable phone message", project: nil, attachments: [])
            let saved = try await f.repository.snapshot().chat
            #expect(saved.contains { $0.kind == .user("durable phone message") })
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func projectTabsUseCurrentNamesWithoutChangingIssueOrderOrOwnership() {
        var projects = SampleKnarrStore().projects
        projects[0].name = "이름을 바꾼 프로젝트"
        let a = ConversationThread(id: "project-a", name: "이전 이름", projectID: projects[0].id)
        let b = ConversationThread(id: "project-b", name: "이전 B", projectID: projects[1].id)
        let issue = ConversationThread(id: "issue-tab", name: "기존 이슈", issueID: "tab-issue")
        let missing = ConversationThread(id: "removed-owner", name: "삭제됨", projectID: "removed")
        var tabs = ConversationTabs(saved: [issue.id])
        tabs.open(a)
        tabs.close(a.id)
        let shown = tabs.displayed(threads: [.default, b, issue, a, missing], projects: projects)
        #expect(shown.map(\.id) == [ConversationThread.defaultID, issue.id, b.id, a.id])
        #expect(shown.last?.name == projects[0].name)
        #expect(shown.last?.projectID == a.projectID)
        #expect(shown[1] == issue)
        #expect(tabs.issueThreadIDs == [issue.id])
    }

    @Test func issueTabsPersistOrderCloseOnlyPresentationAndExcludeLegacyThreads() async throws {
        let f = try await LiveFixture.make()
        let suite = "knarr-tabs-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        func makeStore() -> LiveKnarrStore {
            let rpc = LiveTestRPC()
            let store = LiveKnarrStore(repository: f.repository,
                session: StallariSession(repository: f.repository, rpc: rpc, hird: f.hird),
                rpc: rpc, hird: f.hird, preferences: preferences)
            store.setThreadFactory { thread in
                let child = LiveTestRPC()
                return LiveConversation(repository: f.repository,
                    session: StallariSession(repository: f.repository, rpc: child, hird: f.hird, threadID: thread.id),
                    rpc: child, hird: f.hird, threadID: thread.id, preferences: preferences)
            }
            return store
        }
        var store = makeStore()
        do {
            let legacy = ConversationThread(name: "스레드테스트")
            try await f.repository.saveThread(legacy)
            _ = try await f.session.createIssue(id: "tab-one", title: "첫 이슈", criteria: ["검사"], instruction: "검사", projectID: "p")
            _ = try await f.session.createIssue(id: "tab-two", title: "둘째 이슈", criteria: ["검사"], instruction: "검사", projectID: "p")
            try await store.connect()
            let snapshot = try await f.repository.snapshot()
            let one = try #require(snapshot.issues.first { $0.id == "tab-one" })
            let two = try #require(snapshot.issues.first { $0.id == "tab-two" })
            store.goToThread(for: one.id); try await store.whenIdle()
            store.goToThread(for: two.id); try await store.whenIdle()
            store.goToThread(for: one.id); try await store.whenIdle()
            #expect(store.conversationTabs.map(\.id) == [ConversationThread.defaultID, one.conversationThreadID, two.conversationThreadID])
            #expect(store.selectedThreadID == one.conversationThreadID)
            store.composerDraft.text = "보존할 초안"
            let before = try await f.repository.snapshot()
            store.closeConversationTab(one.conversationThreadID)
            try await store.whenIdle()
            #expect(store.selectedThreadID == ConversationThread.defaultID)
            #expect(try await f.repository.snapshot().chat == before.chat)
            #expect(try await f.repository.snapshot().issues == before.issues)
            store.goToThread(for: one.id); try await store.whenIdle()
            #expect(store.composerDraft.text == "보존할 초안")
            _ = await store.shutdown()
            store = makeStore()
            try await store.connect()
            #expect(store.conversationTabs.map(\.id) == [ConversationThread.defaultID, two.conversationThreadID, one.conversationThreadID])
            store.closeConversationTab(two.conversationThreadID)
            #expect(store.selectedThreadID == one.conversationThreadID)
            store.selectThread(legacy.id); try await store.whenIdle()
            #expect(store.selectedThreadID == legacy.id)
            #expect(!store.conversationTabs.contains { $0.id == legacy.id })
            _ = await store.shutdown()
            try await f.cleanup()
        } catch { _ = await store.shutdown(); try await f.cleanup(); throw error }
    }

    @Test func mainSteersCancelsAndApprovesFollowUpOnlyForItsOwnIssue() async throws {
        let f = try await LiveFixture.make()
        let suite = "knarr-main-control-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        f.store.setThreadFactory { thread in
            let rpc = LiveTestRPC()
            return LiveConversation(repository: f.repository,
                session: StallariSession(repository: f.repository, rpc: rpc, hird: f.hird, threadID: thread.id),
                rpc: rpc, hird: f.hird, threadID: thread.id,
                preferences: preferences)
        }
        let foreign = ConversationThread(name: "다른 사용자 스레드")
        try await f.repository.saveThread(foreign)
        let stranger = StallariSession(repository: f.repository, rpc: LiveTestRPC(), hird: f.hird, threadID: foreign.id)
        do {
            _ = try await f.session.createIssue(id: "controlled", title: "같은 목표", criteria: ["검사"], instruction: "구현", projectID: "p")
            let run = try await f.session.approveIssue(issueID: "controlled", version: 1)
            for _ in 0..<200 { if await f.hird.runs.contains(where: { $0.id == run }) { break }; await Task.yield() }
            try await f.store.whenIdle()
            f.store.goToThread(for: "controlled"); try await f.store.whenIdle()
            let controlledThread = f.store.selectedThreadID
            #expect(f.store.conversationTabs.contains { $0.id == controlledThread })
            await #expect(throws: StallariError.missingIssue) { try await stranger.steerRun(run, instruction: "남의 실행") }
            await #expect(throws: StallariError.missingIssue) { _ = try await stranger.cancelRun(run) }
            await #expect(throws: StallariError.missingIssue) {
                _ = try await stranger.performTool("read_run_output", arguments: .object(["runID": .string(run.rawValue), "verificationID": .string("v")]))
            }
            await #expect(throws: StallariError.missingIssue) { try await stranger.updateIssueProposal(issueID: "controlled", expectedVersion: 1, instruction: "남의 제안") }
            await #expect(throws: StallariError.missingIssue) { _ = try await stranger.approveIssue(issueID: "controlled", version: 1) }
            try await f.session.steerRun(run, instruction: "같은 목표 안에서 범위 축소")
            #expect(await f.hird.instructions.contains { $0.0 == run && $0.1 == "같은 목표 안에서 범위 축소" })
            #expect(try await f.session.cancelRun(run) == .applied)
            #expect(try await f.session.getRun(run).state == .cancelled)
            try await f.store.whenIdle()
            #expect(!f.store.conversationTabs.contains { $0.id == controlledThread })
            #expect(f.store.selectedThreadID == ConversationThread.defaultID)
            try await f.session.updateIssueProposal(issueID: "controlled", expectedVersion: 1, instruction: "사용자가 요청한 후속 수정", previousRunID: run)
            await #expect(throws: (any Error).self) { _ = try await f.session.approveIssue(issueID: "controlled", version: 1) }
            let next = try await f.session.approveIssue(issueID: "controlled", version: 2)
            #expect(try await f.session.approveIssue(issueID: "controlled", version: 2) == next)
            #expect(try await f.session.getRun(next).previousRunID == run)
            #expect(try await f.repository.snapshot().runs.count == 2)
            let foreignID = try await stranger.createIssue(id: "foreign-issue", title: "다른 목표", criteria: ["검사"], instruction: "검사", projectID: "p")
            await #expect(throws: StallariError.missingIssue) { try await f.session.updateIssueProposal(issueID: foreignID, expectedVersion: 1, instruction: "침범") }
            await #expect(throws: StallariError.missingIssue) { _ = try await f.session.approveIssue(issueID: foreignID, version: 1) }
            _ = await stranger.shutdown()
            try await f.cleanup()
        } catch { _ = await stranger.shutdown(); try await f.cleanup(); throw error }
    }
    @Test func independentIssueOwnersShareProjectAdmissionAndUnlimitedZero() async throws {
        let f = try await LiveFixture.make()
        f.store.setThreadFactory { thread in
            let rpc = LiveTestRPC()
            return LiveConversation(repository: f.repository,
                session: StallariSession(repository: f.repository, rpc: rpc, hird: f.hird, threadID: thread.id),
                rpc: rpc, hird: f.hird, threadID: thread.id,
                preferences: UserDefaults(suiteName: "knarr-admission-\(UUID())")!)
        }
        do {
            var project = try #require(try await f.repository.snapshot().projects.first { $0.id == "p" })
            project.settings.maxHirds = 1
            try await f.repository.saveProject(project)
            _ = try await f.session.createIssue(id: "owner-one", title: "첫 작업", criteria: ["검사"], instruction: "첫 검사", projectID: "p")
            _ = try await f.session.createIssue(id: "owner-two", title: "둘째 작업", criteria: ["검사"], instruction: "둘째 검사", projectID: "p")
            _ = try await f.session.approveIssue(issueID: "owner-one", version: 1)
            await #expect(throws: (any Error).self) { _ = try await f.session.approveIssue(issueID: "owner-two", version: 1) }
            #expect(try await f.repository.snapshot().runs.count == 1)
            project.settings.maxHirds = 0
            try await f.repository.saveProject(project)
            _ = try await f.session.approveIssue(issueID: "owner-two", version: 1)
            let snapshot = try await f.repository.snapshot()
            #expect(snapshot.runs.count == 2)
            #expect(Set(snapshot.issues.map(\.conversationThreadID)).count == 2)
            #expect(f.store.selectedThreadID == ConversationThread.defaultID)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func mainRoutesOwnIssueAndReceivesCompletionWithoutNavigation() async throws {
        let f = try await LiveFixture.make()
        var sessions: [String: StallariSession] = [:]
        var rpcs: [String: LiveTestRPC] = [:]
        f.store.setThreadFactory { thread in
            let pending = try? await f.repository.snapshot().pendingDeliveryThreadIDs
            #expect(pending?.contains(thread.id) == true)
            let rpc = LiveTestRPC()
            let session = StallariSession(repository: f.repository, rpc: rpc, hird: f.hird, threadID: thread.id)
            sessions[thread.id] = session; rpcs[thread.id] = rpc
            return LiveConversation(repository: f.repository, session: session, rpc: rpc, hird: f.hird,
                threadID: thread.id, preferences: UserDefaults(suiteName: "knarr-owned-\(UUID())")!)
        }
        do {
            _ = try await f.session.performTool("create_issue", arguments: .object([
                "issueID": .string("owned"), "title": .string("전용 실행"), "criteria": .array([.string("검사")]),
                "instruction": .string("저장된 지시"), "projectID": .string("p"), "handoffSummary": .string("사용자가 이 목표의 실행을 요청했어요")
            ]))
            let issue = try #require(try await f.repository.snapshot().issues.first { $0.id == "owned" })
            #expect(issue.conversationThreadID != ConversationThread.defaultID)
            #expect(sessions.isEmpty)
            let run = try await f.session.approveIssue(issueID: issue.id, version: 1)
            let owner = try #require(sessions[issue.conversationThreadID])
            let ownerRPC = try #require(rpcs[issue.conversationThreadID])
            #expect(f.store.selectedThreadID == ConversationThread.defaultID)
            #expect(try await f.session.approveIssue(issueID: issue.id, version: 1) == run)
            _ = try await owner.receive(.init(id: "owned-finish", runID: run, at: .now, payload: .complete(f.result(), notificationID: "owned-completion")))
            try await f.store.whenIdle()
            #expect(await ownerRPC.prompts.contains { $0["message"]?.string?.contains("사용자가 이 목표의 실행을 요청했어요") == true })
            #expect(await ownerRPC.prompts.filter { $0["message"]?.string?.contains("owned-completion") == true }.count == 1)
            try await f.session.deliverNotifications()
            try await f.session.deliverNotifications()
            #expect(await f.rpc.prompts.filter { $0["message"]?.string?.contains("owned-completion") == true }.count == 0)
            let mainHasNotice = f.store.chat.contains { item in
                if case .notice = item.kind { return true }
                return false
            }
            #expect(!mainHasNotice)
            try "검증 로그: 같은 목표 확인\n".write(to: f.directory.appendingPathComponent("test.log"), atomically: true, encoding: .utf8)
            let output = try await f.session.performTool("read_run_output", arguments: .object(["runID": .string(run.rawValue), "verificationID": .string("v")]))
            #expect(output["text"]?.string == "검증 로그: 같은 목표 확인\n")
            f.store.goToThread(for: issue.id); try await f.store.whenIdle()
            #expect(f.store.conversationTabs.contains { $0.id == issue.conversationThreadID })
            try await owner.judge(issueID: issue.id, runID: run,
                evidence: [.init(criterionIndex: 0, verificationIDs: ["v"], explanation: "검사 통과")])
            try await f.store.whenIdle()
            #expect(!f.store.conversationTabs.contains { $0.id == issue.conversationThreadID })
            #expect(f.store.selectedThreadID == ConversationThread.defaultID)
            f.store.perform(.requestChanges(note: "버튼의 이름을 유지하고 간격만 수정"), on: issue.id)
            try await f.store.whenIdle()
            let corrected = try #require(try await f.repository.snapshot().runs.last { $0.issueID == issue.id })
            #expect(corrected.id != run && corrected.previousRunID == run)
            #expect(corrected.hird.role.contains("버튼의 이름을 유지하고 간격만 수정"))
            #expect(try await f.repository.snapshot().chat.contains { $0.kind == .user("버튼의 이름을 유지하고 간격만 수정") })
            #expect(try await f.repository.snapshot().issues.first { $0.id == issue.id }?.conversationThreadID == issue.conversationThreadID)
            await #expect(throws: (any Error).self) { try await f.session.updateIssueProposal(issueID: issue.id, expectedVersion: 2, instruction: "실행 중 수정 금지") }
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func dynamicPendingDeliveryWakesUnselectedIssueAndClosedComposerCannotSubmit() async throws {
        let f = try await LiveFixture.make()
        var sessions: [String: StallariSession] = [:]
        let childRPC = LiveTestRPC()
        f.store.setThreadFactory { thread in
            let session = StallariSession(repository: f.repository, rpc: childRPC, hird: f.hird, threadID: thread.id)
            sessions[thread.id] = session
            return LiveConversation(repository: f.repository, session: session, rpc: childRPC, hird: f.hird,
                threadID: thread.id, preferences: UserDefaults(suiteName: "knarr-dynamic-owned-\(UUID())")!)
        }
        do {
            _ = try await f.session.createIssue(id: "dynamic", title: "늦은 전달", criteria: ["검사"], instruction: "검사", projectID: "p")
            let issue = try #require(try await f.repository.snapshot().issues.first { $0.id == "dynamic" })
            #expect(issue.conversationThreadID != ConversationThread.defaultID)
            #expect(sessions.isEmpty)
            try await f.repository.requestIssueProposalChanges(issueID: issue.id, version: 1, note: "동적으로 전달한 수정 요청")
            for _ in 0..<200 {
                if try await f.repository.pendingThreadDeliveries(threadID: issue.conversationThreadID).isEmpty { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let owner = try #require(sessions[issue.conversationThreadID])
            #expect(f.store.selectedThreadID == ConversationThread.defaultID)
            #expect(await childRPC.prompts.filter { $0["message"]?.string?.contains("동적으로 전달한 수정 요청") == true }.count == 1)
            #expect(await f.rpc.prompts.isEmpty)
            try await f.repository.closeIssue(issue.id, reason: .cancelled, at: .now)
            try await f.store.whenIdle()
            f.store.selectThread(issue.conversationThreadID)
            try await f.store.whenIdle()
            let count = await childRPC.prompts.count
            await #expect(throws: (any Error).self) { try await f.store.submit(.init(text: "닫힌 대화에서 새 작업")) }
            await #expect(throws: (any Error).self) { try await owner.updateIssueProposal(issueID: issue.id, expectedVersion: 1, instruction: "닫힌 이슈 수정") }
            await #expect(throws: (any Error).self) {
                _ = try await owner.performTool("create_issue", arguments: .object([
                    "issueID": .string("escape"), "title": .string("새 작업"), "criteria": .array([.string("검사")]),
                    "instruction": .string("검사"), "projectID": .string("p")
                ]))
            }
            #expect(await childRPC.prompts.count == count)
            let savedChat = try await f.repository.snapshot().chat
            #expect(!savedChat.contains { $0.kind == .user("닫힌 대화에서 새 작업") })
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func explicitSelectionSurvivesAStaleThreadCache() async throws {
        let f = try await LiveFixture.make()
        let childRPC = LiveTestRPC()
        f.store.setThreadFactory { thread in
            LiveConversation(repository: f.repository,
                session: StallariSession(repository: f.repository, rpc: childRPC, hird: f.hird, threadID: thread.id),
                rpc: childRPC, hird: f.hird, threadID: thread.id,
                preferences: UserDefaults(suiteName: "knarr-stale-selection-\(UUID())")!)
        }
        do {
            // A subscription frame lags a freshly saved thread; selecting it must not be dropped.
            let thread = ConversationThread(name: "늦게 저장된 대화")
            try await f.repository.saveThread(thread)
            #expect(!f.store.threads.contains { $0.id == thread.id })
            f.store.selectThread(thread.id)
            try await f.store.whenIdle()
            #expect(f.store.selectedThreadID == thread.id)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func phoneReviewAndVersionedProposalCardsStayInTheirOwningThread() async throws {
        let f = try await LiveFixture.make()
        let rpc = LiveTestRPC()
        var childSession: StallariSession?
        f.store.setThreadFactory { thread in
            let session = StallariSession(repository: f.repository, rpc: rpc, hird: f.hird, threadID: thread.id)
            childSession = session
            return LiveConversation(repository: f.repository, session: session, rpc: rpc, hird: f.hird,
                                    threadID: thread.id, preferences: UserDefaults(suiteName: "knarr-integrated-thread-\(UUID())")!)
        }
        do {
            f.store.createThread(name: "폰에서 이어가기")
            try await f.store.whenIdle()
            let originThreadID = f.store.selectedThreadID
            let session = try #require(childSession)
            _ = try await session.createIssue(id: "phone-thread", title: "스레드 제안", criteria: ["검사"], instruction: "검사", projectID: "p")
            try await f.store.whenIdle()
            let threadID = try #require(try await f.repository.snapshot().issues.first { $0.id == "phone-thread" }?.conversationThreadID)
            #expect(threadID != originThreadID)
            f.store.selectThread(threadID)
            try await f.store.whenIdle()
            #expect(f.store.chat.contains { $0.kind == .proposal("phone-thread", version: 1) })
            f.store.selectThread(ConversationThread.defaultID)
            try await f.store.whenIdle()
            #expect(!f.store.chat.contains { $0.kind == .proposal("phone-thread", version: 1) })
            try await f.store.reviewProposal(.approveProposal(version: 1), on: "phone-thread", source: "phone")
            let snapshot = try await f.repository.snapshot()
            #expect(snapshot.issues.first { $0.id == "phone-thread" }?.approval?.source == "phone")
            #expect(snapshot.chatLinks.filter { $0.issueID == "phone-thread" }.allSatisfy { $0.conversationThreadID == threadID })
            let foreign = try await f.session.performTool("get_issue", arguments: .object(["issueID": .string("phone-thread")]))
            let readIssue = try JSONDecoder().decode(KnarrCore.Issue.self, from: JSONEncoder().encode(try #require(foreign["issue"])))
            #expect(readIssue.id == "phone-thread" && readIssue.approval?.source == "phone")
            let run = try #require(snapshot.runs.first { $0.issueID == "phone-thread" })
            let foreignRun = try await f.session.performTool("get_run", arguments: .object(["runID": .string(run.id.rawValue)]))
            #expect(foreignRun["run"]?["runID"]?.string == run.id.rawValue)
            await #expect(throws: StallariError.missingIssue) { try await f.session.cancelRun(run.id) }
            await #expect(throws: StallariError.missingIssue) {
                try await f.session.updateIssueProposal(issueID: "phone-thread", expectedVersion: 1, instruction: "다른 스레드의 수정")
            }
            #expect(await f.rpc.prompts.isEmpty)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func startupDrainsUnselectedThreadsPendingProposalOnce() async throws {
        let f = try await LiveFixture.make()
        let thread = ConversationThread(name: "후속 전달")
        try await f.repository.saveThread(thread)
        let sourceRPC = LiveTestRPC()
        let source = StallariSession(repository: f.repository, rpc: sourceRPC, hird: f.hird, threadID: thread.id)
        _ = try await source.createIssue(id: "pending", title: "후속 이슈", criteria: ["검사"], instruction: "검사", projectID: "p")
        let ownerThreadID = try #require(try await f.repository.snapshot().issues.first { $0.id == "pending" }?.conversationThreadID)
        try await f.repository.requestIssueProposalChanges(issueID: "pending", version: 1, note: "범위를 좁혀 주세요")
        _ = await source.shutdown()
        let rpc = LiveTestRPC(), childRPC = LiveTestRPC()
        let preferences = UserDefaults(suiteName: "knarr-pending-thread-\(UUID())")!
        let store = LiveKnarrStore(repository: f.repository,
            session: StallariSession(repository: f.repository, rpc: rpc, hird: f.hird), rpc: rpc, hird: f.hird, preferences: preferences)
        store.setThreadFactory { thread in
            LiveConversation(repository: f.repository,
                session: StallariSession(repository: f.repository, rpc: childRPC, hird: f.hird, threadID: thread.id),
                rpc: childRPC, hird: f.hird, threadID: thread.id, preferences: preferences)
        }
        do {
            try await store.connect()
            #expect(store.selectedThreadID == ConversationThread.defaultID)
            #expect(await rpc.prompts.isEmpty)
            #expect(await childRPC.prompts.filter { $0["message"]?.string?.contains("범위를 좁혀 주세요") == true }.count == 1)
            #expect(try await f.repository.pendingThreadDeliveries(threadID: ownerThreadID).isEmpty)
            #expect(await store.shutdown().remainingProcessIDs.isEmpty)
            try await f.cleanup()
        } catch { _ = await store.shutdown(); try await f.cleanup(); throw error }
    }

    @Test func startupDoesNotLaunchSessionsForIdleUnselectedThreads() async throws {
        let f = try await LiveFixture.make()
        do {
            let idle = ConversationThread(name: "보관된 주제")
            try await f.repository.saveThread(idle)
            let rpc = LiveTestRPC()
            let preferences = UserDefaults(suiteName: "knarr-lazy-threads-\(UUID())")!
            let store = LiveKnarrStore(repository: f.repository,
                session: StallariSession(repository: f.repository, rpc: rpc, hird: f.hird), rpc: rpc, hird: f.hird, preferences: preferences)
            var opened: [String] = []
            store.setThreadFactory { thread in
                opened.append(thread.id)
                let child = LiveTestRPC()
                return LiveConversation(repository: f.repository,
                    session: StallariSession(repository: f.repository, rpc: child, hird: f.hird, threadID: thread.id),
                    rpc: child, hird: f.hird, threadID: thread.id, preferences: preferences)
            }
            try await store.connect()
            #expect(opened.isEmpty)
            store.selectThread(idle.id)
            try await store.whenIdle()
            #expect(opened == [idle.id])
            #expect(store.selectedThreadID == idle.id)
            #expect(await store.shutdown().remainingProcessIDs.isEmpty)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func threadCRUDSwitchDuringResponseAndRestartKeepSeparateTranscripts() async throws {
        let f = try await LiveFixture.make()
        let secondRPC = LiveTestRPC()
        f.store.setThreadFactory { thread in
            let session = StallariSession(repository: f.repository, rpc: secondRPC, hird: f.hird, threadID: thread.id)
            return LiveConversation(repository: f.repository, session: session, rpc: secondRPC, hird: f.hird, threadID: thread.id,
                                    preferences: UserDefaults(suiteName: "knarr-thread-child-\(UUID())")!)
        }
        do {
            try await f.store.submit(.init(text: "기본 질문"))
            f.store.createThread(name: "빌드")
            try await f.store.whenIdle()
            let second = try #require(f.store.threads.first { $0.name == "빌드" })
            #expect(f.store.selectedThreadID == second.id)
            #expect(!f.store.isResponding)
            #expect(f.store.chat.isEmpty)
            try await f.store.submit(.init(text: "빌드 질문"))
            await f.store.observe(frame: .object(["type": .string("message_end"), "messageId": .string("same-id"),
                "message": .object(["role": .string("assistant"), "content": .array([.object(["type": .string("text"), "text": .string("기본 답변")])])])]), threadID: ConversationThread.defaultID)
            #expect(!f.store.chat.contains { $0.kind == .stallari("기본 답변", project: nil) })
            await f.store.observe(frame: .object(["type": .string("message_end"), "messageId": .string("same-id"),
                "message": .object(["role": .string("assistant"), "content": .array([.object(["type": .string("text"), "text": .string("빌드 답변")])])])]), threadID: second.id)
            f.store.renameThread(second.id, to: "배포 검사")
            try await f.store.whenIdle()
            #expect(f.store.threads.first { $0.id == second.id }?.name == "배포 검사")
            #expect(f.store.chat.contains { $0.kind == .stallari("빌드 답변", project: nil) })
            f.store.selectThread(ConversationThread.defaultID)
            try await f.store.whenIdle()
            #expect(f.store.chat.contains { $0.kind == .user("기본 질문") })
            #expect(f.store.chat.contains { $0.kind == .stallari("기본 답변", project: nil) })
            #expect(!f.store.chat.contains { $0.kind == .user("빌드 질문") })
            let snapshot = try await f.repository.snapshot()
            #expect(snapshot.chatLinks.filter { $0.conversationThreadID == second.id }.count == 2)
            let preferences = UserDefaults(suiteName: "knarr-thread-restart-\(UUID())")!
            preferences.set(second.id, forKey: "knarr.selectedThread")
            let restartRPC = LiveTestRPC()
            let restart = LiveKnarrStore(repository: f.repository,
                session: StallariSession(repository: f.repository, rpc: restartRPC, hird: f.hird), rpc: restartRPC, hird: f.hird, preferences: preferences)
            restart.setThreadFactory { thread in
                let rpc = LiveTestRPC()
                return LiveConversation(repository: f.repository,
                    session: StallariSession(repository: f.repository, rpc: rpc, hird: f.hird, threadID: thread.id), rpc: rpc, hird: f.hird,
                    threadID: thread.id, preferences: preferences)
            }
            try await restart.connect()
            #expect(restart.selectedThreadID == second.id)
            #expect(restart.chat.contains { $0.kind == .user("빌드 질문") })
            #expect(!restart.chat.contains { $0.kind == .user("기본 질문") })
            #expect(await restart.shutdown().remainingProcessIDs.isEmpty)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
}

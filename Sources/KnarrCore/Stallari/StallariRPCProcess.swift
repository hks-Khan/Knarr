import Foundation

/// A stable RPC transport across Stallari process generations. Hird remains single-use.
/// This owns no planning/approval logic; OMP still executes and persists the session.
actor StallariRPCProcess: StallariRPC {
    private let launch: @Sendable (Bool) throws -> OMPLaunchConfiguration
    private let makeRPC: @Sendable () -> any HirdRPC
    private var rpc: (any HirdRPC)?
    private var pump: Task<Void, Never>?
    private var buffers: [UUID: OMPEventBuffer] = [:]
    private var generation = UUID().uuidString
    private var sessionID: String?
    private var restarting = false
    private var closed = false
    private var ready = false
    private(set) var exits: [OMPProcessExit] = []
    private var readyFrame: OMPJSON?
    private var presentationFrames: [String: OMPJSON] = [:]
    private var pendingDialogs: [String: OMPJSON] = [:]

    init(launch: @escaping @Sendable (Bool) throws -> OMPLaunchConfiguration,
         makeRPC: @escaping @Sendable () -> any HirdRPC = { OMPRPCSession() }) {
        self.launch = launch; self.makeRPC = makeRPC
    }
    func start() async throws { _ = try await open() }
    private func open() async throws -> OMPJSON {
        var errors: [OMPJSON] = []
        let configuration = try launch(true)
        do { try await startProcess(configuration) }
        catch {
            guard !closed, !Task.isCancelled else { throw error }
            let paths = configuration.arguments.enumerated().compactMap { index, value -> OMPJSON? in
                guard value == "--trusted-extension", index + 1 < configuration.arguments.count else { return nil }
                return .string(configuration.arguments[index + 1])
            }
            // Trusted imports abort before RPC ready in 18.7.0. Report the actual
            // startup failure, then restore a real policy-only process so write_extension
            // can repair the files. Never describe that process as loading those modules.
            let code = exits.last?.status ?? -1
            errors.append(.object(["kind": .string("trusted_extension_startup_failed"),
                "requestedExtensions": .array(paths), "exitCode": .number(Double(code))]))
            try await startProcess(try launch(false))
        }
        guard let rpc, !closed else { throw StallariError.closed }
        let state = try await rpc.request("get_state", fields: [:], timeout: .seconds(10))["data"] ?? .null
        sessionID = state["sessionId"]?.string
        ready = true
        let result: OMPJSON = .object(["generation": .string(generation), "sessionID": sessionID.map(OMPJSON.string) ?? .null,
            "tools": StallariTools.toolSnapshot(state["dumpTools"]), "errors": .array(errors)])
        let frame: OMPJSON = .object(["type": .string("knarr_rpc_ready"), "generation": .string(generation), "sessionID": sessionID.map(OMPJSON.string) ?? .null, "reload": result])
        readyFrame = frame
        publish(.frame(frame))
        return result
    }
    private func startProcess(_ configuration: OMPLaunchConfiguration) async throws {
        let child = makeRPC(), id = UUID().uuidString
        generation = id; ready = false; rpc = child
        readyFrame = nil; presentationFrames.removeAll(); pendingDialogs.removeAll()
        let events = await child.subscribe()
        pump = Task { [weak self] in
            for await event in events { await self?.forward(event, generation: id) }
        }
        do { try await child.start(configuration) }
        catch {
            exits.append(await child.shutdown(cancel: true))
            await pump?.value; pump = nil; rpc = nil
            throw error
        }
        if closed { _ = await child.shutdown(cancel: true); throw StallariError.closed }
    }
    func restart() async throws -> OMPJSON {
        guard !closed, !restarting, let rpc else { throw StallariError.closed }
        restarting = true; ready = false
        publish(.frame(.object(["type": .string("knarr_rpc_restarting")])) )
        defer { restarting = false }
        let exit = await rpc.shutdown(cancel: false)
        exits.append(exit)
        await pump?.value; pump = nil; self.rpc = nil
        guard exit.remainingProcessIDs.isEmpty, !closed else { throw StallariError.closed }
        do { return try await open() }
        catch {
            publish(.frame(.object(["type": .string("knarr_rpc_reload_failed")])) )
            throw error
        }
    }
    func request(_ command: String, fields: [String: OMPJSON], timeout: Duration) async throws -> OMPJSON {
        guard !closed, let rpc else { throw OMPRPCError.notRunning }
        return try await rpc.request(command, fields: fields, timeout: timeout)
    }
    func send(_ command: String, fields: [String: OMPJSON]) async throws {
        guard !closed, let rpc else { throw OMPRPCError.notRunning }
        var fields = fields
        if let expected = fields.removeValue(forKey: "knarrRPCGeneration")?.string, expected != generation { return }
        try await rpc.send(command, fields: fields)
        if command == "extension_ui_response", let id = fields["id"]?.string { pendingDialogs.removeValue(forKey: id) }
    }
    func subscribe() -> AsyncStream<OMPEvent> {
        let id = UUID(), buffer = OMPEventBuffer()
        buffers[id] = buffer
        if ready {
            if let readyFrame { buffer.offer(.frame(readyFrame)) }
            for frame in presentationFrames.values { buffer.offer(.frame(frame)) }
            for frame in pendingDialogs.values { buffer.offer(.frame(frame)) }
        }
        if closed { buffer.finish() }
        return AsyncStream(unfolding: { await buffer.next() }, onCancel: { [weak self] in
            buffer.cancel(); Task { await self?.remove(id) }
        })
    }
    private func remove(_ id: UUID) { buffers.removeValue(forKey: id)?.cancel() }
    private func forward(_ event: OMPEvent, generation id: String) {
        guard id == generation else { return }
        switch event {
        case .terminated:
            if !restarting && ready { publish(event) }
        case .frame(.object(var frame)):
            frame["knarrRPCGeneration"] = .string(id)
            if frame["type"]?.string == "extension_ui_request" {
                switch frame["method"]?.string {
                case "setStatus":
                    if let key = frame["statusKey"]?.string, key != "__knarr_tool_policy__" {
                        if frame["statusText"]?.string == nil { presentationFrames.removeValue(forKey: "status:" + key) }
                        else { presentationFrames["status:" + key] = .object(frame) }
                    }
                case "setWidget":
                    if let key = frame["widgetKey"]?.string {
                        if frame["widgetLines"]?.array == nil { presentationFrames.removeValue(forKey: "widget:" + key) }
                        else { presentationFrames["widget:" + key] = .object(frame) }
                    }
                case "notify":
                    if !ready { presentationFrames["toast"] = .object(frame) }
                case "select", "confirm", "input", "editor":
                    if let key = frame["id"]?.string { pendingDialogs[key] = .object(frame) }
                case "cancel":
                    if let target = frame["targetId"]?.string { pendingDialogs.removeValue(forKey: target) }
                default: break
                }
            }
            publish(.frame(.object(frame)))
        default: break
        }
    }
    private func publish(_ event: OMPEvent) { for buffer in buffers.values { buffer.offer(event) } }
    func shutdown(cancel: Bool) async -> OMPProcessExit {
        closed = true
        if let rpc { exits.append(await rpc.shutdown(cancel: cancel)) }
        await pump?.value; pump = nil; rpc = nil
        buffers.values.forEach { $0.finish() }; buffers.removeAll()
        return .init(status: exits.last?.status ?? 0, reason: exits.last?.reason ?? .normal,
            remainingProcessIDs: Array(Set(exits.flatMap(\.remainingProcessIDs))).sorted())
    }
}

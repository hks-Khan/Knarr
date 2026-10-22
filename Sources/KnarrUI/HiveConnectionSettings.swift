import SwiftUI
import KnarrCore

/// Shared by app Settings and the isolated, synthetic native credential-entry harness.
@MainActor
public struct HiveConnectionSettings: View {
    private let connection: HiveConnection
    private let refresh: (@MainActor () async throws -> Void)?
    private let verify: @MainActor () async -> Void
    @State private var form = HiveCredentialForm()
    @State private var feedback: String?
    @State private var confirmingDelete = false
    @State private var operation: Task<Void, Never>?
    @State private var operationGeneration: UInt64 = 0

    public init(
        connection: HiveConnection,
        refresh: (@MainActor () async throws -> Void)? = nil,
        verify: @escaping @MainActor () async -> Void
    ) {
        self.connection = connection
        self.refresh = refresh
        self.verify = verify
    }

    public var body: some View {
        @Bindable var entry = form
        VStack(alignment: .leading, spacing: K.s2) {
            Text("Hive 연결").font(K.body.weight(.semibold))
            Text("API 키는 이 Knarr 작업 공간 전용 macOS 키체인에 저장해요. 저장된 키는 다시 표시하지 않아요.")
                .font(K.secondary).foregroundStyle(K.muted)
                .fixedSize(horizontal: false, vertical: true)
            Text(connection.message)
                .font(K.secondary).foregroundStyle(statusColor)
                .accessibilityIdentifier("hive-connection-status")
                .fixedSize(horizontal: false, vertical: true)
            SecureField("새 Hive API 키", text: $entry.input)
                .textFieldStyle(.roundedBorder)
                .font(K.secondary)
                .privacySensitive()
                .accessibilityLabel("새 Hive API 키")
                .accessibilityIdentifier("hive-api-key-input")
                .onSubmit { save() }
            HStack(spacing: K.s2) {
                KButton(title: connection.runtime.isPrepared ? "키 바꾸기" : "키 저장", style: .primary) { save() }
                    .disabled(!form.hasInput)
                    .accessibilityIdentifier("hive-save-key")
                KButton(title: "취소") { cancel() }
                    .accessibilityIdentifier("hive-cancel-key")
                KButton(title: "연결 확인") { verifyConnection() }
                    .disabled(!connection.runtime.isPrepared || operation != nil || connection.status == .verifying)
                    .accessibilityIdentifier("hive-verify-connection")
                KButton(title: "키 삭제", style: .destructive) {
                    form.clear()
                    confirmingDelete = true
                }
                .disabled(!connection.runtime.isPrepared)
                .accessibilityIdentifier("hive-delete-key")
            }
            if refresh != nil {
                KButton(title: "모델 목록 새로 읽기") {
                    form.clear()
                    refreshCatalog()
                }
                .disabled(operation != nil)
                .accessibilityIdentifier("hive-refresh-models")
            }
            if let feedback {
                Text(feedback).font(K.secondary).foregroundStyle(K.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("hive-connection-feedback")
            }
            Text("저장·삭제는 새 실행에 적용돼요. 진행 중인 실행의 인증은 바뀌지 않아요.")
                .font(K.caption).foregroundStyle(K.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(K.ink)
        .confirmationDialog("Hive API 키를 키체인에서 삭제할까요?", isPresented: $confirmingDelete) {
            Button("키 삭제", role: .destructive) { remove() }
            Button("취소", role: .cancel) { form.cancel() }
        }
        .onExitCommand { cancel() }
        .onDisappear {
            form.clear()
            cancelOperation()
        }
    }

    private var statusColor: Color {
        switch connection.status {
        case .verified: K.green
        case .verifying: K.accent
        case .failed: K.red
        case .missing, .prepared: K.muted
        }
    }

    private func save() {
        cancelOperation()
        feedback = nil
        do {
            try form.save(to: connection)
            refreshCatalog()
        } catch let error as HiveConnectionError {
            feedback = error.message
        } catch {
            feedback = HiveConnectionError.storageUnavailable.message
        }
    }

    private func remove() {
        form.clear()
        cancelOperation()
        feedback = nil
        do {
            try connection.remove()
            refreshCatalog()
        } catch {
            feedback = HiveConnectionError.storageUnavailable.message
        }
    }

    private func verifyConnection() {
        form.clear()
        cancelOperation()
        feedback = nil
        let attempt = operationGeneration
        operation = Task { @MainActor in
            await verify()
            guard operationGeneration == attempt else { return }
            operation = nil
        }
    }

    private func refreshCatalog() {
        guard let refresh else { return }
        cancelOperation()
        let attempt = operationGeneration
        operation = Task { @MainActor in
            do {
                try Task.checkCancellation()
                try await refresh()
                try Task.checkCancellation()
                guard operationGeneration == attempt else { return }
                feedback = "모델 목록을 새로 읽었어요. 선택한 모델과 프로젝트는 그대로예요."
            } catch {
                guard operationGeneration == attempt else { return }
                if !Task.isCancelled {
                    feedback = "모델 목록을 새로 읽지 못했어요. 진행 중인 실행이 끝나면 다시 시도해 주세요. 저장된 키는 그대로예요."
                }
            }
            guard operationGeneration == attempt else { return }
            operation = nil
        }
    }

    private func cancel() {
        form.cancel()
        cancelOperation()
        feedback = nil
    }

    private func cancelOperation() {
        operationGeneration &+= 1
        operation?.cancel()
        operation = nil
    }
}

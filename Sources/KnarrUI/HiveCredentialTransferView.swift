import SwiftUI
import KnarrCore

/// A metadata-only review until the person presses the explicit approval control.
@MainActor
public struct HiveCredentialTransferView: View {
    private let transfer: HiveCredentialTransfer

    public init(transfer: HiveCredentialTransfer) {
        self.transfer = transfer
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: K.s5) {
                VStack(alignment: .leading, spacing: K.s2) {
                    Text("Hive 연결 복사").font(K.title)
                    Text("서로 다른 Knarr 데이터 영역 사이에서 저장된 Hive 연결을 복사해요.")
                        .font(K.secondary).foregroundStyle(K.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: K.s4) {
                    directory("원본 · 그대로 유지", url: transfer.sourceDirectory, id: "hive-transfer-source")
                    Divider().overlay(K.line)
                    directory("대상 · 기존 연결이 있으면 복사하지 않음", url: transfer.destinationDirectory, id: "hive-transfer-destination")
                }
                VStack(alignment: .leading, spacing: K.s2) {
                    Text("위 전체 경로는 키체인 연결 영역을 구별하는 식별 정보예요. 해당 폴더의 파일을 읽거나 복사하지 않아요.")
                    Text("원본 연결은 그대로 유지하고, 대상의 기존 연결은 절대 덮어쓰지 않아요.")
                    Text("복사는 대상의 새 연결 준비만 완료해요. 인증 검증 성공이나 실행 결과를 뜻하지 않아요.")
                    Text("승인하기 전에는 저장된 키를 읽거나 복사하지 않아요. 키는 이 화면에 표시하지 않아요.")
                }
                .font(K.secondary).foregroundStyle(K.muted)
                .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: K.s3) {
                    Text(transfer.message)
                        .font(K.secondary).foregroundStyle(statusColor)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("hive-transfer-status")
                    HStack(spacing: K.s2) {
                        KButton(title: "연결 복사 승인", style: .primary, enabled: transfer.canConfirm) {
                            transfer.confirm()
                        }
                        .accessibilityIdentifier("hive-transfer-confirm")
                        KButton(title: "취소", enabled: transfer.canConfirm) { transfer.cancel() }
                            .accessibilityIdentifier("hive-transfer-cancel")
                    }
                }
                Text("이 창에서는 운영 대화, Hird, 클라우드 미러를 시작하지 않아요. 끝나면 창을 닫아 주세요.")
                    .font(K.caption).foregroundStyle(K.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(K.s5)
        }
        .foregroundStyle(K.ink)
        .background(K.canvas)
        .onExitCommand {
            if transfer.canConfirm { transfer.cancel() }
        }
    }

    private func directory(_ title: String, url: URL, id: String) -> some View {
        VStack(alignment: .leading, spacing: K.s2) {
            Text(title).font(K.caption.weight(.semibold)).foregroundStyle(K.muted)
            Text(url.path)
                .font(K.mono)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(title + ": " + url.path)
                .accessibilityIdentifier(id)
        }
    }

    private var statusColor: Color {
        switch transfer.status {
        case .awaitingConfirmation: K.amber
        case .completed: K.green
        case .conflict: K.amber
        case .cancelled: K.muted
        case .failed: K.red
        }
    }
}

/// Invalid launch metadata stays in this panel rather than opening the live runtime.
@MainActor
public struct HiveCredentialTransferLaunchErrorView: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: K.s4) {
            Label("Hive 연결 복사를 시작할 수 없어요", systemImage: "exclamationmark.triangle")
                .font(K.title).foregroundStyle(K.red)
            Text("--hive-transfer와 함께 --hive-source-data-directory 및 --hive-destination-data-directory에 서로 구별되는 전체 절대 경로를 각각 한 번 지정해 주세요. 다른 실행 플래그와 함께 사용할 수 없어요.")
                .font(K.secondary).foregroundStyle(K.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("경로는 연결을 구별하는 메타데이터예요. 인자나 환경 변수에 API 키를 넣지 마세요. 키를 읽거나 복사하지 않았으며, 운영 대화와 Hird는 시작하지 않았어요. 이 창을 닫고 경로를 수정해 다시 열어 주세요.")
                .font(K.secondary).foregroundStyle(K.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(K.s5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(K.canvas)
        .accessibilityIdentifier("hive-transfer-launch-error")
    }
}

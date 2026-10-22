import Foundation
import KnarrCore

/// The only tools this local server exposes. They operate on Knarr's own records; none
/// reads files, runs commands, approves a proposal, starts Hird or changes settings.
public enum MCPToolCatalog {
    public static let serverName = "knarr"
    public static let serverVersion = "1.0.0"
    /// The latest specification this server implements, then the compatibility version.
    public static let latestProtocolVersion = "2025-06-18"
    public static let supportedProtocolVersions = ["2025-06-18", "2025-03-26"]
    public static let instructions = """
    Knarr의 프로젝트와 이슈를 조회하고, 승인 대기 제안을 만들거나 고치고, 이슈를 닫습니다. \
    이 서버는 파일·셸·승인·Hird 실행 도구를 제공하지 않습니다. 제안 생성과 수정은 저장만 하며, \
    실행은 언제나 Knarr 화면에서 사용자가 승인한 뒤에만 시작됩니다.
    """

    public static let toolNames: [String] = [
        "list_projects", "list_issues", "get_issue", "create_issue", "update_issue_proposal", "close_issue"
    ]

    private static let string: OMPJSON = .object(["type": .string("string"), "minLength": .number(1)])
    private static let object: OMPJSON = .object(["type": .string("object")])
    private static let strings: OMPJSON = .object(["type": .string("array"), "items": string])
    private static let stages: OMPJSON = .object([
        "type": .string("array"),
        "items": .object([
            "type": .string("object"),
            "properties": .object([
                "title": string, "evidence": string,
                "criterion": .object(["type": .string("integer"), "minimum": .number(1)])
            ]),
            "required": .array(["title", "evidence"].map(OMPJSON.string)),
            "additionalProperties": .bool(false)
        ])
    ])
    private static let mode: OMPJSON = .object([
        "type": .string("string"), "enum": .array([.string("inspect"), .string("change")])
    ])
    private static let offset: OMPJSON = .object(["type": .string("integer"), "minimum": .number(0)])
    private static let limit: OMPJSON = .object([
        "type": .string("integer"), "minimum": .number(1), "maximum": .number(200)
    ])

    private static func tool(_ name: String, _ title: String, _ description: String,
                             _ properties: [String: OMPJSON], _ required: [String]) -> OMPJSON {
        .object([
            "name": .string(name), "title": .string(title), "description": .string(description),
            "inputSchema": .object([
                "type": .string("object"), "properties": .object(properties),
                "required": .array(required.map(OMPJSON.string)), "additionalProperties": .bool(false)
            ]),
            "annotations": .object(["readOnlyHint": .bool(required.isEmpty)])
        ])
    }

    public static let tools: [OMPJSON] = [
        tool("list_projects", "프로젝트 목록",
             "등록되어 활성 상태인 Knarr 프로젝트를 반환합니다. projectID는 다른 모든 도구의 필수 입력입니다.",
             [:], []),
        tool("list_issues", "이슈 목록",
             "한 프로젝트의 이슈를 최신순으로 반환합니다. 각 항목에는 정확한 issueID, 표시 상태, 저장된 제안 버전이 들어 있어 update_issue_proposal과 close_issue에 그대로 쓸 수 있습니다. 보관된 이슈는 includeArchived=true일 때만 포함합니다.",
             ["projectID": string, "includeArchived": .object(["type": .string("boolean")]),
              "offset": offset, "limit": limit], ["projectID"]),
        tool("get_issue", "이슈 상세",
             "정확한 projectID와 issueID로 이슈의 저장된 제안 버전, 제안 이력, 승인 상태, 단계 계획, 진행률을 읽습니다. 실행 결과 전문과 로그 본문은 포함하지 않습니다.",
             ["projectID": string, "issueID": string], ["projectID", "issueID"]),
        tool("create_issue", "이슈 제안 생성",
             "사용자가 요청한 작업을 승인 대기 제안으로 저장합니다. Hird를 실행하지 않고 모델 호출도 하지 않습니다. 같은 idempotencyKey를 다시 보내면 같은 이슈를 반환하며(응답 유실 후 재조회에 사용), 같은 키에 다른 내용을 보내면 conflict로 거부합니다. 지시·모델·모드는 Knarr 화면에서 사용자가 검토합니다.",
             ["projectID": string, "idempotencyKey": string, "title": string, "criteria": strings,
              "instruction": string, "model": string, "mode": mode, "stages": stages,
              "handoffSummary": string],
             ["projectID", "idempotencyKey", "title", "criteria", "instruction"]),
        tool("update_issue_proposal", "저장된 제안 수정",
             "저장된 제안을 명시적 expectedVersion 기준으로 다음 버전으로 고칩니다. 이전 승인은 무효가 되고 Hird는 실행되지 않습니다. 버전이 다르면 conflict로 거부하므로 먼저 get_issue나 list_issues로 최신 버전을 확인하십시오. 직전에 같은 내용으로 성공한 요청을 다시 보내면 중복으로 처리합니다.",
             ["projectID": string, "issueID": string,
              "expectedVersion": .object(["type": .string("integer"), "minimum": .number(1)]),
              "instruction": string, "model": string, "mode": mode, "stages": stages],
             ["projectID", "issueID", "expectedVersion", "instruction"]),
        tool("close_issue", "이슈 닫기·보관",
             "저장된 제안의 expectedVersion을 확인하고 이슈를 기록 보존 방식으로 닫습니다(영구 삭제 없음). reason=applied|superseded|cancelled, note 필수. 먼저 get_issue나 list_issues로 버전을 확인하십시오. 진행 중인 실행이나 버전 충돌은 거부합니다. 같은 버전·사유·메모의 재요청만 중복 성공으로 응답합니다.",
             ["projectID": string, "issueID": string,
              "expectedVersion": .object(["type": .string("integer"), "minimum": .number(1)]),
              "reason": .object(["type": .string("string"),
                                 "enum": .array(["applied", "superseded", "cancelled"].map(OMPJSON.string))]),
              "note": string], ["projectID", "issueID", "expectedVersion", "reason", "note"])
    ]
}

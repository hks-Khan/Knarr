import Foundation

/// Content identity includes every field, the summary and ordered verification references.
/// JSON object key order alone is canonicalized; no prose or audit entry is discarded.
struct NormalizedRunResult: Codable {
    let metadata: RunResult
    let verificationKeys: [String]
}

/// New result-bearing ledger entries refer to the same immutable evidence as run history.
/// Existing ledger payloads remain byte-for-byte intact during migration.
struct NormalizedRunEvent: Codable {
    let metadata: RunEvent
    let resultKey: String
}

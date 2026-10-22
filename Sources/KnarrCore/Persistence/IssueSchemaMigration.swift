import Foundation

/// Only schema-owned keys change. User prose, paths, identifiers and enum values
/// unrelated to the domain cutover are never searched or replaced.
enum IssueSchemaMigration {
    static func payload(_ text: String, table: String) throws -> String {
        guard var object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw MigrationError.invalidObject
        }
        switch table {
        case "runs", "questions": try rename("thingID", to: "issueID", in: &object)
        case "run_events":
            if var payload = object["payload"] as? [String: Any],
               var ask = payload["ask"] as? [String: Any],
               var question = ask["_0"] as? [String: Any] {
                try rename("thingID", to: "issueID", in: &question)
                ask["_0"] = question; payload["ask"] = ask; object["payload"] = payload
            }
        case "chat":
            if var link = object["link"] as? [String: Any] {
                try rename("thingID", to: "issueID", in: &link)
                object["link"] = link
            }
            if var kind = object["kind"] as? [String: Any] {
                try rename("thing", to: "issue", in: &kind)
                if var notice = kind["notice"] as? [String: Any] {
                    try rename("thing", to: "issue", in: &notice)
                    // An old unversioned launch button is not approval of a v2 proposal.
                    if notice["action"] as? String == "acceptProposal" {
                        notice.removeValue(forKey: "label"); notice.removeValue(forKey: "action")
                    }
                    kind["notice"] = notice
                }
                object["kind"] = kind
            }
        default: break
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private static func rename(_ old: String, to new: String, in object: inout [String: Any]) throws {
        guard let value = object.removeValue(forKey: old) else { return }
        guard object[new] == nil else { throw MigrationError.conflictingKeys }
        object[new] = value
    }
    private enum MigrationError: Error { case invalidObject, conflictingKeys }
}

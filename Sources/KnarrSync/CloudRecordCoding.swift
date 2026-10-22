import CloudKit
import Foundation

public enum MobileRecordError: Error, Equatable {
    case unknownType(String)
    case missingPayload(String)
}

// The deployed CloudKit schema and phone payloads retain Thing/thing wire names.
// Domain models remain Issue; all legacy name conversion lives in this boundary.
extension MobileRecord {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        e.outputFormatting = .sortedKeys
        e.userInfo[CloudWire.context] = true
        e.keyEncodingStrategy = .custom { path in
            let key = path.last!
            switch key.stringValue {
            case "issue": return CloudWire.Key(CloudWire.issueReferenceKey)
            case "openIssues": return CloudWire.Key("openThings")
            default: return key
            }
        }
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        d.userInfo[CloudWire.context] = true
        d.keyDecodingStrategy = .custom { path in
            let key = path.last!
            switch key.stringValue {
            case CloudWire.issueReferenceKey: return CloudWire.Key("issue")
            case "openThings": return CloudWire.Key("openIssues")
            default: return key
            }
        }
        return d
    }()

    public func cloudRecord(in zone: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(recordType: CloudWire.recordType(kind), recordID: CKRecord.ID(recordName: recordName, zoneID: zone))
        fill(record)
        return record
    }

    /// Writes this value's fields into an existing record, keeping its change tag for an update.
    public func fill(_ record: CKRecord) {
        let payload: Data
        switch clippedForCloud {
        case .issue(let v): payload = try! Self.encoder.encode(v)
        case .question(let v): payload = try! Self.encoder.encode(v)
        case .message(let v): payload = try! Self.encoder.encode(v)
        case .project(let v): payload = try! Self.encoder.encode(v)
        case .request(let v): payload = try! Self.encoder.encode(v)
        case .status(let v): payload = try! Self.encoder.encode(v)
        case .activityDevice(let v): payload = try! Self.encoder.encode(v)
        case .thread(let v): payload = try! Self.encoder.encode(v)
        case .alert(let v):
            payload = try! Self.encoder.encode(v)
            // The phone's subscription reads these keys to build the notification.
            record["title"] = v.title as NSString
            record["body"] = v.body as NSString
            record[CloudWire.issueReferenceKey] = v.issue.map { $0 as NSString }
        }
        record["payload"] = payload as NSData
        // Images travel as separate asset fields so the JSON payload stays small. A record without
        // them keeps no asset keys, and an upload over an existing record clears the ones it drops.
        switch clippedForCloud {
        case .issue(let v):
            for (index, capture) in (v.captures ?? []).enumerated() {
                if let data = capture.data {
                    record["capture\(index)"] = CKAsset(fileURL: Self.asset(data, key: "\(v.id)-\(index)"))
                }
            }
            for key in record.allKeys() where key.hasPrefix("capture") {
                if Int(key.dropFirst("capture".count)) ?? Int.max >= (v.captures?.count ?? 0) { record[key] = nil }
            }
        case .message(let v):
            for (index, attachment) in (v.attachments ?? []).enumerated() {
                if let data = attachment.data {
                    record["attachment\(index)"] = CKAsset(fileURL: Self.asset(data, key: "\(v.id)-\(index)"))
                }
            }
            for key in record.allKeys() where key.hasPrefix("attachment") {
                if Int(key.dropFirst("attachment".count)) ?? Int.max >= (v.attachments?.count ?? 0) { record[key] = nil }
            }
        case .request(let v):
            let attachments = v.kind.attachments
            for (index, attachment) in attachments.enumerated() {
                if let data = attachment.data {
                    record["attachment\(index)"] = CKAsset(fileURL: Self.asset(data, key: "\(v.id)-\(index)"))
                }
            }
            for key in record.allKeys() where key.hasPrefix("attachment") {
                if Int(key.dropFirst("attachment".count)) ?? Int.max >= attachments.count { record[key] = nil }
            }
        default: break
        }
    }

    public init(cloudRecord record: CKRecord) throws {
        guard let kind = CloudWire.kind(record.recordType) else { throw MobileRecordError.unknownType(record.recordType) }
        guard let data = record["payload"] as? Data else { throw MobileRecordError.missingPayload(record.recordID.recordName) }
        let d = Self.decoder
        switch kind {
        case .issue:
            var value = try d.decode(MobileIssue.self, from: data)
            if let captures = value.captures {
                value.captures = captures.enumerated().map { index, capture in
                    var copy = capture
                    copy.data = Self.assetData(record["capture\(index)"])
                    return copy
                }
            }
            self = .issue(value)
        case .question: self = .question(try d.decode(MobileQuestion.self, from: data))
        case .message:
            var value = try d.decode(MobileMessage.self, from: data)
            if let attachments = value.attachments {
                value.attachments = attachments.enumerated().map { index, attachment in
                    var copy = attachment
                    copy.data = Self.assetData(record["attachment\(index)"])
                    return copy
                }
            }
            self = .message(value)
        case .project: self = .project(try d.decode(MobileProject.self, from: data))
        case .request:
            var value = try d.decode(MobileRequest.self, from: data)
            if case .threadMessage(let text, let thread, let project, let attachments) = value.kind, let attachments {
                let filled = attachments.enumerated().map { index, attachment in
                    var copy = attachment
                    copy.data = Self.assetData(record["attachment\(index)"])
                    return copy
                }
                value.kind = .threadMessage(text: text, thread: thread, project: project, attachments: filled)
            }
            self = .request(value)
        case .alert: self = .alert(try d.decode(MobileAlert.self, from: data))
        case .status: self = .status(try d.decode(MobileStatus.self, from: data))
        case .activityDevice: self = .activityDevice(try d.decode(MobileActivityDevice.self, from: data))
        case .thread: self = .thread(try d.decode(MobileThread.self, from: data))
        }
    }

    /// A stable file for one asset, so re-saving the same record does not create new files.
    static func asset(_ data: Data, key: String) -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("knarr-cloud-assets", isDirectory: true)
        let name = key.replacingOccurrences(of: "/", with: "-")
        let url = directory.appendingPathComponent(name)
        if (try? Data(contentsOf: url)) != data {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        return url
    }

    static func assetData(_ value: Any?) -> Data? {
        guard let asset = value as? CKAsset, let url = asset.fileURL else { return nil }
        return try? Data(contentsOf: url)
    }

    var clippedForCloud: MobileRecord {
        switch self {
        case .issue(var v):
            v.detail = v.detail.clipped()
            v.criteria = v.criteria.map { var c = $0; c.evidence = c.evidence?.clipped(to: 400); return c }
            v.events = v.events.map { var e = $0; e.text = e.text.clipped(to: 300); return e }
            v.runs = v.runs.map { var r = $0; r.role = r.role.clipped(to: 300); r.activity = r.activity?.clipped(to: 200); return r }
            v.report = v.report?.clipped()
            v.verifications = v.verifications.map { Array($0.prefix(12)).map {
                var check = $0; check.command = check.command.clipped(to: 300); check.summary = check.summary?.clipped(to: 300)
                return check
            } }
            v.captures = v.captures.map { Array($0.prefix(MobileLimits.captureCount)).map {
                var copy = $0
                if let data = copy.data, data.count > MobileLimits.attachmentBytes { copy.data = nil }
                return copy
            } }
            return .issue(v)
        case .question(var v): v.prompt = v.prompt.clipped(); return .question(v)
        case .message(var v):
            v.text = v.text.clipped()
            if var activity = v.activity { activity.title = activity.title.clipped(to: 200); v.activity = activity }
            v.attachments = v.attachments.map { Array($0.prefix(MobileLimits.attachmentCount)) }
            return .message(v)
        case .alert(var v): v.body = v.body.clipped(to: 300); return .alert(v)
        case .request(var v):
            switch v.kind {
            case .message(let text, let project): v.kind = .message(text: text.clipped(), project: project)
            case .threadMessage(let text, let thread, let project, let attachments):
                v.kind = .threadMessage(text: text.clipped(), thread: thread, project: project,
                                        attachments: attachments.map { Array($0.prefix(MobileLimits.attachmentCount)) })
            case .steer(let issue, let text): v.kind = .steer(issue: issue, text: text.clipped())
            default: break
            }
            return .request(v)
        case .project, .status, .activityDevice, .thread: return self
        }
    }
}

extension MobileRecord {
    /// One record of every kind with every field set. Saving these in the Development environment creates the
    /// record types CloudKit then deploys to Production (CloudKit Console → Deploy Schema Changes).
    public static var schemaSamples: [MobileRecord] {
        let at = Date(timeIntervalSince1970: 0)
        let pixel = Data([0x89, 0x50, 0x4E, 0x47])
        return [
            .issue(MobileIssue(id: "schema", title: "", project: "", state: .running, group: .working, headline: "", detail: "",
                               criteria: [], progress: nil, startedAt: at, updatedAt: at,
                               runs: [.init(name: "", role: "", status: .working, steps: [], activity: "", stages: [], stage: 1,
                                            startedAt: at, checksPassed: 0, checksFailed: 0)],
                               report: "", verifications: [.init(id: "schema", command: "", exitCode: 0, at: at, summary: "")],
                               captures: (0..<MobileLimits.captureCount).map {
                                   .init(id: "schema-\($0)", caption: "", width: 1, height: 1, data: pixel)
                               })),
            .question(MobileQuestion(id: "schema", issue: "", asker: "", prompt: "", options: [], allowsMultiple: false,
                                     state: .pending, answer: nil, askedAt: at)),
            .message(MobileMessage(id: "schema", at: at, role: .user, text: "", project: nil, thread: "",
                                   attachments: (0..<MobileLimits.attachmentCount).map {
                                       .init(id: "schema-\($0)", name: "schema.jpg", type: "image/jpeg", byteCount: pixel.count, data: pixel)
                                   })),
            .project(MobileProject(id: "schema", name: "", openIssues: 0)),
            .request(MobileRequest(id: "schema", createdAt: at, kind: .threadMessage(
                text: "", thread: "", project: nil,
                attachments: (0..<MobileLimits.attachmentCount).map {
                                       .init(id: "schema-\($0)", name: "schema.jpg", type: "image/jpeg", byteCount: pixel.count, data: pixel)
                                   }))),
            .request(MobileRequest(id: "schema-older", createdAt: at, kind: .loadOlder(thread: "", before: at))),
            .alert(MobileAlert(id: "schema", createdAt: at, title: "schema", body: "schema", issue: "schema")),
            .status(MobileStatus(isResponding: false, engine: "")),
            .activityDevice(MobileActivityDevice(id: "schema", environment: .sandbox, enabled: false, updatedAt: at)),
            .thread(MobileThread(id: "schema", name: "", kind: .issue, project: "", issue: "", lastMessageAt: at,
                                 working: false, messageCount: 0)),
        ]
    }
}

/// Shared CloudKit/notification/ActivityKit boundary, not a domain compatibility alias.
public enum CloudWire {
    public static let issueReferenceKey = "thing"
    static let context = CodingUserInfoKey(rawValue: "Knarr.CloudWire")!

    public static func recordType(_ kind: MobileRecord.Kind) -> String { kind == .issue ? "Thing" : kind.rawValue }
    static func kind(_ type: String) -> MobileRecord.Kind? {
        // Issue was never deployed; do not silently create a second cloud record type.
        type == "Thing" ? .issue : (type == "Issue" ? nil : MobileRecord.Kind(rawValue: type))
    }

    public static func issueID(in notification: [AnyHashable: Any]) -> String? {
        let ck = notification["ck"] as? [String: Any]
        let query = ck?["qry"] as? [String: Any]
        return (query?["af"] as? [String: Any])?[issueReferenceKey] as? String
    }

    public static func issueID(in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == issueReferenceKey })?.value
    }

    struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { return nil }
    }
}

extension MobileMessage.Role {
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(encoder.userInfo[CloudWire.context] as? Bool == true && self == .issue ? "thing" : rawValue)
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        let value = try c.decode(String.self)
        if decoder.userInfo[CloudWire.context] as? Bool == true, value == "thing" { self = .issue; return }
        guard let role = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unknown message role")
        }
        self = role
    }
}

extension MobileIssue.State {
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        // The old phone cannot decode the new states. Neither may look like an active run.
        if encoder.userInfo[CloudWire.context] as? Bool == true {
            switch self {
            case .awaitingApproval: try c.encode("needsInput"); return
            case .rejected: try c.encode("failed"); return
            default: break
            }
        }
        try c.encode(rawValue)
    }
}

extension LiveActivitySummary {
    // ActivityKit uses its own encoder/decoder, so these keys must also work without the CloudKit strategies.
    private enum WireKeys: String, CodingKey {
        case status, title, detail, runningCount, attentionCount, startedAt, newestStartedAt, updatedAt
        case issueID = "thingID"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: WireKeys.self)
        try c.encode(status, forKey: .status)
        try c.encode(title, forKey: .title)
        try c.encode(detail, forKey: .detail)
        try c.encode(runningCount, forKey: .runningCount)
        try c.encode(attentionCount, forKey: .attentionCount)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(newestStartedAt, forKey: .newestStartedAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(issueID, forKey: .issueID)
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: WireKeys.self)
        try self.init(status: c.decode(Status.self, forKey: .status), title: c.decode(String.self, forKey: .title),
                      detail: c.decode(String.self, forKey: .detail), runningCount: c.decode(Int.self, forKey: .runningCount),
                      attentionCount: c.decode(Int.self, forKey: .attentionCount), startedAt: c.decode(Date.self, forKey: .startedAt),
                      newestStartedAt: c.decode(Date.self, forKey: .newestStartedAt), updatedAt: c.decode(Date.self, forKey: .updatedAt),
                      issueID: c.decodeIfPresent(String.self, forKey: .issueID))
    }
}

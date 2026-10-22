import Foundation

/// Block-level Markdown for Stallari's messages. Inline marks (`**bold**`, `` `code` ``, links)
/// stay inside the text and are rendered by the view.
public enum MarkdownBlock: Sendable, Hashable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case listItem(marker: ListMarker, level: Int, text: String)
    case code(language: String?, text: String)
    case table(header: [String], alignments: [TableAlignment], rows: [[String]])
    case quote([MarkdownBlock])
    /// `> [!KIND] title` (GitHub/Obsidian). `> [!KIND]- title` starts folded.
    case callout(kind: CalloutKind, title: String?, folded: Bool, body: [MarkdownBlock])
    case divider
}

public enum ListMarker: Sendable, Hashable {
    case bullet
    case number(String)
    case task(done: Bool)
}

public enum TableAlignment: Sendable, Hashable { case leading, center, trailing }

/// Four meanings, the same as the status colors elsewhere in Knarr.
public enum CalloutKind: Sendable, Hashable {
    /// Blue: background, evidence, progress.
    case info
    /// Green: what got done.
    case result
    /// Red: the person has to decide or act.
    case decide
    /// Amber: stopped or risky.
    case stop

    init(tag: String) {
        switch tag.uppercased() {
        case "TIP", "RESULT", "SUCCESS", "DONE", "CHECK": self = .result
        case "DECIDE", "IMPORTANT", "CAUTION", "QUESTION", "TODO", "ACTION": self = .decide
        case "WARNING", "STOP", "DANGER", "FAILURE", "BUG": self = .stop
        default: self = .info
        }
    }
}

public enum MarkdownBlocks {
    public static func parse(_ text: String) -> [MarkdownBlock] {
        parse(lines: text.components(separatedBy: "\n"))
    }

    private static func parse(lines: [String]) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var i = 0

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }

        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)

            // Fenced code: everything up to the closing fence, indentation kept.
            if let fence = ["```", "~~~"].first(where: { line.hasPrefix($0) }) {
                flush()
                let language = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { body.append(lines[i]); i += 1 }
                blocks.append(.code(language: language.isEmpty ? nil : language, text: body.joined(separator: "\n")))
                i += 1
                continue
            }
            if line.isEmpty { flush(); i += 1; continue }

            // Quote or callout: consecutive `>` lines, parsed again inside.
            if line.hasPrefix(">") {
                flush()
                var inner: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var l = lines[i].trimmingCharacters(in: .whitespaces).dropFirst()
                    if l.hasPrefix(" ") { l = l.dropFirst() }
                    inner.append(String(l)); i += 1
                }
                if let first = inner.first, let callout = calloutHeader(first) {
                    blocks.append(.callout(kind: callout.kind, title: callout.title, folded: callout.folded,
                                           body: parse(lines: Array(inner.dropFirst()))))
                } else {
                    blocks.append(.quote(parse(lines: inner)))
                }
                continue
            }

            // Table: a pipe row followed by a separator row.
            if line.hasPrefix("|"), i + 1 < lines.count, let alignments = separator(lines[i + 1]) {
                flush()
                let header = cells(line)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    var row = cells(lines[i].trimmingCharacters(in: .whitespaces))
                    row = Array(row.prefix(header.count)) + Array(repeating: "", count: max(0, header.count - row.count))
                    rows.append(row); i += 1
                }
                let aligned = Array(alignments.prefix(header.count)) + Array(repeating: .leading, count: max(0, header.count - alignments.count))
                blocks.append(.table(header: header, alignments: aligned, rows: rows))
                continue
            }

            if line.count >= 3, ["-", "*", "_"].contains(where: { c in line.allSatisfy { String($0) == c } }) {
                flush(); blocks.append(.divider); i += 1; continue
            }

            if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                let title = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
                if level <= 6, !title.isEmpty, line.dropFirst(level).hasPrefix(" ") {
                    flush(); blocks.append(.heading(level: min(level, 3), text: title)); i += 1; continue
                }
            }

            if let item = listItem(raw) {
                flush(); blocks.append(item); i += 1; continue
            }

            paragraph.append(line)
            i += 1
        }
        flush()
        return blocks
    }

    private static func calloutHeader(_ line: String) -> (kind: CalloutKind, title: String?, folded: Bool)? {
        guard line.hasPrefix("[!"), let close = line.firstIndex(of: "]") else { return nil }
        let tag = line[line.index(line.startIndex, offsetBy: 2)..<close]
        guard !tag.isEmpty, tag.allSatisfy({ $0.isLetter }) else { return nil }
        var rest = line[line.index(after: close)...]
        var folded = false
        if rest.hasPrefix("-") { folded = true; rest = rest.dropFirst() } else if rest.hasPrefix("+") { rest = rest.dropFirst() }
        let title = rest.trimmingCharacters(in: .whitespaces)
        return (CalloutKind(tag: String(tag)), title.isEmpty ? nil : title, folded)
    }

    private static func listItem(_ raw: String) -> MarkdownBlock? {
        let indent = raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let level = min(indent / 2, 3)
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            let body = String(line.dropFirst(2))
            for (box, done) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where body.hasPrefix(box) {
                return .listItem(marker: .task(done: done), level: level, text: String(body.dropFirst(4)))
            }
            return .listItem(marker: .bullet, level: level, text: body)
        }
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let after = line.dropFirst(digits.count)
        guard let mark = after.first, mark == "." || mark == ")", after.dropFirst().hasPrefix(" ") else { return nil }
        return .listItem(marker: .number(digits + "."), level: level, text: after.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }

    private static func separator(_ raw: String) -> [TableAlignment]? {
        let parts = cells(raw.trimmingCharacters(in: .whitespaces))
        guard !parts.isEmpty else { return nil }
        var result: [TableAlignment] = []
        for part in parts {
            let p = part.trimmingCharacters(in: .whitespaces)
            let dashes = p.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            switch (p.hasPrefix(":"), p.hasSuffix(":")) {
            case (true, true): result.append(.center)
            case (false, true): result.append(.trailing)
            default: result.append(.leading)
            }
        }
        return result
    }

    /// Split a table row on unescaped pipes; `\|` stays a literal pipe.
    private static func cells(_ line: String) -> [String] {
        var body = Substring(line)
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|"), !body.hasSuffix("\\|") { body = body.dropLast() }
        var cells: [String] = [], current = "", escaped = false
        for ch in body {
            if escaped { current.append(ch == "|" ? "|" : "\\\(ch)"); escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "|" { cells.append(current.trimmingCharacters(in: .whitespaces)); current = ""; continue }
            current.append(ch)
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }
}

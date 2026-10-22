import Foundation

/// A small, language-agnostic highlighter for code blocks: keywords, strings, numbers,
/// comments, and whole-line additions/removals for diffs. Enough to make code scannable.
public struct CodeToken: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case plain, keyword, string, number, comment, added, removed }
    public let kind: Kind
    public let text: String
}

public enum CodeTokens {
    private static let hashComment: Set<String> = ["python", "py", "bash", "sh", "zsh", "shell", "ruby", "rb", "yaml", "yml", "toml", "make", "makefile", "dockerfile", "r", "perl"]
    private static let noHighlight: Set<String> = ["text", "plain", "plaintext", "txt", "console", "output", "log", "markdown", "md"]
    private static let keywords: Set<String> = [
        // Swift / Kotlin / Rust / Go
        "let", "var", "func", "fn", "fun", "if", "else", "guard", "return", "import", "struct", "class", "enum", "case",
        "switch", "for", "in", "while", "repeat", "do", "try", "catch", "await", "async", "throws", "throw", "public",
        "private", "internal", "static", "self", "Self", "true", "false", "nil", "init", "extension", "protocol", "where",
        "some", "any", "defer", "break", "continue", "default", "mut", "impl", "use", "mod", "pub", "match", "package", "go",
        // Python
        "def", "elif", "from", "except", "finally", "with", "as", "lambda", "None", "True", "False", "and", "or", "not",
        "pass", "raise", "yield", "global", "is",
        // JavaScript / TypeScript
        "const", "function", "export", "new", "this", "null", "undefined", "typeof", "interface", "type", "extends", "implements",
        // Shell
        "then", "fi", "done", "esac", "echo", "export", "local", "source", "cd", "set",
    ]

    public static func tokenize(_ code: String, language: String?) -> [CodeToken] {
        let lang = language?.lowercased().trimmingCharacters(in: .whitespaces)
        guard let lang, !noHighlight.contains(lang) else { return [.init(kind: .plain, text: code)] }
        if lang == "diff" || lang == "patch" { return diff(code) }
        let hash = hashComment.contains(lang)
        let chars = Array(code)
        var tokens: [CodeToken] = []
        var plain = ""
        var i = 0
        func emit(_ kind: CodeToken.Kind, _ text: String) {
            if !plain.isEmpty { tokens.append(.init(kind: .plain, text: plain)); plain = "" }
            tokens.append(.init(kind: kind, text: text))
        }
        func untilEndOfLine(from start: Int) -> Int { var j = start; while j < chars.count, chars[j] != "\n" { j += 1 }; return j }

        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if (!hash && c == "/" && next == "/") || (hash && c == "#") {
                let end = untilEndOfLine(from: i); emit(.comment, String(chars[i..<end])); i = end; continue
            }
            if c == "\"" || c == "'" || c == "`" {
                var j = i + 1
                while j < chars.count, chars[j] != c, chars[j] != "\n" { j += chars[j] == "\\" ? 2 : 1 }
                let end = min(j + 1, chars.count)
                emit(.string, String(chars[i..<end])); i = end; continue
            }
            if c.isNumber, plain.last.map({ !($0.isLetter || $0 == "_") }) ?? true {
                var j = i
                while j < chars.count, chars[j].isNumber || chars[j] == "." || chars[j] == "_" { j += 1 }
                emit(.number, String(chars[i..<j])); i = j; continue
            }
            if c.isLetter || c == "_", plain.last.map({ !($0.isLetter || $0.isNumber || $0 == "_" || $0 == ".") }) ?? true {
                var j = i
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                let word = String(chars[i..<j])
                if keywords.contains(word) { emit(.keyword, word) } else { plain += word }
                i = j; continue
            }
            plain.append(c); i += 1
        }
        if !plain.isEmpty { tokens.append(.init(kind: .plain, text: plain)) }
        return tokens
    }

    private static func diff(_ code: String) -> [CodeToken] {
        let lines = code.components(separatedBy: "\n")
        return lines.enumerated().flatMap { index, line -> [CodeToken] in
            let kind: CodeToken.Kind
            if line.hasPrefix("@@") || line.hasPrefix("diff ") || line.hasPrefix("index ") { kind = .comment }
            else if line.hasPrefix("+"), !line.hasPrefix("+++") { kind = .added }
            else if line.hasPrefix("-"), !line.hasPrefix("---") { kind = .removed }
            else { kind = .plain }
            let newline: [CodeToken] = index < lines.count - 1 ? [.init(kind: .plain, text: "\n")] : []
            return [.init(kind: kind, text: line)] + newline
        }
    }
}

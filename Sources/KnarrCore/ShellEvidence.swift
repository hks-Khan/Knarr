import Foundation

/// Distinguishes shell operators from quoted arguments. It never executes or expands a command.
enum ShellEvidence {
    static func isSingleCheck(_ arguments: [String]) -> Bool {
        guard !arguments.isEmpty else { return false }
        if arguments.count > 1 { return safeProgram(arguments) }
        let chars = Array(arguments[0])
        var quote: Character?, escaped = false, token = "", tokens: [String] = [], segments: [[String]] = []
        var i = 0
        func flush() { if !token.isEmpty { tokens.append(token); token = "" } }
        while i < chars.count {
            let c = chars[i]
            if escaped { token.append(c); escaped = false; i += 1; continue }
            if quote == "'" { if c == "'" { quote = nil } else { token.append(c) }; i += 1; continue }
            if c == "\\" { escaped = true; i += 1; continue }
            if c == "`" || (c == "$" && i + 1 < chars.count && chars[i + 1] == "(") { return false }
            if quote == "\"" { if c == "\"" { quote = nil } else { token.append(c) }; i += 1; continue }
            if c == "'" || c == "\"" { quote = c; i += 1; continue }
            if c == "|" || c == ";" || c == "\n" || c == "\r" || c == "(" || c == ")" { return false }
            if c == "&" {
                if i + 1 < chars.count && chars[i + 1] == "&" {
                    flush(); guard !tokens.isEmpty else { return false }; segments.append(tokens); tokens = []; i += 2; continue
                }
                if i > 0 && (chars[i - 1] == ">" || chars[i - 1] == "<") { token.append(c); i += 1; continue }
                return false
            }
            if c.isWhitespace { flush() } else { token.append(c) }
            i += 1
        }
        guard quote == nil, !escaped else { return false }
        flush(); guard !tokens.isEmpty else { return false }; segments.append(tokens)
        return segments.allSatisfy(safeProgram)
    }
    private static func safeProgram(_ tokens: [String]) -> Bool {
        var index = 0
        while index < tokens.count && (tokens[index].contains("=") || ["env", "command"].contains(tokens[index])) { index += 1 }
        guard index < tokens.count else { return false }
        let program = URL(fileURLWithPath: tokens[index]).lastPathComponent
        if ["eval", "source", "."].contains(program) { return false }
        if ["sh", "bash", "zsh", "dash", "ksh", "fish"].contains(program), tokens.dropFirst(index + 1).contains(where: { $0.hasPrefix("-") && $0.contains("c") }) { return false }
        return true
    }
}

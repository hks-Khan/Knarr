import Foundation
import Testing
@testable import KnarrUI

/// The screens take every font, color, radius and spacing from `Theme.swift` (`enum K`).
/// These read the Mac screens' source so a hard-coded value fails the suite instead of
/// slipping past review: a screen that quietly diverges from the tokens is how the app
/// drifted into 10.5pt text, five different corner radii and three reds.
struct DesignTokenTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let uiDirectory = root.appendingPathComponent("Sources/KnarrUI")

    private struct Line { let file: String; let number: Int; let text: String }

    /// Every code line of KnarrUI outside Theme.swift, comments removed.
    private func screenLines() throws -> [Line] {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.uiDirectory.path)
            .filter { $0.hasSuffix(".swift") && $0 != "Theme.swift" }.sorted()
        #expect(names.count > 10, "KnarrUI sources not found at \(Self.uiDirectory.path)")
        return try names.flatMap { name -> [Line] in
            let text = try String(contentsOf: Self.uiDirectory.appendingPathComponent(name), encoding: .utf8)
            return text.components(separatedBy: "\n").enumerated().compactMap { index, raw in
                let code = raw.replacingOccurrences(of: #"(^|\s)//.*$"#, with: "", options: .regularExpression)
                return code.trimmingCharacters(in: .whitespaces).isEmpty ? nil : Line(file: name, number: index + 1, text: code)
            }
        }
    }

    /// Fails with every `file:line: code` that matches `pattern`.
    private func expectNone(_ pattern: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let expression = try NSRegularExpression(pattern: pattern)
        let found = try screenLines().compactMap { line -> String? in
            let range = NSRange(line.text.startIndex..., in: line.text)
            guard expression.firstMatch(in: line.text, range: range) != nil else { return nil }
            return "\(line.file):\(line.number): \(line.text.trimmingCharacters(in: .whitespaces))"
        }
        #expect(found.isEmpty, Comment(rawValue: "/\(pattern)/ matched \(found.count) line(s):\n" + found.joined(separator: "\n")), sourceLocation: sourceLocation)
    }

    @Test func fontsComeFromTokensNotSystemSizes() throws {
        try expectNone(#"\.system\(size:"#)
        try expectNone(#"(?:systemFont|SystemFont)\(ofSize:\s*[0-9]"#)
    }

    @Test func colorsComeFromTokensNotLiterals() throws {
        try expectNone(#"\b0x[0-9A-Fa-f]{6,8}\b"#)
        try expectNone(#"#[0-9A-Fa-f]{6}(?:[0-9A-Fa-f]{2})?\b"#)
        try expectNone(#"Color\(\s*(?:red|white|hue|\.sRGB|\.displayP3)"#)
        // White text on an ink fill vanishes in dark mode; the tokens carry the pairing.
        try expectNone(#"\.(?:white|black)\b"#)
    }

    @Test func cornersComeFromTokens() throws {
        try expectNone(#"[cC]ornerRadius:\s*[0-9]"#)
        try expectNone(#"(?:topLeading|bottomLeading|topTrailing|bottomTrailing)Radius:\s*[0-9]"#)
    }

    @Test func themeKeepsTheFiveTextSizesPlusOneIconSize() throws {
        let theme = try String(contentsOf: Self.uiDirectory.appendingPathComponent("Theme.swift"), encoding: .utf8)
        let sizes = try NSRegularExpression(pattern: #"[sS]ize:\s*([0-9]+(?:\.[0-9]+)?)"#)
            .matches(in: theme, range: NSRange(theme.startIndex..., in: theme))
            .compactMap { Range($0.range(at: 1), in: theme).map { String(theme[$0]) } }
        // title 15, body 13.5, secondary 12 (also the mono and 12pt icons), caption 11, and the rail's 16pt icons.
        #expect(Set(sizes).isSubset(of: ["15", "13.5", "12", "11", "16"]), "Unexpected font sizes in Theme.swift: \(Set(sizes).sorted())")
    }

    @Test func spacingSitsOnTheFourPointGridAndRadiiGrow() {
        let steps = [K.s1, K.s2, K.s3, K.s4, K.s5, K.s6]
        #expect(steps.allSatisfy { $0.truncatingRemainder(dividingBy: 4) == 0 }, "spacing steps: \(steps)")
        #expect(steps == steps.sorted())
        #expect(K.rSmall < K.rCard && K.rCard < K.rLarge)
    }
}

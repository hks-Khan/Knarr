import Testing
@testable import KnarrCore

@Suite struct CodeTokensTests {
    private func kinds(_ code: String, _ language: String?) -> [String] {
        CodeTokens.tokenize(code, language: language).filter { $0.kind != .plain }.map { "\($0.kind):\($0.text)" }
    }

    @Test func swiftKeywordsStringsNumbersAndComments() {
        #expect(kinds(#"let total = add(2, 3) // "five""#, "swift") == ["keyword:let", "number:2", "number:3", #"comment:// "five""#])
        #expect(kinds(#"return "a \"quoted\" b""#, "swift") == ["keyword:return", #"string:"a \"quoted\" b""#])
    }

    @Test func pythonAndShellUseHashComments() {
        #expect(kinds("def add(a, b):  # fix\n    return a + b", "python") == ["keyword:def", "comment:# fix", "keyword:return"])
        #expect(kinds("echo 'hi' # note", "bash") == ["keyword:echo", "string:'hi'", "comment:# note"])
    }

    @Test func diffColorsWholeLines() {
        #expect(kinds("@@ -1 +1 @@\n-    return a - b\n+    return a + b\n context", "diff")
                == ["comment:@@ -1 +1 @@", "removed:-    return a - b", "added:+    return a + b"])
    }

    @Test func plainOutputIsLeftAlone() {
        #expect(kinds("FAILED (errors=1) # 2 tests", nil).isEmpty)
        #expect(kinds("let x = 1", "text").isEmpty)
    }

    @Test func tokensRebuildTheOriginalText() {
        let code = "func f() {\n  // hi\n  let s = \"x\" + 'y'\n}"
        #expect(CodeTokens.tokenize(code, language: "swift").map(\.text).joined() == code)
    }
}

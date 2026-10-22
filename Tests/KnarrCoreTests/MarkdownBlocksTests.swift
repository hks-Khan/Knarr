import Testing
@testable import KnarrCore

@Suite struct MarkdownBlocksTests {
    @Test func headingsParagraphsAndDividers() {
        let text = """
        # 결과
        ## 변경 내용
        `add`를 고쳤어요.
        두 줄 문단이에요.

        ---
        ### 남은 일
        """
        #expect(MarkdownBlocks.parse(text) == [
            .heading(level: 1, text: "결과"),
            .heading(level: 2, text: "변경 내용"),
            .paragraph("`add`를 고쳤어요.\n두 줄 문단이에요."),
            .divider,
            .heading(level: 3, text: "남은 일"),
        ])
    }

    @Test func nestedNumberedAndTaskLists() {
        let text = """
        - **변경:** `a - b` → `a + b`
          - 하위 항목
        * 별표 항목
        1. 첫째
        12) 열둘째
        - [ ] 아직
        - [x] 끝남
        """
        #expect(MarkdownBlocks.parse(text) == [
            .listItem(marker: .bullet, level: 0, text: "**변경:** `a - b` → `a + b`"),
            .listItem(marker: .bullet, level: 1, text: "하위 항목"),
            .listItem(marker: .bullet, level: 0, text: "별표 항목"),
            .listItem(marker: .number("1."), level: 0, text: "첫째"),
            .listItem(marker: .number("12."), level: 0, text: "열둘째"),
            .listItem(marker: .task(done: false), level: 0, text: "아직"),
            .listItem(marker: .task(done: true), level: 0, text: "끝남"),
        ])
    }

    @Test func fencedCodeKeepsLanguageAndIndentation() {
        let text = """
        ```swift
        let x = 1
          indented()
        ```
        ~~~
        plain
        ~~~
        """
        #expect(MarkdownBlocks.parse(text) == [
            .code(language: "swift", text: "let x = 1\n  indented()"),
            .code(language: nil, text: "plain"),
        ])
        #expect(MarkdownBlocks.parse("```bash\nrm -rf build") == [.code(language: "bash", text: "rm -rf build")])
    }

    @Test func tablesWithAlignmentEscapedPipesAndRaggedRows() {
        let text = """
        | 요소 | 표시 | 비고 |
        |:---|:---:|---:|
        | **제목** | 크게 | `a \\| b` |
        | 짧은 행 |
        """
        #expect(MarkdownBlocks.parse(text) == [
            .table(header: ["요소", "표시", "비고"], alignments: [.leading, .center, .trailing],
                   rows: [["**제목**", "크게", "`a | b`"], ["짧은 행", "", ""]]),
        ])
    }

    @Test func pipeLineWithoutSeparatorIsJustText() {
        #expect(MarkdownBlocks.parse("| 그냥 | 문장") == [.paragraph("| 그냥 | 문장")])
    }

    @Test func quotesAndCalloutsParseTheirInsides() {
        let text = """
        > 사용자가 말한 요구사항
        > - average는 건드리지 말 것

        > [!RESULT] add를 고쳤어요
        > 테스트가 통과했어요.

        > [!INFO]- 확인 2개
        > - `pytest -q` · 통과
        > - `git diff` · 통과

        > [!WARNING]
        > 원본에 커밋 안 한 변경이 있어요.
        """
        #expect(MarkdownBlocks.parse(text) == [
            .quote([.paragraph("사용자가 말한 요구사항"), .listItem(marker: .bullet, level: 0, text: "average는 건드리지 말 것")]),
            .callout(kind: .result, title: "add를 고쳤어요", folded: false, body: [.paragraph("테스트가 통과했어요.")]),
            .callout(kind: .info, title: "확인 2개", folded: true, body: [
                .listItem(marker: .bullet, level: 0, text: "`pytest -q` · 통과"),
                .listItem(marker: .bullet, level: 0, text: "`git diff` · 통과"),
            ]),
            .callout(kind: .stop, title: nil, folded: false, body: [.paragraph("원본에 커밋 안 한 변경이 있어요.")]),
        ])
    }

    @Test func calloutKindsMapToFourMeanings() {
        func kind(_ tag: String) -> CalloutKind? {
            if case .callout(let k, _, _, _) = MarkdownBlocks.parse("> [!\(tag)]\n> x").first { return k }
            return nil
        }
        #expect(kind("NOTE") == .info); #expect(kind("info") == .info)
        #expect(kind("TIP") == .result); #expect(kind("RESULT") == .result)
        #expect(kind("DECIDE") == .decide); #expect(kind("IMPORTANT") == .decide); #expect(kind("CAUTION") == .decide)
        #expect(kind("WARNING") == .stop); #expect(kind("STOP") == .stop)
        #expect(kind("UNKNOWN") == .info)
    }

    @Test func plainTextIsOneParagraph() {
        #expect(MarkdownBlocks.parse("그냥 문장") == [.paragraph("그냥 문장")])
        #expect(MarkdownBlocks.parse("") == [])
    }
}

import Foundation
private func check(_ value: Bool, _ message: String) throws {
  if !value { throw NSError(domain: "MarkdownTableTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
private func tables(_ source: String) -> [MarkdownTable] {
  MarkdownTableParser.parse(source).compactMap { if case .table(let value) = $0.content { return value }; return nil }
}
@main struct MarkdownTableTests {
  static func main() throws {
    let example = """
    Here are four options.

    | 店名 | 评分 / 评价数 | 距离 | 今日营业信息 |
    |---|---:|---:|---|
    | **Example Coffee** | **4.8** / 74 条 | 约 1.6 公里 | **08:00–23:00**；查询时尚未开门 |
    | Second Coffee | 4.4 / 864 条 | 约 2.7 公里 | 已营业，22:00 关门 |
    | 第三家🙂 | 4.3 / 484 条 | 约 1.0 公里 | 已营业，14:00 关门 |
    | Fourth Coffee | 4.2 / 439 条 | 约 1.3 公里 | 已营业，22:00 关门 |

    **怎么选：**
    - Compare the options.
    """
    let blocks = MarkdownTableParser.parse(example), table = tables(example)[0]
    try check(blocks.count == 3 && table.headers.count == 4 && table.rows.count == 4, "Four-column table not separated from surrounding prose")
    try check(table.alignments == [.leading,.trailing,.trailing,.leading], "Column alignment lost")
    try check(table.rows[0][0] == "**Example Coffee**" && table.rows[2][0] == "第三家🙂", "Cell Markdown/Unicode changed")
    print("PASS four-column mixed-language response, alignment, inline Markdown and surrounding prose")

    let escaped = #"""
    | a\|b | code |
    | :-: | ---: |
    | **x\|y** | `\|` |
    | path\\ | z |
    """#
    let e = tables(escaped)[0]
    try check(e.headers == ["a|b","code"] && e.rows[0] == ["**x|y**","`|`"], "Escaped pipes split cells")
    try check(e.rows[1] == [#"path\\"#,"z"], "Escaped backslash swallowed a delimiter")
    let optional = tables("A | B\n:-: | --:\na | b\nonly one\n\nDone")[0]
    try check(optional.rows == [["a","b"],["only one",""]], "Optional outer delimiters or short row failed")
    let extra = tables("| a | b |\n| --- | --- |\n| x | y | z |")[0]
    try check(extra.headers == ["a","b",""] && extra.rows[0] == ["x","y","z"], "Excess content silently discarded")
    try check(tables("| a |\n| - |\n| b |").first?.headers == ["a"], "Single-column table failed")
    print("PASS escaped pipes/code spans/backslashes, optional outer delimiters and variable row lengths")

    for source in ["a | b\n---\nx | y", "a | b\n--- | text\nx | y", "Heading\n---\ntext", "one | two", "    | a | b |\n    | --- | --- |\n    | x | y |", "```markdown\n| a | b |\n| --- | --- |\n```", "~~~\n| a | b |\n| --- | --- |\n~~~", "````\n```\n| a | b |\n| --- | --- |\n````"] {
      try check(tables(source).isEmpty, "Non-table or fenced code incorrectly recognized: \(source)")
      try check(MarkdownTableParser.parse(source) == [.init(id: 0, content: .text(source))], "Non-table source changed")
    }
    let afterFence = "```\n|a|b|\n|-|-|\n```\n\n|c|d|\n|-|-|\n|1|2|"
    try check(tables(afterFence).count == 1 && tables(afterFence)[0].headers == ["c","d"], "Fence state did not end correctly")
    print("PASS plain pipes, headings, invalid delimiters, indented code and matching fenced-code boundaries")
    try check(tables("  \t| a | b |\n  \t| --- | --- |\n  \t| x | y |").isEmpty,
      "Mixed space/tab indentation incorrectly became a table")

    for suffix in ["# Heading", "> Quote", "- Item", "1. Item", "```swift\nlet x = 1\n```", "---"] {
      let source = "| A | B |\n| --- | --- |\n| 1 | 2 |\n" + suffix
      try check(tables(source)[0].rows.count == 1, "Following block was swallowed into table")
    }
    let adjacent = "|a|b|\n|-|-|\n|1|2|\n|c|d|\n|-|-|\n|3|4|"
    try check(tables(adjacent).count == 2, "Adjacent explicit tables merged")
    print("PASS paragraph/block boundaries and consecutive tables")

    // Every prefix is a plausible streamed frame: it must remain safe to render.
    for end in example.indices {
      for table in tables(String(example[..<end])) {
        try check(table.headers.count == table.alignments.count, "Streamed alignment mismatch")
        try check(table.rows.allSatisfy { $0.count == table.headers.count }, "Streamed row is not rectangular")
      }
    }
    try check(tables("| A | B |\n| -- | -- |\n| 1")[0].rows == [["1",""]], "Partial final row lost")
    let crlf = example.replacingOccurrences(of: "\n", with: "\r\n")
    try check(tables(crlf) == [table], "CRLF input changed table")
    if CommandLine.arguments.count > 1 {
      let reported = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
      try check(tables(reported).contains { $0.headers.count == 4 && $0.rows.count == 4 }, "Reported message did not render as a four-by-four table")
    }
    print("PASS incremental stream prefixes, partial last row, CRLF and optional real-message regression")
  }
}

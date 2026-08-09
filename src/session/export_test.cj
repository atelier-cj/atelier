package atelier.session

import atelier.message.*
import std.collection.*
import jsonvalue.*

func expUser(text: String): Message {
    UserMessage(ContentList.ofText(text), 0)
}

func expAsst(text: String): Message {
    AssistantMessage(ContentList.ofText(text), "gpt-4o", "openai", StopReason.EndTurn, TokenUsage(0, 0), 0)
}

func expTool(name: String, text: String): Message {
    ToolResultMessage("call_1", name, ContentList.ofText(text), false, 0)
}

// 去除空行后按行拆分（导出器每条消息输出一行）
func jsonlLines(text: String): ArrayList<String> {
    let lines = ArrayList<String>()
    for (l in text.split("\n")) {
        if (l != "") { lines.add(l) }
    }
    lines
}

func roleOf(line: String): String {
    let v = JsonValue.parse(line)
    match (v["role"]) {
        case Some(JsonValue.String(s)) => s
        case _ => ""
    }
}

func contentOf(line: String): String {
    let v = JsonValue.parse(line)
    match (v["content"]) {
        case Some(JsonValue.String(s)) => s
        case _ => ""
    }
}

@Test
func exportJsonl_basicRoles() {
    let msgs = ArrayList<Message>()
    msgs.add(expUser("你好"))
    msgs.add(expAsst("回复"))
    msgs.add(expTool("read_file", "内容"))
    let lines = jsonlLines(exportToJsonl(msgs))
    @Expect(lines.size, 3)
    @Expect(roleOf(lines[0]), "user")
    @Expect(roleOf(lines[1]), "assistant")
    @Expect(roleOf(lines[2]), "tool")
    @Expect(contentOf(lines[0]), "你好")
    @Expect(contentOf(lines[1]), "回复")
    @Expect(contentOf(lines[2]), "内容")
}

// 特殊字符必须被正确转义，保证每行仍是合法 JSON 且内容保真
@Test
func exportJsonl_specialCharsEscaped() {
    let msgs = ArrayList<Message>()
    msgs.add(expUser("a\"b\\c<d>&e"))
    let lines = jsonlLines(exportToJsonl(msgs))
    @Expect(lines.size, 1)
    @Expect(contentOf(lines[0]), "a\"b\\c<d>&e")
}

// 含真实换行的内容不能破坏 JSONL 的一行一消息结构
@Test
func exportJsonl_newlineInContent() {
    let msgs = ArrayList<Message>()
    msgs.add(expAsst("line1\nline2"))
    let lines = jsonlLines(exportToJsonl(msgs))
    @Expect(lines.size, 1)
    @Expect(contentOf(lines[0]), "line1\nline2")
}

@Test
func exportJsonl_compactionSkipped() {
    let msgs = ArrayList<Message>()
    msgs.add(CompactionMessage("摘要", 10, 0))
    @Expect(exportToJsonl(msgs), "")
}

@Test
func exportJsonl_empty() {
    @Expect(exportToJsonl(ArrayList<Message>()), "")
}

@Test
func exportHtml_basic() {
    let msgs = ArrayList<Message>()
    msgs.add(expUser("用户问题"))
    msgs.add(expAsst("助手回复"))
    msgs.add(expTool("read_file", "文件内容"))
    let out = exportToHtml(msgs)
    @Expect(out.contains("<!DOCTYPE html>"), true)
    @Expect(out.contains("<div class=\"msg user\">"), true)
    @Expect(out.contains("<div class=\"msg assistant\">"), true)
    @Expect(out.contains("<div class=\"msg tool\">"), true)
    @Expect(out.contains("用户问题"), true)
    @Expect(out.contains("助手回复"), true)
    @Expect(out.contains("read_file"), true)
    @Expect(out.contains("文件内容"), true)
    @Expect(out.endsWith("</body></html>"), true)
}

@Test
func exportHtml_escapesHtml() {
    let msgs = ArrayList<Message>()
    msgs.add(expUser("<script>alert(1)</script>"))
    let out = exportToHtml(msgs)
    @Expect(out.contains("<script>alert(1)</script>"), false)
    @Expect(out.contains("&lt;script&gt;alert(1)&lt;/script&gt;"), true)
}

@Test
func exportHtml_empty() {
    let out = exportToHtml(ArrayList<Message>())
    @Expect(out.contains("<!DOCTYPE html>"), true)
    @Expect(out.endsWith("</body></html>"), true)
    @Expect(out.contains("msg user"), false)
}

package cli

import atelier.message.*

func plainMsg(text: String): Message { UserMessage(ContentList.ofText(text), 0) }

func asstMsg(text: String): Message {
    AssistantMessage(ContentList.ofText(text), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0)
}

@Test
func wrapText_ascii() {
    let lines = wrapText("abcdef", 3)
    @Expect(lines.size, 2)
    @Expect(lines[0], "abc")
    @Expect(lines[1], "def")
}

@Test
func wrapText_exactFit() {
    let lines = wrapText("abcd", 4)
    @Expect(lines.size, 1)
    @Expect(lines[0], "abcd")
}

@Test
func wrapText_cjkWidth() {
    // 每个 CJK 字符按显示宽度 2 计：宽 5 容 "你好"(4)，加 "世"(2) 超宽 → 拆行
    let lines = wrapText("你好世界", 5)
    @Expect(lines.size, 2)
    @Expect(lines[0], "你好")
    @Expect(lines[1], "世界")
}

@Test
func wrapText_cjkMixed() {
    let lines = wrapText("a你b", 3)
    @Expect(lines.size, 2)
    @Expect(lines[0], "a你")
    @Expect(lines[1], "b")
}

@Test
func wrapText_empty() {
    let lines = wrapText("", 10)
    @Expect(lines.size, 1)
    @Expect(lines[0], "")
}

@Test
func wrapText_zeroWidth() {
    let lines = wrapText("ab", 0)
    @Expect(lines.size, 1)
    @Expect(lines[0], "ab")
}

@Test
func messageText_user() {
    @Expect(messageText(plainMsg("hello")), "hello")
}

@Test
func messageText_assistant() {
    @Expect(messageText(asstMsg("world")), "world")
}

@Test
func contentText_extractsTextBlocks() {
    @Expect(contentText(ContentList.ofText("你好")), "你好")
}

@Test
func chatLinePrefix_user() {
    @Expect(chatLinePrefix(MessageRole.User), "you: ")
}

@Test
func chatLinePrefix_others() {
    @Expect(chatLinePrefix(MessageRole.Assistant), "ai:  ")
    @Expect(chatLinePrefix(MessageRole.ToolResult), "ai:  ")
    @Expect(chatLinePrefix(MessageRole.Compaction), "ai:  ")
}

@Test
func runeWidthSum_ascii() {
    let runes = "abc".toRuneArray()
    @Expect(runeWidthSum(runes), 3)
}

@Test
func runeWidthSum_cjk() {
    let runes = "你好a".toRuneArray()
    @Expect(runeWidthSum(runes), 5)
}

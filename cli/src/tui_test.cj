package cli

import std.collection.*
import atelier.message.*
import atelier.agent.*
import atelier.provider.*
import atelier.session.*
import atelier.tool.*
import atelier.trust.*
import atelier.skill.*
import atelier.event.EventStream
import ystyle::xisp.terminal.*

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

// ═══════ 无头事件循环 e2e：验证「打字 → 回车 → 聊天 → 落库」全链路 ═══════


// 脚本化按键终端：队列读完自动回 Esc（安全退出，避免死循环）
class FakeTerminal <: Terminal {
    private var keys: ArrayList<KeyEvent>

    public init(keys: ArrayList<KeyEvent>) { this.keys = keys }

    public func enableRawMode(): Bool { true }
    public func disableRawMode(): Bool { true }
    public func isRawModeEnabled(): Bool { true }
    public func readKey(): Option<KeyEvent> {
        if (this.keys.size == 0) { return Some(KeyEvent(KeyCode.Esc, KeyModifiers())) }
        let k = this.keys[0]
        this.keys.remove(0..1)
        Some(k)
    }
    public func getTerminalSize(): (Int64, Int64) { (80, 24) }
    public func isTTY(): Bool { true }
}

// 固定回复的 Provider（不连网络，复刻核心 runtime_test 的 StubProvider）
class StubProvider <: Provider {
    public func name(): String { "stub" }

    public func chat(req: ChatRequest): ChatResponse {
        let msg = AssistantMessage(ContentList.ofText("ok"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0)
        ChatResponse(msg)
    }

    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        let stream = EventStream<ChatDelta, AssistantMessage>()
        let msg = AssistantMessage(ContentList.ofText("ok"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0)
        stream.emit(ChatDelta("", "", Some(msg.stopReason)))
        stream.setResult(msg)
        stream
    }
}

@Test
func chatTui_enterSubmitsAndPersists() {
    let keys = ArrayList<KeyEvent>()
    keys.add(KeyEvent(KeyCode.Char(Rune(UInt32(104))), KeyModifiers()))  // h
    keys.add(KeyEvent(KeyCode.Char(Rune(UInt32(105))), KeyModifiers()))  // i
    keys.add(KeyEvent(KeyCode.Enter, KeyModifiers()))
    keys.add(KeyEvent(KeyCode.Esc, KeyModifiers()))
    let fake = FakeTerminal(keys)
    let store = MemorySessionStore()
    let trustMgr = TrustManager()
    let tui = ChatTui("default", SlashCommandRegistry(trustMgr), AgentConfig.default(), StubProvider(),
        ToolRegistry(), store, trustMgr, SkillRegistry(), AgentRegistry(), ProviderRegistry(),
        "sess_test_enter", McpManager(), "/tmp/atelier-tui-test")
    tui.runWith(fake)
    // 回车后消息应落库：首条用户 hi，末条助手 ok
    let msgs = store.load("sess_test_enter")
    @Expect(msgs.size >= 2, true)
    match (msgs[0]) {
        case um: UserMessage => @Expect(contentText(um.content), "hi")
        case _ => @Fail("expected user message first")
    }
    match (msgs[msgs.size - 1]) {
        case am: AssistantMessage => @Expect(contentText(am.content), "ok")
        case _ => @Fail("expected assistant reply last")
    }
}

@Test
func chatTui_systemPromptExcludedFromConversation() {
    // 带系统提示词的配置：运行时把提示词注入工作列表头部（UserMessage），
    // 显示与落库都必须排除它——首条应为用户 hi，而非提示词文本
    let keys = ArrayList<KeyEvent>()
    keys.add(KeyEvent(KeyCode.Char(Rune(UInt32(104))), KeyModifiers()))
    keys.add(KeyEvent(KeyCode.Char(Rune(UInt32(105))), KeyModifiers()))
    keys.add(KeyEvent(KeyCode.Enter, KeyModifiers()))
    keys.add(KeyEvent(KeyCode.Esc, KeyModifiers()))
    let fake = FakeTerminal(keys)
    let store = MemorySessionStore()
    let trustMgr = TrustManager()
    let cfg = AgentConfig("t", None, "你是系统提示词", None, "m", None,
        ArrayList<String>(), ArrayList<String>(), 3, UInt32(20), Float32(0.7),
        UInt32(4096), None, false, UInt32(16384), UInt32(20000), None,
        UInt32(50), UInt32(30), UInt32(0), ArrayList<String>(), None, Int64(0), Int64(0))
    let tui = ChatTui("default", SlashCommandRegistry(trustMgr), cfg, StubProvider(),
        ToolRegistry(), store, trustMgr, SkillRegistry(), AgentRegistry(), ProviderRegistry(),
        "sess_test_prompt", McpManager(), "/tmp/atelier-tui-test")
    tui.runWith(fake)
    let msgs = store.load("sess_test_prompt")
    @Expect(msgs.size >= 2, true)
    match (msgs[0]) {
        case um: UserMessage => @Expect(contentText(um.content), "hi")
        case _ => @Fail("expected user hi first (system prompt must be excluded)")
    }
    match (msgs[msgs.size - 1]) {
        case am: AssistantMessage => @Expect(contentText(am.content), "ok")
        case _ => @Fail("expected assistant reply last")
    }
}

@Test
func truncateLine_ascii() {
    @Expect(truncateLine("hello world", 5), "hello...")
}

@Test
func truncateLine_fits() {
    @Expect(truncateLine("ab", 5), "ab")
}

@Test
func truncateLine_cjk() {
    // "你好" 宽 4 恰好；"世" 超宽 → 截断补 "..."
    @Expect(truncateLine("你好世界", 4), "你好...")
}

@Test
func truncateLine_zeroWidth() {
    @Expect(truncateLine("ab", 0), "")
}

@Test
func toolLineText_basic() {
    let tr = ToolResultMessage("call_1", "bash", ContentList.ofText("ok"), false, 0)
    @Expect(toolLineText(tr, 40), "tool: bash  ok")
}

@Test
func toolLineText_errorMark() {
    let tr = ToolResultMessage("call_1", "bash", ContentList.ofText("cmd not found"), true, 0)
    @Expect(toolLineText(tr, 40), "tool: bash ⚠  cmd not found")
}

@Test
func toolLineText_emptyResult() {
    let tr = ToolResultMessage("call_1", "bash", ContentList.ofText(""), false, 0)
    @Expect(toolLineText(tr, 40), "tool: bash")
}

@Test
func toolLineText_truncatesResult() {
    let tr = ToolResultMessage("call_1", "read_file", ContentList.ofText("abcdefghijklmnop"), false, 0)
    // 宽 20 → 结果区 12：abcdefghijkl 后截断补 ...
    @Expect(toolLineText(tr, 20), "tool: read_file  abcdefghijkl...")
}

@Test
func colorize_wrapsAnsi() {
    let out = colorize("abc", C_USER)
    @Expect(out, C_USER + "abc" + C_RESET)
}

@Test
func decorateMessageLines_userColored() {
    let lines = decorateMessageLines(plainMsg("你好"), 40)
    @Expect(lines.size, 1)
    // 前缀着色 + 前缀后立即 RESET（正文默认色）
    @Expect(lines[0].startsWith(C_USER + "you: "), true)
    @Expect(lines[0].contains(C_USER + "you: " + C_RESET), true)
    @Expect(lines[0].contains("你好"), true)
}

@Test
func decorateMessageLines_assistantColored() {
    let lines = decorateMessageLines(asstMsg("回复"), 40)
    @Expect(lines.size, 1)
    @Expect(lines[0].startsWith(C_AI + "ai:  "), true)
    @Expect(lines[0].contains("回复"), true)
}

@Test
func decorateMessageLines_toolColored() {
    let tr = ToolResultMessage("call_1", "bash", ContentList.ofText("ok"), false, 0)
    let lines = decorateMessageLines(tr, 40)
    @Expect(lines.size, 1)
    @Expect(lines[0].startsWith(C_TOOL + "tool: bash"), true)
    @Expect(lines[0].endsWith(C_RESET), true)
}

@Test
func decorateMessageLines_wrapContinuationIndented() {
    let lines = decorateMessageLines(plainMsg("abcdefghij"), 10)
    @Expect(lines.size, 2)
    @Expect(lines[1].startsWith("     "), true)   // 续行缩进 5 格
}

@Test
func chatHistory_pushDedupesAdjacent() {
    let h = ChatHistory()
    h.push("a")
    h.push("a")
    h.push("b")
    let first = h.up("")
    @Expect(first, Some("b"))
    let second = h.up("b")
    @Expect(second, Some("a"))
    // 越过最旧一条后不再上移
    let third = h.up("a")
    @Expect(third, Some("a"))
}

@Test
func chatHistory_downRestoresDraft() {
    let h = ChatHistory()
    h.push("a")
    h.push("b")
    let up1 = h.up("草稿")
    @Expect(up1, Some("b"))
    let up2 = h.up("b")
    @Expect(up2, Some("a"))
    let down1 = h.down()
    @Expect(down1, Some("b"))
    let down2 = h.down()
    @Expect(down2, Some("草稿"))
}

@Test
func chatHistory_empty() {
    let h = ChatHistory()
    @Expect(h.up(""), None)
    @Expect(h.down(), None)
    h.push("")
    @Expect(h.up(""), None)
}

@Test
func toRunes_roundtrip() {
    @Expect(String(toRunes("你好abc")), "你好abc")
}

// ═══════ 会话选择器 ═══════

@Test
func sessionPicker_navigation() {
    let ids = ArrayList<String>()
    ids.add("sess_a")
    ids.add("sess_b")
    ids.add("sess_c")
    let p = SessionPicker(ids)
    @Expect(p.index(), 0)
    @Expect(p.selected(), "sess_a")
    p.moveUp()          // 顶部不再上移
    @Expect(p.index(), 0)
    p.moveDown()
    @Expect(p.index(), 1)
    @Expect(p.selected(), "sess_b")
    p.moveDown()
    p.moveDown()        // 底部不再下移
    @Expect(p.index(), 2)
    @Expect(p.idAt(1), "sess_b")
    @Expect(p.size(), 3)
}

func textKeys(text: String): ArrayList<KeyEvent> {
    let keys = ArrayList<KeyEvent>()
    for (r in text.toRuneArray()) {
        keys.add(KeyEvent(KeyCode.Char(r), KeyModifiers()))
    }
    keys
}

@Test
func chatTui_sessionPickerInteractiveSwitch() {
    let store = MemorySessionStore()
    store.save("sess_a", SessionHeader(1, "sess_a", 0, 0, "", "", "", None),
        ArrayList<Message>([UserMessage(ContentList.ofText("msgA"), 0)]))
    store.save("sess_b", SessionHeader(1, "sess_b", 0, 0, "", "", "", None),
        ArrayList<Message>([UserMessage(ContentList.ofText("msgB"), 0)]))
    let trustMgr = TrustManager()
    let tui = ChatTui("default", SlashCommandRegistry(trustMgr), AgentConfig.default(), StubProvider(),
        ToolRegistry(), store, trustMgr, SkillRegistry(), AgentRegistry(), ProviderRegistry(),
        "sess_test_picker", McpManager(), "/tmp/atelier-tui-test")

    // /session list → 选择模式 → ↓ 选 sess_b → Enter 切换 → 发 hi → Esc 退出
    let keys = textKeys("/session list")
    keys.add(KeyEvent(KeyCode.Enter, KeyModifiers()))
    keys.add(KeyEvent(KeyCode.Down, KeyModifiers()))
    keys.add(KeyEvent(KeyCode.Enter, KeyModifiers()))
    keys.add(KeyEvent(KeyCode.Char(Rune(UInt32(104))), KeyModifiers()))
    keys.add(KeyEvent(KeyCode.Char(Rune(UInt32(105))), KeyModifiers()))
    keys.add(KeyEvent(KeyCode.Enter, KeyModifiers()))
    keys.add(KeyEvent(KeyCode.Esc, KeyModifiers()))
    tui.runWith(FakeTerminal(keys))

    // 切换后聊天落到 sess_b（msgB + 本轮回复 ok）
    let b = store.load("sess_b")
    @Expect(b.size >= 2, true)
    match (b[b.size - 1]) {
        case am: AssistantMessage => @Expect(contentText(am.content), "ok")
        case _ => @Fail("expected assistant ok in sess_b")
    }
    // sess_a 不受影响
    let a = store.load("sess_a")
    @Expect(a.size, 1)
}

@Test
func chatTui_switchAgentStartsNewSession() {
    let store = MemorySessionStore()
    let trustMgr = TrustManager()
    let agentReg = AgentRegistry()
    agentReg.create("a1", AgentConfig.default())
    agentReg.create("a2", AgentConfig.default())
    let tui = ChatTui("a1", SlashCommandRegistry(trustMgr), AgentConfig.default(), StubProvider(),
        ToolRegistry(), store, trustMgr, SkillRegistry(), agentReg, ProviderRegistry(),
        "sess_test_agent", McpManager(), "/tmp/atelier-tui-test")

    // m1 聊天 → 落在 sess_test_agent；/agent a2 切换（新会话）；m2 聊天 → 新会话
    let keys = textKeys("m1")
    keys.add(KeyEvent(KeyCode.Enter, KeyModifiers()))
    let agentCmd = textKeys("/agent a2")
    for (k in agentCmd) { keys.add(k) }
    keys.add(KeyEvent(KeyCode.Enter, KeyModifiers()))
    let m2 = textKeys("m2")
    for (k in m2) { keys.add(k) }
    keys.add(KeyEvent(KeyCode.Enter, KeyModifiers()))
    keys.add(KeyEvent(KeyCode.Esc, KeyModifiers()))
    tui.runWith(FakeTerminal(keys))

    // 原会话只有 m1 + ok1（切换后的聊天去了新会话）
    let a = store.load("sess_test_agent")
    @Expect(a.size, 2)
    match (a[a.size - 1]) {
        case am: AssistantMessage => @Expect(contentText(am.content), "ok")
        case _ => @Fail("expected ok in original session")
    }
}

// ═══════ 会话信息条 / 状态净化 ═══════

@Test
func countUserTurns_onlyUser() {
    let msgs = ArrayList<Message>()
    msgs.add(plainMsg("a"))
    msgs.add(asstMsg("b"))
    msgs.add(plainMsg("c"))
    msgs.add(ToolResultMessage("c1", "bash", ContentList.ofText("ok"), false, 0))
    @Expect(countUserTurns(msgs), 2)
}

@Test
func contextChars_sumOfText() {
    let msgs = ArrayList<Message>()
    msgs.add(plainMsg("你好"))
    msgs.add(asstMsg("回复"))
    @Expect(contextChars(msgs), 4)
}

@Test
func sessionInfoText_format() {
    let text = sessionInfoText("assistant", "gpt-4o", 3, 1234, 100, 25)
    @Expect(text.contains("Agent: assistant"), true)
    @Expect(text.contains("Model: gpt-4o"), true)
    @Expect(text.contains("Turns: 3"), true)
    @Expect(text.contains("Ctx: 1234"), true)
    @Expect(text.contains("Tokens: 100/25"), true)
}

@Test
func sessionTokens_sumsAssistantUsage() {
    let msgs = ArrayList<Message>()
    msgs.add(plainMsg("hi"))
    msgs.add(AssistantMessage(ContentList.ofText("r1"), "", "", StopReason.EndTurn, TokenUsage(10, 5), 0))
    msgs.add(AssistantMessage(ContentList.ofText("r2"), "", "", StopReason.EndTurn, TokenUsage(30, 8), 0))
    let (inp, out) = sessionTokens(msgs)
    @Expect(inp, 40)
    @Expect(out, 13)
}

@Test
func flattenStatus_flattensAndTruncates() {
    // 宽 16 恰好容 "line1 | line2"（13 列）+ "..."；更宽的正文被截断
    let flat = flattenStatus("line1\nline2 with long text", 16)
    @Expect(flat.contains("line1"), true)
    @Expect(flat.contains("line2"), true)
    @Expect(flat.contains("\n"), false)
    @Expect(flat.toRuneArray().size <= 19, true)
}

@Test
func helpLines_eachEntryOnOwnLine() {
    let lines = helpLines()
    @Expect(lines.size >= 9, true)
    @Expect(lines[0].contains("/help"), true)
    @Expect(lines[1].contains("/agent"), true)
    @Expect(lines[2].contains("/session"), true)
    @Expect(lines[3].contains("/model"), true)
    @Expect(lines[4].contains("/tools"), true)
    @Expect(lines[5].contains("/subagent"), true)
    // 每条目独立一行（不含换行符）
    for (l in lines) {
        @Expect(l.contains("\n"), false)
    }
}

@Test
func chatTui_newAliasStartsNewSession() {
    let store = MemorySessionStore()
    let trustMgr = TrustManager()
    let tui = ChatTui("default", SlashCommandRegistry(trustMgr), AgentConfig.default(), StubProvider(),
        ToolRegistry(), store, trustMgr, SkillRegistry(), AgentRegistry(), ProviderRegistry(),
        "sess_test_new", McpManager(), "/tmp/atelier-tui-test")

    // m1 聊天 → sess_test_new；/new 开新会话；m2 聊天 → 新会话
    let keys = textKeys("m1")
    keys.add(KeyEvent(KeyCode.Enter, KeyModifiers()))
    let cmd = textKeys("/new")
    for (k in cmd) { keys.add(k) }
    keys.add(KeyEvent(KeyCode.Enter, KeyModifiers()))
    let m2 = textKeys("m2")
    for (k in m2) { keys.add(k) }
    keys.add(KeyEvent(KeyCode.Enter, KeyModifiers()))
    keys.add(KeyEvent(KeyCode.Esc, KeyModifiers()))
    tui.runWith(FakeTerminal(keys))

    // 原会话只有 m1 + ok1（/new 后的聊天去了新会话）
    let a = store.load("sess_test_new")
    @Expect(a.size, 2)
    match (a[a.size - 1]) {
        case am: AssistantMessage => @Expect(contentText(am.content), "ok")
        case _ => @Fail("expected ok in original session")
    }
}

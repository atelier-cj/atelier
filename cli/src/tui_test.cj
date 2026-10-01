package cli

import std.collection.*
import std.sync.*
import atelier.message.*
import atelier.agent.*
import atelier.provider.*
import atelier.session.*
import atelier.tool.*
import atelier.trust.*
import atelier.skill.*
import atelier.interaction.*
import jsonvalue.*
import atelier.ptc.{JsonBridge, RunXispTool}
import atelier.event.EventStream
import ystyle::xisp.terminal.*

func plainMsg(text: String): Message { UserMessage(ContentList.ofText(text), 0) }

/** 等待后台回合收尾（submit 是异步的：回合跑在后台线程，主线程要继续读键盘
 *  才能回答信任闸门的询问）。分步断言必须显式等待，不能一次把按键全喂进去。 */
func waitTurn(tui: ChatTui): Unit {
    var guard = 0
    while (tui.busy.load() && guard < 500) {
        sleep(Duration.millisecond * 10)
        guard = guard + 1
    }
}

/** 走一次完整的提交（填输入 → 提交 → 等回合结束）。 */
func submitText(tui: ChatTui, t: Terminal, text: String): Unit {
    tui.input = toRunes(text)
    tui.submit(t)
    waitTurn(tui)
}

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
    let tui = ChatTui("default", SlashCommandRegistry(trustMgr), AgentConfig.default(),
        cliTestSpec(ToolRegistry(), store, trustMgr, SkillRegistry(), AgentRegistry(), ProviderRegistry(), McpManager(), StubProvider()),
        "sess_test_enter", "/tmp/atelier-tui-test")
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
        UInt32(4096), None, false, None,
        UInt32(50), UInt32(30), UInt32(0), ArrayList<String>(), None, Int64(0), Int64(0))
    let tui = ChatTui("default", SlashCommandRegistry(trustMgr), cfg,
        cliTestSpec(ToolRegistry(), store, trustMgr, SkillRegistry(), AgentRegistry(), ProviderRegistry(), McpManager(), StubProvider()),
        "sess_test_prompt", "/tmp/atelier-tui-test")
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
    let tui = ChatTui("default", SlashCommandRegistry(trustMgr), AgentConfig.default(),
        cliTestSpec(ToolRegistry(), store, trustMgr, SkillRegistry(), AgentRegistry(), ProviderRegistry(), McpManager(), StubProvider()),
        "sess_test_picker", "/tmp/atelier-tui-test")

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
    let tui = ChatTui("a1", SlashCommandRegistry(trustMgr), AgentConfig.default(),
        cliTestSpec(ToolRegistry(), store, trustMgr, SkillRegistry(), agentReg, ProviderRegistry(), McpManager(), StubProvider()),
        "sess_test_agent", "/tmp/atelier-tui-test")

    // m1 聊天 → 落在 sess_test_agent；/agent a2 切换（新会话）；m2 聊天 → 新会话。
    // 分步驱动：一次性喂按键会让 /agent 与上一轮回合并发。
    let fake = FakeTerminal(ArrayList<KeyEvent>())
    submitText(tui, fake, "m1")
    tui.runCommand("/agent a2")
    submitText(tui, fake, "m2")

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

func helpHasEntry(lines: ArrayList<String>, keyword: String): Bool {
    for (l in lines) {
        if (l.contains(keyword)) { return true }
    }
    false
}

@Test
func helpLines_eachEntryOnOwnLine() {
    let lines = helpLines()
    @Expect(lines.size >= 10, true)
    @Expect(helpHasEntry(lines, "/help"), true)
    @Expect(helpHasEntry(lines, "/new"), true)
    @Expect(helpHasEntry(lines, "/agent"), true)
    @Expect(helpHasEntry(lines, "/session"), true)
    @Expect(helpHasEntry(lines, "/model"), true)
    @Expect(helpHasEntry(lines, "/models"), true)
    @Expect(helpHasEntry(lines, "/tools"), true)
    @Expect(helpHasEntry(lines, "/subagent"), true)
    @Expect(helpHasEntry(lines, "/clear"), true)
    // 每条目独立一行（不含换行符）
    for (l in lines) {
        @Expect(l.contains("\n"), false)
    }
}

@Test
func chatTui_newAliasStartsNewSession() {
    let store = MemorySessionStore()
    let trustMgr = TrustManager()
    let tui = ChatTui("default", SlashCommandRegistry(trustMgr), AgentConfig.default(),
        cliTestSpec(ToolRegistry(), store, trustMgr, SkillRegistry(), AgentRegistry(), ProviderRegistry(), McpManager(), StubProvider()),
        "sess_test_new", "/tmp/atelier-tui-test")

    // m1 聊天 → sess_test_new；/new 开新会话；m2 聊天 → 新会话。分步驱动，同上。
    let fake = FakeTerminal(ArrayList<KeyEvent>())
    submitText(tui, fake, "m1")
    tui.runCommand("/new")
    submitText(tui, fake, "m2")

    // 原会话只有 m1 + ok1（/new 后的聊天去了新会话）
    let a = store.load("sess_test_new")
    @Expect(a.size, 2)
    match (a[a.size - 1]) {
        case am: AssistantMessage => @Expect(contentText(am.content), "ok")
        case _ => @Fail("expected ok in original session")
    }
}

@Test
func uniqueModels_dedupesByOrder() {
    let agents = ArrayList<(String, AgentConfig)>()
    agents.add(("a1", AgentConfig("a1", None, "", None, "gpt-4o", None, ArrayList<String>(), ArrayList<String>(), 3,
        UInt32(20), Float32(0.7), UInt32(4096), None, false, None,
        UInt32(50), UInt32(30), UInt32(0), ArrayList<String>(), None, Int64(0), Int64(0))))
    agents.add(("a2", AgentConfig("a2", None, "", None, "deepseek-chat", None, ArrayList<String>(), ArrayList<String>(), 3,
        UInt32(20), Float32(0.7), UInt32(4096), None, false, None,
        UInt32(50), UInt32(30), UInt32(0), ArrayList<String>(), None, Int64(0), Int64(0))))
    agents.add(("a3", AgentConfig("a3", None, "", None, "gpt-4o", None, ArrayList<String>(), ArrayList<String>(), 3,
        UInt32(20), Float32(0.7), UInt32(4096), None, false, None,
        UInt32(50), UInt32(30), UInt32(0), ArrayList<String>(), None, Int64(0), Int64(0))))
    let models = uniqueModels(agents)
    @Expect(models.size, 2)
    @Expect(models[0], "gpt-4o")
    @Expect(models[1], "deepseek-chat")
}

// ═══════ Markdown 渲染 ═══════

@Test
func markdown_bold() {
    let lines = markdownToLines("**你好** world", 40, 0)
    @Expect(lines.size >= 1, true)
    @Expect(lines[0].contains(M_BOLD), true)
    @Expect(lines[0].contains("你好"), true)
}

@Test
func markdown_heading() {
    let lines = markdownToLines("# 标题", 40, 0)
    @Expect(lines[0].contains(M_HEADING), true)
    @Expect(lines[0].contains("#"), true)
    @Expect(lines[0].contains("标题"), true)
}

@Test
func markdown_codeBlock() {
    let lines = markdownToLines("```\ncode here\n```", 40, 0)
    var found = false
    for (l in lines) {
        if (l.contains(M_CODE) && l.contains("code here")) { found = true }
    }
    @Expect(found, true)
}

@Test
func markdown_list() {
    let lines = markdownToLines("- 第一项\n- 第二项", 40, 0)
    var b1 = false
    var b2 = false
    for (l in lines) {
        if (l.contains("•") && l.contains("第一项")) { b1 = true }
        if (l.contains("•") && l.contains("第二项")) { b2 = true }
    }
    @Expect(b1, true)
    @Expect(b2, true)
}

@Test
func markdown_link() {
    let lines = markdownToLines("[点这里](https://example.com)", 60, 0)
    @Expect(lines[0].contains("点这里"), true)
    @Expect(lines[0].contains("https://example.com"), true)
}

@Test
func markdown_wrapsAtWidth() {
    let lines = markdownToLines("一二三四五六七八九十 甲乙丙丁戊己庚辛壬癸", 12, 0)
    @Expect(lines.size >= 2, true)
}



@Test
func markdown_boldDoesNotLeak() {
    // **a** 后跟普通文本：粗体段后必须复位，普通文本不带粗体
    let lines = markdownToLines("**a** b", 40, 0)
    @Expect(lines[0].contains(M_BOLD + "a"), true)
    // 粗体段结束后复位，普通 " b" 前有 RESET
    @Expect(lines[0].contains(M_RESET + " b"), true)
    // 行尾有复位（下一行不会被继承）
    @Expect(lines[0].endsWith(M_RESET), true)
}

@Test
func markdown_noStyleLeakAcrossTypes() {
    let lines = markdownToLines("*斜* x **粗** y `码` z ~~删~~ w", 80, 0)
    let l = lines[0]
    @Expect(l.contains(M_ITALIC + "斜" + M_RESET), true)
    @Expect(l.contains(M_BOLD + "粗" + M_RESET), true)
    @Expect(l.contains(M_CODE + "码" + M_RESET), true)
    @Expect(l.contains(M_STRIKE + "删" + M_RESET), true)
}

@Test
func markdown_headingLineEndsWithReset() {
    let lines = markdownToLines("# 标题", 40, 0)
    @Expect(lines[0].endsWith(M_RESET), true)
}

@Test
func markdown_quoteLineEndsWithReset() {
    let lines = markdownToLines("> 引用", 40, 0)
    @Expect(lines[0].endsWith(M_RESET), true)
}

@Test
func markdown_listMarkerNotRepeatedOnWrap() {
    // 长条目续行只出现一次 "1. " 前缀，序号不递增
    let lines = markdownToLines("1. 一二三四五六七八九十 甲乙丙丁戊己庚辛壬癸子丑寅卯", 16, 0)
    var markerCount: Int64 = 0
    for (l in lines) {
        if (l.contains("1. ")) { markerCount = markerCount + 1 }
    }
    @Expect(markerCount, 1)
}

@Test
func conversationLines_turnSeparatorBetweenRounds() {
    let msgs = ArrayList<Message>()
    msgs.add(plainMsg("第一问"))
    msgs.add(asstMsg("第一答"))
    msgs.add(plainMsg("第二问"))
    msgs.add(asstMsg("第二答"))
    let lines = conversationLines(msgs, 40)
    // 第二问前应有分隔线：总行数 = 4 条消息行 + 1 条分隔线
    @Expect(lines.size, 5)
    // 分隔线含暗色样式与 ─
    var sepFound = false
    for (l in lines) {
        if (l.contains("─") && l.startsWith(C_DIM)) { sepFound = true }
    }
    @Expect(sepFound, true)
}

@Test
func conversationLines_noTrailingSeparator() {
    let msgs = ArrayList<Message>()
    msgs.add(plainMsg("问"))
    msgs.add(asstMsg("答"))
    let lines = conversationLines(msgs, 40)
    @Expect(lines.size, 2)   // 结尾助手回复后不再加分隔线
}

@Test
func conversationLines_singleUserNoSeparator() {
    let msgs = ArrayList<Message>()
    msgs.add(plainMsg("问"))
    let lines = conversationLines(msgs, 40)
    @Expect(lines.size, 1)
}

// ═══════ PTC：工具调用与结果的多行呈现 ═══════════════════════════════
// 工具调用此前完全不渲染、工具结果被压成一行；PTC 下程序与日志都在这两处，
// 所以要守住「调用可见、正文成块、超长折叠」，同时守住非 PTC 路径不变。

func toolCall(name: String, args: JsonValue): ToolCallBlock {
    ToolCallBlock("call_1", name, args)
}

func jsonMap(pairs: Array<(String, String)>): JsonValue {
    let m = HashMap<String, JsonValue>()
    for ((k, v) in pairs) { m.add(k, JsonValue.String(v)) }
    JsonValue.Map(m)
}

func asstMsgWithCalls(text: String, calls: Array<ToolCallBlock>): Message {
    let blocks = ArrayList<ContentBlock>()
    if (text != "") { blocks.add(ContentBlock.TextBlock(text)) }
    for (c in calls) { blocks.add(ContentBlock.ToolCall(c)) }
    AssistantMessage(ContentList(blocks), "", "", StopReason.ToolUse, TokenUsage(0, 0), 0)
}

@Test
func toolCallLines_plainToolIsSingleLineWithArgs() {
    let lines = toolCallLines(toolCall("read_file", jsonMap([("path", "a.cj")])), 80)
    @Expect(lines.size, 1)
    @Assert(lines[0].contains("tool→ read_file"))
    @Assert(lines[0].contains("a.cj"))
}

@Test
func toolCallLines_runXispExpandsProgram() {
    let args = jsonMap([("description", "读两个文件"), ("code", "(tools::read_file {:path \"a\"})\n(tools::read_file {:path \"b\"})")])
    let lines = toolCallLines(toolCall(RunXispTool.TOOL_NAME, args), 80)
    // 首行是说明，其后每行程序各占一行——程序被折叠成一行就失去了意义
    @Assert(lines[0].contains("run_xisp"))
    @Assert(lines[0].contains("读两个文件"))
    @Assert(lines.size >= 3)
    var joined = ""
    for (l in lines) { joined = joined + l + "\n" }
    @Assert(joined.contains("tools::read_file"))
    @Assert(joined.contains(":path \"b\""))
}

@Test
func toolCallLines_runXispWithoutDescription() {
    let args = jsonMap([("description", ""), ("code", "(+ 1 2)")])
    let lines = toolCallLines(toolCall(RunXispTool.TOOL_NAME, args), 80)
    @Assert(lines[0].contains("tool→ run_xisp"))
    @Expect(lines.size, 2)
}

@Test
func runXispResultLines_multiLineBody() {
    let tr = ToolResultMessage("call_1", RunXispTool.TOOL_NAME,
        ContentList.ofText("progress-line\nfinal-value"), false, 0)
    let lines = runXispResultLines(tr, 80)
    @Assert(lines[0].contains("tool← run_xisp"))
    @Assert(!lines[0].contains("⚠"))
    var joined = ""
    for (l in lines) { joined = joined + l + "\n" }
    @Assert(joined.contains("progress-line"))
    @Assert(joined.contains("final-value"))
}

@Test
func runXispResultLines_marksError() {
    let tr = ToolResultMessage("call_1", RunXispTool.TOOL_NAME,
        ContentList.ofText("[syntax_error] unexpected end of input"), true, 0)
    let lines = runXispResultLines(tr, 80)
    @Assert(lines[0].contains("⚠"))
}

@Test
func runXispResultLines_foldsLongBody() {
    let sb = StringBuilder()
    for (i in 0..(PTC_MAX_BODY_LINES + 5)) { sb.append("line-${i}\n") }
    let tr = ToolResultMessage("call_1", RunXispTool.TOOL_NAME,
        ContentList.ofText(sb.toString()), false, 0)
    let lines = runXispResultLines(tr, 80)
    // 1 行标题 + PTC_MAX_BODY_LINES 行正文 + 1 行折叠提示
    @Expect(lines.size, PTC_MAX_BODY_LINES + 2)
    @Assert(lines[lines.size - 1].contains("还有"))
}

@Test
func decorateMessageLines_rendersAssistantToolCalls() {
    // 这是此前的缺口：助手消息的 toolCalls 完全不渲染
    let calls: Array<ToolCallBlock> = [toolCall("read_file", jsonMap([("path", "a.cj")]))]
    let m = asstMsgWithCalls("我来读文件", calls)
    let lines = decorateMessageLines(m, 80)
    var joined = ""
    for (l in lines) { joined = joined + l + "\n" }
    // 前缀着色会在其后插入 RESET，因此正文要单独断言
    @Assert(lines[0].contains("ai:  "))
    @Assert(lines[0].contains("我来读文件"))
    @Assert(joined.contains("tool→ read_file"))
}

@Test
func decorateMessageLines_assistantWithoutCallsUnchanged() {
    // 回归守卫：没有 toolCalls 时行为与改动前一致（单行）
    let lines = decorateMessageLines(asstMsg("回复"), 40)
    @Expect(lines.size, 1)
    @Assert(lines[0].startsWith(C_AI + "ai:  "))
}

@Test
func decorateMessageLines_plainToolResultStillSingleLine() {
    // 回归守卫：非 run_xisp 的结果仍走一行摘要
    let tr = ToolResultMessage("call_1", "bash", ContentList.ofText("ok"), false, 0)
    let lines = decorateMessageLines(tr, 40)
    @Expect(lines.size, 1)
    @Assert(lines[0].startsWith(C_TOOL + "tool: bash"))
}

@Test
func decorateMessageLines_runXispResultIsMultiLine() {
    let tr = ToolResultMessage("call_1", RunXispTool.TOOL_NAME,
        ContentList.ofText("log-a\nanswer"), false, 0)
    let lines = decorateMessageLines(tr, 80)
    @Assert(lines.size >= 3)
    @Assert(lines[0].contains("tool← run_xisp"))
}

// ═══════ 提问：必须能被主线程回答 ═══════════════════════════════════
// 此前运行线程自己 readLine，与主线程的 readKey 抢同一个 stdin，提示又被重绘覆盖——
// 表现为「跑了几分钟没有任何反馈」，实际是在等一个用户看不到的询问。
// 收敛规则本身（选项/表单/取消）在 ask_test.cj，这里只管跨线程投递。

@Test
func askPrompt_waitsUntilResolved() {
    let req = approvalRequest("ask:s:1:c:approval", "glob", JsonValue.String("{}"),
        "Tool 'glob' needs your approval.")
    let prompt = AskPrompt(req)
    // 主线程在稍后回填；运行线程在此之前必须阻塞而不是拿到空答复
    spawn {
        sleep(Duration.millisecond * 120)
        prompt.deliver(UserAnswer(req.id, UserAnswerStatus.Answered,
            selected: ArrayList<String>(["allow_once"])))
    }
    let ans = prompt.waitAnswer()
    @Expect(ans.isAllowOnce(), true)
}

@Test
func askPrompt_firstAnswerWins() {
    let req = approvalRequest("ask:s:1:c:approval", "glob", JsonValue.String("{}"), "q")
    let prompt = AskPrompt(req)
    prompt.deliver(UserAnswer(req.id, UserAnswerStatus.Answered,
        selected: ArrayList<String>(["allow_once"])))
    // 重复回填不得覆盖：第二次是"总是允许"，先到的"本次允许"才是答复
    prompt.deliver(UserAnswer(req.id, UserAnswerStatus.Answered,
        selected: ArrayList<String>(["allow_always"])))
    @Expect(prompt.waitAnswer().isAllowOnce(), true)
}

@Test
func askPrompt_statusTextIsOneLineAndSelfDescribing() {
    let req = approvalRequest("ask:s:1:c:approval", "glob", JsonValue.String("{}"),
        "Tool 'glob' needs your approval.\n  args: {pattern: **/*}")
    let text = AskPrompt(req).statusText()
    // 状态行只有一行：保留提问对象、自述按键，多行细节留给面板
    @Assert(text.contains("glob"))
    @Assert(text.contains("↑/↓"))
    @Assert(text.contains("Esc 取消"))
    @Assert(!text.contains("pattern"))
    @Assert(!text.contains("\n"))
}

// ═══════ 提问模态：按键真的路由到提问、答复真的回到回合线程 ═══════════════
// ask_test.cj 覆盖"答复怎么收敛"，这里覆盖"谁来收"：回合线程登记并等待 →
// 主线程按键 → 答复回填。这条路径跨两个线程，只有在这里能跑到。

class AnswerBox {
    private var v: Option<UserAnswer> = None
    private let lock = Mutex()

    public func put(a: UserAnswer): Unit {
        synchronized(this.lock) {
            this.v = Some(a)
        }
    }

    public func get(): Option<UserAnswer> {
        synchronized(this.lock) {
            this.v
        }
    }
}

func makeAskTui(sessionId: String): ChatTui {
    let trustMgr = TrustManager()
    ChatTui("default", SlashCommandRegistry(trustMgr), AgentConfig.default(),
        cliTestSpec(ToolRegistry(), MemorySessionStore(), trustMgr, SkillRegistry(), AgentRegistry(), ProviderRegistry(), McpManager(), StubProvider()),
        sessionId, "/tmp/atelier-tui-test")
}

/** 等到"有提问"（want=true）或"提问已结束"（want=false）；超时返回 false。 */
func waitAskState(tui: ChatTui, want: Bool): Bool {
    var guard = 0
    while (tui.hasPendingAsk() != want && guard < 200) {
        sleep(Duration.millisecond * 20)
        guard = guard + 1
    }
    tui.hasPendingAsk() == want
}

func waitAnswerBox(box: AnswerBox): Option<UserAnswer> {
    var guard = 0
    while (box.get().isNone() && guard < 200) {
        sleep(Duration.millisecond * 20)
        guard = guard + 1
    }
    box.get()
}

func isCancelledAnswer(a: UserAnswer): Bool {
    match (a.status) {
        case UserAnswerStatus.Cancelled => true
        case _ => false
    }
}

@Test
func chatTui_askModalRoutesKeysAndAnswersTurn() {
    let tui = makeAskTui("sess_ask_modal")
    let fake = FakeTerminal(ArrayList<KeyEvent>())
    let req = approvalRequest("ask:s:1:c:approval", "bash", JsonValue.String("{}"), "批准执行？")
    let box = AnswerBox()
    spawn {
        box.put(tui.askHost(fake, req))
    }
    @Expect(waitAskState(tui, true), true)
    // 模态：方向键移动光标、回车提交 —— 都不会变成新消息
    tui.handleAskKey(KeyEvent(KeyCode.Down, KeyModifiers()), fake)
    tui.handleAskKey(KeyEvent(KeyCode.Enter, KeyModifiers()), fake)
    @Expect(waitAskState(tui, false), true)
    match (waitAnswerBox(box)) {
        case Some(a) =>
            @Expect(a.isAllowAlways(), true)
            @Expect(askValid(req, a), true)
        case None => @Fail("turn thread never received an answer")
    }
}

@Test
func chatTui_askModalEscCancelsAndTurnSeesCancelled() {
    let tui = makeAskTui("sess_ask_modal_esc")
    let fake = FakeTerminal(ArrayList<KeyEvent>())
    let req = approvalRequest("ask:s:1:c:approval", "bash", JsonValue.String("{}"), "批准执行？")
    let box = AnswerBox()
    spawn {
        box.put(tui.askHost(fake, req))
    }
    @Expect(waitAskState(tui, true), true)
    tui.handleAskKey(KeyEvent(KeyCode.Esc, KeyModifiers()), fake)
    @Expect(waitAskState(tui, false), true)
    match (waitAnswerBox(box)) {
        // Esc 取消的是这次提问，不是整个程序 —— 回合要能带着"取消"继续
        case Some(a) => @Expect(isCancelledAnswer(a), true)
        case None => @Fail("turn thread never received an answer")
    }
}

@Test
func chatTui_askModalSwallowsTypedTextInsteadOfSubmittingMessage() {
    let tui = makeAskTui("sess_ask_swallow")
    let fake = FakeTerminal(ArrayList<KeyEvent>())
    let req = choiceRequest("ask:s:1:c", "选环境", askOpts(["dev", "prod"]))
    let box = AnswerBox()
    spawn {
        box.put(tui.askHost(fake, req))
    }
    @Expect(waitAskState(tui, true), true)
    // 打字进的是输入行（文本字段要用），不是新消息；回车交的是光标处的候选
    tui.handleAskKey(KeyEvent(KeyCode.Char(Rune(UInt32(120))), KeyModifiers()), fake)
    @Expect(String(tui.input), "x")
    tui.handleAskKey(KeyEvent(KeyCode.Enter, KeyModifiers()), fake)
    @Expect(waitAskState(tui, false), true)
    match (waitAnswerBox(box)) {
        case Some(a) =>
            @Expect(a.selected.size, 1)
            @Expect(a.selected[0], "dev")
        case None => @Fail("turn thread never received an answer")
    }
    // 提问期间打的那一行没有被当成用户消息提交
    @Expect(countUserTurns(tui.messages), 0)
}


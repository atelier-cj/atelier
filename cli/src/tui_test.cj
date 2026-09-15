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

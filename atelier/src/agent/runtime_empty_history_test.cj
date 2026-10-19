package atelier.agent

/*
 * 空历史入参的契约。
 *
 * `chat(messages)` / `chatWithEnv(sessionId, messages, sessionEnv)` 的入参是调用方给出的
 * 历史，**空列表是合法输入**：新会话首轮、历史被归档或压缩清空之后都可能传空。
 * 运行时不能因为「取首条消息」而抛越界，也不能为了凑出首条而伪造一条消息。
 *
 * 复用同包的测试助手：NoopTool / endTurnMsg / ScriptedMsgProvider（见 runtime_length_continue_test.cj）、
 * testRuntime（见 test_support_test.cj）。
 */

import std.collection.*
import atelier.message.*
import atelier.provider.*
import atelier.tool.*
import atelier.session.*
import atelier.trust.*
import atelier.skill.*

// 收集运行时发出的全部事件类型名与消息开始事件，用来断言「哪些事件该发、哪些不该发」
class MessageEventCollector {
    public let types = ArrayList<String>()
    public let starts = ArrayList<Message>()

    public init(bus: EventBus) {
        bus.subscribe({ ev =>
            this.types.add(ev.eventType())
            match (ev) {
                case e: MessageStartEvent => this.starts.add(e.message)
                case _ => ()
            }
        })
    }

    public func has(evType: String): Bool {
        for (t in this.types) {
            if (t == evType) { return true }
        }
        false
    }
}

func makeEmptyHistoryRuntime(config: AgentConfig, provider: Provider,
    bus: EventBus): AgentRuntime {
    let toolReg = ToolRegistry()
    toolReg.register(NoopTool())
    let providerReg = ProviderRegistry()
    providerReg.register("default", provider)
    testRuntime(config, provider, toolReg, MemorySessionStore(), TrustManager(),
        SkillRegistry(), AgentRegistry(), providerReg, ArrayList<Hook>(),
        SessionEnvironment(), McpManager(), eventBus: Some(bus))
}

// 空历史是合法输入：不抛异常，run 正常收敛，result() 正常返回。
@Test
func runtime_emptyHistory_doesNotThrow() {
    let responses = ArrayList<AssistantMessage>()
    responses.add(endTurnMsg("ok"))
    let provider = ScriptedMsgProvider(responses)
    let bus = EventBus()
    let collector = MessageEventCollector(bus)
    let runtime = makeEmptyHistoryRuntime(AgentConfig.default(), provider, bus)

    // 越界会以异常终止 run：result() 抛出，或 result 里只剩运行时错误哨兵
    let result = runtime.chat(ArrayList<Message>()).result()
    @Expect(provider.callCount, Int64(1))
    @Expect(result.size, Int64(1))
    match (result[0]) {
        case am: AssistantMessage =>
            match (am.stopReason) {
                case StopReason.EndTurn => ()
                case _ => @Fail("空历史跑完后应当以正常回合结束收尾")
            }
        case _ => @Fail("空历史跑完后历史里应当只有这次回复")
    }
    // AgentStart / AgentEnd 括住整个 run：空历史同样是一次完整的执行
    @Expect(collector.has("agent_start"), true)
    @Expect(collector.has("agent_end"), true)
}

// MessageStartEvent 的载荷是**一条具体消息**，语义是「这条消息开始播放」。
// 空历史时不存在这条消息 —— 不发，而不是伪造一条占位消息（协议适配层按 role 分派，
// 伪造会让它开出消息 id 并等一个永远不会到来的正文）。
@Test
func runtime_emptyHistory_emitsNoMessageStart() {
    let responses = ArrayList<AssistantMessage>()
    responses.add(endTurnMsg("ok"))
    let provider = ScriptedMsgProvider(responses)
    let bus = EventBus()
    let collector = MessageEventCollector(bus)
    let runtime = makeEmptyHistoryRuntime(AgentConfig.default(), provider, bus)
    runtime.chat(ArrayList<Message>()).result()

    @Expect(collector.starts.size, Int64(0))
    // 回合本身仍然被 TurnStart / TurnEnd 括起：「有回合在跑」不靠 MessageStart 表达
    @Expect(collector.has("turn_start"), true)
    @Expect(collector.has("turn_end"), true)
    // 回复本身照常经 MessageEnd 交付
    @Expect(collector.has("message_end"), true)
}

// 非空历史照旧：首条消息发 MessageStartEvent（上一条放宽的只是空历史这一种情况）
@Test
func runtime_nonEmptyHistory_stillEmitsMessageStart() {
    let responses = ArrayList<AssistantMessage>()
    responses.add(endTurnMsg("ok"))
    let provider = ScriptedMsgProvider(responses)
    let bus = EventBus()
    let collector = MessageEventCollector(bus)
    let runtime = makeEmptyHistoryRuntime(AgentConfig.default(), provider, bus)
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("hi"), 0))
    runtime.chat(msgs).result()

    @Expect(collector.starts.size, Int64(1))
    match (collector.starts[0]) {
        case um: UserMessage => @Expect(textOfMsg(um), "hi")
        case _ => @Fail("MessageStartEvent 应当携带历史首条消息")
    }
}

// 历史被归档/压缩清空后从空列表续跑（同一 runtime、同一会话）：同样不崩
@Test
func runtime_emptyHistory_explicitSessionIdContinues() {
    let responses = ArrayList<AssistantMessage>()
    responses.add(endTurnMsg("第一轮"))
    responses.add(endTurnMsg("第二轮"))
    let provider = ScriptedMsgProvider(responses)
    let bus = EventBus()
    let runtime = makeEmptyHistoryRuntime(AgentConfig.default(), provider, bus)
    let first = runtime.chatWithSessionId("sess_empty_history",
        ArrayList<Message>(), SessionEnvironment()).result()
    let second = runtime.chatWithSessionId("sess_empty_history",
        ArrayList<Message>(), SessionEnvironment()).result()
    @Expect(provider.callCount, Int64(2))
    @Expect(first.size, Int64(1))
    @Expect(second.size, Int64(1))
}

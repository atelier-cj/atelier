package atelier.agent

import jsonvalue.*
import std.collection.*
import atelier.message.*
import atelier.provider.*
import atelier.tool.*
import atelier.session.*
import atelier.trust.*
import atelier.skill.*
import atelier.event.EventStream

@Test
func beforeToolDecision_variants() {
    let allow = BeforeToolDecision.Allow
    @Expect(allow is BeforeToolDecision, true)
    let deny = BeforeToolDecision.Deny("not allowed")
    @Expect(deny is BeforeToolDecision, true)
    let modify = BeforeToolDecision.Modify(JsonValue.Map(HashMap<String, JsonValue>()))
    @Expect(modify is BeforeToolDecision, true)
}

@Test
func turnDecision_variants() {
    let req = ChatRequest("m", ArrayList<Message>(), 0.7, 100, None, ArrayList())
    let cont = TurnDecision.Continue(req)
    @Expect(cont is TurnDecision, true)
    let sc = TurnDecision.ShortCircuit("stop")
    @Expect(sc is TurnDecision, true)
}

@Test
func hookState_getSet() {
    let st = HookState()
    st.set("cost", JsonValue.Number(1.5))
    match (st.get("cost")) {
        case Some(JsonValue.Number(n)) => @Expect(n, 1.5)
        case _ => @Fail("expected number")
    }
    match (st.get("missing")) {
        case None => ()
        case _ => @Fail("expected None for missing key")
    }
}

func makeChatRequest(): ChatRequest {
    ChatRequest("m", ArrayList<Message>(), 0.7, 100, None, ArrayList())
}

func makeHookCtx(): HookContext {
    HookContext(AgentConfig.default(), ToolRegistry(), 1, HookState())
}

@Test
func hookContext_carriesState() {
    let ctx = makeHookCtx()
    ctx.state.set("k", JsonValue.String("v"))
    match (ctx.state.get("k")) {
        case Some(JsonValue.String(s)) => @Expect(s, "v")
        case _ => @Fail("state not shared")
    }
}

class RecordingHook <: Hook {
    public var events: ArrayList<String> = ArrayList<String>()
    public override func beforeRun(ctx: HookContext): Unit {
        this.events.add("beforeRun")
    }
    public override func afterRun(ctx: HookContext): Unit {
        this.events.add("afterRun")
    }
    public override func beforeTurn(ctx: HookContext, request: ChatRequest): TurnDecision {
        this.events.add("beforeTurn")
        TurnDecision.Continue(request)
    }
    public override func afterTurn(ctx: HookContext): AfterTurnUpdate {
        this.events.add("afterTurn")
        AfterTurnUpdate.none()
    }
    public override func beforeTool(ctx: HookContext, call: ToolCallBlock): BeforeToolDecision {
        this.events.add("beforeTool")
        BeforeToolDecision.Allow
    }
    public override func afterTool(ctx: HookContext, call: ToolCallBlock, result: ToolResultMessage): Unit {
        this.events.add("afterTool")
    }
}

class NoopHook <: Hook {}

@Test
func hook_defaultImplsAreNoops() {
    let h = NoopHook()
    let ctx = makeHookCtx()
    h.beforeRun(ctx)
    h.afterRun(ctx)
    let cont = h.beforeTurn(ctx, makeChatRequest())
    match (cont) {
        case TurnDecision.Continue(r) => @Expect(r.model, "m")
        case _ => @Fail("default should continue")
    }
    let upd = h.afterTurn(ctx)
    @Expect(upd.shortCircuit, false)
    match (upd.messages) {
        case None => ()
        case _ => @Fail("default should not modify messages")
    }
    let allow = h.beforeTool(ctx, ToolCallBlock("c1", "t", JsonValue.Map(HashMap<String, JsonValue>())))
    match (allow) {
        case BeforeToolDecision.Allow => ()
        case _ => @Fail("default should allow")
    }
}

@Test
func hook_recordingHookEvents() {
    let h = RecordingHook()
    let ctx = makeHookCtx()
    h.beforeRun(ctx)
    h.afterRun(ctx)
    h.beforeTurn(ctx, makeChatRequest())
    h.afterTurn(ctx)
    h.beforeTool(ctx, ToolCallBlock("c1", "t", JsonValue.Map(HashMap<String, JsonValue>())))
    h.afterTool(ctx, ToolCallBlock("c1", "t", JsonValue.Map(HashMap<String, JsonValue>())), ToolResultMessage("c1", "t", ContentList.ofText("ok"), false, 0))
    @Expect(h.events, ArrayList<String>(["beforeRun", "afterRun", "beforeTurn", "afterTurn", "beforeTool", "afterTool"]))
}

func makeAssistantMsg(text: String, reason: StopReason): AssistantMessage {
    let blocks = ArrayList<ContentBlock>()
    blocks.add(ContentBlock.TextBlock(text))
    AssistantMessage(ContentList(blocks), "m", "fake", reason, TokenUsage(0, 0), 0)
}

func makeToolUseMsg(name: String, toolCallId: String): AssistantMessage {
    let tc = ToolCallBlock(toolCallId, name, JsonValue.Map(HashMap<String, JsonValue>()))
    let blocks = ArrayList<ContentBlock>()
    blocks.add(ContentBlock.ToolCall(tc))
    AssistantMessage(ContentList(blocks), "m", "fake", StopReason.ToolUse, TokenUsage(0, 0), 0)
}

class FakeProvider <: Provider {
    public var responses: ArrayList<AssistantMessage>
    public var callCount: Int64 = 0

    public init(responses: ArrayList<AssistantMessage>) {
        this.responses = responses
    }

    public func name(): String { "fake" }

    public func chat(req: ChatRequest): ChatResponse {
        let msg = this.responses[this.callCount]
        this.callCount++
        ChatResponse(msg)
    }

    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        let stream = EventStream<ChatDelta, AssistantMessage>()
        let idx = this.callCount
        this.callCount++
        let msg = this.responses[idx]
        let delta = ChatDelta("", "", Some(msg.stopReason))
        stream.emit(delta)
        stream.setResult(msg)
        stream
    }
}

func makeRuntime(config: AgentConfig, provider: Provider, hooks: ArrayList<Hook>): AgentRuntime {
    let toolReg = ToolRegistry()
    let sessionStore = MemorySessionStore()
    let trustMgr = TrustManager()
    let skillReg = SkillRegistry()
    let agentReg = AgentRegistry()
    let providerReg = ProviderRegistry()
    providerReg.register("default", provider)
    AgentRuntime(config, provider, toolReg, sessionStore, trustMgr,
        skillReg, agentReg, providerReg, hooks, { q => "" })
}

class CountingTool <: Tool {
    public var calls: Int64 = 0
    public func name(): String { "count_tool" }
    public func description(): String { "counts" }
    public func schema(): JsonValue {
        JsonValue.Map(HashMap<String, JsonValue>())
    }
    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        this.calls++
        ToolResult("ok", None, false, false)
    }
    public func executionMode(): ToolExecutionMode {
        ToolExecutionMode.Parallel
    }
}

class BlockingHook <: Hook {
    public override func beforeTool(ctx: HookContext, call: ToolCallBlock): BeforeToolDecision {
        BeforeToolDecision.Deny("blocked for test")
    }
}

@Test
func beforeTool_deny_blocksExecution() {
    let tool = CountingTool()
    let toolReg = ToolRegistry()
    toolReg.register(tool)

    let responses = ArrayList<AssistantMessage>()
    responses.add(makeToolUseMsg("count_tool", "call_1"))
    responses.add(makeAssistantMsg("done", StopReason.EndTurn))
    let provider = FakeProvider(responses)

    let config = AgentConfig.default()
    let sessionStore = MemorySessionStore()
    let trustMgr = TrustManager()
    let skillReg = SkillRegistry()
    let agentReg = AgentRegistry()
    let providerReg = ProviderRegistry()
    providerReg.register("default", provider)
    let hooks = ArrayList<Hook>([BlockingHook()])
    let runtime = AgentRuntime(config, provider, toolReg, sessionStore, trustMgr,
        skillReg, agentReg, providerReg, hooks, { q => "" })

    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("hi"), 0))
    let result = runtime.chat(msgs).result()

    @Expect(tool.calls, 0)
    @Expect(result.size > 0, true)
}

class RecorderTool <: Tool {
    public var received: Option<JsonValue> = None
    public func name(): String { "rec_tool" }
    public func description(): String { "records" }
    public func schema(): JsonValue {
        JsonValue.Map(HashMap<String, JsonValue>())
    }
    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        this.received = Some(args)
        ToolResult("ok", None, false, false)
    }
    public func executionMode(): ToolExecutionMode {
        ToolExecutionMode.Parallel
    }
}

class ModifyHook <: Hook {
    public override func beforeTool(ctx: HookContext, call: ToolCallBlock): BeforeToolDecision {
        let m = HashMap<String, JsonValue>()
        m["modified"] = JsonValue.String("yes")
        BeforeToolDecision.Modify(JsonValue.Map(m))
    }
}

@Test
func beforeTool_modify_changesArgs() {
    let tool = RecorderTool()
    let toolReg = ToolRegistry()
    toolReg.register(tool)

    let responses = ArrayList<AssistantMessage>()
    responses.add(makeToolUseMsg("rec_tool", "call_1"))
    responses.add(makeAssistantMsg("done", StopReason.EndTurn))
    let provider = FakeProvider(responses)

    let config = AgentConfig.default()
    let sessionStore = MemorySessionStore()
    let trustMgr = TrustManager()
    let skillReg = SkillRegistry()
    let agentReg = AgentRegistry()
    let providerReg = ProviderRegistry()
    providerReg.register("default", provider)
    let hooks = ArrayList<Hook>([ModifyHook()])
    let runtime = AgentRuntime(config, provider, toolReg, sessionStore, trustMgr,
        skillReg, agentReg, providerReg, hooks, { q => "" })

    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("hi"), 0))
    runtime.chat(msgs).result()

    match (tool.received) {
        case Some(args) =>
            let v = args["modified"]
            match (v) {
                case Some(JsonValue.String(s)) => @Expect(s, "yes")
                case _ => @Fail("args not modified by hook")
            }
        case None => @Fail("tool not executed")
    }
}

class RewriteHook <: Hook {
    public override func afterTurn(ctx: HookContext): AfterTurnUpdate {
        let msgs = ArrayList<Message>()
        msgs.add(UserMessage(ContentList.ofText("rewritten"), 0))
        AfterTurnUpdate(Some(msgs), false)
    }
}

@Test
func afterTurn_rewritesContext() {
    let responses = ArrayList<AssistantMessage>()
    responses.add(makeAssistantMsg("original reply", StopReason.EndTurn))
    let provider = FakeProvider(responses)

    let config = AgentConfig.default()
    let hooks = ArrayList<Hook>([RewriteHook()])
    let runtime = makeRuntime(config, provider, hooks)

    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("hi"), 0))
    let result = runtime.chat(msgs).result()

    let last = result[result.size - 1]
    match (last) {
        case um: UserMessage =>
            var text = ""
            for (b in um.content.blocks()) {
                match (b) {
                    case ContentBlock.TextBlock(t) => text = t
                    case _ => ()
                }
            }
            @Expect(text, "rewritten")
        case _ => @Fail("expected rewritten user message at end")
    }
}

class CostHook <: Hook {
    public var finalCost: Float64 = -1.0
    public override func beforeTurn(ctx: HookContext, request: ChatRequest): TurnDecision {
        let cost = match (ctx.state.get("cost")) {
            case Some(JsonValue.Number(n)) => n
            case _ => 0.0
        }
        ctx.state.set("cost", JsonValue.Number(cost + 1.0))
        TurnDecision.Continue(request)
    }
    public override func afterRun(ctx: HookContext): Unit {
        match (ctx.state.get("cost")) {
            case Some(JsonValue.Number(n)) => this.finalCost = n
            case _ => this.finalCost = -1.0
        }
    }
}

@Test
func state_sharedAcrossPhases() {
    let responses = ArrayList<AssistantMessage>()
    responses.add(makeAssistantMsg("reply", StopReason.EndTurn))
    let provider = FakeProvider(responses)
    let config = AgentConfig.default()
    let h = CostHook()
    let runtime = makeRuntime(config, provider, ArrayList<Hook>([h]))

    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("hi"), 0))
    runtime.chat(msgs).result()

    @Expect(h.finalCost, 1.0)
}

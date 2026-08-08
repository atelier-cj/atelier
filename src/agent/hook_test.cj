package atelier.agent

import jsonvalue.*
import std.collection.*
import atelier.message.*
import atelier.provider.*
import atelier.tool.*

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

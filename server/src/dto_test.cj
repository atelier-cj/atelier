package server

import std.collection.*
import atelier.util.{toJsonString, fromJsonString}
import atelier.interaction.*
import atelier.agent.*
import atelier.tool.ToolRegistry
import atelier.tool.McpManager
import atelier.trust.TrustManager
import atelier.skill.SkillRegistry
import atelier.provider.ProviderRegistry
import atelier.session.MemorySessionStore
import jsonvalue.*

func chatMsg(role: String, content: String): MessageDTO { MessageDTO(role, content) }

// ChatRequestDTO sessionId 透传：有值 → JSON 往返保留
@Test
func chatRequestDTO_roundTrip_withSessionId() {
    let dto = ChatRequestDTO("agent1",
        ArrayList<MessageDTO>([chatMsg("user", "hi")]), true, Some("sess_abc"))
    let back = fromJsonString<ChatRequestDTO>(toJsonString(dto))
    @Expect(back.sessionId, Some("sess_abc"))
    @Expect(back.agent, "agent1")
    @Expect(back.messages.size, 1)
    @Expect(back.stream, true)
}

// 无 sessionId → toJson 写出 null → 读回 None
@Test
func chatRequestDTO_roundTrip_withoutSessionId() {
    let dto = ChatRequestDTO("agent1",
        ArrayList<MessageDTO>([chatMsg("user", "hi")]), false, None)
    let back = fromJsonString<ChatRequestDTO>(toJsonString(dto))
    @Expect(back.sessionId, None)
}

// 请求体不含 sessionId 字段 → 缺省 None
@Test
func chatRequestDTO_fromJsonMissingSessionIdDefaultsNone() {
    let back = fromJsonString<ChatRequestDTO>(
        "{\"agent\":\"a\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"stream\":false}")
    @Expect(back.sessionId, None)
    @Expect(back.agent, "a")
}

// OpenAI 兼容端点：sessionId 透传解析
@Test
func chatCompletionRequest_sessionIdParsed() {
    let back = fromJsonString<ChatCompletionRequest>(
        "{\"model\":\"m\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"stream\":false,\"sessionId\":\"sess_xyz\"}")
    @Expect(back.sessionId, Some("sess_xyz"))
    @Expect(back.model, "m")
    @Expect(back.messages.size, 1)
}

@Test
func chatCompletionRequest_sessionIdMissingDefaultsNone() {
    let back = fromJsonString<ChatCompletionRequest>(
        "{\"model\":\"m\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"stream\":false}")
    @Expect(back.sessionId, None)
}

// ── /agent/input：按 requestId 对上一条待答提问（旧契约"投给任意一个等待者"在并发下会串答案）──

func inputChoiceReq(): UserRequest {
    let opts = ArrayList<UserOption>()
    opts.add(UserOption("dev", "dev"))
    opts.add(UserOption("prod", "prod"))
    choiceRequest("ask:s:1:c", "选环境", opts)
}

// 本端产出的答复是否过 runtime 那套校验（枚举比较走 match：仓颉枚举没有 ==）
func inputValid(req: UserRequest, ans: UserAnswer): Bool {
    match (validateAnswer(req, ans)) {
        case None => true
        case Some(_) => false
    }
}

@Test
func inputDTO_parsesSelectedAndStatus() {
    let dto = fromJsonString<SessionInputDTO>(
        "{\"requestId\":\"ask:s:1:c\",\"selected\":[\"prod\"],\"text\":\"\"}")
    @Expect(dto.requestId, "ask:s:1:c")
    @Expect(dto.status, "answered")
    @Expect(dto.selected.size, 1)
    @Expect(dto.selected[0], "prod")
    let ans = dto.toAnswer(inputChoiceReq())
    @Expect(ans.selected[0], "prod")
    @Expect(inputValid(inputChoiceReq(), ans), true)
}

@Test
func inputDTO_cancelledStatusIsNotAnAnswer() {
    let dto = fromJsonString<SessionInputDTO>("{\"requestId\":\"ask:s:1:c\",\"status\":\"cancelled\"}")
    let ans = dto.toAnswer(inputChoiceReq())
    match (ans.status) {
        case UserAnswerStatus.Cancelled => ()
        case _ => @Fail("cancelled 必须映射成 Cancelled")
    }
    // 取消不是错误（校验放行），但下游据此知道"没人答"而不是"答了个空"
    @Expect(inputValid(inputChoiceReq(), ans), true)
}

// 表单值按字段声明类型包装：bool/multi_select 不包装就会被校验按"类型不符"打回
@Test
func inputDTO_wrapsFormValuesByFieldType() {
    let fields = ArrayList<UserField>()
    fields.add(UserField("name", "姓名", UserFieldType.Text, required: true))
    fields.add(UserField("vip", "会员", UserFieldType.Boolean))
    let opts = ArrayList<UserOption>()
    opts.add(UserOption("a", "a"))
    opts.add(UserOption("b", "b"))
    fields.add(UserField("tags", "标签", UserFieldType.MultiSelect, options: opts))
    let req = formRequest("ask:s:1:f", "登记", fields)

    let dto = fromJsonString<SessionInputDTO>(
        "{\"requestId\":\"ask:s:1:f\",\"values\":{\"name\":\"张三\",\"vip\":\"true\",\"tags\":\"a, b\"}}")
    let ans = dto.toAnswer(req)
    match (ans.values.get("vip")) {
        case Some(JsonValue.Boolean(b)) => @Expect(b, true)
        case _ => @Fail("bool 字段必须是布尔值")
    }
    match (ans.values.get("tags")) {
        case Some(JsonValue.Array(items)) => @Expect(items.size, 2)
        case _ => @Fail("multi_select 字段必须是数组")
    }
    match (ans.values.get("name")) {
        case Some(JsonValue.String(v)) => @Expect(v, "张三")
        case _ => @Fail("text 字段是字符串")
    }
    @Expect(inputValid(req, ans), true)
}

// 非法答复在边界处就被拦下：handler 据此回 400，而不是让 runtime 事后拒绝
@Test
func inputDTO_invalidOptionIsRejectedByValidation() {
    let dto = fromJsonString<SessionInputDTO>(
        "{\"requestId\":\"ask:s:1:c\",\"selected\":[\"staging\"]}")
    let ans = dto.toAnswer(inputChoiceReq())
    @Expect(inputValid(inputChoiceReq(), ans), false)
}

// 提问帧：客户端要拿到整条请求（选项/字段/toolCallId）才能渲染
@Test
func inputFrame_carriesWholeRequest() {
    let json = toJsonString(UserRequestFrame(inputChoiceReq()))
    @Assert(json.contains("\"type\":\"user_request\""))
    @Assert(json.contains("\"id\":\"ask:s:1:c\""))
    @Assert(json.contains("\"prod\""))
}


// ==================== 运行时状态：handler 必须让所有请求共享同一张状态表 ====================
//
// 背景：/agent/run 这类端点每次请求都新建 loop。若状态表随 loop 新建，
// status 永远是 Idle —— 客户端刷新或切换会话后无法知道"这个会话还在跑吗"。
// 所以状态表必须由 handler 持有，并在建 handler 时就注入装配束。

@Test
func handler_sharesOneStatusRegistryAcrossRequests() {
    let spec = HarnessSpec(tools: ToolRegistry(), store: MemorySessionStore(),
        trust: TrustManager(), skills: SkillRegistry(), agents: AgentRegistry(),
        providers: ProviderRegistry(), mcp: McpManager())
    let h1 = AtelierHttpHandler(spec)
    let h2 = AtelierHttpHandler(h1.components())   // 模拟"从已有 handler 派生"
    // 两个 handler 看到的必须是同一张表（否则状态各记各的）
    let r1 = match (h1.components().statusRegistry) {
        case Some(x) => x
        case None => return @Fail("handler1 未注入 statusRegistry")
    }
    let r2 = match (h2.components().statusRegistry) {
        case Some(x) => x
        case None => return @Fail("handler2 未注入 statusRegistry")
    }
    // 同一张表的判据：在 r1 上标记，r2 必须看得到
    r1.transition("probe", AgentStatus.Running)
    match (r2.statusOf("probe")) {
        case AgentStatus.Running => @Expect(true, true)
        case AgentStatus.Idle => @Fail("两个 handler 用的不是同一张状态表")
    }
}

@Test
func handler_reusesRegistryProvidedByHost() {
    let mine = AgentStatusRegistry()
    let spec = HarnessSpec(tools: ToolRegistry(), store: MemorySessionStore(),
        trust: TrustManager(), skills: SkillRegistry(), agents: AgentRegistry(),
        providers: ProviderRegistry(), mcp: McpManager())
        .withStatusRegistry(mine)
    let h = AtelierHttpHandler(spec)
    let got = match (h.components().statusRegistry) {
        case Some(r) => r
        case None => return @Fail("registry 丢失")
    }
    // 宿主注入的那张表必须被复用：在 mine 上标记，got 要能看到
    mine.transition("probe2", AgentStatus.Running)
    match (got.statusOf("probe2")) {
        case AgentStatus.Running => @Expect(true, true)
        case AgentStatus.Idle => @Fail("宿主注入的 registry 被替换了")
    }
}

// 状态 DTO 的 JSON 形状（客户端按 running[] 解析）
@Test
func sessionStatusResponse_serializesRunningList() {
    let resp = SessionStatusResponse(ArrayList<SessionStatusItem>([
        SessionStatusItem("s1", "running"),
        SessionStatusItem("s2", "running")]))
    let json = toJsonString(resp)
    @Expect(json.contains("\"running\""), true)
    @Expect(json.contains("\"s1\""), true)
    @Expect(json.contains("\"s2\""), true)
}

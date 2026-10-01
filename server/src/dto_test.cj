package server

import std.collection.*
import atelier.util.{toJsonString, fromJsonString}
import atelier.interaction.*
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

// 动态建 agent：窗口声明必须能从请求体传进来（否则 HTTP 那条路的配置形态是缺的）
@Test
func agentConfigDTO_contextWindow() {
    let withWindow = fromJsonString<AgentConfigDTO>("{\"name\":\"a\",\"model\":\"m\",\"contextWindow\":262144}")
    @Expect(withWindow.contextWindow, Some(262144))
    @Expect(configFromDTO(withWindow).contextWindow, Some(262144))

    // 不传 = None：交给 [[model]] / 内置表 / 兜底
    let without = fromJsonString<AgentConfigDTO>("{\"name\":\"a\",\"model\":\"m\"}")
    @Expect(without.contextWindow, None)
    @Expect(configFromDTO(without).contextWindow, None)
}

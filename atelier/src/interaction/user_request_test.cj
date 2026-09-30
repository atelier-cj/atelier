package atelier.interaction

import std.collection.*
import jsonvalue.*
import atelier.util.{toJsonString, fromJsonString}

// 提问原语的用例：三种形态的构造、答复的审批语义、以及校验规则。
// 校验放在 runtime 侧是刻意的——宿主只渲染，否则多端行为会分叉，所以这里要盯紧。

func opt(id: String): UserOption { UserOption(id, id) }

func textField(name: String, required: Bool): UserField {
    UserField(name, name, UserFieldType.Text, required: required)
}

@Test
func userRequest_approvalCarriesThreeFixedOptions() {
    let req = approvalRequest("ask:1", "bash", JsonValue.String("{}"), "要执行 bash 吗？")
    @Expect(req.kindName(), "approval")
    @Expect(req.options.size, 3)
    @Expect(req.options[0].id, "allow_once")
    @Expect(req.options[1].id, "allow_always")
    @Expect(req.options[2].id, "deny")
    @Expect(req.options[2].danger, true)
    // 被批准的操作要能展示（前端据此渲染"你要执行的是这个"）
    @Expect(req.args.isSome(), true)
}

@Test
func userRequest_choiceAndFormFactories() {
    let opts = ArrayList<UserOption>([opt("a"), opt("b")])
    let c = choiceRequest("ask:2", "选一个", opts, multi: true)
    @Expect(c.kindName(), "choice")
    @Expect(c.multi, true)
    @Expect(c.options.size, 2)
    let fields = ArrayList<UserField>([textField("name", true)])
    let f = formRequest("ask:3", "填一下", fields)
    @Expect(f.kindName(), "form")
    @Expect(f.fields.size, 1)
}

@Test
func userAnswer_approvalSemantics() {
    let once = UserAnswer("ask:1", UserAnswerStatus.Answered,
        selected: ArrayList<String>(["allow_once"]))
    @Expect(once.isAllowOnce(), true)
    @Expect(once.isAllowAlways(), false)
    @Expect(once.isDenied(), false)
    let always = UserAnswer("ask:1", UserAnswerStatus.Answered,
        selected: ArrayList<String>(["allow_always"]))
    @Expect(always.isAllowAlways(), true)
    let deny = UserAnswer("ask:1", UserAnswerStatus.Answered,
        selected: ArrayList<String>(["deny"]))
    @Expect(deny.isDenied(), true)
}

@Test
func userAnswer_cancelledAndTimedOutCountAsDenied() {
    // 取消与超时都不能被当成"同意"——审批的默认必须是否决
    @Expect(UserAnswer("ask:1", UserAnswerStatus.Cancelled).isDenied(), true)
    @Expect(UserAnswer("ask:1", UserAnswerStatus.TimedOut).isDenied(), true)
    // 但 Pending 不是拒绝：它是"宿主挂起、稍后再答"，runtime 必须据此挂起而不是当否决。
    // 把两者混为一谈正是旧实现里空串语义重载的老问题。
    @Expect(UserAnswer.pending("ask:1").isDenied(), false)
    @Expect(UserAnswer.pending("ask:1").approvalDecision().isNone(), true)
}

@Test
func validate_approvalRequiresExactlyOneKnownOption() {
    let req = approvalRequest("ask:1", "bash", JsonValue.String("{}"), "批准？")
    @Expect(validateAnswer(req, UserAnswer("ask:1", UserAnswerStatus.Answered)).isSome(), true)
    let two = UserAnswer("ask:1", UserAnswerStatus.Answered,
        selected: ArrayList<String>(["allow_once", "deny"]))
    @Expect(validateAnswer(req, two).isSome(), true)
    let unknown = UserAnswer("ask:1", UserAnswerStatus.Answered,
        selected: ArrayList<String>(["yes"]))
    @Expect(validateAnswer(req, unknown).isSome(), true)
    let ok = UserAnswer("ask:1", UserAnswerStatus.Answered,
        selected: ArrayList<String>(["allow_once"]))
    @Expect(validateAnswer(req, ok).isNone(), true)
}

@Test
func validate_pendingIsNotAnError() {
    let req = approvalRequest("ask:1", "bash", JsonValue.String("{}"), "批准？")
    // 挂起是正常状态：runtime 据此结束本次 run，而不是报错
    @Expect(validateAnswer(req, UserAnswer.pending("ask:1")).isNone(), true)
}

@Test
func validate_requestIdMustMatch() {
    let req = approvalRequest("ask:1", "bash", JsonValue.String("{}"), "批准？")
    let wrong = UserAnswer("ask:other", UserAnswerStatus.Answered,
        selected: ArrayList<String>(["allow_once"]))
    @Expect(validateAnswer(req, wrong).isSome(), true)
}

@Test
func validate_choiceRespectsMultiFlag() {
    let opts = ArrayList<UserOption>([opt("a"), opt("b")])
    let single = choiceRequest("ask:2", "选一个", opts)
    let two = UserAnswer("ask:2", UserAnswerStatus.Answered,
        selected: ArrayList<String>(["a", "b"]))
    @Expect(validateAnswer(single, two).isSome(), true)
    let multi = choiceRequest("ask:2", "选几个", opts, multi: true)
    @Expect(validateAnswer(multi, two).isNone(), true)
    let empty = UserAnswer("ask:2", UserAnswerStatus.Answered)
    @Expect(validateAnswer(single, empty).isSome(), true)
    let unknown = UserAnswer("ask:2", UserAnswerStatus.Answered,
        selected: ArrayList<String>(["c"]))
    @Expect(validateAnswer(single, unknown).isSome(), true)
}

@Test
func validate_formRequiredAndTypes() {
    let fields = ArrayList<UserField>([
        textField("name", true),
        UserField("age", "age", UserFieldType.Number),
        UserField("role", "role", UserFieldType.Select,
            options: ArrayList<UserOption>([opt("dev"), opt("ops")])),
        UserField("tags", "tags", UserFieldType.MultiSelect,
            options: ArrayList<UserOption>([opt("x"), opt("y")]))])
    let req = formRequest("ask:3", "填一下", fields)

    // 必填缺失
    let missing = UserAnswer("ask:3", UserAnswerStatus.Answered)
    @Expect(validateAnswer(req, missing).isSome(), true)

    // 类型不符：数字字段给了非数字
    let badNum = HashMap<String, JsonValue>()
    badNum["name"] = JsonValue.String("n")
    badNum["age"] = JsonValue.String("abc")
    @Expect(validateAnswer(req, UserAnswer("ask:3", UserAnswerStatus.Answered,
        values: badNum)).isSome(), true)

    // 数字允许以字符串形式提交（协议上常见），能解析即可
    let okNum = HashMap<String, JsonValue>()
    okNum["name"] = JsonValue.String("n")
    okNum["age"] = JsonValue.String("42")
    @Expect(validateAnswer(req, UserAnswer("ask:3", UserAnswerStatus.Answered,
        values: okNum)).isNone(), true)

    // Select 取值必须来自候选项
    let badSelect = HashMap<String, JsonValue>()
    badSelect["name"] = JsonValue.String("n")
    badSelect["role"] = JsonValue.String("ceo")
    @Expect(validateAnswer(req, UserAnswer("ask:3", UserAnswerStatus.Answered,
        values: badSelect)).isSome(), true)

    // MultiSelect 逐项校验
    let badMulti = HashMap<String, JsonValue>()
    badMulti["name"] = JsonValue.String("n")
    badMulti["tags"] = JsonValue.Array(ArrayList<JsonValue>([JsonValue.String("x"), JsonValue.String("z")]))
    @Expect(validateAnswer(req, UserAnswer("ask:3", UserAnswerStatus.Answered,
        values: badMulti)).isSome(), true)

    let good = HashMap<String, JsonValue>()
    good["name"] = JsonValue.String("n")
    good["role"] = JsonValue.String("dev")
    good["tags"] = JsonValue.Array(ArrayList<JsonValue>([JsonValue.String("x")]))
    @Expect(validateAnswer(req, UserAnswer("ask:3", UserAnswerStatus.Answered,
        values: good)).isNone(), true)
}

@Test
func userRequest_jsonShapeIsStable() {
    // 对外协议形状：kind / options / fields 的字段名与取值是契约
    let req = approvalRequest("ask:1", "bash", JsonValue.String("{}"), "批准？")
    let s = toJsonString(req)
    @Expect(s.contains("\"kind\":\"approval\""), true)
    @Expect(s.contains("\"id\":\"allow_once\""), true)
    @Expect(s.contains("\"danger\":true"), true)

    let ans = UserAnswer("ask:1", UserAnswerStatus.Answered,
        selected: ArrayList<String>(["allow_always"]),
        editedArgs: Some(JsonValue.String("{}")))
    let a = toJsonString(ans)
    @Expect(a.contains("\"status\":\"answered\""), true)
    @Expect(a.contains("\"editedArgs\""), true)

    // 挂起状态必须能原样表达（AG-UI 侧靠它决定"结束这次 run"）
    @Expect(toJsonString(UserAnswer.pending("ask:1")).contains("\"status\":\"pending\""), true)
}

@Test
func userRequest_fieldTypeNames() {
    @Expect(fieldTypeName(UserFieldType.Text), "text")
    @Expect(fieldTypeName(UserFieldType.MultiSelect), "multi_select")
    @Expect(fieldTypeName(UserFieldType.Boolean), "bool")
}

@Test
func userRequest_toolExecutionKind() {
    // 客户端工具复用同一套请求：kind=tool_execution，toolCallId 就是请求 id
    let req = toolExecutionRequest("int-c1", "get_weather", JsonValue.String("{}"), "请执行")
    @Expect(req.kindName(), "tool_execution")
    @Expect(req.toolCallId, "int-c1")
}

// ── 答复的持久化编码（恢复的载体）────────────────────────────────────────────
// 恢复靠"下一次 run 的消息里带着答复"：编码必须无损，坏数据必须能被识别（宁可再问一次，
// 也不要拿半个答复去执行）。

@Test
func codec_roundTripApprovalWithEdits() {
    let edited = JsonValue.Map(HashMap<String, JsonValue>([("cmd", JsonValue.String("ls"))]))
    let a = UserAnswer("ask:1", UserAnswerStatus.Answered,
        selected: ArrayList<String>(["allow_once"]), text: "", editedArgs: Some(edited))
    let back = decodeAnswer(encodeAnswer(a))
    @Expect(back.isSome(), true)
    match (back) {
        case Some(v) =>
            @Expect(v.requestId, "ask:1")
            @Expect(v.isAllowOnce(), true)
            let hasEdited = match (v.editedArgs) { case Some(_) => true; case None => false }
            @Expect(hasEdited, true)
        case None => @Fail("应当能还原")
    }
}

@Test
func codec_roundTripFormValues() {
    let values = HashMap<String, JsonValue>()
    values["name"] = JsonValue.String("阿特")
    values["age"] = JsonValue.String("42")
    values["tags"] = JsonValue.Array(ArrayList<JsonValue>([JsonValue.String("x")]))
    let a = UserAnswer("ask:2", UserAnswerStatus.Answered, values: values)
    match (decodeAnswer(encodeAnswer(a))) {
        case Some(v) =>
            @Expect(v.values.size, 3)
            match (v.values.get("name")) {
                case Some(JsonValue.String(s)) => @Expect(s, "阿特")
                case _ => @Fail("name 应当还原")
            }
            match (v.values.get("tags")) {
                case Some(JsonValue.Array(items)) => @Expect(items.size, 1)
                case _ => @Fail("tags 应当还原成数组")
            }
        case None => @Fail("应当能还原")
    }
}

@Test
func codec_multiSelectSelectedList() {
    let a = UserAnswer("ask:3", UserAnswerStatus.Answered,
        selected: ArrayList<String>(["a", "b", "c"]))
    match (decodeAnswer(encodeAnswer(a))) {
        case Some(v) => @Expect(v.selected.size, 3)
        case None => @Fail("应当能还原")
    }
}

@Test
func codec_statusesPreserved() {
    // Cancelled / TimedOut 必须能跨 run 传下去：它们与"答了空"是不同语义
    for (st in [UserAnswerStatus.Cancelled, UserAnswerStatus.TimedOut]) {
        let a = UserAnswer("ask:4", st)
        match (decodeAnswer(encodeAnswer(a))) {
            case Some(v) => @Expect(v.statusName(), a.statusName())
            case None => @Fail("应当能还原")
        }
    }
}

@Test
func codec_detectsBrokenData() {
    // 缺 id / 坏 JSON / 空 values：一律 None（当作没答复，重新提问）
    @Expect(encodeAnswer(UserAnswer("", UserAnswerStatus.Answered)).get(ASK_ID), Some(""))
    let missing = HashMap<String, String>()
    @Expect(decodeAnswer(missing).isNone(), true)
    let badJson = HashMap<String, String>()
    badJson[ASK_ID] = "ask:9"
    badJson[ASK_VALUES] = "{not json"
    @Expect(decodeAnswer(badJson).isNone(), true)
    let badEdited = HashMap<String, String>()
    badEdited[ASK_ID] = "ask:9"
    badEdited[ASK_EDITED_ARGS] = "[[["
    @Expect(decodeAnswer(badEdited).isNone(), true)
}

@Test
func codec_isAnswerMetadataRecognisesCarrier() {
    let m = encodeAnswer(UserAnswer("ask:5", UserAnswerStatus.Pending))
    @Expect(isAnswerMetadata(m), true)
    @Expect(isAnswerMetadata(HashMap<String, String>()), false)
}

// 截断的复合 JSON 不能让解码器崩：实测 JsonValue.fromJson 对 `{not json` 会无限递归到 OOM
// （不是异常，try/catch 兜不住），所以解码前必须有形状检查
@Test
func codec_truncatedCompositeIsRejectedNotCrash() {
    let truncated = HashMap<String, String>()
    truncated[ASK_ID] = "ask:1"
    truncated[ASK_VALUES] = "{not json"
    @Expect(decodeAnswer(truncated).isNone(), true)
    let truncated2 = HashMap<String, String>()
    truncated2[ASK_ID] = "ask:1"
    truncated2[ASK_EDITED_ARGS] = "[1, 2"
    @Expect(decodeAnswer(truncated2).isNone(), true)
    // 完整对象的正常路径不受影响
    let ok = HashMap<String, String>()
    ok[ASK_ID] = "ask:1"
    ok[ASK_VALUES] = "{\"a\":\"b\"}"
    match (decodeAnswer(ok)) {
        case Some(v) => @Expect(v.values.size, 1)
        case None => @Fail("完整对象应当能解析")
    }
}

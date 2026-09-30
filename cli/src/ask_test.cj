package cli

import std.collection.*
import atelier.interaction.*
import jsonvalue.*

// ═══════ TUI 提问收敛（选项 / 表单 / 取消）═══════════════════════════
//
// 每个用例都额外断言「本端产出的答复能过 validateAnswer」——那是 runtime 侧的同一套校验。
// 这层断言是这里最值钱的部分：宿主自己造答复时最容易出的错，就是造出一个 runtime
// 认不出来的东西（用户已经走完流程，回合却报"答复不合格"）。

func askAnswerOf(p: AskPrompt): UserAnswer {
    match (p.answer()) {
        case Some(a) => a
        case None => UserAnswer(p.req.id, UserAnswerStatus.Cancelled)
    }
}

/** 本端产出的答复是否过 runtime 那套校验（枚举比较走 match：仓颉枚举没有 ==）。 */
func askValid(req: UserRequest, ans: UserAnswer): Bool {
    match (validateAnswer(req, ans)) {
        case None => true
        case Some(_) => false
    }
}

/** 值形态用前缀标出来：s: 字符串 / b: 布尔 / a: 数组长度 —— 一眼看出存成了什么。 */
func askValueOf(ans: UserAnswer, name: String): String {
    match (ans.values.get(name)) {
        case Some(JsonValue.String(s)) => "s:" + s
        case Some(JsonValue.Boolean(b)) => "b:" + b.toString()
        case Some(JsonValue.Array(items)) => "a:" + items.size.toString()
        case Some(JsonValue.Number(n)) => "n:" + n.toString()
        case _ => "none"
    }
}

func askIsTyping(p: AskPrompt): Bool {
    match (p.currentPhase()) {
        case AskPhase.Typing => true
        case _ => false
    }
}

func askOpts(ids: Array<String>): ArrayList<UserOption> {
    let out = ArrayList<UserOption>()
    for (id in ids) { out.add(UserOption(id, id)) }
    out
}

// ── 审批 ─────────────────────────────────────────────────────────────

@Test
func ask_approvalDefaultsToFirstOption() {
    let req = approvalRequest("ask:s:1:c:approval", "bash", JsonValue.String("{}"), "批准执行？")
    let p = AskPrompt(req)
    @Expect(p.done(), false)
    @Expect(p.currentOptions().size, 3)
    // 回车提交光标处（默认第一项 = 允许这一次）
    @Expect(p.submit(""), true)
    let ans = askAnswerOf(p)
    @Expect(ans.isAllowOnce(), true)
    @Expect(ans.isDenied(), false)
    @Expect(askValid(req, ans), true)
}

@Test
func ask_approvalMoveDownPicksAllowAlways() {
    let req = approvalRequest("ask:s:1:c:approval", "bash", JsonValue.String("{}"), "批准执行？")
    let p = AskPrompt(req)
    p.moveDown()
    @Expect(p.submit(""), true)
    @Expect(askAnswerOf(p).isAllowAlways(), true)
    @Expect(askValid(req, askAnswerOf(p)), true)
}

@Test
func ask_approvalDangerOptionIsTheDenyOne() {
    let req = approvalRequest("ask:s:1:c:approval", "bash", JsonValue.String("{}"), "批准执行？")
    let p = AskPrompt(req)
    p.moveDown()
    p.moveDown()
    @Expect(p.submit(""), true)
    let ans = askAnswerOf(p)
    @Expect(ans.isDenied(), true)
    @Expect(askValid(req, ans), true)
}

@Test
func ask_approvalEscCancelsNotDeniesSilently() {
    let req = approvalRequest("ask:s:1:c:approval", "bash", JsonValue.String("{}"), "批准执行？")
    let p = AskPrompt(req)
    p.cancel()
    @Expect(p.done(), true)
    let ans = askAnswerOf(p)
    // 取消要如实说成取消：空答复无法与"拒绝/没通道"区分
    match (ans.status) {
        case UserAnswerStatus.Cancelled => ()
        case _ => @Fail("cancel must produce Cancelled")
    }
    @Expect(askValid(req, ans), true)
}

@Test
func ask_approvalWithoutOptionsCancelsInsteadOfHanging() {
    // 没有候选项就没有可作答的东西：等着用户敲回车只会把回合挂死
    let req = UserRequest("ask:x", UserRequestKind.Approval, "无选项的审批")
    let p = AskPrompt(req)
    @Expect(p.done(), true)
    @Expect(p.currentNote() != "", true)
    match (askAnswerOf(p).status) {
        case UserAnswerStatus.Cancelled => ()
        case _ => @Fail("must cancel")
    }
}

// ── 选择 ─────────────────────────────────────────────────────────────

@Test
func ask_choiceSingleSelectTakesCursor() {
    let req = choiceRequest("ask:s:1:c", "选一个环境", askOpts(["dev", "staging", "prod"]))
    let p = AskPrompt(req)
    p.moveDown()
    @Expect(p.submit(""), true)
    let ans = askAnswerOf(p)
    @Expect(ans.selected.size, 1)
    @Expect(ans.selected[0], "staging")
    @Expect(askValid(req, ans), true)
}

@Test
func ask_choiceMultiCollectsToggledItemsInOrder() {
    let req = choiceRequest("ask:s:1:c", "选若干能力", askOpts(["a", "b", "c"]), multi: true)
    let p = AskPrompt(req)
    @Expect(p.allowsToggle(), true)
    p.toggle()                 // a
    p.moveDown()
    p.moveDown()
    p.toggle()                 // c
    @Expect(p.isPicked("a"), true)
    @Expect(p.isPicked("b"), false)
    @Expect(p.submit(""), true)
    let ans = askAnswerOf(p)
    @Expect(ans.selected.size, 2)
    @Expect(ans.selected[0], "a")
    @Expect(ans.selected[1], "c")
    @Expect(askValid(req, ans), true)
}

@Test
func ask_choiceMultiUncheckRemovesItem() {
    let req = choiceRequest("ask:s:1:c", "选若干能力", askOpts(["a", "b"]), multi: true)
    let p = AskPrompt(req)
    p.toggle()
    p.toggle()                 // 再按一次取消勾选
    @Expect(p.isPicked("a"), false)
    // 一项没勾时回车 = 选中光标项（否则用户会以为回车坏了）
    @Expect(p.submit(""), true)
    @Expect(askAnswerOf(p).selected[0], "a")
    @Expect(askValid(req, askAnswerOf(p)), true)
}

@Test
func ask_choiceSingleSelectIgnoresSpace() {
    let req = choiceRequest("ask:s:1:c", "选一个", askOpts(["a", "b"]))
    let p = AskPrompt(req)
    @Expect(p.allowsToggle(), false)
    p.toggle()                 // 单选下空格不该有副作用
    @Expect(p.isPicked("a"), false)
    @Expect(p.submit(""), true)
    @Expect(askAnswerOf(p).selected.size, 1)
}

// ── 表单 ─────────────────────────────────────────────────────────────

func nameAgeFields(): ArrayList<UserField> {
    let fs = ArrayList<UserField>()
    fs.add(UserField("name", "姓名", UserFieldType.Text, required: true))
    fs.add(UserField("age", "年龄", UserFieldType.Number))
    fs.add(UserField("vip", "会员", UserFieldType.Boolean))
    fs
}

@Test
func ask_formWalksFieldsInOrder() {
    let req = formRequest("ask:s:1:c", "登记", nameAgeFields())
    let p = AskPrompt(req)
    @Expect(askIsTyping(p), true)                 // 首字段是文本
    @Expect(p.submit(""), false)                  // 必填为空 → 打回
    @Expect(p.done(), false)
    @Expect(p.currentNote().contains("必填"), true)
    @Expect(p.submit("张三"), true)
    @Expect(askIsTyping(p), true)                 // 第二字段仍是输入行（number）
    @Expect(p.submit("abc"), false)               // 非数字 → 打回
    @Expect(p.currentNote().contains("数字"), true)
    @Expect(p.submit("30"), true)
    @Expect(askIsTyping(p), false)                // 第三字段是布尔 → 走列表
    @Expect(p.submit(""), true)
    let ans = askAnswerOf(p)
    @Expect(askValueOf(ans, "name"), "s:张三")
    @Expect(askValueOf(ans, "age"), "s:30")
    @Expect(askValueOf(ans, "vip"), "b:true")
    @Expect(askValid(req, ans), true)
}

@Test
func ask_formBooleanSecondOptionIsFalse() {
    let fs = ArrayList<UserField>()
    fs.add(UserField("ok", "同意", UserFieldType.Boolean, required: true))
    let req = formRequest("ask:s:1:c", "确认", fs)
    let p = AskPrompt(req)
    p.moveDown()
    @Expect(p.submit(""), true)
    @Expect(askValueOf(askAnswerOf(p), "ok"), "b:false")
    @Expect(askValid(req, askAnswerOf(p)), true)
}

@Test
func ask_formSelectFieldUsesItsOwnOptions() {
    let opts = askOpts(["prod", "dev"])
    let fs = ArrayList<UserField>()
    fs.add(UserField("env", "环境", UserFieldType.Select, required: true, options: opts))
    let req = formRequest("ask:s:1:c", "选环境", fs)
    let p = AskPrompt(req)
    @Expect(p.currentOptions().size, 2)           // 候选来自字段，不是顶层 options
    p.moveDown()
    @Expect(p.submit(""), true)
    @Expect(askValueOf(askAnswerOf(p), "env"), "s:dev")
    @Expect(askValid(req, askAnswerOf(p)), true)
}

@Test
func ask_formMultiSelectFieldStoresArray() {
    let opts = askOpts(["a", "b", "c"])
    let fs = ArrayList<UserField>()
    fs.add(UserField("tags", "标签", UserFieldType.MultiSelect, required: true, options: opts))
    let req = formRequest("ask:s:1:c", "打标签", fs)
    let p = AskPrompt(req)
    @Expect(p.allowsToggle(), true)
    p.toggle()
    p.moveDown()
    p.toggle()
    @Expect(p.submit(""), true)
    let ans = askAnswerOf(p)
    @Expect(askValueOf(ans, "tags"), "a:2")
    @Expect(askValid(req, ans), true)
}

@Test
func ask_formEmptyOptionalFieldIsSkipped() {
    let fs = ArrayList<UserField>()
    fs.add(UserField("note", "备注", UserFieldType.Text))
    let req = formRequest("ask:s:1:c", "补充", fs)
    let p = AskPrompt(req)
    @Expect(p.submit(""), true)
    let ans = askAnswerOf(p)
    @Expect(askValueOf(ans, "note"), "none")
    @Expect(askValid(req, ans), true)
}

@Test
func ask_formEmptyRequiredFieldTakesDefault() {
    let fs = ArrayList<UserField>()
    fs.add(UserField("env", "环境", UserFieldType.Text, required: true, defaultValue: "dev"))
    let req = formRequest("ask:s:1:c", "环境", fs)
    let p = AskPrompt(req)
    @Expect(p.submit(""), true)                   // 回车即用默认值，不必重打一遍
    @Expect(askValueOf(askAnswerOf(p), "env"), "s:dev")
    @Expect(askValid(req, askAnswerOf(p)), true)
}

@Test
func ask_formPlainQuestionIsASingleTextField() {
    // 普通提问（ask_user 无 options/fields）走的就是这个形态
    let fs = ArrayList<UserField>()
    fs.add(UserField("answer", "answer", UserFieldType.Text, required: true))
    let req = formRequest("ask:s:1:c", "你想部署到哪个区？", fs)
    let p = AskPrompt(req)
    @Expect(p.submit("华东"), true)
    @Expect(askValueOf(askAnswerOf(p), "answer"), "s:华东")
    @Expect(askValid(req, askAnswerOf(p)), true)
}

// ── 客户端工具 / 面板 ────────────────────────────────────────────────

@Test
func ask_toolExecutionCancelsWithoutWaiting() {
    let req = toolExecutionRequest("ask:s:1:c", "web_search", JsonValue.String("{}"), "执行搜索")
    let p = AskPrompt(req)
    // TUI 没有执行客户端工具的通道：如实取消，不能让回合等一个永远不会来的答复
    @Expect(p.done(), true)
    @Expect(p.currentNote() != "", true)
    match (askAnswerOf(p).status) {
        case UserAnswerStatus.Cancelled => ()
        case _ => @Fail("must cancel")
    }
}

@Test
func ask_panelShowsOptionsAndFormProgress() {
    let req = approvalRequest("ask:s:1:c:approval", "bash", JsonValue.String("{}"), "批准执行？")
    let p = AskPrompt(req)
    let lines = p.panelLines(120)
    var joined = ""
    for (l in lines) { joined = joined + l + "\n" }
    @Assert(joined.contains("审批"))
    @Assert(joined.contains("→ "))              // 当前项有标记
    @Assert(joined.contains("总是允许"))
    @Assert(joined.contains("⚠"))               // 危险项有警示
    @Assert(joined.contains("批准执行？"))
}

@Test
func ask_panelShowsFieldProgressAndNote() {
    let fs = ArrayList<UserField>()
    fs.add(UserField("name", "姓名", UserFieldType.Text, required: true))
    fs.add(UserField("age", "年龄", UserFieldType.Number))
    let req = formRequest("ask:s:1:c", "登记", fs)
    let p = AskPrompt(req)
    p.submit("张三")
    p.submit("abc")                             // 打回：note 要出现在面板上
    var joined = ""
    for (l in p.panelLines(120)) { joined = joined + l + "\n" }
    @Assert(joined.contains("姓名: 张三"))
    @Assert(joined.contains("年龄"))
    @Assert(joined.contains("需要一个数字"))
    @Assert(joined.contains("必填"))
}

@Test
func ask_multilineQuestionKeepsOneLineStatus() {
    let req = choiceRequest("ask:s:1:c", "选一个\n候选很多\n仔细看", askOpts(["a", "b"]))
    let text = AskPrompt(req).statusText()
    @Assert(text.contains("选一个"))
    @Assert(!text.contains("\n"))
}

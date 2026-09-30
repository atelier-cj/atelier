package atelier.acp

import std.collection.*
import jsonvalue.*
import atelier.interaction.*

// ACP 侧"提问 → elicitation → 答复"的换算。
// 刻意用字符串 property（候选写进提示）而不是 enum/array 属性：那些构造入口未确认，
// 而合法性由 runtime 的 validateAnswer 把关，所以字符串通道不会放过非法选项。
// 用例要盯的是：字段集合对不对、历史写法能不能认、失败与拒绝是否可区分。

func optOf(id: String): UserOption { UserOption(id, id) }

func approvalReq(): UserRequest {
    approvalRequest("ask:1", "bash", JsonValue.String("{}"), "要执行 bash 吗？")
}

@Test
func acpFields_approvalAndChoiceAskSingleAnswer() {
    @Expect(elicitationFieldsOf(approvalReq()).size, 1)
    @Expect(elicitationFieldsOf(approvalReq())[0], "answer")
    let opts = ArrayList<UserOption>([optOf("a"), optOf("b")])
    let choice = choiceRequest("ask:2", "选一个", opts)
    @Expect(elicitationFieldsOf(choice)[0], "answer")
}

@Test
func acpFields_formAsksOnePerField() {
    let fields = ArrayList<UserField>([
        UserField("env", "环境", UserFieldType.Select, required: true,
            options: ArrayList<UserOption>([optOf("prod")])),
        UserField("note", "备注", UserFieldType.Text)])
    let req = formRequest("ask:3", "填一下", fields)
    let names = elicitationFieldsOf(req)
    @Expect(names.size, 2)
    @Expect(names[0], "env")
    @Expect(names[1], "note")
    @Expect(isRequiredField(req, "env"), true)
    @Expect(isRequiredField(req, "note"), false)
    // 审批固定必答（不给"空着"这种状态）
    @Expect(isRequiredField(approvalReq(), "answer"), true)
}

@Test
func acpPromptCarriesOptionsAndFieldHints() {
    let opts = ArrayList<UserOption>([optOf("prod"), optOf("test")])
    let choice = choiceRequest("ask:2", "选环境", opts)
    let text = elicitationPromptOf(choice)
    @Expect(text.contains("prod"), true)
    @Expect(text.contains("test"), true)
    let fields = ArrayList<UserField>([
        UserField("env", "环境", UserFieldType.Select, options: opts)])
    @Expect(elicitationPromptOf(formRequest("ask:3", "填一下", fields)).contains("env"), true)
}

@Test
func acpAnswer_approvalIdsAndLegacyWordsBothWork() {
    let req = approvalReq()
    let allow = JsonValue.Map(HashMap<String, JsonValue>([("answer", JsonValue.String("allow_once"))]))
    @Expect(answerFromElicitation(req, Some(allow)).isAllowOnce(), true)
    // 历史写法（用户手输 y/a/n）也要认：ACP 侧提示可能被直接当文本回填
    let legacy = JsonValue.Map(HashMap<String, JsonValue>([("answer", JsonValue.String("y"))]))
    @Expect(answerFromElicitation(req, Some(legacy)).isAllowOnce(), true)
    let never = JsonValue.Map(HashMap<String, JsonValue>([("answer", JsonValue.String("a"))]))
    @Expect(answerFromElicitation(req, Some(never)).isAllowAlways(), true)
    let deny = JsonValue.Map(HashMap<String, JsonValue>([("answer", JsonValue.String("n"))]))
    @Expect(answerFromElicitation(req, Some(deny)).isDenied(), true)
}

@Test
func acpAnswer_choiceSplitsCommaSeparatedIds() {
    let opts = ArrayList<UserOption>([optOf("x"), optOf("y"), optOf("z")])
    let req = choiceRequest("ask:2", "选几个", opts, multi: true)
    let content = JsonValue.Map(HashMap<String, JsonValue>([("answer", JsonValue.String("x, z"))]))
    let ans = answerFromElicitation(req, Some(content))
    @Expect(ans.selected.size, 2)
    @Expect(ans.selected[0], "x")
    @Expect(ans.selected[1], "z")
    // 选出来的值要能过 runtime 校验（说明字符串通道没有放过非法值）
    @Expect(validateAnswer(req, ans).isNone(), true)
}

@Test
func acpAnswer_formValuesAndMissingFields() {
    let fields = ArrayList<UserField>([
        UserField("env", "环境", UserFieldType.Text, required: true),
        UserField("note", "备注", UserFieldType.Text)])
    let req = formRequest("ask:3", "填一下", fields)
    let content = JsonValue.Map(HashMap<String, JsonValue>([
        ("env", JsonValue.String("prod")), ("note", JsonValue.String("ok"))]))
    let ans = answerFromElicitation(req, Some(content))
    @Expect(ans.values.size, 2)
    @Expect(validateAnswer(req, ans).isNone(), true)
    // 必填缺失 → 校验必须拦下（而不是静默当通过）
    let partial = JsonValue.Map(HashMap<String, JsonValue>([("note", JsonValue.String("ok"))]))
    @Expect(validateAnswer(req, answerFromElicitation(req, Some(partial))).isSome(), true)
}

@Test
func acpAnswer_missingContentYieldsEmptyButValidShape() {
    // content 缺失（客户端只回 action）：不崩，产出可判定的答复（校验会指出必填缺失）
    let ans = answerFromElicitation(approvalReq(), None)
    @Expect(ans.selected.size, 1)
    @Expect(ans.selected[0], "")
}

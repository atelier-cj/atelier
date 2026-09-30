package atelier.agent

import std.collection.*
import atelier.message.*
import atelier.interaction.*

// 恢复侧的两个不变量：
// ① 答复只从带元数据的消息里来（别把普通用户消息误当答复）；
// ② 命中答复时**不能再问宿主**——否则重放会二次提问，用户被问第二遍。

func msgWithAnswer(a: UserAnswer, text: String): UserMessage {
    UserMessage(ContentList.ofText(text), 0, metadata: encodeAnswer(a))
}

@Test
func resumed_collectsAnswerFromMessage() {
    let a = UserAnswer("ask:1", UserAnswerStatus.Answered,
        selected: ArrayList<String>(["allow_once"]))
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("继续"), 0))
    msgs.add(msgWithAnswer(a, "批准"))
    let map = collectResumedAnswers(msgs)
    @Expect(map.size, 1)
    match (map.get("ask:1")) {
        case Some(v) => @Expect(v.isAllowOnce(), true)
        case None => @Fail("应当收集到答复")
    }
}

@Test
func resumed_ignoresPlainMessages() {
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("普通消息"), 0))
    msgs.add(ToolResultMessage("c1", "bash", ContentList.ofText("ok"), false, 0))
    @Expect(collectResumedAnswers(msgs).size, 0)
}

@Test
func resumed_skipsBrokenMetadata() {
    let broken = HashMap<String, String>()
    broken[ASK_ID] = "ask:bad"
    broken[ASK_VALUES] = "{truncated"
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("x"), 0, metadata: broken))
    // 坏数据不产生答复（而不是产生半个）
    @Expect(collectResumedAnswers(msgs).size, 0)
}

@Test
func resumed_metadataChannelIsUsedByAllRoles() {
    // 工具结果消息也可以承载答复（宿主把答复挂在工具结果上时）
    let a = UserAnswer("ask:2", UserAnswerStatus.Answered, text: "好")
    let msgs = ArrayList<Message>()
    msgs.add(ToolResultMessage("c1", "bash", ContentList.ofText("ok"), false, 0,
        metadata: encodeAnswer(a)))
    @Expect(collectResumedAnswers(msgs).size, 1)
}

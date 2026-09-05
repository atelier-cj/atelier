package atelier.acp

import jsonvalue.*
import std.collection.*
import acp.types.{ElicitationActionAccept, ElicitationActionDecline, ElicitationActionCancel}

func answerContent(text: String): JsonValue {
    let m = HashMap<String, JsonValue>()
    m["answer"] = JsonValue.String(text)
    JsonValue.Map(m)
}

// accept + content.answer → 文本
@Test
public func elicitationAnswer_acceptReturnsAnswer() {
    @Expect(elicitationAnswerOf(ElicitationActionAccept, Some(answerContent("42 岁"))), "42 岁")
}

// accept 但 content 缺 answer（schema 校验外的宽容路径）→ 空
@Test
public func elicitationAnswer_acceptWithoutAnswerField() {
    let m = HashMap<String, JsonValue>()
    m["other"] = JsonValue.String("x")
    @Expect(elicitationAnswerOf(ElicitationActionAccept, Some(JsonValue.Map(m))), "")
}

// decline / cancel → 空（askUserFn 拒绝语义）
@Test
public func elicitationAnswer_declineAndCancelEmpty() {
    @Expect(elicitationAnswerOf(ElicitationActionDecline, Some(answerContent("no"))), "")
    @Expect(elicitationAnswerOf(ElicitationActionCancel, None), "")
}

// content 非对象 / None → 空
@Test
public func elicitationAnswer_missingContent() {
    @Expect(elicitationAnswerOf(ElicitationActionAccept, None), "")
    @Expect(elicitationAnswerOf(ElicitationActionAccept, Some(JsonValue.String("raw"))), "")
}

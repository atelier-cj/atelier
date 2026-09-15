package server

import std.collection.*
import atelier.util.{toJsonString, fromJsonString}

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

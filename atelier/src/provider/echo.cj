package atelier.provider

import std.core.sleep
import std.core.Duration
import atelier.message.*
import atelier.event.EventStream

// EchoProvider：离线冒烟/测试用 Provider —— 直接把最后一条用户消息文本回显。
// 不访问任何网络/API；可选延时（毫秒）模拟慢响应，供取消路径端到端验证。
public class EchoProvider <: Provider {
    private let delayMs: Int64

    public init(delayMs: Int64) {
        this.delayMs = delayMs
    }

    public init() {
        this.delayMs = 0
    }

    public func name(): String { "echo" }

    private func echoText(req: ChatRequest): String {
        var last = ""
        for (m in req.messages) {
            match (m) {
                case um: UserMessage =>
                    let t = textOf(um.content)
                    if (t != "") { last = t }
                case _ => ()
            }
        }
        last
    }

    public func chat(req: ChatRequest): ChatResponse {
        if (this.delayMs > 0) { sleep(Duration.millisecond * this.delayMs) }
        let msg = AssistantMessage(ContentList.ofText("echo: " + this.echoText(req)), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0)
        ChatResponse(msg)
    }

    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        let stream = EventStream<ChatDelta, AssistantMessage>()
        spawn {
            if (this.delayMs > 0) { sleep(Duration.millisecond * this.delayMs) }
            let text = "echo: " + this.echoText(req)
            let msg = AssistantMessage(ContentList.ofText(text), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0)
            stream.emit(ChatDelta(text, "", None))
            stream.emit(ChatDelta("", "", Some(msg.stopReason)))
            stream.setResult(msg)
        }
        stream
    }
}

func textOf(cl: ContentList): String {
    var r = ""
    for (b in cl.blocks()) {
        match (b) { case ContentBlock.TextBlock(t) => r = r + t; case _ => () }
    }
    r
}

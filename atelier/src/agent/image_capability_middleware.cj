package atelier.agent

import std.collection.*
import atelier.message.*
import atelier.provider.*
import atelier.event.EventStream

// 能力感知中间件（请求级，wrap Provider 的 chat/chatStreaming）：
// 请求消息含 ImageBlock 时——
//   - 模型声明了 supportsVision：原样转发
//   - 未声明：配置了 visionModel 则自动路由到视觉模型（同一 provider 换模型名）；
//     否则明确抛错（不静默丢弃图片）。
// 用法（SessionLoop / AgentRuntime 注入，先注入者最外层）：
//   middlewares.add(ImageCapabilityMiddleware(cfg.supportsVision, visionModel: Some("qwen-vl")))
public class ImageCapabilityMiddleware <: ProviderMiddleware {
    private let supportsVision: Bool
    private let visionModel: Option<String>

    public init(supportsVision: Bool, visionModel!: Option<String> = None) {
        this.supportsVision = supportsVision
        this.visionModel = visionModel
    }

    public func wrap(provider: Provider): Provider {
        ImageCapabilityWrapper(this, provider)
    }

    // 能力裁决：返回实际发送的请求（原样 / 路由 / 抛错）
    func apply(req: ChatRequest): ChatRequest {
        if (!hasImageBlockIn(req.messages)) { return req }
        if (this.supportsVision) { return req }
        match (this.visionModel) {
            case Some(v) =>
                if (v != req.model) {
                    ChatRequest(v, req.messages, req.temperature, req.maxTokens,
                        req.reasoningEffort, req.tools, req.extra,
                        systemPrompt: req.systemPrompt)
                } else {
                    throw Exception("model '" + req.model +
                        "' does not support image input (supportsVision=false)")
                }
            case None =>
                throw Exception("model '" + req.model +
                    "' does not support image input (supportsVision=false); " +
                    "set supportsVision=true or configure visionModel for routing")
        }
    }
}

class ImageCapabilityWrapper <: Provider {
    private let outer: ImageCapabilityMiddleware
    private let inner: Provider

    public init(outer: ImageCapabilityMiddleware, inner: Provider) {
        this.outer = outer
        this.inner = inner
    }

    public func name(): String { this.inner.name() }

    public func chat(req: ChatRequest): ChatResponse {
        this.inner.chat(this.outer.apply(req))
    }

    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        this.inner.chatStreaming(this.outer.apply(req))
    }
}

// 请求消息中是否含图片块（仅 user 消息携带的图片会发送）。
// 判定走 llm_api 的 isImageBlock：图片有多种形态（内联/URL、带 detail、Files API 引用），
// 在这里逐个 match 会漏判新形态，而漏判的后果是把图发给不支持视觉的模型。
func hasImageBlockIn(msgs: ArrayList<Message>): Bool {
    for (m in msgs) {
        match (m) {
            case um: UserMessage =>
                for (b in um.content.blocks()) {
                    if (isImageBlock(b)) { return true }
                }
            case _ => ()
        }
    }
    false
}

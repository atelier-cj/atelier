# Provider

Provider 是 LLM 服务适配器，直接对接 REST API。

## Provider 接口

```cangjie
interface Provider {
    func name(): String
    func chat(req: ChatRequest): ChatResponse
    func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage>
}
```

## OpenAI 兼容 API

默认实现，覆盖绝大多数国产模型（DeepSeek、Qwen、GLM 等）。

### 配置

```toml
[[provider]]
name = "default"
baseURL = "https://api.openai.com/v1"
apiKey = "${OPENAI_API_KEY}"
```

### 环境变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `OPENAI_API_KEY` | API Key | — |
| `OPENAI_BASE_URL` | API 地址 | `https://api.openai.com/v1` |
| `OPENAI_MODEL` | 默认模型 | `gpt-4o` |

### 模型示例

| 服务商 | baseURL | 模型名 |
|--------|---------|--------|
| OpenAI | `https://api.openai.com/v1` | `gpt-4o`, `gpt-4o-mini` |
| DeepSeek | `https://api.deepseek.com` | `deepseek-chat`, `deepseek-reasoner` |
| 阿里 Qwen | `https://dashscope.aliyuncs.com/compatible-mode/v1` | `qwen-turbo`, `qwen-max` |
| 硅基流动 | `https://api.siliconflow.cn/v1` | `Qwen/Qwen2.5-72B-Instruct` |

### 代码创建

```cangjie
import atelier.provider.*

let provider = OpenAIProvider(
    "default",
    "https://api.openai.com/v1",
    "sk-xxx")
```

## ProviderRegistry

```cangjie
let reg = ProviderRegistry()
reg.register("default", provider)
reg.register("deepseek", deepseekProvider)

match (reg.get("deepseek")) {
    case Some(p) => // 使用
    case None => // 找不到
}
```

Agent 通过 `provider` 字段指定使用的 Provider：

```toml
[[agent]]
name = "assistant"
model = "deepseek-chat"
provider = "deepseek"
```

不指定时按 `provider` 名在 registry 中查找。

## 上下文窗口

Atelier 内置 `ModelContextRegistry` 查表：

| 模型 | 上下文窗口 |
|------|-----------|
| gpt-4o / gpt-4o-mini / gpt-4-turbo | 128,000 |
| gpt-4 / gpt-4-32k | 8,192 / 32,768 |
| gpt-3.5-turbo / gpt-3.5-turbo-16k | 16,384 |
| deepseek-chat / deepseek-reasoner | 65,536 |
| deepseek-coder | 16,384 |
| claude-sonnet-4 / claude-3.5-sonnet / claude-3-opus / claude-3-sonnet / claude-3-haiku | 200,000 |
| gemini-1.5-pro / gemini-1.5-flash / gemini-2.0-flash | 1,048,576 |
| qwen-turbo / qwen-plus / qwen-max | 131,072 |
| 未知模型 | 8,192（兜底） |

## 自定义 Provider

实现 `Provider` 接口即可对接任意 LLM API：

```cangjie
import atelier.provider.*
import atelier.message.*
import atelier.event.EventStream
import std.collection.ArrayList

class MyProvider <: Provider {
    private let name: String
    public init(name: String) { this.name = name }

    public func name(): String { this.name }

    public func chat(req: ChatRequest): ChatResponse {
        // 1. 构建 HTTP 请求体
        // 2. 调用 LLM API
        // 3. 解析为 AssistantMessage
        let msg = AssistantMessage(
            ContentList.ofText("response"),
            req.model, this.name,
            StopReason.EndTurn,
            TokenUsage(0, 0), 0)
        msg
    }

    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        let stream = EventStream<ChatDelta, AssistantMessage>()
        spawn {
            // 1. 构建 HTTP 请求（SSE）
            // 2. 逐 chunk 发射 ChatDelta
            // 3. 结束时 setResult
        }
        stream
    }
}

// 注册
providerReg.register("my-provider", MyProvider("my-provider"))
```

## 思考模式（DeepSeek）

DeepSeek Reasoner 支持思考模式，通过 `thinkingLevel` 配置：

```toml
[[agent]]
name = "reasoner"
model = "deepseek-reasoner"
thinkingLevel = "high"
```

`thinkingLevel` 可选值：`low` / `medium` / `high`。运行时透传给 OpenAI `reasoning_effort` 参数。

# Provider

Provider 是 LLM 服务适配器，直接对接 REST API。目前支持三种 Provider：

| 类型 | 协议 | 配置 `type` |
|------|------|-------------|
| OpenAI 兼容 | OpenAI Chat API | `"openai"`（默认） |
| Anthropic 兼容 | Anthropic Messages API | `"anthropic"` |
| Ollama | Ollama Chat API | `"ollama"` |

## Provider 接口

```cangjie
interface Provider {
    func name(): String
    func chat(req: ChatRequest): ChatResponse
    func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage>
}
```

## OpenAI 兼容

默认实现，覆盖绝大多数国产模型（DeepSeek、Qwen、GLM 等）。

### 配置

```toml
[[provider]]
name = "default"
type = "openai"
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

## Anthropic 兼容

通过 DeepSeek 等第三方服务商提供的 Anthropic Messages API 接入。

### 配置

```toml
[[provider]]
name = "deepseek-anthropic"
type = "anthropic"
baseURL = "https://api.deepseek.com/anthropic"
apiKey = "${DEEPSEEK_API_KEY}"

[[agent]]
name = "my-agent"
model = "deepseek-v4-flash"
provider = "deepseek-anthropic"
```

### 说明

- 请求格式遵循 [Anthropic Messages API](https://docs.anthropic.com/en/api/messages)
- System prompt 从 messages 提取为顶级 `system` 字段
- 工具调用通过 `content_block_start` + `input_json_delta` 流式传输
- 目前已知 DeepSeek 的 Anthropic 兼容接口可用

### 代码创建

```cangjie
let provider = AnthropicProvider(
    "deepseek-anthropic",
    "https://api.deepseek.com/anthropic",
    "sk-xxx")
```

## Ollama

接入本地 Ollama 服务。

### 配置

```toml
[[provider]]
name = "ollama"
type = "ollama"
baseURL = "http://192.168.3.6:11434"

[[agent]]
name = "local"
model = "qwen3.5:2b"
provider = "ollama"
```

### 说明

- Ollama 使用 NDJSON（非 SSE）作为流式传输格式
- 支持工具调用（需模型支持，如 qwen3.5:2b）
- 不需要 API Key
- 单模型服务，并发请求会排队

### 代码创建

```cangjie
let provider = OllamaProvider(
    "ollama",
    "http://192.168.3.6:11434")
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

`ProviderRegistry.default()` 返回带内置工厂的实例（CLI 默认），空构造 `ProviderRegistry()` 供库集成完全自控。工厂注册与按配置创建见下文「自定义 Provider」。

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

两种方式：**直接注册实例**（代码内）或**注册工厂**（配置驱动）。

### 方式一：直接注册实例（代码内）

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

### 方式二：注册工厂（配置驱动）

适合需要在 `~/.atelier.toml` 里用 `type` 配置的自定义 Provider：

```cangjie
import atelier.provider.*

class DeepSeekFactory <: ProviderFactory {
    public func `type`(): String { "deepseek" }
    public func create(cfg: ProviderConfig): Provider {
        // cfg.name / cfg.baseURL / cfg.apiKey / cfg.headers / cfg.extra 均可用
        DeepSeekProvider(cfg)
    }
}

// 注册工厂
providerReg.registerFactory(DeepSeekFactory())
```

配置：

```toml
[[provider]]
name = "deepseek"
type = "deepseek"          # 匹配工厂 type()
baseURL = "https://api.deepseek.com"
apiKey = "${DEEPSEEK_API_KEY}"
headers = ["x-custom: value"]          # 自定义请求头
extra = { reasoning_effort = "high" }  # 透传扩展参数
```

**内置工厂**（`ProviderRegistry.default()` 自动注册，无需手动）：

| type | 工厂 |
|------|------|
| `openai` | `OpenAIFactory` |
| `anthropic` | `AnthropicFactory` |
| `ollama` | `OllamaFactory` |

### ChatRequest.extra 扩展参数

`ChatRequest.extra: HashMap<String, JsonValue>` 可携带任意扩展参数，透传进请求体：

```cangjie
let extra = HashMap<String, JsonValue>()
extra["reasoning_effort"] = JsonValue.String("high")
extra["top_p"] = JsonValue.Number(0.9)

let req = ChatRequest("model", msgs, 0.7, 100, None, tools, extra)
```

- 三种内置 Provider 会把 extra 里**非保留字段**（model/messages/stream 等除外）原样写入请求体
- 值类型保真：`"high"` 写字符串，`0.9` 写数字
- 自定义 Provider 可完全自行决定如何使用 extra

### 自定义请求头

三种内置 Provider 的构造均支持 `headers: ArrayList<String>`（`"Name: value"` 格式）：

```cangjie
let provider = OpenAIProvider("default", "https://api.openai.com/v1", "sk-xxx",
    ["x-custom: value"])
```

配置层通过 `headers` 字段配置：

```toml
[[provider]]
name = "default"
type = "openai"
baseURL = "https://api.openai.com/v1"
apiKey = "${OPENAI_API_KEY}"
headers = ["x-custom: value", "x-org: my-org"]
```

### ProviderRegistry.default()

`ProviderRegistry.default()` 返回已注册内置工厂的实例（CLI 默认使用）；`ProviderRegistry()` 空构造供完全自控：

```cangjie
let reg = ProviderRegistry.default()   // 带 openai/anthropic/ollama 工厂
let reg = ProviderRegistry()           // 空，完全自控

// 按配置创建 Provider（工厂查 type 创建）
let prov = reg.create(cfg)
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

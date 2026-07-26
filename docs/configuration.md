# 配置参考

## TOML 配置文件

`~/.atelier.toml` 是 Atelier 的全局配置文件。不提供此文件也能运行，所有配置通过环境变量和默认值兜底。

```toml
[server]
host = "0.0.0.0"              # 监听地址，默认 0.0.0.0
port = 8080                    # 端口，默认 8080
sessionStore = "bstorm"        # 会话存储类型（默认 bstorm）
sessionDir = ""                # 会话存储目录，默认 ~/.atelier/sessions
authToken = ""                 # API Key 认证（可选）
trustMode = "ask"              # 信任模式：strict / approve-all / ask
logLevel = "info"              # 日志级别：debug / info / warn / error
logFormat = "text"             # 日志格式：text / json
rateLimit = 60                 # 每分钟请求限制（可选，0 表示不限）

[[provider]]
name = "default"               # Provider 名称
type = "openai"                # 类型（当前仅 openai）
baseURL = "https://api.openai.com/v1"
apiKey = "${OPENAI_API_KEY}"   # 支持 ${ENV_VAR} 引用环境变量

[[agent]]
name = "assistant"             # Agent 名称
description = "通用助手"       # 描述（可选）
model = "gpt-4o"               # 模型名称
provider = "default"           # 使用的 Provider（可选，默认按 model 推断）
systemPrompt = "你是一个有用的助手"
tools = ["bash", "read_file"]  # 可用工具列表
skills = ["code_review"]       # Skill 列表（可选）

[logging]
level = "info"                 # 日志级别，覆盖 server.logLevel

[[mcpServer]]
name = "playwright"            # MCP 服务器名称
transport = "stdio"            # 传输方式：stdio / streamable-http
command = "npx @playwright/mcp"
# streamable-http 时：
# transport = "streamable-http"
# url = "http://localhost:3100"
```

### 环境变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `OPENAI_API_KEY` | API Key | — |
| `OPENAI_BASE_URL` | API 地址 | `https://api.openai.com/v1` |
| `OPENAI_MODEL` | 默认模型 | `gpt-4o` |

---

## AgentConfig

通过代码构建 Agent 时使用 `AgentConfig` 结构体：

```cangjie
import atelier.agent.AgentConfig
import std.collection.ArrayList

let config = AgentConfig(
    name: "code-assistant",
    description: Some("代码审查助手"),
    systemPrompt: "你是高级工程师，审查代码质量",
    userPromptTemplate: None,
    model: "gpt-4o",
    provider: Some("default"),
    tools: ArrayList<String>(["read_file", "grep", "bash"]),
    skills: ArrayList<String>(["code_review"]),
    maxTurns: UInt32(20),           // 最大轮次
    temperature: Float32(0.7),      // 生成温度
    maxOutputTokens: UInt32(4096),  // 最大输出 Token
    thinkingLevel: None,            // 思考级别：None / "low" / "medium" / "high"
    compactionEnabled: true,        // 启用上下文压缩
    compactionReserveTokens: UInt32(16384),  // 压缩保留缓冲
    keepRecentTokens: UInt32(20000),         // 保留最近 Token 数
    maxToolCalls: UInt32(50),       // 单次运行最大工具调用
    toolTimeout: UInt32(30),        // 工具超时（秒）
    minToolInterval: UInt32(0),     // 工具最小间隔（毫秒）
    tags: ArrayList<String>(),      // 标签
    createdBy: None,                // 创建者
    createdAt: Int64(0),            // 创建时间戳
    updatedAt: Int64(0)             // 更新时间戳
)
```

### 字段说明

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `name` | `String` | — | 唯一标识 |
| `systemPrompt` | `String` | — | 系统提示词 |
| `model` | `String` | `"gpt-4o"` | 模型名称 |
| `provider` | `Option<String>` | `None` | 推断 |
| `tools` | `ArrayList<String>` | `[]` | 工具名称列表 |
| `skills` | `ArrayList<String>` | `[]` | Skill 名称列表 |
| `maxTurns` | `UInt32` | `20` | 最大推理轮次 |
| `temperature` | `Float32` | `0.7` | 生成温度 |
| `maxOutputTokens` | `UInt32` | `4096` | 最大输出 |
| `thinkingLevel` | `Option<String>` | `None` | 思考模式 |
| `compactionEnabled` | `Bool` | `true` | 上下文压缩 |
| `compactionReserveTokens` | `UInt32` | `16384` | 压缩缓冲 |
| `keepRecentTokens` | `UInt32` | `20000` | 保留最近 |
| `maxToolCalls` | `UInt32` | `50` | 工具调用上限 |
| `toolTimeout` | `UInt32` | `30` | 工具超时 |
| `minToolInterval` | `UInt32` | `0` | 工具最小间隔 |

### 默认配置

```cangjie
let config = AgentConfig.default()
```

默认值适用于大多数场景，只需覆写需要的字段。

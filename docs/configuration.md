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
trustMode = "ask"              # 保留字段，暂未接入运行时逻辑
logLevel = ""                  # 日志级别（空=不输出，debug/info/warn/error）
logFormat = "text"             # 日志格式：text / json
rateLimit = 0                  # 每分钟请求限制（0 表示不限）

[[provider]]
name = "default"               # Provider 名称
type = "openai"                # 类型：openai / anthropic / ollama（或注册的自定义工厂 type）
baseURL = "https://api.openai.com/v1"
apiKey = "${OPENAI_API_KEY}"   # 支持 ${ENV_VAR} 引用环境变量（ollama 不需要）
headers = ["x-custom: value"]  # 自定义请求头（可选，Name: value 格式）
extra = { reasoning_effort = "high" }  # 透传扩展参数（可选，写入请求体）

[[provider]]
name = "ollama"
type = "ollama"
baseURL = "http://localhost:11434"

[[provider]]
name = "deepseek-anthropic"
type = "anthropic"
baseURL = "https://api.deepseek.com/anthropic"
apiKey = "${DEEPSEEK_API_KEY}"

[[agent]]
name = "assistant"             # Agent 名称
description = "通用助手"       # 描述（可选）
model = "gpt-4o"               # 模型名称
provider = "default"           # 使用的 Provider（可选，不指定则按 model 在 registry 中查找）
systemPrompt = "你是一个有用的助手"
tools = ["bash", "read_file", "mcp_*"]  # 可用工具列表（mcp_* 通配暴露已激活的 MCP 工具）
skills = ["code_review"]       # Skill 列表（可选）
mcpCooldownTurns = 0           # MCP 冷却卸载轮数（可选，0=不启用默认；>0=N 轮未用自动卸载）

[logging]
level = "info"                 # 日志级别，覆盖 server.logLevel

[[mcpServer]]
name = "playwright"            # MCP 服务器名称（不能含下划线）
transport = "stdio"            # 传输方式：stdio / streamable-http / session-http
command = "npx @playwright/mcp"
# streamable-http 时：
# transport = "streamable-http"
# url = "http://localhost:3100"
```

### MCP 服务

- 启动时连接全部 `[[mcpServer]]`（连接不占用 LLM token），工具定义**不直接进入 LLM 工具列表**
- LLM 通过调用 `load_mcp_toolset(server_id)` 工具**激活**服务后，其 `mcp_<server>_<tool>` 工具才进入可用列表（需在 `tools` 白名单配置 `mcp_*` 通配）
- 激活状态进程级共享、不持久化；`mcpCooldownTurns > 0` 时，连续 N 轮未使用该服务的工具会自动卸载
- 系统提示中的 `[可用 MCP 服务]` 目录段展示全部服务（名称/版本/工具清单），激活服务标注 `[已加载]`
- 服务名不能包含下划线（工具名 `mcp_<server>_<tool>` 前缀解析依赖）

### 压缩增强（可选）

不配置 `[agent.compaction]` 时使用平铺字段（`compactionEnabled`/`compactionReserveTokens`/`keepRecentTokens`），配置后嵌套优先：

```toml
[[agent]]
name = "assistant"
# ... 其他字段 ...
compactionEnabled = true          # 平铺配置（可选，兼容旧配置）

# [agent.compaction]              # 嵌套配置（可选，优先于平铺字段）
# enabled = true
# reserveTokens = 16384
# keepRecentTokens = 20000
# summaryModel = "deepseek-chat"   # 摘要模型，缺省复用主模型
# promptTemplate = "压缩以下对话：\n{{conversation}}"
# outputSchema = { required = ["goal"], types = { goal = "string" } }
```

- 压缩摘要通过**独立子调用**生成（无 system/tools，不影响主对话缓存命中）
- `promptTemplate` 支持 mustache 变量：`{{conversation}}` / `{{previous_summary}}` / `{{max_tokens}}` / `{{#previous_summary}}` 条件块
- `outputSchema` 极简校验（required 必填 + types 类型断言），校验失败自动降级为占位摘要

### 会话环境

`~/.atelier.toml` 中可设置默认会话环境：

```toml
[server.env]
directory = "/data/projects/default"

[server.env.context]
current_page = "/"
user_role = "guest"
```

会话级可覆盖。参见 [会话管理](sessions.md#会话环境)。

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
    maxTurns: UInt32(20),
    temperature: Float32(0.7),
    maxOutputTokens: UInt32(4096),
    thinkingLevel: None,
    compactionEnabled: true,
    compactionReserveTokens: UInt32(16384),
    keepRecentTokens: UInt32(20000),
    maxToolCalls: UInt32(50),
    toolTimeout: UInt32(30),
    minToolInterval: UInt32(0),
    tags: ArrayList<String>(),
    createdBy: None,
    createdAt: Int64(0),
    updatedAt: Int64(0)
)
```

### 字段说明

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `name` | `String` | `""` | 唯一标识 |
| `description` | `Option<String>` | `None` | 描述 |
| `systemPrompt` | `String` | `""` | 系统提示词 |
| `userPromptTemplate` | `Option<String>` | `None` | 用户提示词模板 |
| `model` | `String` | `""` | 模型名称（空则运行时取 OPENAI_MODEL 或 gpt-4o） |
| `provider` | `Option<String>` | `None` | Provider 名称，在 ProviderRegistry 中查找 |
| `tools` | `ArrayList<String>` | `[]` | 工具名称列表 |
| `skills` | `ArrayList<String>` | `[]` | Skill 名称列表 |
| `maxTurns` | `UInt32` | `20` | 最大推理轮次 |
| `temperature` | `Float32` | `0.7` | 生成温度 |
| `maxOutputTokens` | `UInt32` | `4096` | 最大输出 Token |
| `thinkingLevel` | `Option<String>` | `None` | 思考模式（deepseek-reasoner 可用） |
| `compactionEnabled` | `Bool` | `true` | 启用上下文压缩 |
| `compactionReserveTokens` | `UInt32` | `16384` | 压缩保留缓冲 |
| `keepRecentTokens` | `UInt32` | `20000` | 保留最近 Token 数 |
| `maxToolCalls` | `UInt32` | `50` | 单次运行最大工具调用数 |
| `toolTimeout` | `UInt32` | `30` | **只读**（`Parallel`）工具的单次墙钟预算（秒）；`0` = 不限时 |
| `sideEffectToolTimeout` | `UInt32` | `300` | **有副作用**（`Sequential`）工具的预算（秒）；`0` = 不限时 |
| `minToolInterval` | `UInt32` | `0` | 工具调用最小间隔（毫秒） |
| `toolPresentation` | `ToolPresentationMode` | `Native` | 工具呈现模式：`native` / `ptc` / `both`，见 [tools.md](tools.md) |
| `ptcTimeoutSeconds` | `UInt32` | `30` | PTC 单次程序的经过时间预算（秒） |
| `ptcMaxSubCalls` | `UInt32` | `64` | PTC 单次程序允许的子调用上限 |
| `tags` | `ArrayList<String>` | `[]` | 标签 |
| `createdBy` | `Option<String>` | `None` | 创建者 |
| `createdAt` | `Int64` | `0` | 创建时间戳 |
| `updatedAt` | `Int64` | `0` | 更新时间戳 |

### 工具预算（`toolTimeout` / `sideEffectToolTimeout`）

工具是同步接口（`execute` 一直阻塞到返回），内部没有可协作的中断点，因此预算在
**调用边界**上用「另起线程 + 限时等待」实现。核心事实：

> **超时 = 不再等它，不是把它停掉。** 仓颉线程不可抢占，被超时的那次执行会在后台
> 一直跑到自己结束——预算保护回合的前进，不保护副作用。

这条事实决定了两类工具必须分开配额度，因为超时的**含义**不同：

| 类别 | 判定 | 默认 | 超时意味着 | 模型该怎么做 |
|---|---|---|---|---|
| 只读 | `ToolExecutionMode.Parallel` | 30s | 白跑一趟 | 重试无害 |
| 有副作用 | `ToolExecutionMode.Sequential` | 300s | **结果未知**（可能已落盘，也可能什么都没做） | 先核实状态再决定是否重试 |

写类额度宽一个量级：构建、安装、批量写入这类正常耗时本就长，而这一类的「超时」
代价大得多——模型若当成失败直接重试，一次写入会变成两次。因此超时文本也分两套：

```
[tool timeout] 'read_file' did not return within 30s; the call was abandoned and may still
be running in the background (declared side-effect-free).

[tool timeout] 'bash' did not return within 300s. The call was abandoned but may still
complete in the background, so its outcome is UNKNOWN — verify the resulting state
(read the file / check the effect) before retrying.
```

其它语义：

- **超时不是 `terminate`**：同一批次里后面的工具照常执行。
- 生效范围包括程序化调用（PTC）的**子调用**：否则一个卡住的工具连脚本带回合一起拖死。
- 工具可以用 `Tool.timeoutBudget()` 覆盖本配置，三态：`Default`（用本表）、
  `Unbounded`（本工具不该有预算，如 `ask_user` 等人回答）、`Limit(d)`（自己的额度）。
  `run_xisp` 用 `Limit`：外层额度 = 程序预算 + 一次在途子调用 + 5s 宽限，好让脚本
  先给出自己的失败原因，而不是被外层掐成一句笼统的工具超时。
- `0` = 该类不限时（显式选择）。此时卡住的同步工具会一直占着回合，只剩 Ctrl+C 一条退路。

### 默认配置

```cangjie
let config = AgentConfig.default()
```

所有字段使用代码默认值，适用于快速测试。

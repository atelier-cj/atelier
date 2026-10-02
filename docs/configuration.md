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
skipTlsVerify = false          # 跳过 TLS 证书校验（可选，默认 false；仅在系统 CA 不可得时开启，见 docs/providers.md「TLS 校验」）

  # 本端点上的模型事实（可选，可多段）：上下文窗口是 (provider, model) 这一对路由的属性 ——
  # 同名模型走官方端点和走截断过的代理，窗口可以不同，所以声明在这里而不是 agent 上
  [[provider.model]]
  name = "deepseek-chat"
  contextWindow = 65536        # token，**含输入与输出**；不声明则回退 provider 自报/内置目录
  maxTokens = 8192             # 默认完成预算（token）；压缩要按 窗口 - 完成预算 - 余量 留预算

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
model = "deepseek-chat"        # 模型名称
provider = "default"           # 使用的 Provider（可选，缺省 "default"）
systemPrompt = "你是一个有用的助手"
tools = ["bash", "read_file", "mcp_*"]  # 可用工具列表（mcp_* 通配暴露已激活的 MCP 工具）
skills = ["code_review"]       # Skill 列表（可选）
mcpCooldownTurns = 0           # MCP 冷却卸载轮数（可选，0=不启用默认；>0=N 轮未用自动卸载）
maxTurns = 20                  # 单次 run 的最大回合数（可选，默认 20）
maxOutputTokens = 4096         # 单条回复的最大输出 token（可选，默认 4096）
maxLengthContinuations = 3     # 输出被截断后同回合自动续跑的次数上限（可选，默认 3；0=截断即结束）
maxVerifyPasses = 0            # 收尾前自验次数上限（可选，默认 0=关闭；评测/长任务建议 1）

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

### 上下文压缩（可选）

`compactionEnabled` 是开关；预算口径全在 `[agent.compaction]` 里（dsh 同款）：

```text
W = 本路由的上下文窗口（[[provider.model]] / provider 自报）
O = 本次请求的输出上限（maxOutputTokens；0 = 用模型事实）
messageBudget  = W − O              留给消息的部分
pressureBudget = messageBudget − B  B = headroomTokens
threshold      = floor(min(W × thresholdRatio, pressureBudget))   越过它才压
retain         = retainTokens ?? floor(messageBudget × retainRatio)  压完逐字保留多少
```

```toml
[[agent]]
name = "assistant"
compactionEnabled = true           # 开关（可选，默认 true）

# [agent.compaction]               # 预算与摘要调用（可选，缺省值见下）
# enabled = true
# thresholdRatio = 0.8             # 阈值占窗口比例
# headroomTokens = 65536           # 完成预算之外的额外余量（估算误差/图片/工具声明的缓冲）
# retainRatio = 0.16               # 逐字保留的近期历史占"消息预算"的比例
# retainTokens = 20000             # 绝对保留预算（与 retainRatio 互斥，给了就以它为准）
# maxOverflowRetries = 1           # provider 报超窗后的最大恢复重试次数（0 = 关闭恢复）
# summaryMaxTokens = 0             # 摘要子调用输出上限；0 = 跟随 headroomTokens

# [agent.compaction.prune]         # 工具结果修剪（可选；不配 = 开启，阈值 8192 码点）
# enabled = true
# thresholdChars = 8192            # 合并文本超过这么多**码点**才修剪
# headChars = 4096                 # 保留的开头码点数
# tailChars = 1024                 # 保留的末尾码点数
# summaryModel = "deepseek-chat"   # 摘要模型，缺省复用主模型
# promptTemplate = "压缩以下对话：\n{{conversation}}"
# outputSchema = { required = ["goal"], types = { goal = "string" } }
```

- **三个不变量**：`W − O > 0`、`− B > 0`、`retain < threshold`。任一不成立就**不压**：
  日志留一条警告（每个原因一次），而**溢出恢复仍然可用** —— 配置坏了不该让会话不可用。
  小窗口部署要么调大窗口，要么把 `headroomTokens` 收小（默认 64k 是为大窗口模型留的余量）。
- **手动触发**：`/compact`（TUI）或库 API `AgentRuntime.compactNow(sessionId, messages, env)` ——
  绕过阈值，仍守上面的保留策略与三个不变量；压不动时返回原因而不改历史。
  自动与手动共用同一条管线、同一个事务括弧与会话级互斥。
- **触发点在请求派发前**：每回合发请求前量一次压力（provider 报的用量为锚 + 其后新增消息的估算），
  越过阈值才处理 —— 回合结束后再压的话，本轮该发的请求早就发出去了。
- **先修剪、后摘要**：先按 `[agent.compaction.prune]` 把超长工具结果换成"头 + 标记 + 尾"
  （**不发模型调用**，只作用于发给模型的那一份，落库历史保持完整），修剪后回到阈值内就
  **省掉摘要调用**；仍在阈值之上才做摘要 + 替换。
- **溢出恢复**：provider 明确报"超上下文窗口"（`maximum context length` / `prompt is too long` 等）
  时，绕过阈值压掉最大的一段头部（只保最后一条用户消息起的内容，不拆散工具调用对），
  再用新历史重试同一请求，次数受 `maxOverflowRetries` 限制。
- 默认摘要指令是 dsh 同款的 Markdown 检查点骨架（八个固定小节 + "空节写 (none)"/"不照抄上一份"
  等硬规则）；指令里说的"上面这段对话"就是被回放的那批消息，提示词本身**不内联对话**
  （内联会毁掉前缀复用）。`promptTemplate` 可整段替换；自定义模板仍可用
  `{{conversation}}`（被压区域的扁平文本）/ `{{previous_summary}}` / `{{max_tokens}}`
- 压缩后的替换消息带**检查点框架**：一段前言（"这是自动生成的检查点…当作既定背景，不要复述、
  也不要提及"）+ `<compacted-summary>…</compacted-summary>` 标签。落库的就是这份文本 ——
  模型看到的即所存的，续跑/回放不会变样；界面与"上一份检查点"复用会剥掉框架取裸摘要。
- 摘要子调用**复用主对话前缀**：同样的 system 提示词 + 工具声明 + 被压区域消息原样回放，
  压缩指令只追加在最后一条 user 消息里。provider 的前缀缓存按"缓存前缀单元完整匹配"计费
  （[DeepSeek 的硬盘缓存](https://api-docs.deepseek.com/zh-cn/guides/kv_cache/) 即如此），
  这样那段长输入按缓存价结算；若把对话内联进提示词，前缀从第一个 token 就不同，整段按未命中计价。
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
    compaction: None,                       // 预算口径见「上下文压缩」节
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
| `provider` | `Option<String>` | `None` | Provider 名称，缺省 `"default"`；在装配束（叠加表 → 注册表）中解析，找不到会明确报错 |
| `tools` | `ArrayList<String>` | `[]` | 工具名称列表 |
| `skills` | `ArrayList<String>` | `[]` | Skill 名称列表 |
| `maxTurns` | `UInt32` | `20` | 最大推理轮次 |
| `temperature` | `Float32` | `0.7` | 生成温度 |
| `maxOutputTokens` | `UInt32` | `4096` | 最大输出 Token（agent 的策略）；`0` = 交给模型事实（`[[provider.model]] maxTokens` / provider 自报） |
| `maxLengthContinuations` | `UInt32` | `3` | 输出撞 token 上限后同回合自动续跑的次数上限；`0` = 不续跑（截断即回合结束） |
| `maxVerifyPasses` | `UInt32` | `0` | 收尾前自验次数上限：宣布完成时先要求实操核对再收尾；`0` = 关闭 |
| `thinkingLevel` | `Option<String>` | `None` | 思考模式（deepseek-reasoner 可用） |
| `compactionEnabled` | `Bool` | `true` | 启用上下文压缩 |
| `compaction` | `Option<CompactionConfig>` | `None` | 压缩预算与摘要调用（阈值/余量/保留/溢出恢复），见「上下文压缩」节 |
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

### 输出截断的自动续跑（`maxLengthContinuations`）

模型单条回复撞到 `maxOutputTokens` 上限时，provider 返回的是**被截断的半截回复**
（`StopReason.Length`，ACP 侧呈现为 `stopReason: max_tokens`）。这不等于任务结束：
运行时会自动追加一条「从截断处继续、不要重复已写内容」的消息，并在**同一回合内**再请求一次，
最多续跑 `maxLengthContinuations` 次（默认 `3`；`0` = 保持旧行为，截断即回合结束）。

- 续跑**不消耗**回合数（`maxTurns`）；但同一回合的续跑次数用尽后仍会收尾，
  避免「模型一直写不完 → 无限续跑」。
- 续跑只追加一条用户消息，不重复已有内容，因此不会把上下文翻倍。
- 需要严格「一问一答」的场景（例如把截断本身当作有意义的信号）把它设为 `0`。

### 收尾前自验（`maxVerifyPasses`）

最常见的失败模式不是「做不完」，而是「**模型自认为做完了**」：回合以 `EndTurn` 结束、没有任何
工具调用，但产物并不满足任务约束。把 `maxVerifyPasses` 设为 `> 0` 后，运行时会在这个时刻插入
一条「逐条核对任务要求、重新读取/运行产物、确认无误再收尾」的消息，并把自验当作**新回合**
（消耗 `maxTurns`），最多插入该次数。

- 默认 `0`（关闭）：交互式对话里不会被自动追问打扰；评测/长任务建议设 `1`。
- 只在「本 run 已经调用过工具」（真的做过事）且回合以 `EndTurn` 正常结束时触发；
  直接问答式回答不触发。
- 它是「纪律」而不是「验证器」：只要求模型自己实操核对，判定仍由外部（人/验证器）完成。

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

## `[a2a]` 段

A2A v1 服务端配置（`atelier a2a`，或 `mountToServer` 挂进 `serve` 时生效）。

```toml
[a2a]
auth = true                                   # 开启 Bearer / API Key 认证
token = "..."                                 # 静态 token（也可用 ATELIER_A2A_TOKEN）
apiKeyHeader = "X-API-Key"
listen = "127.0.0.1"                          # 后端监听；LB 在别的容器时用 0.0.0.0
publicUrl = "https://agent.example.com"       # 卡片发布的对外地址（LB 终止 TLS 时必填）
mountToServer = false                         # 挂进 serve，与既有 HTTP 服务共用端口
```

字段说明与部署要点见《[A2A 接入](a2a.md)》；CLI 用法见《[CLI 参考](cli.md)》。

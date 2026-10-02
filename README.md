# Atelier — 可嵌入的 Agent Harness

Atelier 是一个纯仓颉实现的 Agent Harness —— 把模型变成 Agent 的那层脚手架。

定位为**成品工坊**而非**编排框架**——挂载工具、配置 Skills、选择存储，即可获得完整的可运行 Agent，无需从零实现推理循环、上下文管理或模型适配。

## 特性

- **开箱即用**：库 + HTTP 服务 + CLI 三种形态
- **ACP 兼容**：`atelier acp` 以 ACP v1 Agent 身份被 Zed/opencode 等宿主拉起（stdio）
- **A2A 双向**：`atelier a2a` 把 Agent 暴露为 A2A v1 Agent —— JSON-RPC 与 HTTP+JSON 双绑定、
  SSE 流式、推送通知、Bearer/API Key 认证、按调用方隔离任务可见性；也可用
  `[a2a].mountToServer` 挂进 `serve`，与既有 HTTP 服务共用一个端口。反向则把**远端** A2A Agent
  接入子 Agent 体系（`remote_a2a_subagent`），父侧 `subagent_*` 工具无需改动即可驱动它
- **运行时动态**：Agent 在运行时通过 TOML 或代码定义，无需编译
- **多模型**：OpenAI / Anthropic / Ollama 三种 Provider，覆盖绝大多数模型
- **MCP 工具**：通过 `ystyle::mcp` 接入任意 MCP 服务器（stdio/Streamable HTTP）
- **树形会话**：Entry + ParentID 树模型，支持 fork/clone/JSONL 持久化
- **信任闸门**：目录级权限控制，`Undecided` 时发出结构化审批（允许本次 / 总是允许 / 拒绝）
- **Skill 系统**：按 AgentSkills 规范的声明式技能注入
- **上下文压缩**：dsh 口径阈值（`min(W × ratio, W − O − headroom)`）+ 超窗恢复 + 工具结果修剪 +
  摘要复用主对话前缀（吃 provider 缓存）+ 手动 `/compact`；provider 用量优先、本地估算兜底
- **钩子系统**：6 个生命周期钩子（beforeRun~afterTool）
- **Agent-as-Tool**：子 Agent 委派模式，同进程隔离上下文
- **可持续子 Agent**：常驻子 Agent + 双向 send_message（汇报/提问/唤醒取代单向 report）
- **全功能提问**：审批 / 选择 / 表单统一成一个提问原语（`UserRequest` → `UserAnswer`）；
  TUI、ACP、AG-UI、HTTP 四端各自接线——可同 run 内等待，也可返回 `Pending` 挂起本次 run、在下一次输入里带答复

## 安装

仓库为 **monorepo**（一个 cjpm 工作区，产品版本 lockstep）：`atelier/`（核心库 `atelier`，发布中心仓）
+ `cli/`（终端 agent 产品，产物 `cli.app`）+ `server/`（HTTP 服务库 `server`）。

```bash
git clone https://atomgit.com/ystyle/atelier
cd atelier

# 核心库
cjpm build -j 16

# 终端 agent 产品（cli.app）与 HTTP 服务库
(cd cli && cjpm build -j 16)
(cd server && cjpm build -j 16)
```

## 集成方式

**库模式** — 在 `cjpm.toml` 添加依赖，装一个**装配束**（HarnessSpec）就能跑：

```cangjie
import atelier.agent.*

// 零配置：内置工具 + 内存会话 + 环境变量里的 provider
let h = Harness.open()
println(h.run("你好"))
h.close()
```

要换组件就派生装配束 —— 每个组件都是接口，`with*` 只影响这一份（不写穿共享组件）：

```cangjie
let spec = HarnessSpec.default()
    .withProvider("default", OpenAIProvider("default", baseUrl, apiKey))  // 换模型服务
    .withStore(StormSessionStore("./sessions"))                           // 换会话存储
    .withTool(SqlTool())                                                  // 加/换工具（同名覆盖）
    .withHook(AuditHook())                                                // 横切钩子
    .withModelContext("deepseek", "deepseek-chat", 65536)                 // 声明端点上的模型窗口
    // askFn：(UserRequest) -> UserAnswer —— 审批/选择/表单的宿主侧入口。
    // 不挂 = 没有提问通道：需要用户拍板的地方按「取消」处理（等同拒绝）
    .withAsk({ req => myApprovalUi(req) })

let h = Harness.open(spec)
```

> 上下文窗口是 **`(provider, model)` 这一对的事实**，不是 agent 的属性：同名模型走官方端点和走
> 一个截断过的代理，窗口可以不同。所以它声明在 provider 下（配置里 `[[provider.model]]`、
> 代码里上面的 `withModelContext`），agent 只负责**选**这一对。想让它更早压缩是另一回事，
> 用 `compactionReserveTokens` / `keepRecentTokens` 这类策略旋钮。

需要会话 id、事件流、取消、子 Agent 这些细粒度能力时，从**同一个装配束**下钻到运行时
（没有第二套配置）：

```cangjie
let runtime = AgentRuntime(spec, cfg)          // cfg: AgentConfig
let stream = runtime.chatWithSessionId(sid, msgs, env)
for (event in stream) { ... }
runtime.cancelSession(sid)
```

**HTTP 挂载** — 路由挂到既有 HTTP 服务，用的还是同一份装配束：

```cangjie
let atelier = AtelierHttpHandler(spec)
atelier.registerRoutes(server.distributor)
```

**独立服务** — 一键启动：

```bash
cli.app serve 8080
```

**CLI** — 交互式或单次运行：

```bash
cli.app tui
cli.app run "你好"
```

## 快速开始

```bash
# 构建整个工作区（atelier 核心库 + server + cli；一条命令覆盖三个成员）
# 产物：target/release/bin/cli.app
cjpm build -j 16

# 写入环境变量
export OPENAI_API_KEY="sk-xxx"
export OPENAI_BASE_URL="https://api.openai.com/v1"

# 交互式 TUI
./target/release/bin/cli.app tui

# 单次对话
./target/release/bin/cli.app run "你好，介绍一下你自己"

# 启动 HTTP 服务
./target/release/bin/cli.app serve 8080

# 调用 API
curl http://localhost:8080/agent/run \
  -H "Content-Type: application/json" \
  -d '{"agent":"default","messages":[{"role":"user","content":"你好"}]}'
```

## 配置

写入 `~/.atelier.toml`：

```toml
[[provider]]
name = "deepseek"
baseURL = "https://api.deepseek.com"
apiKey = "${DEEPSEEK_API_KEY}"

  # 端点上的模型事实：窗口是 (provider, model) 这一对的属性
  # （同名模型走官方端点和走截断过的代理，窗口可以不同）
  [[provider.model]]
  name = "deepseek-chat"
  contextWindow = 65536        # 窗口含输入与输出
  maxTokens = 8192             # 默认完成预算（压缩要按它留余量）

[[agent]]
name = "assistant"
model = "deepseek-chat"
provider = "deepseek"          # agent 只负责「选」这一对（provider + model）
systemPrompt = "你是一个有用的助手"
tools = ["bash", "read_file", "grep", "glob"]

[logging]
level = "info"

[[mcpServer]]
name = "playwright"
transport = "stdio"
command = "npx @playwright/mcp"
```

## 文档

| 文档 | 说明 |
|------|------|
| [集成指南](docs/integration.md) | 库模式 / HTTP 挂载 / CLI / Docker |
| [配置参考](docs/configuration.md) | TOML 配置 + AgentConfig 字段 |
| [消息模型](docs/messages.md) | 4 种角色 + ContentBlock |
| [事件流](docs/events.md) | 12 种事件（含 Suspend 挂起）+ EventStream |
| [工具开发](docs/tools.md) | 内置工具 + 自定义 + MCP |
| [Provider](docs/providers.md) | OpenAI / 自定义 Provider |
| [会话管理](docs/sessions.md) | 树模型 + 持久化 |
| [信任闸门](docs/trust.md) | 权限控制 |
| [Skill](docs/skills.md) | 声明式技能注入 |
| [HTTP API](docs/http-api.md) | 端点参考 + curl 示例 |
| [CLI 参考](docs/cli.md) | serve/tui/run/acp/a2a |
| [ACP 接入](docs/acp.md) | ACP v1 Agent 侧：能力矩阵、接入示例、config options |
| [A2A 接入](docs/a2a.md) | A2A v1 双向：能力矩阵、概念映射、远端子 Agent、部署（LB/认证/共用端口） |
| [架构设计](docs/design.md) | 总体设计文档 |

## 开发

```bash
# 核心库：编译 + 测试
cjpm build -j 16
cjpm test -j 16 --no-progress

# cli / server：各自独立构建与测试
(cd cli && cjpm build -j 16 && cjpm test -j 16 --no-progress)
(cd server && cjpm build -j 16 && cjpm test -j 16 --no-progress)

# 运行单个测试
cjpm test --show-all-output --filter 'TestName.*'
```

## 外部依赖

| 依赖 | 用途 | 协议 |
|------|------|------|
| `ystyle::mcp` | MCP 协议层（工具发现/调用/传输） | MIT |
| `bstorm` | 会话持久化（基于 badger-cj 的 ORM） | MIT |
| `tomlcj` | TOML 解析（`server` 项目使用） | MIT |
| `acp` | ACP v1 协议层（Agent/Client 双端） | MulanPSL-2.0 |

核心 Harness（Agent Loop、事件流、上下文压缩、Provider、信任闸门）全部自研，零外部依赖。

# 集成指南

## 场景一：库模式嵌入到既有应用

最适合在既有仓颉项目内使用 Agent 能力的场景。

### 步骤

**1. 添加依赖**

在 `cjpm.toml` 中引入 atelier：

```toml
[dependencies]
atelier = { path = "/path/to/atelier" }
```

**2. 创建 Agent 并运行**

```cangjie
import atelier.*
import atelier.message.*
import atelier.provider.*
import atelier.tool.*
import atelier.tool.builtin.*
import atelier.session.*
import atelier.skill.*
import atelier.trust.*
import std.collection.*

main() {
    // 装配束：内置工具 + 本次要用的 provider / 会话存储
    let spec = HarnessSpec.default()
        .withProvider("default",
            OpenAIProvider("default",
                "https://api.openai.com/v1",
                getApiKey()))
        .withStore(MemorySessionStore())

    // 定义 Agent 并创建运行时（装配束 + 配置）
    let config = AgentConfig.default()
    let runtime = AgentRuntime(spec, config)

    // 发送消息
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("列出当前目录的文件"), 0))

    let stream = runtime.chat(msgs)

    // 消费事件流
    for (event in stream) {
        match (event) {
            case u: MessageUpdateEvent =>
                print(u.delta)
            case _: AgentEndEvent =>
                println("\n--- 完成 ---")
            case _ => ()
        }
    }

    // 或直接取最终结果
    let result = stream.result()
    let lastText = extractText(result)
    println(lastText)
}

func getApiKey(): String {
    match (getVariable("OPENAI_API_KEY")) {
        case Some(k) => k
        case None => ""
    }
}

func extractText(msgs: ArrayList<Message>): String {
    var i = msgs.size - 1
    while (i >= 0) {
        match (msgs[i]) {
            case am: AssistantMessage =>
                var r = ""
                for (b in am.content.blocks()) {
                    match (b) {
                        case ContentBlock.TextBlock(t) => r = r + t
                        case _ => ()
                    }
                }
                return r
            case _ => ()
        }
        i--
    }
    ""
}
```

## 场景二：挂载到既有 HTTP 服务

适合已有仓颉 HTTP 服务的项目，不占独立端口。

### 步骤

```cangjie
import atelier.server.*
import atelier.agent.*
import atelier.tool.*
import atelier.tool.builtin.*
import atelier.session.*
import atelier.trust.*
import atelier.skill.*
import stdx.net.http.*

main() {
    // 1. 准备 Atelier 组件
    let toolReg = ToolRegistry()
    toolReg.register(ReadFileTool())
    toolReg.register(BashTool())

    let agentReg = AgentRegistry()
    let sessionStore = MemorySessionStore()
    let trustMgr = TrustManager()
    let skillReg = SkillRegistry()

    // 2. 创建 Handler
    let atelier = AtelierHttpHandler(
        agentReg, toolReg, sessionStore, trustMgr, skillReg)

    // 3. 创建你的 HTTP 服务
    let server = ServerBuilder()
        .addr("0.0.0.0")
        .port(8080)
        .build()

    // 4. 挂载 Atelier 路由
    atelier.registerRoutes(server.distributor)

    // 5. 还可以加你自己的路由
    server.distributor.register("/health", { ctx =>
        let b = ctx.responseBuilder
        b.status(200)
        b.body("ok")
    })

    server.serve()
}
```

### 注册的路由

| 方法 | 路径 | 说明 |
|------|------|------|
| GET/POST/DELETE | `/agent/config` | Agent 配置管理 |
| GET | `/agent/configs` | 列举 Agent 配置详情 |
| POST | `/agent/run` | 同步运行 |
| GET | `/agent/stream` | SSE 流式运行 |
| POST | `/agent/input` | 提问答复回传（按 requestId：审批/选择/表单） |
| POST | `/session/save` | 保存会话 |
| POST | `/session/load` | 加载会话 |
| POST | `/session/fork` | 克隆会话 |
| POST | `/session/export` | 导出会话（JSONL/HTML） |
| GET | `/sessions` | 会话列表 |
| POST | `/trust` | 信任管理 |
| POST | `/v1/chat/completions` | OpenAI 兼容 API |
| POST | `/ag-ui/agent` | **AG-UI 协议**端点（对外前端协议）：`RunAgentInput` → SSE 事件流 |
| GET | `/health` | 健康检查 |

---

## 场景三：独立 HTTP 服务

一行命令启动，适合快速部署。

```bash
# 使用默认端口 8080
cli.app serve

# 指定端口
cli.app serve 9000

# 配置 ~/.atelier.toml 控制服务行为
```

配置示例 `~/.atelier.toml`：

```toml
[server]
host = "0.0.0.0"
port = 8080
sessionDir = "/var/lib/atelier/sessions"
logLevel = "info"
trustMode = "ask"

[[provider]]
name = "default"
baseURL = "https://api.openai.com/v1"
apiKey = "${OPENAI_API_KEY}"

[[agent]]
name = "assistant"
model = "gpt-4o"
systemPrompt = "你是一个有用的助手"
tools = ["bash", "read_file", "grep", "glob"]
```

---

## 场景四：CLI 交互

适合开发调试和一次性任务。

### 交互式 TUI

```bash
# 启动 TUI（默认 agent）
cli.app tui

# 指定 agent
cli.app tui my-assistant

# 恢复之前会话
cli.app tui my-assistant sess_abc123
```

TUI 内支持斜杠命令：

| 命令 | 说明 |
|------|------|
| `/help` | 帮助 |
| `/model <name>` | 切换模型 |
| `/tools` | 列出可用工具 |
| `/session new` | 新建会话 |
| `/session list` | 列出会话 |
| `/session switch <id>` | 切换会话 |
| `/session export <id> html` | 导出回放 |
| `/trust <path>` | 信任目录 |
| `/untrust <path>` | 取消信任 |
| `/clear` | 清屏 |
| `/exit` | 退出 |

### 单次执行

```bash
# 使用默认 agent
cli.app run "分析这个日志文件"

# 指定 agent
cli.app run code-assistant "给这个函数加注释"
```

---

## 场景五：Docker 部署

```dockerfile
FROM cangjie:latest AS build
WORKDIR /app
COPY . .
RUN cjpm build -j 16

FROM cangjie:latest
COPY --from=build /app/target/release/atelier /usr/local/bin/
COPY atelier.toml /root/.atelier.toml
EXPOSE 8080
CMD ["atelier", "serve", "8080"]
```

```bash
docker build -t atelier .
docker run -e OPENAI_API_KEY=sk-xxx -p 8080:8080 atelier
```

## 场景六：用 Atelier 构建 LLM Wiki

LLM Wiki 是一个知识库问答系统——用户提问，AI 检索知识库后回答。用 Atelier 库模式实现，代码量很少。

### 架构

```
┌──────────────────────────────────────────┐
│              你的 HTTP 服务               │
│  ┌─────────┐   ┌────────────────────┐    │
│  │ 路由/处理 │   │  KnowledgeSearchTool │   │
│  └────┬────┘   └─────────┬──────────┘    │
│       │                  │               │
│  ┌────▼──────────────────▼──────────┐    │
│  │        AgentRuntime (全局单例)      │    │
│  │  chat(messages) → EventStream     │    │
│  └───────────────┬──────────────────┘    │
│                  │                       │
│  ┌───────────────▼──────────────────┐    │
│  │        SessionStore (bstorm)      │    │
│  │  save/load/list/delete           │    │
│  └──────────────────────────────────┘    │
└──────────────────────────────────────────┘
```

### 步骤

**1. 编写知识检索工具**

```cangjie
import atelier.tool.*
import jsonvalue.*

class KnowledgeSearchTool <: Tool {
    public func name(): String { "wiki_search" }
    public func description(): String { "搜索知识库，返回相关文档片段" }
    public func schema(): JsonValue {
        SchemaBuilder()
            .addString("query", "搜索关键词", required: true)
            .build()
    }
    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        let query = match (args["query"]) {
            case Some(JsonValue.String(s)) => s
            case _ => return ToolResult("", None, true, false)
        }
        // 调用你的搜索引擎/向量数据库
        let results = searchKnowledgeBase(query)
        ToolResult(results, None, false, false)
    }
    public func executionMode(): ToolExecutionMode { ToolExecutionMode.Parallel }
}
```

**2. 配置 Agent**

```cangjie
let config = AgentConfig(
    name: "wiki-assistant",
    description: Some("知识库问答助手"),
    systemPrompt: "你是一个知识库助手。用 wiki_search 查询后回答，注明来源。",
    model: "deepseek-chat",
    tools: ArrayList<String>(["wiki_search"]),
    ...AgentConfig.default() 中的其他字段
)
```

**3. 初始化全局组件**

```cangjie
// 全局初始化一次
let toolReg = ToolRegistry()
toolReg.register(KnowledgeSearchTool())

let providerReg = ProviderRegistry()
providerReg.register("default", OpenAIProvider("default", "https://api.deepseek.com", apiKey))

// 装配束可全局共享（组件是引用，运行时不改它们）
let spec = HarnessSpec.default()
    .withProvider("default", OpenAIProvider("default", "https://api.deepseek.com", apiKey))
    .withStore(StormSessionStore("/data/wiki/sessions"))

let runtime = AgentRuntime(spec, config)
```

**4. 处理用户请求**

```cangjie
// HTTP 路由处理函数
func handleChat(ctx: HttpContext): Unit {
    let body = readBody(ctx)
    let req = fromJsonString<ChatRequestDTO>(body)

    // 加载或创建会话
    let sessionId = req.sessionId
    if (!sessionStore.has(sessionId)) {
        let header = SessionHeader(1, sessionId, 0, 0, "deepseek-chat", "default", "你是一个知识库助手", None)
        sessionStore.save(sessionId, header, ArrayList())
    }

    // 追加用户消息
    let msgs = sessionStore.load(sessionId)
    msgs.add(UserMessage(ContentList.ofText(req.messages[0].content), 0))

    // 执行
    let stream = runtime.chat(msgs)
    let result = stream.result()

    // 持久化
    sessionStore.save(sessionId, header, result)

    // 返回最后一条回复
    let lastText = lastAssistantText(result)
    jsonResponse(ctx, 200, toJsonString(ContentResponse(lastText)))
}
```

**5. 会话管理**

```cangjie
// 列表
func handleSessions(ctx: HttpContext): Unit {
    let sessions = sessionStore.list()
    jsonResponse(ctx, 200, toJsonString(SessionListResponse(sessions)))
}

// 删除
func handleDelete(ctx: HttpContext): Unit {
    sessionStore.delete(req.sessionId)
    jsonResponse(ctx, 200, toJsonString(StatusResponse("deleted")))
}
```

### 扩展方向

| 能力 | 实现方式 |
|------|----------|
| 多知识库 | 注册多个工具，如 `wiki_search_tech`、`wiki_search_product` |
| 权限控制 | `TrustManager` 按目录隔离知识域 |
| 上下文增强 | `SessionEnvironment.context` 传入用户/页面信息 |
| 流式输出 | 用 `runtime.chat(messages)` 的 `EventStream` 逐 token SSE 推送 |
| 多轮记忆 | `SessionStore` 自动持久化 |

## 库模式 API 参考

`AgentRuntime` 是**无状态**的——它不持有会话数据，每次 `chat()` 从入参 `messages` 读取历史：

```cangjie
// 全局一个 runtime 实例（装配束 + 该 agent 的配置）
let runtime = AgentRuntime(spec, config)

// 用户 A 的会话
let msgsA = sessionStore.load("session_a")
msgsA.add(UserMessage(ContentList.ofText("你好"), 0))
let newA = runtime.chat(msgsA).result()
sessionStore.save("session_a", header, newA)

// 用户 B 的会话，同一 runtime，完全隔离
let msgsB = sessionStore.load("session_b")
msgsB.add(UserMessage(ContentList.ofText("查订单"), 0))
let newB = runtime.chat(msgsB).result()
sessionStore.save("session_b", header, newB)
```

- **不缓存 runtime**：每次 `chat()` 新建或复用均可，构造开销只有 O(1)
- **不存 Map<sessionId, runtime>**：runtime 无状态，不需要按会话缓存
- **会话在 store 里**：`SessionStore` 负责持久化，库集成方只需 `load → append → chat → save`

### 订阅事件

EventStream 让你在获取结果的同时消费中间事件：

```cangjie
let stream = runtime.chat(msgs)

// 在后台线程消费事件
spawn {
    for (event in stream) {
        match (event) {
            case s: TurnStartEvent => println(">>> 推理开始")
            case u: MessageUpdateEvent => print(u.delta)
            case s: ToolExecutionStartEvent =>
                println(">>> 调用工具: ${s.toolName}")
            case e: ToolExecutionEndEvent =>
                println(">>> 工具结果: ${e.result}")
            // 压缩是一次"改写历史"的事务：这段括弧里可以显示进度（大上下文压缩要几十秒）
            case c: CompactionStartEvent => println(">>> 压缩上下文: ${c.trigger}")
            case c: CompactionEndEvent =>
                println(">>> 压缩完成: ${c.messagesBefore} -> ${c.messagesAfter} 条")
            case _: AgentEndEvent => println(">>> 完成")
            case _ => ()
        }
    }
}

// 在主线程等待最终结果
let messages = stream.result()
```

宿主也可以**手动触发**一次压缩（对应 TUI 的 `/compact`）：`runtime.compactNow(sessionId, messages, env)`
返回 `CompactionReport`（新历史 + 覆盖量 + 未压成的原因）；它绕过阈值，但走同一条管线、
同一个会话级互斥与同一份台账。压缩会改写历史，落库要**整份重写**（`store.save`），
不能追加——追加会让检查点与旧头部叠在一起。

每次压缩还会往 `SessionStore` 的台账里写一开一合两条记录（`appendCompaction` / `loadCompactions`，
接口有默认空实现）：`interruptedCompactions(records)` 能捞出有开无合的**中断残留**（进程在压缩中途
没了）。它只是提示，**不当锁用**——残留会一直在，当锁会让会话永远压不动。

压缩事件（`CompactionStartEvent` / `CompactionEndEvent`）以同一个 `compactionId` 成对出现，
中途放弃时也会闭合（`messagesAfter == messagesBefore` 表示"尝试过但没替换"），所以消费端
不会看到悬挂的事务。同一会话同时只允许一次压缩：另一次进来的压缩会**跳过**并留一条警告
（并发压缩各自基于同一份旧历史，后写的会覆盖先写的）。

### 自定义钩子

实现 `Hook` 接口可介入 Agent 生命周期。钩子是**决策型拦截器**——6 个相位（beforeRun/afterRun/beforeTurn/afterTurn/beforeTool/afterTool）可观察、改写或短路运行流程：

```cangjie
import atelier.agent.*

class AuditHook <: Hook {
    public override func beforeTool(ctx: HookContext, call: ToolCallBlock): BeforeToolDecision {
        println(">>> 调用工具: ${call.name}")
        BeforeToolDecision.Allow
    }
}

// 钩子挂在装配束上（可多个：withHook 追加）
let spec = HarnessSpec.default().withHook(AuditHook())
let runtime = AgentRuntime(spec, config)
```

所有钩子都有空默认实现，只需覆写需要的。完整的决策类型、状态共享、融合顺序与最佳实践见 **[Hook 文档](hooks.md)**。

### 注入依赖：装配束（HarnessSpec）

组件一次装配，运行时只收两个参数：装配束 + agent 配置。

```cangjie
let spec = HarnessSpec.default()
    .withProvider("default", myProvider)      // 换模型服务
    .withStore(myStore)                       // 换会话存储
    .withTool(myTool)                         // 加/换工具（同名覆盖）
    .withToolsView(clientTools)               // 只影响本次 run 的工具叠加视图
    .withSkills(mySkillRegistry)
    .withAgents(myAgentRegistry)
    .withMcp(myMcpManager)
    .withHook(AuditHook())
    .withAsk(askFn)                           // (UserRequest) -> UserAnswer
    .withModelContext("deepseek", "deepseek-chat", 65536) // 端点上的模型窗口
    .withMiddlewares(middlewares)
    .withEventBus(bus)

let runtime = AgentRuntime(spec, cfg)
```

| 组件 | 类型 | 换法 |
|------|------|------|
| 工具表 | `ToolRegistry` | `withTool` / `withToolsView`（run 作用域派生视图）/ `withToolRegistry` |
| Provider | `Provider` | `withProvider(name, p)`（叠加表，不动宿主共享的注册表） |
| 会话存储 | `SessionStore` | `withStore` |
| 信任闸门 | `TrustManager` | `withTrust` |
| Skill 注册表 | `SkillRegistry` | `withSkills` |
| Agent 注册表 | `AgentRegistry` | `withAgents` |
| MCP 连接 | `McpManager` | `withMcp` |
| 钩子 | `ArrayList<Hook>` | `withHook` / `withHooks` |
| 提问通道 | `Option<AskFn>` | `withAsk`（审批/选择/表单） |
| 模型窗口表 | `ModelContextRegistry` | `withModelContext(provider, model, n)`（端点层）/ `withModelContextByName` / `withModels` / `withDefaultContextWindow` |
| 请求级中间件 | `ArrayList<ProviderMiddleware>` | `withMiddlewares` |
| 系统提示段 | `ArrayList<PromptSegmentContributor>` | `withContributors` |
| 事件总线 | `EventBus` | `withEventBus` |

`AgentConfig` 里的 `provider` 决定用哪个 provider（缺省 `"default"`）；装配束里找不到会**明确报错**，
不会静默退化成某个默认端点。上下文窗口按 `(provider, model)` 查（见 docs/providers.md「上下文窗口」）。

------|------|------|
| `config` | `AgentConfig` | Agent 身份、模型、参数 |
| `provider` | `Provider` | LLM 服务适配器 |
| `toolRegistry` | `ToolRegistry` | 工具注册表 |
| `sessionStore` | `SessionStore` | 会话持久化 |
| `trustManager` | `TrustManager` | 信任闸门 |
| `skillRegistry` | `SkillRegistry` | Skill 注册表 |
| `agentRegistry` | `AgentRegistry` | 子 Agent 注册 |
| `providerRegistry` | `ProviderRegistry` | Provider 注册表 |
| `hooks` | `ArrayList<Hook>` | 生命周期钩子（可选），见下方示例 |
| `askFn` | `Option<AskFn>` | 提问通道：`(UserRequest) -> UserAnswer`（审批/选择/表单）。不传 = 无交互通道，提问按取消处理 |

---

## A2A 服务端形态

除库 / HTTP 挂载 / 独立服务 / CLI / Docker 之外，还可用 A2A 协议对外：

```bash
atelier a2a default 8931        # 独立端口，作为 A2A v1 Agent 提供服务
```

或挂进既有 HTTP 服务共用端口：

```toml
[a2a]
mountToServer = true
```

```bash
atelier serve 8080              # 同一端口同时提供 agent API 与 A2A
```

能力矩阵、认证与 LB 部署（TLS 终止、SSE 缓冲）见《[A2A 接入](a2a.md)》。

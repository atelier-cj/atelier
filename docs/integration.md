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
    // 准备工具
    let toolReg = ToolRegistry()
    toolReg.register(ReadFileTool())
    toolReg.register(BashTool())

    // 创建 Provider
    let providerReg = ProviderRegistry()
    providerReg.register("default",
        OpenAIProvider("default",
            "https://api.openai.com/v1",
            getApiKey()))

    let sessionStore = MemorySessionStore()
    let trustMgr = TrustManager()
    let skillReg = SkillRegistry()
    let agentReg = AgentRegistry()

    // 定义 Agent
    let config = AgentConfig.default()
    let provider = providerReg.get("default").getOrThrow()

    // 创建运行时
    let runtime = AgentRuntime(config, provider,
        toolReg, sessionStore, trustMgr, skillReg,
        agentReg, providerReg)

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
| POST | `/agent/input` | ask_user 交互输入 |
| POST | `/session/save` | 保存会话 |
| POST | `/session/load` | 加载会话 |
| POST | `/session/fork` | 克隆会话 |
| POST | `/session/export` | 导出会话（JSONL/HTML） |
| GET | `/sessions` | 会话列表 |
| POST | `/trust` | 信任管理 |
| POST | `/v1/chat/completions` | OpenAI 兼容 API |
| GET | `/health` | 健康检查 |

---

## 场景三：独立 HTTP 服务

一行命令启动，适合快速部署。

```bash
# 使用默认端口 8080
atelier serve

# 指定端口
atelier serve 9000

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

### REPL 交互

```bash
# 启动 REPL（默认 agent）
atelier repl

# 指定 agent
atelier repl my-assistant

# 恢复之前会话
atelier repl my-assistant sess_abc123
```

REPL 内支持斜杠命令：

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
atelier run "分析这个日志文件"

# 指定 agent
atelier run code-assistant "给这个函数加注释"
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

let sessionStore = StormSessionStore("/data/wiki/sessions")
let trustMgr = TrustManager()
let skillReg = SkillRegistry()
let agentReg = AgentRegistry()

// AgentRuntime 可全局共享
let runtime = AgentRuntime(config, provider, toolReg, sessionStore, trustMgr, skillReg, agentReg, providerReg)
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
// 全局一个 runtime 实例
let runtime = AgentRuntime(config, provider, toolReg, sessionStore, ...)

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
            case _: AgentEndEvent => println(">>> 完成")
            case _ => ()
        }
    }
}

// 在主线程等待最终结果
let messages = stream.result()
```

### 自定义钩子

实现 `Hook` 接口可介入 Agent 生命周期。钩子是**决策型拦截器**——保留 6 个相位，每个相位可返回决策影响运行流程：

```cangjie
import atelier.agent.*

// 观察型：记录工具调用
class AuditHook <: Hook {
    public override func beforeTool(ctx: HookContext, call: ToolCallBlock): BeforeToolDecision {
        println(">>> 调用工具: ${call.name}")
        BeforeToolDecision.Allow
    }
    public override func afterTool(ctx: HookContext, call: ToolCallBlock, result: ToolResultMessage): Unit {
        println(">>> 工具结果: ${result.content.blocks().size} 块")
    }
}

// 拦截型：阻止敏感工具
class GuardHook <: Hook {
    public override func beforeTool(ctx: HookContext, call: ToolCallBlock): BeforeToolDecision {
        if (call.name == "bash") {
            BeforeToolDecision.Deny("bash 工具被策略禁止")
        } else {
            BeforeToolDecision.Allow
        }
    }
}

let hooks = ArrayList<Hook>([AuditHook(), GuardHook()])
let runtime = AgentRuntime(config, provider, toolReg,
    sessionStore, trustMgr, skillReg, agentReg, providerReg,
    hooks, askUserFn)
```

6 个钩子按执行顺序：

| 钩子 | 触发时机 | 决策 |
|------|----------|------|
| `beforeRun` | Run 开始后，第一轮 Turn 前 | 观察 |
| `afterRun` | Run 结束时 | 观察 |
| `beforeTurn` | 每轮推理开始前 | `TurnDecision.Continue`（可改写请求）`/ ShortCircuit` |
| `afterTurn` | 每轮推理结束后 | `AfterTurnUpdate`（可改写上下文 `/` 短路） |
| `beforeTool` | 工具执行前 | `Allow` `/` `Deny` `/` `Modify` |
| `afterTool` | 工具执行后 | 观察 |

所有钩子都有空默认实现，只需覆写需要的。`HookContext.state` 在每次 run 内共享，可跨相位传递数据（如成本累计、token 统计）。

### 注入依赖

AgentRuntime 的构造参数即依赖注入点：

| 参数 | 类型 | 说明 |
|------|------|------|
| `config` | `AgentConfig` | Agent 身份、模型、参数 |
| `provider` | `Provider` | LLM 服务适配器 |
| `toolRegistry` | `ToolRegistry` | 工具注册表 |
| `sessionStore` | `SessionStore` | 会话持久化 |
| `trustManager` | `TrustManager` | 信任闸门 |
| `skillRegistry` | `SkillRegistry` | Skill 注册表 |
| `agentRegistry` | `AgentRegistry` | 子 Agent 注册 |
| `providerRegistry` | `ProviderRegistry` | Provider 注册表 |
| `hooks` | `ArrayList<Hook>` | 生命周期钩子（可选），见下方示例 |
| `askUser` | `AskUserFn` | 用户交互回调（可选），默认返回空字符串 |

---
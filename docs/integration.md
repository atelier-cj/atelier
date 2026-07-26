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
| `hooks` | `ArrayList<Hook>` | 生命周期钩子（可选） |
| `askUser` | `AskUserFn` | 用户交互回调（可选） |

---

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

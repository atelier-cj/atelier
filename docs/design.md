# Atelier - Agent 运行时设计文档

> 一个面向业务集成的、开箱即用的 Agent 运行时

---

## 一、项目定位

### 1.1 一句话定义

**Atelier** 是一个**开箱即用、可组合的 Agent 运行时**——开发者只需挂载业务工具、配置 Skills、选择会话存储方式，即可获得一个完整的、可运行的 Agent 服务，无需从零实现推理循环、上下文管理或模型适配。

### 1.2 与现有框架的区别

| | LangChain / Eino / ADK | Atelier |
| :--- | :--- | :--- |
| **定位** | 编排框架（积木盒） | Agent 运行时（成品工坊） |
| **开发者要做的事** | 组装链条、实现循环、管理状态 | 挂载工具、配置 Skills、选择存储 |
| **交付形态** | 库，需二次开发 | 库 + HTTP 服务 + CLI，开箱即用 |
| **Agent 定义** | 代码中构建 | 运行时动态创建（JSON/YAML 配置） |
| **目标用户** | 框架开发者、高级工程师 | 业务工程师、AI 应用集成者 |

### 1.3 典型应用场景

- **智能客服 / LLM Wiki**：挂载企业知识库检索工具 + 对话记忆
- **数据助手**：挂载 SQL 执行器 + 数据分析工具 + 可视化生成
- **业务自动化**：挂载内部 API 工具 + 审批流程 Skills
- **研发提效**：挂载代码读写 + 测试执行 + 文档生成工具

---

## 二、核心概念

### 2.1 Agent —— 智能体实例

一个 Agent 是**运行时实体**，由 `AgentConfig` 定义，包含：

- 身份（名称/描述）
- 指令（系统提示词）
- 可用工具集
- 关联的模型 Provider
- 对话历史（会话状态）

Agent 可以**动态创建、更新、销毁**，无需重新编译或重启服务。

### 2.2 AgentConfig —— Agent 定义（可序列化）

开发者通过 JSON 或代码定义 Agent 的完整配置：

```json
{
  "name": "数据助手",
  "description": "帮助分析业务数据的智能助手",
  "systemPrompt": "你是一个数据分析专家，善于使用 SQL 和 Python",
  "model": "gpt-4o",
  "tools": ["sql_executor", "python_runner", "chart_renderer"],
  "skills": ["data_cleaning", "outlier_detection"],
  "maxTurns": 10,
  "temperature": 0.3
}
```

### 2.3 Tool —— 工具（函数调用）

实现标准工具接口的可执行单元：

```cangjie
interface Tool {
    name(): String
    description(): String
    schema(): JSON  // JSON Schema 定义参数
    execute(ctx: Context, args: JSON): ToolResult
}
```

**内置工具**：文件读写、Shell 执行、搜索
**业务工具**：SQL 查询、API 调用、数据处理
**MCP 工具**：通过 mcp-cj 接入的外部 MCP 服务器工具

### 2.4 Skill —— 技能包（声明式能力）

Skill 是按 [AgentSkills 规范](https://agentskills.io/specification) 定义的目录，内含 `SKILL.md` + 可选资源文件：

```
skills/my-skill/
├── SKILL.md           # 必需：YAML frontmatter + Markdown 指令
├── scripts/           # 可选：可执行脚本
├── references/        # 可选：补充文档
└── assets/            # 可选：模板/图片/数据文件
```

`SKILL.md` 的 frontmatter 包含：

| 字段 | 必需 | 说明 |
| :--- | :--- | :--- |
| `name` | 是 | 唯一标识，全小写+连字符，匹配目录名 |
| `description` | 是 | 描述技能做什么及何时使用 |
| `license` | 否 | 许可证 |
| `compatibility` | 否 | 环境要求 |
| `allowed-tools` | 否 | 预授权工具列表（实验性） |
| `metadata` | 否 | 扩展字段，用于 Atelier 特有配置 |

Atelier 通过 `metadata` 携带自有扩展（推荐工具列表、模型绑定等），不破坏标准兼容性。Skill 本质是**提示词工程化的最佳实践**，可由非开发人员（产品/运营）编写和维护。

### 2.5 Provider —— 模型服务适配器

统一的大模型服务接入层，直接对接 LLM REST API：

- OpenAI 兼容 API（初始实现）
- Anthropic Messages API（后续扩展）
- 本地模型 Ollama（后续扩展）

### 2.6 Message —— 消息模型

消息是 Agent 对话的基本单位，采用**密封接口 + 角色判别**模式，4 种角色：

```cangjie
enum MessageRole {
    User
    Assistant
    ToolResult
    Compaction
}

interface Message {
    func role(): MessageRole
}
```

**UserMessage** —— 用户输入：

```cangjie
class UserMessage <: Message {
    func role(): MessageRole { MessageRole.User }
    content: ContentList
    timestamp: Int64
}
```

**AssistantMessage** —— 模型回复，承载可观测信息与工具调用：

```cangjie
class AssistantMessage <: Message {
    func role(): MessageRole { MessageRole.Assistant }
    content: ContentList
    model: String
    provider: String
    stopReason: StopReason       // end_turn | tool_use | length | error
    usage: TokenUsage
    timestamp: Int64
    func toolCalls(): List<ToolCallContent>  // 从 content 中筛选工具调用
}
```

**ToolResultMessage** —— 工具执行结果：

```cangjie
class ToolResultMessage <: Message {
    func role(): MessageRole { MessageRole.ToolResult }
    toolCallId: String
    toolName: String
    content: ContentList
    isError: Bool
    timestamp: Int64
}
```

**CompactionMessage** —— 上下文压缩摘要检查点：

```cangjie
class CompactionMessage <: Message {
    func role(): MessageRole { MessageRole.Compaction }
    summary: String
    tokensBefore: Int64
    timestamp: Int64
}
```

消息的 `content` 是 `ContentList`，由多个 `ContentBlock` 组成，支持多模态：

```cangjie
enum ContentBlock {
    TextBlock(text: String)
    ToolCallBlock(id: String, name: String, args: JsonValue)
    ToolResultBlock(toolCallId: String, result: String)
    ImageBlock(data: String, mimeType: String)       // 后续扩展
}
```

### 2.7 Session —— 会话

会话是一次对话上下文的**持久化记录**。采用**树形数据模型**，支持分叉与历史回溯。

**文件格式**：JSONL，首行 `SessionHeader`，后续每行一个 `Entry`。

```cangjie
struct SessionHeader {
    version: Int32                          // 格式版本，当前为 1
    id: String                              // 会话唯一标识
    createdAt: Int64
    updatedAt: Int64
    model: String
    provider: String
    systemPrompt: String
    parentSession: Option<String>           // 分叉来源会话 ID
}

struct Entry {
    id: String                              // entry 唯一标识（随机 8 字符）
    parentId: Option<String>                // 上一条 entry ID，形成树结构
    timestamp: Int64
    message: Message
}
```

Entry 的 `parentId` 将消息织成一棵树——线性会话就是每条 entry 的 parentId 都指向前一条的特例，根节点 parentId 为空。

**核心操作**：`PathToLeaf(entries, leafId)` 从叶子沿 parentId 上溯到根，重建线性对话。

### 2.8 Event —— 运行时事件

Agent 运行过程中发出的流式事件，采用**密封接口 + 判别字符串**模式：

```cangjie
interface AgentEvent {
    func eventType(): String
}
```

**11 种事件**，按层级嵌套组织：

```
Agent (start / end)
  └── Turn (start / end)
       ├── Message (start / update / end)
       └── ToolExecution (start / update / end)
Compaction (独立事件)
```

**事件层级**：一次 `Run` 由 `AgentStart`/`AgentEnd` 包住，中间是若干 `Turn`（`TurnStart`/`TurnEnd`），每个 Turn 里有一条流式消息（`MessageStart` → 若干 `MessageUpdate` → `MessageEnd`）和随后的工具执行（`ToolExecutionStart` → `ToolExecutionUpdate` → `ToolExecutionEnd`）。`Compaction` 在上下文压缩发生时独立发出。

| 事件 | 携带数据 | 说明 |
| :--- | :--- | :--- |
| `AgentStartEvent` | `sessionId` | Run 开始，在任何网络请求前发出 |
| `AgentEndEvent` | `messages` | Run 结束，捎带本轮新产消息 |
| `TurnStartEvent` | — | 新推理轮次开始 |
| `TurnEndEvent` | `message`, `toolResults` | 轮次结束，带助手消息与工具结果 |
| `MessageStartEvent` | `message` | 流式消息开始 |
| `MessageUpdateEvent` | `message`, `delta` | 流式增量，带底层 Provider 原始事件 |
| `MessageEndEvent` | `message` | 流式消息完成 |
| `ToolExecutionStartEvent` | `toolCallId`, `toolName` | 工具开始执行 |
| `ToolExecutionUpdateEvent` | `toolCallId`, `progress` | 工具执行进度 |
| `ToolExecutionEndEvent` | `toolCallId`, `result`, `isError` | 工具执行完成 |
| `CompactionEvent` | `reason`, `tokensBefore`, `tokensAfter` | 上下文压缩已发生 |

**EventStream 泛型**：事件通过 `EventStream<T, R>` 传递，T 是事件类型，R 是流终结时的结果：

```cangjie
class EventStream<T, R> {
    // IsComplete 判断某事件是否为终止事件
    // ExtractResult 从终止事件提取结果 R
    func emit(event: T): Result<Unit>
    func result(): R          // 独立于事件通道，可跳过中间事件
}
```

`LoopEventStream = EventStream<AgentEvent, List<Message>>`——流上跑 AgentEvent，终结时给出本次 Run 新产的消息列表。

**设计要点**：
- 结果与事件通道分离：消费者可忽略中间事件直接取最终结果
- Emit 监听取消信号，消费者被取消时生产者不泄漏
- 结果用 Once 语义：SetResult / SetError / Close 三者竞争，先到先赢

---

## 三、设计原则

### 3.1 开箱即用

- 零配置即可启动一个可对话的基础 Agent
- 提供合理的默认值（模型、工具、存储）
- 内置常用工具集，覆盖 80% 场景

### 3.2 动态可配

- Agent 定义在运行时创建，不依赖编译
- 支持热更新（添加/修改/删除 Agent）
- 配置可序列化、可导入导出

### 3.3 可组合

- 工具、Skills、Provider、存储均为可插拔接口
- 不同 Agent 可复用同一套工具/Skill 定义
- 支持多 Agent 协同（后续扩展，生态已有：<https://atomgit.com/ystyle/jisi-pavilion>）

### 3.4 可嵌入

- **库形态**：`import atelier`，在应用内直接调用 Agent Runtime
- **挂载形态**：`atelier.registerRoutes(server.distributor)`，将 Atelier 路由挂载到既有 HTTP 服务上，不占独立端口
- **服务形态**：`atelier serve --port 8080`，一键启动独立 HTTP 服务
- **CLI 形态**：命令行交互（后期完善）

### 3.5 安全优先

- 工具执行前过信任闸门（目录级/会话级）
- 密钥不出边界（不日志、不事件、不序列化）
- 支持敏感操作确认（交互式）

### 3.6 自研优先

- 核心运行时（Agent Loop、事件流、上下文压缩）全部自研
- Tool 接口与内置工具自研，MCP 工具通过 `ystyle::mcp` 接入
- Provider 层直接对接 LLM REST API，不引入额外抽象层
- 外部依赖最小化，`mcp-cj` 为 MCP 协议层依赖，`bstorm` 为会话存储后端

---

## 四、运行时架构

### 4.1 核心循环（Agent Loop）

```
┌─────────────────────────────────────────────────────────────────┐
│                        Agent Runtime                           │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │                    Outer Loop (Run)                        │ │
│  │  ┌──────────────────────────────────────────────────────┐  │ │
│  │  │               Inner Loop (Turn)                      │  │ │
│  │  │  ┌────────────────────────────────────────────────┐  │  │ │
│  │  │  │  1. Build Request (System + Messages + Tools)  │  │  │ │
│  │  │  │  2. Stream from Provider                       │  │  │ │
│  │  │  │  3. Collect Assistant Response                 │  │  │ │
│  │  │  └────────────────────────────────────────────────┘  │  │ │
│  │  │  ┌────────────────────────────────────────────────┐  │  │ │
│  │  │  │  4. Check Stop Reason                          │  │  │ │
│  │  │  │     ├─ end_turn → exit inner loop              │  │  │ │
│  │  │  │     ├─ tool_use → execute tools                │  │  │ │
│  │  │  │     ├─ length → retry with shorter request     │  │  │ │
│  │  │  │     └─ error/aborted → terminate run           │  │  │ │
│  │  │  └────────────────────────────────────────────────┘  │  │ │
│  │  │  ┌────────────────────────────────────────────────┐  │  │ │
│  │  │  │  5. Execute Tool Calls (batch)                 │  │  │ │
│  │  │  │     ├─ serial (sequential tools)               │  │  │ │
│  │  │  │     └─ parallel (stateless tools)              │  │  │ │
│  │  │  └────────────────────────────────────────────────┘  │  │ │
│  │  │  ┌────────────────────────────────────────────────┐  │  │ │
│  │  │  │  6. Append Tool Results to Context             │  │  │ │
│  │  │  │  7. Compaction Check (if enabled)              │  │  │ │
│  │  │  └────────────────────────────────────────────────┘  │  │ │
│  │  └──────────────────────────────────────────────────────┘  │ │
│  │  ┌──────────────────────────────────────────────────────┐  │ │
│  │  │  8. Check Follow-up Messages (steering)             │  │ │
│  │  └──────────────────────────────────────────────────────┘  │ │
│  └────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

### 4.2 事件流（Event Stream）

Runtime 与调用方之间通过**事件流**通信：

- 事件是类型化的、流式的
- 支持 SSE（HTTP）、Channel（库模式）、JSON Lines（CLI）
- 消费者可订阅全部或部分事件类型

### 4.3 上下文压缩（Compaction）

长对话自动压缩：

- 检测 Token 用量（优先使用 Provider 报告的用量）
- 越过阈值时触发
- 选择压缩切点（不拆散 ToolCall ↔ ToolResult）
- 调用模型生成结构化摘要
- 摘要作为 Compaction 消息保留在上下文中

### 4.4 MCP 工具集成

MCP 工具通过 `mcp-cj` 的 `McpClient` 接入：

```
Agent Runtime
     │
     ▼
Tool Executor ──► MCPToolWrapper ──► mcp-cj McpClient ──► MCP Server (stdio/SSE/HTTP)
```

- `MCPToolWrapper` 实现 `Tool` 接口，适配 mcp-cj 的 `McpClient`
- 支持 stdio、SSE、Streamable HTTP 三种传输
- 工具列表在连接时通过 `tools/list` 获取，缓存在本地注册表

---

## 五、使用形态

### 5.1 库模式（Embedded）

```cangjie
import atelier.*

// 1. 创建消息
let messages = [
    UserMessage { content: ContentList.ofText("我的订单还没发货，帮我查一下") }
]

// 2. 创建 Agent 配置
let config = AgentConfig {
    name: "客服助手",
    systemPrompt: "你是公司产品的客服，回答用户问题",
    tools: [KnowledgeSearchTool(), TicketCreateTool()],
    model: "gpt-4o"
}

// 3. 创建 Runtime 并运行
let runtime = AgentRuntime.new(config)
let stream = runtime.chat(messages)

// 4. 消费事件流
for event in stream {
    match event {
        is MessageChunk -> print(event.delta)
        is ToolCallStart -> print("调用工具: ${event.toolName}")
        is RunEnd -> print("完成")
    }
}
```

### 5.2 HTTP 服务模式（Phase 2）

HTTP 服务支持两种启动方式：

**方式一：独立服务**——一键启动，自带 HTTP Server：

```bash
atelier serve --port 8080
```

**方式二：挂载模式**——通过 `registerRoutes` 接入既有 HTTP 服务，不占端口：

```cangjie
import atelier.*
import stdx.net.http.*

// 创建既有 HTTP 服务
let server = ServerBuilder()
    .addr("0.0.0.0")
    .port(8080)
    .build()

// 将 Atelier 路由挂载到 server 上
let atelier = AtelierHttpHandler.new(...)
atelier.registerRoutes(server.distributor)

// 还可挂载其他路由（如健康检查、管理端等）
server.distributor.register("/health", { ctx => ... })
server.serve()
```

**核心 API**：

| 方法 | 路径 | 描述 |
| :--- | :--- | :--- |
| `POST` | `/v1/chat/completions` | 兼容 OpenAI Chat API |
| `POST` | `/agent/run` | 运行 Agent（自有格式） |
| `GET` | `/agent/stream` | SSE 流式交互 |
| `POST` | `/agent/config` | 动态创建 Agent 配置 |
| `GET` | `/agent/configs` | 列出所有 Agent 配置 |
| `DELETE` | `/agent/config/{name}` | 删除 Agent 配置 |
| `POST` | `/session/save` | 保存会话 |
| `GET` | `/session/{id}` | 加载会话 |

**请求示例**：

```bash
curl -X POST http://localhost:8080/agent/run \
  -H "Content-Type: application/json" \
  -d '{
    "agent": "data-assistant",
    "messages": [{"role": "user", "content": "分析上个月的销售趋势"}],
    "stream": true
  }'
```

### 5.3 CLI 模式（Phase 3）

```bash
# 单次对话
atelier run -a data-assistant "分析上个月销售"

# 交互式 REPL
atelier repl -a data-assistant

# 列表 Agent
atelier agent list

# 动态创建 Agent
atelier agent create --from config.yaml
```

---

## 六、模块架构

### 6.1 目录结构

```text
atelier/
├── src/
│   ├── message/
│   │   ├── message.cj        # Message 密封接口 + 4 种角色实现
│   │   ├── content.cj        # ContentBlock 枚举 + ContentList
│   │   └── role.cj           # MessageRole / StopReason 枚举
│   │
│   ├── agent/
│   │   ├── config.cj         # AgentConfig 定义
│   │   ├── runtime.cj        # AgentRuntime 核心循环
│   │   ├── event.cj          # 事件类型定义
│   │   └── registry.cj       # Agent 配置注册表（动态管理）
│   │
│   ├── tool/
│   │   ├── interface.cj      # Tool 接口
│   │   ├── registry.cj       # 工具注册表
│   │   ├── builtin/
│   │   │   ├── read_file.cj  # 读文件（分页/行号/截断）
│   │   │   ├── write_file.cj # 写文件（覆盖检测）
│   │   │   ├── edit_file.cj  # 编辑文件（精确替换/唯一性检查）
│   │   │   ├── bash.cj       # Shell 执行（流式/超时/取消）
│   │   │   ├── grep.cj       # 内容搜索
│   │   │   ├── glob.cj       # 文件模式匹配
│   │   │   └── todo.cj       # 待办管理（唯一有状态工具）
│   │   ├── mcp_tool.cj       # MCP 工具适配器（通过 mcp-cj）
│   │   └── executor.cj       # 批量工具执行器（串行/并行）
│   │
│   ├── skill/
│   │   ├── interface.cj      # Skill 接口
│   │   ├── loader.cj         # 从 SKILL.md 目录加载（对齐 AgentSkills 规范）
│   │   ├── registry.cj       # Skill 注册表
│   │   └── validator.cj      # SKILL.md 格式校验（name/目录 一致性检查）
│   │
│   ├── provider/
│   │   ├── interface.cj      # Provider 接口
│   │   ├── registry.cj       # Provider 注册表
│   │   ├── openai.cj         # OpenAI 兼容 API（直接 REST）
│   │   ├── anthropic.cj      # Anthropic 适配（后续扩展）
│   │   ├── ollama.cj         # 本地 Ollama（后续扩展）
│   │   └── transport.cj      # HTTP + SSE 传输层
│   │
│   ├── session/
│   │   ├── store.cj          # SessionStore 接口
│   │   ├── memory_store.cj   # 内存存储（默认）
│   │   ├── file_store.cj     # 文件存储（JSONL，tmp+rename 原子写入）
│   │   └── session.cj        # SessionHeader / Entry / PathToLeaf
│   │
│   ├── context/
│   │   ├── builder.cj               # L2 上下文构建器（系统提示 + 消息组装 + ChatRequest）
│   │   ├── system_prompt_builder.cj # 系统提示分段构建（固定前缀 + 动态后缀）
│   │   ├── compaction.cj            # 上下文压缩
│   │   ├── tokens.cj                # Token 估算
│   │   └── cutpoint.cj              # 压缩切点选择
│   │
│   ├── trust/
│   │   ├── manager.cj        # 信任状态管理
│   │   └── gate.cj           # 工具执行前闸门
│   │
│   ├── server/
│   │   ├── handler.cj        # AtelierHttpHandler（registerRoutes 挂载）
│   │   ├── dto.cj            # 请求/响应 DTO
│   │   └── middleware.cj     # 鉴权/日志/限流
│   │
│   └── cli/
│       └── main.cj           # CLI 入口
│
├── examples/
│   ├── data_analyst/         # 数据分析示例
│   ├── customer_service/     # 客服示例
│   └── code_assistant/       # 代码助手示例
│
└── tests/
    ├── unit/
    └── integration/
```

### 6.2 模块依赖关系

```text
           ┌─────────┐
           │  cli    │  ← 入口层（Phase 3）
           └────┬────┘
                │
           ┌────┴────┐
           │ server  │  ← HTTP 服务层（Phase 2）
           └────┬────┘
                │
           ┌────┴────┐
           │ runtime │  ← 运行编排层
           └────┬────┘
                │
     ┌──────────┼──────────┐
     │          │          │
┌────┴────┐ ┌──┴──┐ ┌────┴────┐
│ agent   │ │tool │ │provider │  ← 核心领域层
└─────────┘ └─────┘ └─────────┘
     │          │          │
     └──────────┼──────────┘
                │
           ┌────┴────┐
           │ session │  ← 存储抽象层
           └─────────┘

                │
           ┌────┴────┐
           │ mcp-cj  │  ← 外部依赖（MCP 协议层）
           └─────────┘
```

**依赖原则**：

- 上层可依赖下层，下层不可依赖上层
- `core` 层（`agent`/`tool`/`provider`/`session`）不依赖 `server`/`cli`
- `runtime` 依赖所有核心层，是唯一的"编排点"
- 同层模块之间可通过接口松耦合
- 外部依赖限 `mcp-cj`（MCP 协议）和 `bstorm`（会话持久化）
- `message` 层（消息模型）不依赖任何外部包

### 6.3 外部依赖策略

| 依赖 | 类型 | 用途 |
| :--- | :--- | :--- |
| `ystyle::mcp` | 外部 | MCP 协议层（工具发现/调用/传输） |
| `bstorm` | 外部 | 默认会话存储后端（嵌入式 JSON 文档库） |
| 仓颉 stdx | 标准库 | JSON 解析、HTTP 客户端、加密等 |

其余全部自研：

- **Provider**：直接对接 OpenAI REST API，不通过 MCP 代理 LLM
- **Tool 接口与内置工具**：全部自研，MCP 工具通过 `MCPToolWrapper` 适配
- **Agent Runtime**：核心循环、事件流、上下文压缩全部自研
- **Session 接口与内存实现**：自研；默认持久化后端通过 `bstorm` 实现
- **Trust/Config**：自研

---

## 七、配置管理

### 7.1 Agent 配置（可序列化）

```cangjie
struct AgentConfig {
    // 身份信息
    name: String
    description: Option<String>
    
    // 指令
    systemPrompt: String
    userPromptTemplate: Option<String>  // 可选模板
    
    // 模型
    model: String                       // 如 "gpt-4o"
    provider: Option<String>            // 可选，默认根据 model 推断
    
    // 工具与技能
    tools: List<String>                 // 工具名称列表
    skills: List<String>                // Skill 名称列表
    
    // 运行时参数
    maxTurns: UInt32                    // 最大轮次，默认 20
    temperature: Float32                // 生成温度，默认 0.7
    maxOutputTokens: UInt32             // 最大输出 Token
    thinkingLevel: Option<String>       // "off" | "low" | "medium" | "high"
    
    // 上下文压缩
    compactionEnabled: Bool             // 默认 true
    compactionReserveTokens: UInt32     // 保留缓冲，默认 16384
    keepRecentTokens: UInt32            // 保留最近 Token 数，默认 20000
    
    // 元数据
    tags: List<String>
    createdBy: Option<String>
    createdAt: Int64
    updatedAt: Int64
}
```

### 7.2 服务配置

```cangjie
struct ServerConfig {
    host: String          // 默认 "0.0.0.0"
    port: UInt16          // 默认 8080
    
    // 存储
    sessionStore: StoreType  // "memory" | "bstorm" 等
    sessionDir: Option<String>
    
    // 安全
    authToken: Option<String>  // API Key 认证
    trustMode: TrustMode       // "strict" | "approve-all" | "ask"
    
    // 日志
    logLevel: LogLevel
    logFormat: LogFormat
    
    // 限流
    rateLimit: Option<RateLimit>
}
```

### 7.3 配置文件示例（YAML）

```yaml
# atelier.yaml
server:
  host: 0.0.0.0
  port: 8080
  trustMode: ask

session:
  store: file
  dir: ./data/sessions

providers:
  - name: openai
    type: openai
    baseURL: https://api.openai.com/v1
    apiKey: ${OPENAI_API_KEY}
  
  - name: ollama
    type: ollama
    baseURL: http://localhost:11434

agents:
  - name: data-assistant
    systemPrompt: |
      你是一个数据分析专家。你可以使用 SQL 查询数据库，
      使用 Python 分析数据，并生成可视化图表。
    model: gpt-4o
    tools:
      - sql_executor
      - python_runner
      - chart_renderer
    skills:
      - data_cleaning
      - outlier_detection
    compactionEnabled: true
```

---

## 八、扩展点（可插拔接口）

### 8.1 Tool 接口

```cangjie
interface Tool {
    name(): String
    description(): String
    schema(): JSON
    execute(ctx: Context, args: JSON): ToolResult
    executionMode(): ToolExecutionMode  // Parallel | Sequential
}

struct ToolResult {
    content: ContentList  // 回填给模型的文本/多模态内容
    details: Option<JSON> // 结构化详情（给 UI/日志）
    isError: Bool
    terminate: Option<Bool> // 是否终止整个 Run
}
```

内置工具初始一次性配齐：

| 工具 | 执行模式 | 信任闸门 | 说明 |
| :--- | :--- | :--- | :--- |
| `read_file` | 并行 | 放行 | 分页、行号、截断 |
| `write_file` | 串行 | 过闸 | 覆盖检测 |
| `edit_file` | 串行 | 过闸 | 精确字符串替换、唯一性检查 |
| `bash` | 串行 | 过闸 | 流式输出、超时、取消 |
| `grep` | 并行 | 放行 | 正则搜索 |
| `glob` | 并行 | 放行 | 文件模式匹配 |
| `todo` | 串行 | 放行 | 待办列表管理（有状态） |

MCP 工具通过 `MCPToolWrapper` 适配 `Tool` 接口，运行时动态发现。

**后续扩展——Agent-as-Tool**：可将一个 Agent 包装为 Tool，供其他 Agent 通过工具调用委派子任务。子 Agent 有独立上下文、工具集和模型，通过 `Tool.execute()` 返回最终结果。隔离方式支持同进程 goroutine 和独立子进程两种（参考 pigo 第 9 章 SubAgent 模式）。Phase 4 实现。

### 8.2 Provider 接口

```cangjie
interface Provider {
    func name(): String
    func chat(req: ChatRequest): ChatResponse
    func chatStreaming(req: ChatRequest): EventStream<ChatDelta>
}

struct ChatRequest {
    model: String
    messages: List<Message>       // 使用 2.6 节定义的 Message 密封接口
    tools: List<ToolDefinition>
    temperature: Float64
    maxTokens: Int64
    // ...
}
```

Provider 直接对接 LLM REST API，初始实现 `OpenAIProvider`（兼容 OpenAI 格式），后续扩展 `AnthropicProvider`、`OllamaProvider`。

### 8.2.1 模型上下文窗口推断

上下文压缩等模块需要知道模型的上下文窗口大小，采用**硬编码查找表 + 现场实测校准**双重策略：

```cangjie
class ModelContextRegistry {
    // 内置已知模型 → 上下文窗口（硬编码查找表）
    private let knownModels = HashMap<String, Int64> {
        "gpt-4o": 128000,
        "gpt-4o-mini": 128000,
        "gpt-4-turbo": 128000,
        "claude-sonnet-4": 200000,
        "claude-3.5-sonnet": 200000,
        "claude-3-haiku": 200000,
        "deepseek-chat": 64000,
        // ...
    }

    // 兜底默认值
    public let defaultContextWindow: Int64 = 8192

    public func get(model: String): Int64 {
        knownModels.get(model).getOr(defaultContextWindow)
    }
}
```

**优先级**：
1. 已知模型 → 查表拿到准确窗口，用于压缩触发的预判
2. 未知模型 → 使用默认值 8192，首次请求后通过 `response.usage.promptTokens` 获取实际用量
3. Token 估算模块优先信任 Provider 报告的用量值，精度高于本地估算

### 8.3 SessionStore 接口

```cangjie
interface SessionStore {
    // 整份写入（线性消息 → 生成 ID 树）
    save(id: String, header: SessionHeader, messages: List<Message>): Result<Unit>

    // 增量追加（保留已有树结构，新消息挂在 parentLeafId 下）
    appendBranch(id: String, parentLeafId: String, messages: List<Message>): Result<String>

    // 读取（返回线性消息列表）
    load(id: String): Result<List<Message>>

    // 读取（返回完整 entry 树，供 fork/resume 使用）
    loadEntries(id: String): Result<SessionHeader, List<Entry>>

    // 列出所有会话元数据
    list(): Result<List<SessionHeader>>

    // 删除会话
    delete(id: String): Result<Unit>

    // 分叉：从源会话的 leafId 处复制一条线性路径为新会话
    fork(sourceId: String, leafId: String): Result<SessionHeader, List<Entry>>
}
```

**默认实现**：基于 `bstorm`（嵌入式 JSON 文档库）：

```cangjie
import bstorm.*

@Model
class SessionRecord {
    @Id
    var id: String
    var header: String        // SessionHeader JSON 序列化
    var entries: String       // List<Entry> JSON 序列化
    var updatedAt: Int64
}

class StormSessionStore <: SessionStore {
    private let db: Storm

    public init(path: String) {
        this.db = Storm.open(path)
    }

    // save / load / appendBranch / list / delete / fork
    // 通过 bstorm 的 get/save/find/delete 实现
    // list 通过 all<SessionRecord>() 或排序查询实现
    // appendBranch 通过 load → append → save 实现
}
```

`SessionStore` 接口保持纯抽象，`bstorm` 是默认持久化实现，用户可替换为其他存储（如内存、SQLite 等）。

### 8.4 钩子（Hooks）

钩子是**决策型拦截器**：保留 6 个相位，每个相位可返回决策影响运行流程。`Hook` 名保持，注册序 = 执行序，先注册的先处理、可短路。

```cangjie
public class HookContext {
    public let config: AgentConfig
    public let toolRegistry: ToolRegistry
    public let turnCount: Int64
    public let state: HookState   // 每次 run 独立共享，跨相位传递数据
}

public enum BeforeToolDecision {
    | Allow
    | Deny(reason: String)
    | Modify(args: JsonValue)
}

public enum TurnDecision {
    | Continue(request: ChatRequest)   // 放行并可能改写请求（模型路由）
    | ShortCircuit(message: String)    // 终止 run
}

public class AfterTurnUpdate {
    public let messages: Option<ArrayList<Message>>  // 改写上下文
    public let shortCircuit: Bool                     // 短路
}

public interface Hook {
    public func beforeRun(ctx: HookContext): Unit {}
    public func afterRun(ctx: HookContext): Unit {}
    public func beforeTurn(ctx: HookContext, request: ChatRequest): TurnDecision {
        TurnDecision.Continue(request)
    }
    public func afterTurn(ctx: HookContext): AfterTurnUpdate {
        AfterTurnUpdate.none()
    }
    public func beforeTool(ctx: HookContext, call: ToolCallBlock): BeforeToolDecision {
        BeforeToolDecision.Allow
    }
    public func afterTool(ctx: HookContext, call: ToolCallBlock, result: ToolResultMessage): Unit {}
}
```

**决策语义**：

- `TurnDecision.Continue` 放行，可携带改写后的 `ChatRequest`（模型路由）；`ShortCircuit` 终止 run
- `BeforeToolDecision.Allow` 放行 / `Deny` 拦截 / `Modify` 改写工具参数
- `AfterTurnUpdate` 可改写上下文消息或短路；`HookState` 每次 run 独立创建，跨相位共享

**融合顺序**：

1. 工具执行前：**信任闸门先判定**（`shouldAllow`），通过后 **beforeTool hook 再判定**；两者任一 Deny 即拦截
2. 每轮结束：**afterTurn hook 先改写**上下文，之后内置 **compaction** 再压缩
3. 内置限流（maxToolCalls / minToolInterval）与 hook 无关，始终生效

---

## 九、安全设计

### 9.1 信任闸门（Trust Gate）

- 目录级别信任（`~/.atelier/trust.json`）
- 三种状态：`Undecided` / `Trusted` / `Untrusted`
- 就近继承：信任父目录，子目录自动继承
- 交互式确认：首次进入未信任目录时提示
- 会话级信任：`/trust once` 仅本次会话有效

### 9.2 工具白名单

- `bash`、`write_file`、`edit_file` 为副作用工具，需过信任闸门
- `read_file`、`grep`、`glob` 为只读工具，直接放行
- 工具可通过 `ExecutionMode` 声明并发策略

### 9.3 密钥安全

- 密钥从不写入可能被日志/事件打印的结构体
- 事件流裁剪敏感字段
- 错误消息只引用密钥名称，不引用值

---

## 十、性能与约束

| 项目 | 默认值 | 可配置 |
| :--- | :--- | :--- |
| 最大对话轮次 | 20 | `maxTurns` |
| 最大输出 Token | 4096 | `maxOutputTokens` |
| 压缩缓冲 Token | 16384 | `compactionReserveTokens` |
| 保留最近 Token | 20000 | `keepRecentTokens` |
| 上下文窗口（未知时禁用压缩） | 0（禁用） | Provider 提供时启用 |
| 并发工具执行 | 根据 `ExecutionMode` | 串行/并行 |
| 最大工具结果字符 | 2000（摘要场景） | 硬编码 |

---

## 十一、路线图

### Phase 1：核心库

- [x] Agent Runtime 核心循环（Outer Loop + Inner Loop）
- [x] 事件流（Event Stream）类型定义与实现
- [x] Tool 接口与全部内置工具（read/write/edit/bash/grep/glob/todo）
- [x] MCP 工具适配器（通过 mcp-cj 的 McpClient）
- [x] Provider 接口 + OpenAI 兼容适配器（直接 REST API）
- [x] Message 数据模型（密封接口 + 4 种角色 + ContentBlock）
- [x] SessionStore 接口 + 内存实现（树形结构 + AppendBranch + PathToLeaf）
- [x] bstorm 持久化实现（默认后端）
- [x] 上下文压缩（Compaction）
- [x] 信任闸门（Trust Gate）
- [x] AgentConfig 定义 + 代码方式构建
- [x] SchemaBuilder（替代手写 HashMap 造 JSON Schema）
- [x] 配套单元测试（116+ 测试）

### Phase 2：HTTP 服务 + 动态配置

- [x] HTTP Server（registerRoutes 挂载模式）
- [x] SSE 流式端点（POST /agent/stream，逐事件推送）
- [x] /session/save + /session/load 端点
- [x] AgentConfig 动态注册表（CRUD）
- [x] 配置文件加载（TOML）
- [x] 请求/响应 DTO（实现 JsonSerializable）
- [x] 日志系统（SimpleLogger → 文件，可配级别）
- [x] MCP Server TOML 配置 + 运行时自动连接
- [x] 工具命名空间（mcp_<server>_<name> + agent_<name> + 通配符 _*）
- [x] Agent-as-Tool（同进程子运行时委派）
- [x] 信任闸门接入运行时 + CLI /trust 命令
- [x] 钩子系统（6 个钩子：beforeRun/afterRun/beforeTurn/afterTurn/beforeTool/afterTool）
- [x] 工具防护链（配额 maxToolCalls + 速率限制 minToolInterval）
- [x] 上下文压缩接入运行时（afterTurn 时自动摘要）
- [x] 会话持久化（StormSessionStore ≈ 存储 ~/.atelier/sessions/）
- [x] REPL 会话管理（/session new/list/switch）
- [x] Anthropic Provider 扩展（兼容 DeepSeek Anthropic API）
- [x] Ollama Provider 扩展（sync + streaming + 工具调用）

### Phase 3：Skill 系统 + CLI

- [x] Skill 加载器（对齐 AgentSkills 规范，从 SKILL.md 目录加载）
- [x] SKILL.md 格式校验器
- [x] Skill 运行时注入（指令拼入 system prompt）
- [x] 斜杠命令系统（/help /trust /untrust /session /model /tools /clear /exit）
- [x] 交互式 REPL（session 持久化 + 恢复 + 模型切换）
- [x] CLI run 命令（单次执行）
- [x] 会话导出（JSONL/HTML）

### Phase 4：增强

- [x] 会话导出与 HTML 回放（JSONL 导出 + 自足 HTML 页面，REPL + HTTP 端点）
- [ ] 包管理器（安装/卸载 Skills/Tools）
- [x] HTTP 信任管理端点（`/trust` POST，支持 get/set/reset）
- [x] HTTP 会话管理端点（`/sessions` 列表 + `/session/fork` 克隆）
- [x] 信任提示/申请流程（TrustDecision 三态 + ask_user 三选）
- [x] 用户交互工具
  - [x] `ask_user` 内置工具：AI 主动向用户提问，runtime 暂停等待回答
  - [x] REPL 交互支持（暂停 → 显示问题 → 获取输入 → 恢复）
  - [x] HTTP 端点支持（SSE `user_input_request` 事件 + `/agent/input` 端点）

### Phase 5：ACP 接入（Agent 侧）

- [x] AgentRuntime 会话级取消（cancelSession + 检查点，供 session/cancel）
- [x] 工具执行开始/结束事件发射（修复事件无 producer 缺口）
- [x] ACP 适配层 `src/acp/`（translator / session_map / config options / bridge）
- [x] CLI `atelier acp`（ACP v1 stdio Agent，被 Zed/opencode 等宿主拉起）
- [x] Session Config Options（模型选择 `model_config` + 压缩开关）
- [x] 会话全能力（list/load 重放/resume/delete/close）+ 工具授权（request_permission）
- [x] e2e 线协议验证（离线 echo provider，35 断言）
- [x] 发版衔接：`acp` 0.2.0 已发布，依赖切注册表版本

---

## 十二、技术选型

### 12.1 是否使用 CangjieMagic

**结论：不使用。**

CangjieMagic（`/home/ystyle/Projects/Cangjie/CangjieMagic`）是一个宏 DSL 驱动的 Agent 框架，核心设计哲学是编译期通过 `@agent`/`@tool`/`@ai` 等宏生成代码。这与 Atelier 的**运行时动态配置**路线不兼容。

Atelier 的设计目标是开发者通过 JSON/YAML 在运行时定义 Agent，而 CangjieMagic 要求 Agent 在编译时通过宏定义。强行使用会导致架构扭曲。

**作为参考的价值**：

- Provider 实现（`OpenAIChatModel`、`AnthropicChatModel`）的设计思路
- 事件模型的分层设计
- Tool 接口抽象方式

### 12.2 MCP 协议层

**结论：使用 `ystyle::mcp`。**

mcp-cj（`/home/ystyle/Projects/Cangjie/mcp-cj`）是仓颉原生的 MCP 完整实现，版本 2.2.0，MIT 协议，支持：

- 客户端 + 服务端双端实现
- 3 种协议版本（2024-11-05 / 2025-11-25 / 2026-07-28）
- 8 种传输实现（stdio、SSE、Streamable HTTP、Stateless HTTP）
- 完整的工具/资源/提示生命周期管理

作为 Atelier 的 MCP 层依赖，负责所有 MCP 协议通信。Tool 层的 `MCPToolWrapper` 适配 mcp-cj 的 `McpClient`。

### 12.3 Provider 层

**结论：自研，直接对接 REST API。**

不通过 MCP 代理 LLM 调用。Provider 层直接实现 HTTP + SSE 的 LLM API 调用，参考 soulsoft.openai 的接口设计和消息模型，但全部自研以避免外部依赖。

初始实现 OpenAI 兼容 API（覆盖绝大多数国产模型），后续扩展 Anthropic 和 Ollama。

### 12.4 外部依赖总结

| 依赖 | 选型 | 原因 |
| :--- | :--- | :--- |
| MCP 协议 | `ystyle::mcp` | 仓颉原生、功能完备、无替代品 |
| 会话持久化 | `bstorm` | 嵌入式 JSON 文档库，`@Model` 宏自动序列化，支持索引与查询 |
| Agent 运行时 | 自研 | 无符合运行时动态路线的现成运行时 |
| LLM 客户端 | 自研 | 避免外部依赖，直接对接 REST API |
| 工具系统 | 自研 | 核心业务逻辑，需信任闸门等定制 |
| 配置 | 自研 | 与 Agent 动态管理深度绑定 |

---

## 十三、总结

Atelier 是一个**面向业务集成的 Agent 运行时**，其核心价值在于：

1. **开箱即用**：无需从零实现 Agent 循环，运行即可用
2. **动态可配**：Agent 定义运行时创建，像 Cherry Studio 一样灵活
3. **多形态部署**：可嵌入库、可 HTTP 服务、可 CLI
4. **社区友好**：命名与接口设计对齐行业标准
5. **可扩展**：Tool/Skill/Provider/SessionStore 均可插拔

开发者只需关注三件事：

- **挂载什么工具**（业务逻辑接入）
- **配置什么 Skills**（领域知识注入）
- **用什么存储**（会话持久化方案）

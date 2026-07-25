# Phase 1: 核心库实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 完成 Atelier 核心库的全部基础模块，交付可编程使用的 Agent 运行时

**架构:** 自底向上构建，每层依赖下层接口。Message → Tool/Provider/Session → Runtime 核心循环。mcp-cj 和 bstorm 为外部依赖。

**Tech Stack:** Cangjie 语言, `ystyle::mcp` (MCP 协议), `bstorm` (会话持久化)

**项目根目录:** `/home/ystyle/Projects/Cangjie/atelier`

---

## Task 1: 项目脚手架

**Files:**
- Create: `cjpm.toml`
- Create: `build.cj`

**Step 1: 创建 cjpm.toml**

```toml
[package]
name = "atelier"
version = "0.1.0"
cjc-version = "1.1.0"
output-type = "static"
compile-option = "-Woff unused"

[dependencies]
"ystyle::mcp" = "2.0.0"
"bstorm" = "1.4.0"
```

**Step 2: 创建 build.cj**

```cangjie
// build.cj - 构建脚本（用于 stdx 环境配置）
```

**Step 3: 验证**

Run: `cjpm build` 在项目根目录
Expected: 编译成功，生成 target/ 目录

**Step 4: Commit**

```bash
git add cjpm.toml build.cj
git commit -m "chore: scaffold atelier project"
```

---

## Task 2: Message 数据模型

**Files:**
- Create: `src/message/role.cj`
- Create: `src/message/content.cj`
- Create: `src/message/message.cj`

消息模型是贯穿全系统的地基。采用密封接口 (sealed interface / enum) + 角色判别模式，4 种角色 + 多模态 ContentBlock。

**Step 1: 创建 role.cj**

```cangjie
package atelier.message

public enum MessageRole {
    User
    Assistant
    ToolResult
    Compaction
}

public enum StopReason {
    EndTurn
    ToolUse
    Length
    Error
    Aborted
}
```

**Step 2: 创建 content.cj**

```cangjie
package atelier.message

public enum ContentBlock {
    TextBlock(text: String)
    ToolCallBlock(id: String, name: String, args: JsonValue)
    ToolResultBlock(toolCallId: String, result: String)
    ImageBlock(data: String, mimeType: String)
}

public class ContentList {
    private let blocks: ArrayList<ContentBlock>

    public init(blocks: ArrayList<ContentBlock>) { ... }
    public static func ofText(text: String): ContentList { ... }
    public func blocks(): ArrayList<ContentBlock> { ... }
    public func toolCalls(): ArrayList<ContentBlock> { ... }
}
```

**Step 3: 创建 message.cj**

```cangjie
package atelier.message

public interface Message {
    func role(): MessageRole
}

public class UserMessage <: Message { ... }
public class AssistantMessage <: Message { ... }
public class ToolResultMessage <: Message { ... }
public class CompactionMessage <: Message { ... }
```

**Step 4: 创建根模块导出**

```cangjie
// src/message/root.cj
package atelier.message
public import atelier.message.role.*
public import atelier.message.content.*
public import atelier.message.message.*
```

**Step 5: 编写单元测试**

```cangjie
// tests/message_test.cj 或内联测试
func test_user_message() { ... }
func test_assistant_message_tool_calls() { ... }
func test_content_list() { ... }
```

Run: `cjpm test` Expected: 4 种消息类型编译通过

**Step 6: Commit**

```bash
git add src/message/ tests/
git commit -m "feat: add message data model with 4 roles and content blocks"
```

---

## Task 3: 事件流（Event Stream）

**Files:**
- Create: `src/agent/event.cj`

事件系统定义了运行时循环发射的 11 种事件 + EventStream 泛型。

**Step 1: 定义事件枚举与接口**

```cangjie
package atelier.agent

public interface AgentEvent {
    func eventType(): String
}

public struct AgentStartEvent <: AgentEvent { sessionId: String }
public struct AgentEndEvent <: AgentEvent { messages: List<Message> }
public struct TurnStartEvent <: AgentEvent {}
public struct TurnEndEvent <: AgentEvent { message: AssistantMessage; toolResults: List<ToolResultMessage> }
public struct MessageStartEvent <: AgentEvent { message: Message }
public struct MessageUpdateEvent <: AgentEvent { message: Message; delta: String }
public struct MessageEndEvent <: AgentEvent { message: Message }
public struct ToolExecutionStartEvent <: AgentEvent { toolCallId: String; toolName: String }
public struct ToolExecutionUpdateEvent <: AgentEvent { toolCallId: String; progress: String }
public struct ToolExecutionEndEvent <: AgentEvent { toolCallId: String; result: String; isError: Bool }
public struct CompactionEvent <: AgentEvent { reason: String; tokensBefore: Int64; tokensAfter: Int64 }
```

**Step 2: 实现 EventStream 泛型**

```cangjie
public class EventStream<T, R> {
    private let ch: Channel<T>
    private var result: ?R
    private var resultErr: ?Error

    public init(buffer: Int) { ... }
    public func emit(event: T): Result<Unit> { ... }
    public func result(): R { ... }
    public func setResult(r: R) { ... }
    public func setError(e: Error) { ... }
}
```

**Step 3: 编写单元测试**

```cangjie
func test_event_stream_emit_and_result() { ... }
func test_event_stream_cancellation() { ... }
func test_event_types() { ... }
```

Run: `cjpm test` Expected: PASS

**Step 4: Commit**

```bash
git add src/agent/event.cj
git commit -m "feat: add event stream with 11 event types"
```

---

## Task 4: AgentConfig 定义

**Files:**
- Create: `src/agent/config.cj`

**Step 1: 定义 AgentConfig 结构体**

对齐设计文档 7.1 节的结构体设计，包含身份、指令、模型、工具与技能、运行时参数、上下文压缩配置和元数据。

**Step 2: 编写单元测试**

验证序列化/反序列化、默认值填充、可选字段处理。

Run: `cjpm test` Expected: PASS

**Step 3: Commit**

```bash
git add src/agent/config.cj
git commit -m "feat: add AgentConfig definition"
```

---

## Task 5: Tool 接口 + 注册表

**Files:**
- Create: `src/tool/interface.cj`
- Create: `src/tool/registry.cj`

**Step 1: 定义 Tool 接口**

```cangjie
package atelier.tool

public enum ToolExecutionMode {
    Parallel
    Sequential
}

public interface Tool {
    func name(): String
    func description(): String
    func schema(): JsonValue
    func execute(ctx: Context, args: JsonValue): ToolResult
    func executionMode(): ToolExecutionMode
}

public struct ToolResult {
    content: ContentList
    details: Option<JsonValue>
    isError: Bool
    terminate: Option<Bool>
}
```

**Step 2: 定义 Context**

```cangjie
public struct Context {
    workDir: String
    // 信任、元数据等
}
```

**Step 3: 实现 ToolRegistry**

```cangjie
public class ToolRegistry {
    private let tools = HashMap<String, Tool>()

    public func register(tool: Tool) { ... }
    public func get(name: String): Option<Tool> { ... }
    public func list(): List<Tool> { ... }
    public func remove(name: String) { ... }
}
```

**Step 4: 编写单元测试**

验证注册、查找、列出的基本行为。

Run: `cjpm test` Expected: PASS

**Step 5: Commit**

```bash
git add src/tool/interface.cj src/tool/registry.cj
git commit -m "feat: add Tool interface and registry"
```

---

## Task 6: 内置工具

**Files:**
- Create: `src/tool/builtin/read_file.cj`
- Create: `src/tool/builtin/write_file.cj`
- Create: `src/tool/builtin/edit_file.cj`
- Create: `src/tool/builtin/bash.cj`
- Create: `src/tool/builtin/grep.cj`
- Create: `src/tool/builtin/glob.cj`
- Create: `src/tool/builtin/todo.cj`
- Create: `src/tool/executor.cj`

**每个内置工具步骤：**
1. 实现 Tool 接口（name/description/schema/execute/executionMode）
2. 编写单元测试
3. 在 executor.cj 中实现批量执行器（串行/并行）

**read_file：** 分页读取，支持行号前缀和截断。只读工具（ExecutionMode.Parallel）。

**write_file：** 覆盖检测（文件已存在时返回错误而非静默覆盖）。副作用工具（ExecutionMode.Sequential）。

**edit_file：** 精确字符串替换 + 唯一性检查（匹配到多处时拒绝）。副作用工具（ExecutionMode.Sequential）。

**bash：** 执行 shell 命令，支持超时和取消。副作用工具（ExecutionMode.Sequential）。

**grep：** 正则搜索文件内容。只读工具（ExecutionMode.Parallel）。

**glob：** 文件模式匹配。只读工具（ExecutionMode.Parallel）。

**todo：** 待办列表管理（唯一有状态工具）。ExecutionMode.Sequential。

**executor.cj：**

```cangjie
public class ToolExecutor {
    public func execute(tool: Tool, ctx: Context, args: JsonValue): ToolResult { ... }
    public func executeBatch(tools: List<(Tool, Context, JsonValue)>): List<ToolResult> { ... }
}
```

- 单个工具：过信任闸门 → 执行 → 返回结果
- 批量：按 ExecutionMode 决定串行还是并发

Run: `cjpm test` Expected: 全部内置工具测试通过

**Commit at end:**

```bash
git add src/tool/
git commit -m "feat: add 7 built-in tools and batch executor"
```

---

## Task 7: MCP 工具适配器

**Files:**
- Create: `src/tool/mcp_tool.cj`

通过 mcp-cj 的 `McpClient` 将 MCP Server 的工具适配为 Atelier 的 `Tool` 接口。

```cangjie
public class MCPToolWrapper <: Tool {
    private let client: McpClient
    private let toolDef: mcp.Tool

    public func name(): String { toolDef.name }
    public func schema(): JsonValue { toolDef.inputSchema.toJson() }
    public func execute(ctx: Context, args: JsonValue): ToolResult {
        let result = client.callTool(this.name, args)
        // 将 mcp.CallToolResult 转为 ToolResult
    }
}
```

Run: `cjpm test` Expected: 编译通过

**Commit:**

```bash
git add src/tool/mcp_tool.cj
git commit -m "feat: add MCP tool adapter via mcp-cj"
```

---

## Task 8: Provider 接口 + OpenAI 实现

**Files:**
- Create: `src/provider/interface.cj`
- Create: `src/provider/registry.cj`
- Create: `src/provider/openai.cj`
- Create: `src/provider/transport.cj`

**Step 1: Provider 接口**

```cangjie
package atelier.provider

public interface Provider {
    func name(): String
    func chat(req: ChatRequest): ChatResponse
    func chatStreaming(req: ChatRequest): EventStream<ChatDelta>
}

public struct ChatRequest {
    model: String
    messages: List<Message>
    tools: List<ToolDefinition>
    temperature: Float64
    maxTokens: Int64
}
```

**Step 2: transport.cj — HTTP + SSE 传输层**

实现 HTTP POST 请求 + SSE 流式读取。处理：
- 自动重试（仅服务端明确指示时可重试）
- 超时
- ctx cancellation
- 行式 SSE 解析（`data:` 前缀、`[DONE]` 信号、跨行事件累积）

**Step 3: openai.cj — OpenAI 兼容 Provider**

实现 `OpenAIProvider <: Provider`：
- `chat()`：POST `/v1/chat/completions` → 解析 JSON 响应
- `chatStreaming()`：POST 带 `stream: true` → SSE 解析 → 增量事件

消息转换：Atelier 的 `Message` → OpenAI `messages` 数组
工具转换：Atelier 的 `Tool` → OpenAI `tools` 数组

**Step 4: ProviderRegistry**

```cangjie
public class ProviderRegistry {
    public func register(name: String, provider: Provider)
    public func get(name: String): Option<Provider>
}
```

**Step 5: 编写单元测试（使用 mock server）**

Run: `cjpm test` Expected: PASS

**Step 6: Commit**

```bash
git add src/provider/
git commit -m "feat: add Provider interface and OpenAI compatible adapter"
```

---

## Task 9: 会话模型 + 存储

**Files:**
- Create: `src/session/session.cj`
- Create: `src/session/store.cj`
- Create: `src/session/memory_store.cj`

**Step 1: session.cj — 数据结构**

```cangjie
package atelier.session

public struct SessionHeader {
    version: Int32
    id: String
    createdAt: Int64
    updatedAt: Int64
    model: String
    provider: String
    systemPrompt: String
    parentSession: Option<String>
}

public struct Entry {
    id: String
    parentId: Option<String>
    timestamp: Int64
    message: Message
}
```

**Step 2: 实现 PathToLeaf**

```cangjie
public func pathToLeaf(entries: List<Entry>, leafId: String): List<Entry> {
    // 从 leafId 沿 parentId 上溯到根，返回 root→leaf 的有序列表
    // 防环（seen map）/ 防缺失父节点（停在最后一个祖先）
}
```

**Step 3: store.cj — SessionStore 接口**

同设计文档 8.3 节。

**Step 4: memory_store.cj — 内存实现**

```cangjie
public class MemorySessionStore <: SessionStore {
    private let sessions = HashMap<String, (SessionHeader, List<Entry>)>()

    // save / load / loadEntries / appendBranch / list / delete / fork
    // 全部基于 HashMap 操作
}
```

**Step 5: 编写单元测试**

测试 save/load/appendBranch/fork/list/delete 全流程。

Run: `cjpm test` Expected: PASS

**Step 6: Commit**

```bash
git add src/session/
git commit -m "feat: add session data model, memory store, and SessionStore interface"
```

---

## Task 10: bstorm 持久化后端

**Files:**
- Create: `src/session/file_store.cj`

基于 bstorm 实现 SessionStore 的持久化版本。

```cangjie
import bstorm.*

@Model
public class SessionRecord {
    @Id
    var id: String
    var header: String
    var entries: String
    var updatedAt: Int64
}

public class StormSessionStore <: SessionStore {
    private let db: Storm

    public init(path: String) {
        this.db = Storm.open(Config.dir(path))
    }

    public func save(id: String, header: SessionHeader, messages: List<Message>): Result<Unit> {
        let record = SessionRecord {
            id: id,
            header: serialize(header),
            entries: serialize(entries),
            updatedAt: timestamp()
        }
        db.save(record)
    }
    // ... load / appendBranch / list / delete / fork
}
```

Run: `cjpm test` Expected: 集成测试通过

**Commit:**

```bash
git add src/session/file_store.cj
git commit -m "feat: add bstorm-based persistent session store"
```

---

## Task 11: 信任闸门

**Files:**
- Create: `src/trust/manager.cj`
- Create: `src/trust/gate.cj`

**Step 1: trust manager**

```cangjie
public enum TrustState {
    Undecided
    Trusted
    Untrusted
}

public class TrustManager {
    // 目录级别信任存储 ~/.atelier/trust.json
    // 就近继承：信任父目录，子目录自动继承
    // 会话级信任（/trust once）
}
```

**Step 2: trust gate**

```cangjie
public func checkTool(tool: Tool, workDir: String, trustManager: TrustManager): Bool {
    // 只读工具 → 放行
    // 副作用工具 → 过信任闸门
    // 未决目录 → 交互式确认
}
```

Run: `cjpm test` Expected: PASS

**Commit:**

```bash
git add src/trust/
git commit -m "feat: add trust gate for tool execution safety"
```

---

## Task 12: Agent Runtime 核心循环

**Files:**
- Create: `src/agent/runtime.cj`
- Create: `src/agent/registry.cj`
- Create: `src/agent/root.cj`（包级导出）

这是最核心的任务，将全部下层模块串联起来。

**Step 1: 实现两层循环**

```cangjie
public class AgentRuntime {
    private let config: AgentConfig
    private let provider: Provider
    private let tools: ToolRegistry
    private let sessionStore: SessionStore

    public func chat(messages: List<Message>): EventStream<AgentEvent, List<Message>> {
        // Outer Loop:
        //   1. emit AgentStartEvent
        //   2. 进入 inner loop
        //   3. emit AgentEndEvent(messages)
        //   4. 持久化到 sessionStore

        // Inner Loop (Turn):
        //   1. Build Request: system + messages + tools
        //   2. provider.chatStreaming() → 收集 AssistantMessage
        //   3. Check stopReason:
        //      - end_turn → exit inner loop
        //      - tool_use → execute tools + append results + repeat
        //      - length → retry
        //      - error/aborted → terminate
        //   4. After-turn hooks
        //   5. Check follow-up messages
    }
}
```

**Step 2: 实现钩子系统**

AgentHooks 的四个钩子挂载点。

**Step 3: 实现上下文压缩集成**

在 afterTurn 中检查 token 用量，触发 compaction。

**Step 4: 编写集成测试**

- 完整 Agent 对话流程（模拟 Provider 返回）
- 工具调用循环
- 上下文压缩触发
- 会话持久化

Run: `cjpm test` Expected: 全部集成测试通过

**Step 5: Commit**

```bash
git add src/agent/runtime.cj src/agent/registry.cj src/agent/root.cj
git commit -m "feat: add Agent Runtime core loop with full integration"
```

---

## Task 13: 上下文压缩

**Files:**
- Create: `src/context/tokens.cj`
- Create: `src/context/cutpoint.cj`
- Create: `src/context/compaction.cj`

**Step 1: tokens.cj — Token 估算**

```cangjie
public class TokenEstimator {
    // 优先信任 Provider 报告的 usage
    // 本地估算作为 fallback
    public func estimate(messages: List<Message>): Int64 { ... }
}
```

**Step 2: cutpoint.cj — 压缩切点选择**

```cangjie
public struct CutPoint {
    firstKeptIndex: Int   // 第一条保留的消息索引
    isSplitTurn: Bool     // 是否在 turn 中间切
}

public func selectCutPoint(messages: List<Message>, reserveTokens: Int64, keepRecentTokens: Int64): CutPoint {
    // 从尾部往前数 keepRecentTokens
    // 再往前找到最近的一个完整 turn 边界
    // 不拆散 ToolCall ↔ ToolResult 对
}
```

**Step 3: compaction.cj — 压缩执行**

```cangjie
public func compact(messages: List<Message>, provider: Provider, contextWindow: Int64): List<Message> {
    // 1. Token 用量检测
    // 2. 选切点
    // 3. 调用模型生成结构化摘要
    // 4. 用 CompactionMessage 替换被压缩的历史
    // 5. 保留最近 keepRecentTokens 的消息
}
```

Run: `cjpm test` Expected: PASS

**Commit:**

```bash
git add src/context/
git commit -m "feat: add context compaction with token estimation and cutpoint selection"
```

---

## Task 14: 总体验证

**Step 1: 编写一个完整的端到端集成测试**

创建一个完整的 Agent 对话（使用 mock Provider）：
1. 发送用户消息
2. Agent 回复（模拟流式）
3. Agent 调用工具
4. 工具返回结果
5. Agent 继续回复
6. 验证事件流完整性
7. 验证会话持久化

Run: `cjpm test` Expected: 全部测试通过

**Step 2: 验证所有模块的依赖关系符合设计**

- `message` 层不依赖任何外部包
- `agent` 层依赖 `message`/`tool`/`provider`/`session`/`context`/`trust`
- `tool` 层仅依赖 `message`
- `provider` 层仅依赖 `message`

**Commit:**

```bash
git add .
git commit -m "chore: Phase 1 core library complete"
```

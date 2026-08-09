# Atelier 上下文与扩展系统设计文档

> 现状实现 + 演进路线：上下文构建、读写分离存储、压缩、MCP 按需加载、Skills 渐进式披露
>
> 本文档以**当前实现代码**为准，标注 ✅ 的部分可直接对照源码；标注 🚧 的部分为演进方向，实现时更新本文档。
>
> 定位：**设计规格（spec）**。功能落地后，面向使用者的开发者文档另开 `docs/context.md`（与 hooks.md 等同级）。

---

## 一、总体架构：读写分离的分层模型

Atelier 的上下文管理采用 **“存储层（L1）+ 构建层（L2）”** 双层架构。所有历史数据只增不改，每次请求前动态构建 LLM 上下文。

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              L1: 存储层（只增不改）                         │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │  session/store.cj        SessionStore 接口                          │  │
│  │  session/session.cj      SessionHeader / Entry（树形，parentId 链）  │  │
│  │  session/file_store.cj   StormSessionStore（bstorm 持久化，默认）     │  │
│  │  session/memory_store.cj MemoryStore（内存，测试/嵌入用）            │  │
│  │                                                                      │  │
│  │  每条 Entry: {id, parentId, timestamp, message}                      │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                      │                                     │
│                                      ▼                                     │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                    L2: 上下文构建层                                  │  │
│  │  context/builder.cj         ContextBuilder（initMessages / buildChatRequest）│
│  │  context/system_prompt_builder.cj  SystemPromptBuilder.build（4 段）          │
│  │  agent/runtime.cj            resolveTools() + 委托 ContextBuilder            │
│  │  context/compaction.cj       compactMessages()                          │  │
│  │  │                                                                  │  │
│  │  • 组装系统提示（静态指令 + Skills + AGENTS.md + 会话环境）          │  │
│  │  • 组装工具定义（config.tools 精确名 / agent_ 前缀 / _* 通配符）     │  │
│  │  • 上下文压缩（超阈值时，前部替换为 CompactionMessage）              │  │
│  │  • 输出: ChatRequest {model, messages, tools}                       │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 为什么读写分离？

| 问题 | 混在一起 | 读写分离 |
|------|----------|----------|
| UI 回看历史 | ❌ 被压缩弄丢 | ✅ 完整保留（只增不改） |
| 调试工具调用 | ❌ 无法回溯原始结果 | ✅ 随时导出完整会话 |
| 上下文膨胀 | ❌ 越来越长 | ✅ 构建层可压缩，不影响原始数据 |
| `/tree` 分叉 | ❌ 压缩后难以回溯 | ✅ 完美支持 |
| 审计合规 | ❌ 无完整日志 | ✅ 有不可篡改的审计链 |

**现状**：L2 构建已抽离为 `ContextBuilder`（✅ context/builder.cj）+ `SystemPromptBuilder`（✅ context/system_prompt_builder.cj），`AgentRuntime.chatWithEnv()`（runtime.cj:102）委托调用。每次 `chat()` 传入的是已加载的消息列表（由调用方经 `sessionStore.load` / `loadEntries` + `pathToLeaf` 得到），运行时负责系统提示组装、工具解析与压缩。

---

## 二、存储层（L1）

### 2.1 Entry 数据模型（✅ session/session.cj）

```cangjie
public struct SessionHeader {
    public let version: Int32
    public let id: String
    public let createdAt: Int64
    public let updatedAt: Int64
    public let model: String
    public let provider: String
    public let systemPrompt: String
    public let parentSession: Option<String>   // 分叉来源会话 ID
    public let env: SessionEnvironment          // {directory, context: HashMap<String,String>}
}

public struct Entry {
    public let id: String              // entry 唯一标识（如 "sess_0_3"）
    public let parentId: Option<String> // 上一条 entry ID，构成树
    public let timestamp: Int64
    public let message: Message         // 密封接口：User/Assistant/ToolResult/Compaction
}
```

Entry 的 `parentId` 将消息织成一棵树——线性会话就是每条 entry 的 parentId 都指向前一条的特例，根节点 parentId 为空。

**核心操作**：`pathToLeaf(entries, leafId)` 从叶子沿 parentId 上溯到根，重建线性对话（fork 复用）。

### 2.2 SessionStore 接口（✅ session/store.cj）

```cangjie
public class SessionData {
    public let header: SessionHeader
    public let entries: ArrayList<Entry>
}

public interface SessionStore {
    func save(id: String, header: SessionHeader, messages: ArrayList<Message>): Unit
    func appendBranch(id: String, parentLeafId: String, messages: ArrayList<Message>): String
    func load(id: String): ArrayList<Message>
    func loadEntries(id: String): SessionData
    func list(): ArrayList<SessionHeader>
    func delete(id: String): Unit
    func fork(sourceId: String, leafId: String): SessionData
    public func close(): Unit {}
}
```

### 2.3 实现（✅）

| 实现 | 文件 | 说明 |
|------|------|------|
| `StormSessionStore` | session/file_store.cj | 默认后端，基于 bstorm（badger 嵌入式 JSON 文档库）。`SessionRecord {id, headerJson, entriesJson, updatedAt}`，entries 整体序列化为 JSON 存储 |
| `MemoryStore` | session/memory_store.cj | 内存实现，测试/嵌入场景 |

### 2.4 实现约定

| 原则 | 说明 |
|------|------|
| **只增不改** | `appendBranch` 只追加新 Entry；接口不提供修改/删除单条 Entry 的能力（`delete` 仅整会话删除） |
| **树形追加** | 新消息挂在 `parentLeafId` 下，返回新叶子 ID，天然支持分叉 |
| **可插拔** | `SessionStore` 纯抽象接口，可替换存储后端 |

---

## 三、上下文构建（L2）

### 3.1 现状：ContextBuilder + SystemPromptBuilder（✅ P0 已实现）

`AgentRuntime.chatWithEnv()` 每次 run 委托 `ContextBuilder` 按以下步骤构建上下文：

```
1. ContextBuilder.initMessages() 内部经 SystemPromptBuilder.build 生成系统提示   // 4 段
2. 系统提示作为首条 UserMessage 加入 currentMessages（非空才注入）              // （兼容 OpenAI 系 API 的 system 传法）
3. 追加调用方传入的历史消息
4. 每轮 resolveTools() 解析工具定义（config.tools → ToolRegistry）→ buildChatRequest() 组装 ChatRequest
5. 每轮结束（end_turn）后：afterTurn hooks 改写 → compactMessages() 压缩
```

**固定部分**（前缀，缓存友好）：

- `config.systemPrompt`（Agent 角色定义、核心指令）
- `config.skills` 声明的 Skill 完整指令（当前全量注入，🚧 演进见第七章）
- 工作目录 `AGENTS.md`（[Project Rules]）

**动态部分**（后缀，随会话变化）：

- `[Session Context]`：`SessionEnvironment.context` 键值对（工作目录、会话环境变量）

### 3.2 独立 ContextBuilder（✅ P0 已实现，context/builder.cj）

P0 已完成抽取，职责收敛、可独立测试。实际签名（与现有构建逻辑一一对应，不引入新概念）：

```cangjie
// context/builder.cj（P0 已实现）
public class ContextBuilder {
    public init(skills: SkillRegistry, env: SessionEnvironment)   // 无 store——P3 归档解析时引入

    // run 一次：系统提示作为首条 UserMessage 注入（空则不注入），再追加历史
    public func initMessages(systemPrompt: String, skillNames: ArrayList<String>,
        history: ArrayList<Message>): ArrayList<Message>

    // 每轮：组装 ChatRequest
    public func buildChatRequest(model: String, messages: ArrayList<Message>,
        temperature: Float64, maxOutputTokens: Int64,
        thinkingLevel: Option<String>, tools: ArrayList<OpenAITool>): ChatRequest
}
```

> 注：为避开 context→agent 包循环依赖，不引入 AgentConfig 参数，拆为标量/列表传参。

### 3.3 独立 SystemPromptBuilder（✅ P0 已实现，context/system_prompt_builder.cj）

P0 前，系统提示拼接是 runtime.cj 的顶层函数 `buildSystemPromptWithEnv`，已承担 4 段拼接（systemPrompt / Skills 指令 / AGENTS.md / Session Context），演进后还会增加 MCP 服务目录、Skills 目录等段。独立成类（✅ P0 已实现），让**分段顺序、段格式、前缀稳定性**收拢在一处、可单独测试：

```
┌──────────────────────────────────────────────────────┐
│ [固定] config.systemPrompt（Agent 角色定义、核心指令）│  ← 前缀，缓存友好
├──────────────────────────────────────────────────────┤
│ [固定] Skills 指令（config.skills 全量注入）          │  ← 兼容路径（P2 保留）
├──────────────────────────────────────────────────────┤
│ [动态] [Project Rules] 工作目录 AGENTS.md             │  ← 会话级变动，挂末尾
│ [动态] [Session Context] env.context 键值对           │  ← 会话级变动
│ [动态] [可用 MCP 服务] 服务目录（✅ P1，第五章）       │  ← 会话级变动
│ [动态] [可用 Skills] 目录（✅ P2，第七章）             │  ← 会话级变动
└──────────────────────────────────────────────────────┘
```

```cangjie
// context/system_prompt_builder.cj（P0 已实现）
// 分段式构建：固定段在前（缓存前缀），动态段按需挂末尾
public class SystemPromptBuilder {
    public init() {}

    // 4 段拼接：systemPrompt / Skills 指令 / [Project Rules] AGENTS.md / [Session Context]
    public func build(systemPrompt: String, skillNames: ArrayList<String>,
        skills: SkillRegistry, env: SessionEnvironment): String
}
```

与现有 `buildSystemPromptWithEnv` 行为等价（4 段），`AgentRuntime` 已改为委托调用。P1/P2 的 MCP 服务目录段、Skill 目录段演进时在此类追加。

**要点**：

- **无状态、每次 build 重新拼接**：各段来源（config/env）可能变化，构建器不做缓存；缓存友好靠"段顺序固定 + 前缀段稳定"实现
- **分段顺序即文档顺序**：固定段（systemPrompt → skills 指令）在前，动态段（AGENTS.md → Session Context → MCP 目录 → Skills 目录）在后，与缓存前缀规则一致（见下表）
- **演进兼容**：现状 4 段全部对应原 `buildSystemPromptWithEnv` 行为（P0 已抽取为 `SystemPromptBuilder.build`）；MCP/Skills 目录段为新增，配置了才挂，不影响旧行为
- **目录段带引导语**：MCP/Skills 目录不只是列表，还要写明"怎么用"（调用哪个工具加载），让 LLM 知道按需激活（见下例）

**构建结果示例**（`build()` 输出，✅ = 现状已有，🚧 = 演进新增）：

```
你是一个数据分析专家...                          ✅ [固定] config.systemPrompt

## 代码审查流程                                  ✅ [固定] config.skills 指令（全量）
1. 先用 read_file 读取目标文件
...

[Project Rules]                                  ✅ [动态] 工作目录 AGENTS.md
（AGENTS.md 内容）

[Session Context]                                ✅ [动态] SessionEnvironment.context
workDir = /home/ystyle/Projects/atelier

[可用 MCP 服务]                                  🚧 [动态] 服务目录（第五章）
调用 load_mcp_toolset(server_id) 按需加载完整工具集。
- github: GitHub 仓库管理（12 个工具）
- slack: 消息发送与查询（8 个工具）

[可用 Skills]                                    🚧 [动态] Skill 目录（第七章）
调用 use_skills(name) 激活对应的技能包。
- code-review: 代码审查技能，帮助审查 Cangjie 代码质量
- data-cleaning: 清洗和标准化 CSV 数据
```

| 改动位置 | 是否影响 DeepSeek 缓存 | 原因 |
|----------|------------------------|------|
| System Prompt 头部 | ❌ 影响 | 缓存前缀匹配从第 0 个 Token 开始 |
| 工具定义（Tools） | ❌ 影响 | Tools 在请求前部 |
| 动态环境信息（System 末尾） | ✅ 不影响 | 前缀不变，只改尾部 |
| 历史消息（Messages 后部） | ✅ 不影响 | 前缀不变 |
| 压缩（Messages 变短） | ✅ 正面影响 | Token 减少，缓存命中率不变 |

---

## 四、上下文压缩（Compaction）

### 4.1 现状（✅ context/compaction.cj + tokens.cj + cutpoint.cj + model_registry.cj）

**两阶段 Token 判定**：

1. **窗口查表**：`ModelContextRegistry.get(model)`——21 个已知模型硬编码查找表（gpt-4o 128k、deepseek-chat 64k、claude-sonnet-4 200k 等），未知模型兜底 8192
2. **本地估算**：`estimateTokens(messages)`——按角色估算（文本 ≈ `size/4` token，工具块固定+20 等）

**压缩策略** `compactMessages(messages, contextWindow, reserveTokens, keepRecentTokens)`：

- `total <= reserveTokens` 或 `contextWindow == 0` → 不压缩
- 超阈值 → 从尾部回溯保留最近 `keepRecentTokens`，之前全部替换为一条 `CompactionMessage`
- 切点选择（cutpoint.cj）目前为简单策略：按 token 回溯；ToolCall ↔ ToolResult 配对保护留作增强

**当前局限**：

- 摘要为**固定占位文本**（`"... N previous messages summarized ..."`），未调用 LLM 生成结构化摘要
- 压缩结果只影响**本次 run 的内存上下文**，不落库、不持久化
- Provider 报告的 `usage.promptTokens` 已在 ChatResponse 中携带，优先使用为演进方向

### 4.2 ✅ P3 已实现：AI 自主归档（archive_history 工具）

由 LLM 判断"哪些历史可以归档"（代码无法判断语义），调用 `archive_history(start_index, end_index, summary)` 工具。

**实现要点（基于现有 Message 密封接口，Entry/store 零改动）**：

- ✅ Message 密封接口新增第 5 个实现类 `ArchiveMessage {startIndex, endIndex, summary, timestamp}`（role() → MessageRole.Archive；不新增 Entry 字段、不引入 system_internal 角色）；`serialize.cj` 的 `readMessageFromJson` 加一个 case，旧文件加载不受影响（缺字段默认 0）
- ✅ `archive_history` 工具（tool/archive_history.cj）：校验 start ≥ 0、end ≥ start、summary 非空 → 返回归档确认；三参数缺失/非法报错
- ✅ `ContextBuilder.applyArchives(messages)`：扫描 `archive_history` 调用对（ToolCall + ToolResult），**范围钳制**（start ≥ 0；上限钳到调用对前一条，归档不能越过调用对自身）→ 替换为 ArchiveMessage → 调用对自身移除（天然幂等）；无调用对返回原列表；多调用对从后往前处理
- ✅ runtime 每轮构建 ChatRequest 前应用（`TurnStartEvent` 后）
- ✅ 三 Provider 消息转换：ArchiveMessage → `[Archived <start>-<end>: <summary>]`（user 消息）
- **持久化策略**：归档在 run 内应用（内存替换），run 结束 REPL save 时 ArchiveMessage 随消息序列化入库（store 保留归档痕迹：范围 + 摘要）；**严格 L1 只增不改**（appendBranch 追加归档 Entry、原始消息不删）需 runtime 会话链路（sessionId/parentLeafId），当前 runtime 无会话对象——🚧 后续演进

| 方案 | 判断主体 | 准确度 | 实现复杂度 |
|------|----------|--------|------------|
| 规则引擎 | 代码 | ❌ 无法判断语义 | 低 |
| AI 自主归档 | LLM | ✅ 理解上下文语义 | 低（只加一个工具） |

### 4.3 ✅ P4 已实现：可配置压缩模板（独立子调用）

**动机**：不同业务场景对摘要粒度需求不同（法律文书要 `cited_laws`，代码场景要 `files_modified`/报错栈）。压缩发生在**独立的 LLM 子调用**中——请求体与主对话完全不同（无 system/tools，仅一条 user 消息），缓存 Key 独立，**修改压缩模板不影响主对话的 DeepSeek 缓存命中率**。

**配置结构**（✅ `context/compaction.cj` 的 `CompactionConfig`，实现 JsonSerializable & JsonDeserializable）：

```cangjie
public struct CompactionConfig {
    public let enabled: Bool = true                 // 与现有 compactionEnabled 语义一致
    public let reserveTokens: Int64 = 16384         // 与现有 compactionReserveTokens 语义一致
    public let keepRecentTokens: Int64 = 20000      // 与现有 keepRecentTokens 语义一致
    public let promptTemplate: String = DEFAULT_PROMPT_TEMPLATE  // 压缩提示词模板
    public let outputSchema: Option<JsonValue> = None            // 极简输出约束（见下）
    public let summaryModel: Option<String> = None               // 摘要模型，None = 复用主模型
}
```

**模板变量与条件块**（✅ mustache-cj v1.2.1 中心仓版）：

| 语法 | 说明 |
|------|------|
| `{{conversation}}` | 待压缩的对话文本（必填） |
| `{{previous_summary}}` | 历史摘要（可选，首次压缩不存在） |
| `{{max_tokens}}` | 摘要输出上限（= reserveTokens） |
| `{{#previous_summary}}...{{/previous_summary}}` | 条件块（section）：变量存在且非空才渲染，否则整块忽略 |

- **引擎**：mustache 1.2.1（cjpm.toml 依赖，仓颉 1.1.x 兼容已验证）。`truth()` 判定 None / 空串 / 空列表 → 不渲染
- **上下文注入**：`CompactionContext <: MustacheComponent`，`mustache()` 返回 `DataModelStruct {conversation, previous_summary?, max_tokens}`（previous_summary 仅 Some 时加字段），`Template.parse` + `render` 渲染
- **容错**：变量缺失时引擎静默忽略（silentMiss）

**outputSchema：极简校验，不引完整 JSON Schema**（✅ `validateSummary`）：

- 配置格式：`{required: ["goal", "key_findings"], types: {"goal": "string", "key_findings": "array"}}`
- 校验逻辑：解析为 `JsonValue` → 必填键存在 + 类型断言（string/array/number/bool/object 五类）
- 校验失败/解析失败：记录日志、**降级为占位摘要文本**（不中断主循环）
- ⚠️ stdx 1.1.0 的 `readValue<Option<JsonValue>>` 有 bug（对象后接成员报 "Commas are required"）——outputSchema 反序列化用手写 `peek()==JsonNull` + `JsonValue.fromJson` 绕过（cangjie-mem 433）

**独立子调用**（✅ 复用 `Provider.chat(req)` 非流式接口，请求体无 system、无 tools）：

```
调用链：
runtime afterTurn 压缩触发（runtime.cj 压缩调用点）
  → 判定：Provider 实际用量（assistantMsg.usage.inputTokens > 0）优先，本地估算兜底
  → 触发条件：total > reserve && contextWindow != 0 && total > contextWindow - reserve
  → summarizeText（对话文本，截取到 reserve*4 字节；单条超限截取前缀）
  → renderCompactionPrompt（模板渲染）
  → provider.chat(ChatRequest(summaryModel ?? 主模型, [UserMessage(prompt)],
      temperature: 0.2, maxTokens: reserveTokens, tools: []))
  → plainTextOf 取摘要 → outputSchema 校验（失败降级占位）→ compactWithSummary 切点替换
  → 子调用异常 → 占位摘要降级
```

**与 AgentConfig 的兼容策略**（✅ 防序列化大改）：

- `AgentConfig` 现有三个平铺字段（`compactionEnabled`/`compactionReserveTokens`/`keepRecentTokens`）**保留**，旧配置零影响
- ✅ 新增可选字段 `compaction: Option<CompactionConfig> = None`；`fromJson` 兼容两种来源：读到 `compaction` 对象用嵌套配置，否则回退平铺字段
- `None` 且未配置模板 = 现有行为（本地估算 + 占位文本），渐进式启用——✅ 已实现（配置合并逻辑：嵌套优先、平铺兜底；不配置时与 P4 前行为等价）

---

## 五、MCP 工具集成

### 5.1 现状：启动连接 + 激活过滤（✅ P1 已实现）

`McpManager.addServer(toolRegistry, cfg)`（server 启动阶段调用）——**连接保留**（连接不占 LLM token），但工具定义**不再直接进入 LLM tools 段**：

```
1. createTransport(cfg)：stdio / streamable-http / session-http 三种传输
2. McpClient.connect(info) → listTools()
3. 每个工具包装为 MCPToolWrapper，注册名 mcp_<server>_<tool>（如 mcp_github_search_repos）
4. clients[cfg.name] = client（持有连接）+ 缓存协议信息（serverInfo.version + 工具数 + 工具名/描述目录）
```

- 配置来源：`server/config.cj` 的 `TomlMcpServer`（name/transport/command/url/headers），经 `server/handler.cj` 在服务启动时注入
- 服务名**不允许含下划线**（registerServer/addServer 校验拒绝）——工具名 `mcp_<server>_<tool>` 靠前缀解析服务名，下划线会歧义
- 连接失败的服务：启动时 log 警告，`load_mcp_toolset` 时报"未连接"

### 5.2 ✅ P1 已实现：按服务激活（load_mcp_toolset）

**目标**：减少 LLM 请求 tools 定义段的 token——`resolveTools` 只暴露**已激活**且未过冷却期的服务工具。

| 对比项 | 全量暴露（P1 前） | 按服务激活（P1） |
|--------|------------------|--------------------|
| tools 定义段 Token | ❌ 极高（所有工具 schema） | ✅ 只有激活服务的工具 |
| 激活延迟 | ✅ 无 | ⚠️ 一次 `load_mcp_toolset` 调用（纯状态翻转，无网络） |
| 缓存命中率 | ❌ 差（工具多易变动） | ✅ 高 |

**实现要点**：

- ✅ `load_mcp_toolset(server_id)` 工具（tool/load_mcp_toolset.cj）：**纯激活无网络**——校验服务存在（"未知"）→ 检查已连接（"未连接"）→ 激活 → 返回工具清单；幂等（已激活直接返回）；缺参/错误返回 `(Bool, String)` 结构化结果
- ✅ 激活状态机（进程级、不持久化，McpManager 持有）：`activeServers`/`lastUsed`/`turnCounter` + Mutex 锁（HTTP 并发安全）；`resolveTools` 的 `_*` 通配展开按 `isActiveTool(name, cooldownTurns)` 过滤
- ✅ **冷却自动卸载为 agent 级配置、默认关闭**：`AgentConfig.mcpCooldownTurns`（0=永不卸载；>0=N 轮未用自动卸载）；TOML `[[agent]] mcpCooldownTurns` + HTTP DTO 均可配置；`isActiveTool` 对非 mcp 工具名恒返回 true（不受冷却管辖）
- ✅ 使用标记：mcp 工具真实执行后 `markUsedTool(toolName)` 刷新冷却（hook 拒绝/信任拒绝/超限跳过的工具不刷新）
- ✅ 系统提示目录段（`SystemPromptBuilder.buildMcpCatalog`）：全部服务（含未激活）显示 `- name (v<version>, N 个工具)` + 工具名/描述列表（启动已缓存）；激活服务标注 `[已加载]`；引导语提示调用 `load_mcp_toolset(server_id)`
- ✅ 子 agent（AgentTool）共享同一 McpManager（父子激活状态一致）
- 命名空间 `mcp_<server>_<name>` 保持不变，与 `resolveTools()` 的 `_*` 通配符兼容

---

## 六、Skills 系统

### 6.1 现状：配置声明 + 全量注入（✅ skill/ 目录 + runtime 注入）

**加载链路**（✅ skill/loader.cj + validator.cj + registry.cj）：

```
SkillLoader.loadDir(dir)      // 扫描目录，每个子目录视为一个 Skill
  └─ loadSkill(dir)           // 解析 SKILL.md：frontmatter + body
       ├─ SkillValidator       // 校验 name/description 必填、frontmatter 闭合
       └─ SkillRegistry.register // name → Skill 注册表（后注册覆盖）
```

**Skill 数据模型**（✅ skill/interface.cj）：

```cangjie
public struct Skill {
    public let name: String             // 全小写+连字符
    public let description: String      // 做什么 + 何时使用
    public let license: Option<String>
    public let compatibility: Option<String>
    public let metadata: HashMap<String, String>
    public let allowedTools: ArrayList<String>  // 实验性
    public let instructions: String     // SKILL.md body
    public let dirPath: String
}
```

**注入方式**（✅ SystemPromptBuilder.build 第 2 段）：`config.skills` 声明哪些 Skill 启用，运行时把其 `instructions` **全量拼入系统提示**。

**当前局限（P2 已部分缓解）**：

- 静态声明（AgentConfig.skills）仍为唯一自动注入方式——✅ P2 起 AI 可通过 `[可用 Skills]` 目录 + `use_skills(name)` 动态加载未声明的 Skill
- 全量注入（config.skills 声明的 Skill 固定占 token）——保留为兼容路径，新 Skill 走动态加载

### 6.2 ✅ P2 已实现：渐进式披露（方案 B：工具结果即指令）

规范三层披露（AgentSkills），P2 落地第 1、2 层：

| 层级 | Token | 机制 | 落地 |
|------|-------|------|------|
| 第 1 层：Metadata | ~100 | 全部 Skill 的 name+description 常驻系统提示（目录段） | ✅ `SystemPromptBuilder.buildSkillCatalog`：`[可用 Skills]` 段（name+description+`use_skills` 引导语），ContextBuilder.initMessages 拼接 |
| 第 2 层：Instructions | <5000 | Skill 激活时加载完整 SKILL.md body | ✅ `use_skills(name)` 工具：返回指令全文作为**工具结果**，进入对话历史立即生效 |
| 第 3 层：Resources | 按需 | scripts/references/assets 需要时读取 | 🚧 后续 |

**关键设计：工具结果即指令（无激活状态）**

- `use_skills(name)`（✅ tool/builtin/use_skills.cj）：`SkillRegistry.get(name)` 命中 → `ToolResult("# Skill: " + name + "\n\n" + instructions)`；未知名报错；缺参报错；幂等（重复调用返回同样指令）
- **无 loadedSkills 状态、无系统提示注入改造**——REPL 每次消息创建新 runtime（无会话对象），状态放进程级会跨 agent 污染、放请求级每次丢失；工具结果进入对话历史，天然按需、天然幂等、跨请求靠会话持久化保持（被压缩 LLM 可再调用）
- `config.skills` 全量注入**保留为兼容路径**（默认常驻技能集），与 use_skills 动态加载并存
- `find_skills` **不实现**（YAGNI——目录段已含检索所需全部信息）
- 冲突处理：同名 Skill 后加载覆盖（与 SkillRegistry 现状一致）；main.cj 启动时注册 UseSkillsTool（serve/repl/run 三模式可用）

---

## 七、事件与钩子（支撑扩展点）

### 7.1 事件流（✅ agent/event.cj + event/event.cj）

`EventStream<AgentEvent, R>`：Agent/Turn/Message/ToolExecution/Compaction 五级事件，结果与事件通道分离。上下文相关事件：`CompactionEvent(reason, tokensBefore, tokensAfter)`。

### 7.2 决策型钩子（✅ agent/hook.cj + hook_decision.cj）

钩子是上下文构建的**扩展闸门**，6 个相位，注册序 = 执行序：

| 相位 | 决策 | 对上下文的影响 |
|------|------|----------------|
| `beforeRun` / `afterRun` | — | 观察 |
| `beforeTurn` | `Continue(request)/ShortCircuit` | 可改写 ChatRequest（含 messages 同步回运行时，防分叉） |
| `afterTurn` | `AfterTurnUpdate{messages, shortCircuit}` | **可整体改写上下文消息**（在压缩之前） |
| `beforeTool` | `Allow/Deny/Modify` | 可改写工具参数（信任闸门之后） |
| `afterTool` | — | 观察工具结果 |

**融合顺序**：工具执行前信任闸门先判 → beforeTool 再判；每轮结束 afterTurn hook 先改写 → compaction 再压缩。

---

## 八、总览：一次完整请求的链路

```
用户输入
    │
    ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 1. 调用方（REPL / HTTP / 库）                                      │
│    → sessionStore.appendBranch(sessionId, leafId, [user_msg])  ← L1 写入│
└─────────────────────────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 2. AgentRuntime.chatWithEnv(messages, sessionEnv)                  │
│    ├─ ContextBuilder.initMessages() ← SystemPromptBuilder.build（4 段）│
│    ├─ 系统提示作首条 UserMessage 注入（非空才注入）                 │
│    ├─ resolveTools()               ← config.tools → ToolRegistry    │
│    └─ ChatRequest {model, messages, tools} → Provider.chatStreaming()│
└─────────────────────────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 3. LLM 返回                                                        │
│    ├─ 文本回复（end_turn）→ afterTurn hooks → compactMessages()    │
│    │     → 结果经 EventStream 返回给调用方                        │
│    ├─ 工具调用（tool_use）→ 信任闸门 → beforeTool hooks → 执行 →   │
│    │     ToolResultMessage 追加 → 下一轮（回到步骤 2）              │
│    └─ length/error → 终止 run                                     │
└─────────────────────────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 4. 调用方持久化（可选）：save() / appendBranch() 把结果写回 L1     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 九、模块职责与演进清单

### 9.1 模块职责卡片

| 模块 | 状态 | 职责 | 关键接口 |
|------|------|------|----------|
| `session/store.cj` | ✅ | L1 存储抽象，只增不改 | `save / appendBranch / loadEntries / fork` |
| `session/file_store.cj` | ✅ | bstorm 持久化（默认后端） | `StormSessionStore` |
| `session/memory_store.cj` | ✅ | 内存实现 | `MemoryStore` |
| `agent/runtime.cj` | ✅ | 推理循环 + 工具解析（L2 委托 ContextBuilder） | `chatWithEnv / resolveTools` |
| `context/compaction.cj` | ✅ | 上下文压缩 + 可配置模板（✅ P4） | `compactMessages / compactWithSummary / renderCompactionPrompt / validateSummary / CompactionConfig` |
| `context/tokens.cj` | ✅ | Token 本地估算 | `estimateTokens` |
| `context/model_registry.cj` | ✅ | 模型上下文窗口查表 | `ModelContextRegistry.get` |
| `tool/mcp_manager.cj` | ✅ | MCP 启动连接 + 协议/工具目录缓存 + 激活状态机（Mutex） | `addServer / registerServer / loadToolset / isActiveTool / markUsedTool` |
| `tool/mcp_tool.cj` | ✅ | MCP 工具适配 | `MCPToolWrapper` |
| `skill/loader.cj` | ✅ | SKILL.md 解析加载 | `SkillLoader.loadDir / loadSkill` |
| `skill/validator.cj` | ✅ | frontmatter 校验 | `SkillValidator.validate` |
| `skill/registry.cj` | ✅ | Skill 注册表 | `register / get / list / loadDirectory` |
| `agent/hook*.cj` | ✅ | 决策型拦截器（上下文闸门） | `beforeTurn / afterTurn / beforeTool / afterTool` |
| `context/builder.cj` | ✅ | L2 上下文构建器（系统提示注入 + 历史组装 + ChatRequest） | `initMessages / buildChatRequest` |
| `context/system_prompt_builder.cj` | ✅ | 系统提示分段构建（4 段：systemPrompt/Skills/AGENTS.md/SessionContext） | `build` |
| `tool/archive_history.cj` | ✅ | AI 自主归档（校验 + 确认；run 内应用） | `execute(start, end, summary)` |
| `tool/load_mcp_toolset.cj` | ✅ | MCP 按服务激活（纯状态翻转，无网络） | `execute(server_id)` |
| `tool/builtin/use_skills.cj` | 🚧 | Skill 按需激活（渐进披露第 2 层） | `execute(name)` |
| `tool/builtin/use_skills.cj` | ✅ | Skill 按需加载（工具结果即指令） | `execute(name)` |

### 9.2 演进路线（按依赖排序）

1. **ContextBuilder + SystemPromptBuilder 抽取**：从 `runtime.cj` 抽出独立构建器与系统提示分段构建器，补单元测试（不改变行为）
2. **MCP 按服务加载**：服务目录注入 system prompt → `load_mcp_toolset` 工具 → 会话级 `activeMcpServers` 状态 → 冷却期卸载
3. **Skills 渐进式披露**：目录（name+description）注入 → `use_skills` 工具激活 → （可选）`find_skills`
4. **AI 自主归档**：Message 密封接口新增 `ArchiveMessage` 实现类（Entry 零改动）→ `archive_history` 工具 → L2 解析标记
5. **压缩增强**：Provider 用量优先 + LLM 结构化摘要 + 可配置模板（`CompactionConfig`，独立子调用不污染主缓存；与归档工具互补，见 4.3）

### 9.3 设计哲学

| 原则 | 体现 |
|------|------|
| **读写分离** | L1 存储只增不改，L2 上下文每次动态构建 |
| **判断权交给 AI** | 归档、加载 MCP 服务、激活 Skill 均由 LLM 自主决策 |
| **渐进式披露** | 服务目录（轻量）→ 按需加载工具定义 / Skill 指令（重量），Token 最优 |
| **缓存友好** | 系统提示固定前缀 + 动态后缀，最大化缓存命中 |
| **容错加载** | Skill 一个坏了不影响其他（loadDir 逐目录 try/catch），MCP 一个服务挂了不影响主循环 |

---

## 十、任务阶段设计

### 10.1 阶段依赖图

```
P0  构建器抽取（ContextBuilder + SystemPromptBuilder）
│   └─ 无依赖，先行；后续所有阶段的地基
│
├─→ P1  MCP 按服务加载          （依赖 P0 的 withMcpCatalog）
├─→ P2  Skills 渐进式披露        （依赖 P0 的 withSkillCatalog）
└─→ P3  AI 自主归档              （依赖 P0 的 ContextBuilder 解析）
        │
        └─→ P4  压缩增强          （依赖 P3：LLM 摘要与归档互补）
```

P1 / P2 / P3 **互不依赖，可并行**；P4 依赖 P3，排在最后。每个阶段独立提交、独立跑全量测试（当前基线：148 PASSED + 6 SKIPPED）。

### 10.2 P0：构建器抽取（无依赖，先行）

> ✅ 已完成（2026-08-09）

**目标**：从 `runtime.cj` 抽出 `ContextBuilder` 与 `SystemPromptBuilder`，行为不变，为后续阶段提供挂载点。

**任务**：

1. 新建 `src/context/system_prompt_builder.cj`：分段构建（现状 4 段：systemPrompt / skills 指令 / AGENTS.md / Session Context），对应现有 `buildSystemPromptWithEnv` 行为
2. 新建 `src/context/builder.cj`：`ContextBuilder.build(config, leafId) → ChatRequest`，收拢系统提示 + 历史消息 + 工具定义组装
3. `runtime.cj` 改为委托调用，删除内联构建逻辑

**验收**：现有 148 测试全绿（行为零变化）；新增构建器单元测试（分段顺序、空段跳过、`[Project Rules]`/`[Session Context]` 格式、无 AGENTS.md 时不挂段）。

### 10.3 P1：MCP 按服务加载（依赖 P0）✅ 已完成（2026-08-09）

**目标**：减少 LLM tools 定义段 token——启动连接保留（连接不占 token 且能缓存协议信息），`resolveTools` 只暴露已激活且未过冷却期的服务工具。

**任务**（实施记录，与设计 5.2 一致）：

1. `SystemPromptBuilder.buildMcpCatalog(mcpManager)`：目录段（全部服务显示 name (version, N 工具) + 工具名/描述，激活标注 [已加载]，含 `load_mcp_toolset` 引导语）
2. `McpManager` 增强：addServer 连接成功后缓存协议信息（version/工具数/工具目录）；激活状态机（进程级 + Mutex）；loadToolset 纯激活（无网络，返回 (Bool, String)）
3. 新建 `tool/load_mcp_toolset.cj` 工具：校验存在 → 检查连接 → 激活 → 返回工具清单；幂等
4. `AgentRuntime` 持有 McpManager：每轮 advanceTurn、`resolveTools()` 按 `isActiveTool(name, config.mcpCooldownTurns)` 过滤、工具执行后 markUsedTool；**冷却为 agent 级配置默认关闭**（`AgentConfig.mcpCooldownTurns`，0=不启用，TOML/DTO 可配）
5. 工具名需加入 `config.tools` 白名单（`mcp_*` 通配）才能被 LLM 调用；`load_mcp_toolset` 工具在 main.cj 启动时注册

**验收**（全部通过）：McpManager 14 单测（状态机/缓存/校验/幂等）+ LoadMcpToolsetTool 3 单测 + 目录段 5 单测 + runtime_test.cj 3 集成测试（未激活过滤/激活可见/冷却过期）+ config 3 测试；全量 191 PASSED + 6 SKIPPED。

### 10.4 P2：Skills 渐进式披露（依赖 P0，可与 P1/P3 并行）✅ 已完成（2026-08-09）

**目标**：从"config.skills 静态全量注入"升级为"目录常驻 + `use_skills` 按需激活"。

**任务**（实施记录，方案 B 与设计 6.2 一致）：

1. `SystemPromptBuilder.buildSkillCatalog(skillRegistry)`：目录段（`[可用 Skills]` + name/description + `use_skills` 引导语），ContextBuilder.initMessages 拼接
2. 新建 `tool/builtin/use_skills.cj`：按名加载，**工具结果即指令全文**（进入对话历史立即生效）；未知 skill 报错；缺参报错；幂等
3. `find_skills` **不实现**（YAGNI，目录段已含检索信息）
4. **无 loadedSkills 状态**（REPL 每次消息新建 runtime 无会话对象；工具结果方案无需状态）；`config.skills` 全量注入保留兼容路径
5. main.cj 启动注册 UseSkillsTool（serve/repl/run 三模式可用）

**验收**（全部通过）：UseSkillsTool 3 单测（指令返回/未知报错/缺参报错）+ 目录段 3 单测（含引导语与 name/description、无 skill 空、ContextBuilder 首条含目录段）；config.skills 兼容无回归；全量 197 PASSED + 6 SKIPPED。

### 10.5 P3：AI 自主归档（依赖 P0，可与 P1/P2 并行）✅ 已完成（2026-08-09）

**目标**：LLM 通过 `archive_history` 自主压缩历史，判断权交给 AI，代码只做校验与容错。

**任务**（实施记录，与设计 4.2 一致）：

1. Message 密封接口新增 `ArchiveMessage {startIndex, endIndex, summary, timestamp}`（第 5 角色）；`serialize.cj` 加 case，旧文件兼容
2. 新建 `tool/archive_history.cj`：校验（start ≥ 0 / end ≥ start / summary 非空）→ 返回归档确认；**不碰 store**（run 内应用）
3. `ContextBuilder.applyArchives`：调用对扫描 → 范围钳制（上限 = 调用对前一条）→ 替换为 ArchiveMessage → 调用对移除（幂等）；runtime 每轮应用
4. 三 Provider 消息转换加 ArchiveMessage case（`[Archived <start>-<end>: <summary>]`）
5. 🚧 后续演进：严格 L1 追加（appendBranch）需 runtime 会话链路（sessionId/parentLeafId）

**验收**：单元测试覆盖——序列化往返（新消息类型 + 旧文件兼容）、范围校验边界（负值/越界/倒序）、解析后消息替换正确、多条归档叠加、store 追加语义（原消息仍在 L1）。

### 10.6 P4：压缩增强（依赖 P3）✅ 已完成（2026-08-09）

**目标**：压缩判定更准、摘要更有用、摘要格式可配置。设计细节见 4.3。

**任务**（实施记录）：

1. Provider 用量优先：`assistantMsg.usage.inputTokens > 0` 优先，本地估算兜底（✅）
2. `CompactionConfig` 结构（✅ 实现 JsonSerializable & JsonDeserializable）+ `AgentConfig.compaction: Option<CompactionConfig>`（✅ 平铺保留，fromJson 双来源兼容；stdx readValue<Option<JsonValue>> bug 手写绕过）
3. 模板渲染（✅ mustache 1.2.1）：`CompactionContext <: MustacheComponent` + `Template.parse/render`，`{{#previous_summary}}` 由 truth() 保证
4. 独立子调用（✅）：`provider.chat(ChatRequest(summaryModel ?? 主模型, [UserMessage(prompt)], 0.2, reserveTokens, None, []))`；异常/schema 校验失败 → 占位降级
5. 极简 outputSchema 校验（✅ `validateSummary`：{required, types} 五类型断言）
6. 附带修复：`compactMessages`/`compactWithSummary` **切点 bug**（单条消息超预算时 i 越界到 -1、cutIndex=0 误判不压缩）——达标 break + i<0 判断；`TokenUsage` 字段补 public

**验收**（全部通过）：有 usage 按实际值判定、无 usage 回退本地估算；模板变量/条件块渲染；schema 通过/类型不符/缺必填/解析失败四类；子调用异常降级；旧配置（无 compaction 字段）加载后行为不变；5 个 runtime 集成测试（嵌套优先/两条降级路径/用量优先/不触发等价）+ 3 个切点回归；全量 226 PASSED + 6 SKIPPED。

### 10.7 执行约定

- 每阶段按「新功能先写单元测试 → 全量 `cjpm test -j 16 --no-progress` 通过 → 独立提交」推进
- 每阶段完成一个功能分支（`feat/<name>`），合并 master 后进入下一阶段
- 阶段内任务粒度细化到具体测试用例在实施计划（`docs/plans/YYYY-MM-DD-<phase>-plan.md`）中展开，执行时遵循 writing-plans 的 TDD 节奏

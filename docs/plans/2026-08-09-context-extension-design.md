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
│ [固定] Skills 指令（config.skills 全量注入）          │  ← 现状；🚧 演进为目录 + use_skills 激活
├──────────────────────────────────────────────────────┤
│ [动态] [Project Rules] 工作目录 AGENTS.md             │  ← 会话级变动，挂末尾
│ [动态] [Session Context] env.context 键值对           │  ← 会话级变动
│ [动态] [可用 MCP 服务] 服务目录（演进，第五章）        │  ← 会话级变动
│ [动态] [可用 Skills] 目录（演进，第七章）              │  ← 会话级变动
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

### 4.2 🚧 演进：AI 自主归档（archive_history 工具）

由 LLM 判断"哪些历史可以归档"（代码无法判断语义），调用 `archive_history(start_index, end_index, summary)` 工具。

**实现要点（基于现有 Message 密封接口，不动 Entry 结构）**：

- Message 密封接口（User/Assistant/ToolResult/Compaction）是既定扩展点 → 🚧 新增第 5 个实现类 `ArchiveMessage {startIndex, endIndex, summary, timestamp}`（对应参考设计里的 archiveMarker，但**不新增 Entry 字段、不引入 system_internal 角色**）
- `archive_history` 工具执行时在 L1 追加一条 `ArchiveMessage` 的 Entry（只增不改，不删旧数据）
- L2 构建时解析：范围内（startIndex..endIndex，按 Entry 顺序全局序号）的原始消息跳过，插入摘要消息
- 影响面最小：`serialize.cj` 的 `readMessageFromJson` 加一个 case，store 零改动
- `startIndex/endIndex` 使用 Entry 在会话中的顺序序号（现有 `Entry.id` 形如 `sess_0_3`，序号可解析，🚧 演进时也可给 Entry 加只读序号视图，不改存储格式）

| 方案 | 判断主体 | 准确度 | 实现复杂度 |
|------|----------|--------|------------|
| 规则引擎 | 代码 | ❌ 无法判断语义 | 低 |
| AI 自主归档 | LLM | ✅ 理解上下文语义 | 低（只加一个工具） |

### 4.3 🚧 演进：可配置压缩模板（独立子调用）

**动机**：不同业务场景对摘要粒度需求不同（法律文书要 `cited_laws`，代码场景要 `files_modified`/报错栈）。压缩发生在**独立的 LLM 子调用**中——请求体与主对话完全不同（无 system/tools，仅一条 user 消息），缓存 Key 独立，**修改压缩模板不影响主对话的 DeepSeek 缓存命中率**。

**配置结构**（🚧 新建 `context/compaction.cj` 的 `CompactionConfig`，伪代码示意）：

```cangjie
// context/compaction.cj（演进方向）
public struct CompactionConfig {
    public let enabled: Bool = true                 // 与现有 compactionEnabled 语义一致
    public let reserveTokens: UInt32 = 16384        // 与现有 compactionReserveTokens 语义一致
    public let keepRecentTokens: UInt32 = 20000     // 与现有 keepRecentTokens 语义一致
    public let promptTemplate: String = DEFAULT_PROMPT_TEMPLATE  // 压缩提示词模板
    public let outputSchema: Option<JsonValue> = None            // 极简输出约束（见下）
    public let summaryModel: Option<String> = None               // 摘要模型，None = 复用主模型
}
```

**模板变量与条件块**（✅ 使用现成模板引擎 `mustache-cj`，不自研）：

| 语法 | 说明 |
|------|------|
| `{{conversation}}` | 待压缩的对话文本（必填） |
| `{{previous_summary}}` | 历史摘要（可选，首次压缩不存在） |
| `{{max_tokens}}` | 摘要输出上限（= reserveTokens） |
| `{{#previous_summary}}...{{/previous_summary}}` | 条件块（section）：变量存在且非空才渲染，否则整块忽略 |

- **引擎**：`mustache-cj`（中心仓 `mustache`，v1.0.3，cjc 适配版本实施时验证）。标准 mustache 语法，支持 Dotted Names / Sections（list、if、inverted）/ Comments
- **条件语义**：`truth()` 判定 None / 空串 / 空列表 / false → 不渲染（mustache.cj:249），正是 `{{#previous_summary}}` 所需
- **上下文注入**：自定义 `CompactionContext` 结构实现 `MustacheComponent` 接口（README 推荐方式），`mustache()` 返回 `DataModelStruct {conversation, previous_summary?, max_tokens}`，经 `Template.parse(template)` + `render(context)` 渲染
- **容错**：变量缺失时引擎静默忽略（silentMiss），无需自研容错与替换顺序处理

**outputSchema：极简校验，不引完整 JSON Schema**（jsonvalue 无 schema 校验能力，自研完整标准是大工程，YAGNI）：

- 配置格式：`{required: ["goal", "key_findings"], types: {"goal": "string", "key_findings": "array"}}`
- 校验逻辑：解析为 `JsonValue` → 必填键存在 + 类型断言（复用 `cast<T>()` 风格）
- 校验失败：记录日志、**降级使用原始文本摘要**（不中断主循环）

**独立子调用**（复用现有 `Provider.chat(req)` 非流式接口，请求体无 system、无 tools）：

```
调用链：
runtime afterTurn 压缩触发（runtime.cj:322 现调用点）
  → 判定：Provider 用量（usage.promptTokens）优先，本地估算兜底
  → 渲染 promptTemplate（conversation = 待压缩消息文本）
  → provider.chat(ChatRequest(summaryModel ?? 主模型, [UserMessage(prompt)],
      temperature: 0.2, maxTokens: reserveTokens, tools: []))
  → 取 ChatResponse.message.content → 生成 CompactionMessage(summary, tokensBefore, 0)
  → outputSchema 校验失败则降级原文
```

**与 AgentConfig 的兼容策略**（防序列化大改）：

- `AgentConfig` 现有三个平铺字段（`compactionEnabled`/`compactionReserveTokens`/`keepRecentTokens`）**保留**，旧配置零影响
- 🚧 新增可选字段 `compaction: Option<CompactionConfig> = None`；`fromJson` 兼容两种来源：读到 `compaction` 对象用嵌套配置，否则回退平铺字段
- `None` 且未配置模板 = 现有行为（本地估算 + 占位文本），渐进式启用

---

## 五、MCP 工具集成

### 5.1 现状：启动时全量连接 + 全量注册（✅ tool/mcp_manager.cj + mcp_tool.cj）

`McpManager.addServer(toolRegistry, cfg)`（server 启动阶段调用）：

```
1. createTransport(cfg)：stdio / streamable-http / session-http 三种传输
2. McpClient.connect(info) → listTools()
3. 每个工具包装为 MCPToolWrapper，注册名 mcp_<server>_<tool>（如 mcp_github_search_repos）
4. clients[cfg.name] = client（持有连接）
```

- 工具定义在连接时全量拉取、全量注册到 `ToolRegistry`，**没有按需加载**（全量摊平）
- 配置来源：`server/config.cj` 的 `TomlMcpServer`（name/transport/command/url/headers），经 `server/handler.cj` 在服务启动时注入

### 5.2 🚧 演进：按服务加载（load_mcp_toolset）

对照参考设计的"渐进式披露"：

| 对比项 | 全量摊平（现状） | 按服务加载（演进） |
|--------|------------------|--------------------|
| 初始 Token | ❌ 极高（所有工具定义） | ✅ 极低（只有服务名+描述目录） |
| 首次使用工具延迟 | ✅ 无 | ⚠️ 一次 `load_mcp_toolset` 调用 |
| 缓存命中率 | ❌ 差（工具多易变动） | ✅ 高（只加载需要的服务） |

演进要点：

- 系统提示注入 **MCP 服务目录**（服务名 + 描述 + 工具数，轻量）
- 🚧 新工具 `load_mcp_toolset(server_id)`：建立连接 → 拉取工具列表 → 注册 `mcp_<server>_<name>` → 返回工具清单（复用现有 `McpManager` + `MCPToolWrapper`，🚧 给 McpManager 增加按需注册方法，不重写连接管理）
- 🚧 会话级状态 `activeMcpServers: Set<String>` 与冷却轮次统计——**运行时状态、不持久化**：放 `AgentRuntime`（或演进后的 `ContextBuilder`）字段，**不改 SessionHeader/Entry 的持久化格式**（参考设计的 `Session.activeMcpServers/serverLastUsed` 落在持久化模型上，会造成序列化大改，不采用）
- 命名空间 `mcp_<server>_<name>` 保持不变，与现有 `resolveTools()` 的 `_*` 通配符兼容

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

**当前局限**：

- 静态声明（AgentConfig.skills），AI 无法自行发现/激活新 Skill
- 全量注入（即使某个 Skill 本轮用不到也占 token）
- 无 Skill 目录（name+description）注入，AI 不知道"有什么可用"

### 6.2 🚧 演进：渐进式披露（对齐 AgentSkills 规范）

规范三层披露，对应两种工具，**核心是 `use_skills`**：

| 层级 | Token | 机制 | 工具 |
|------|-------|------|------|
| 第 1 层：Metadata | ~100 | 全部 Skill 的 name+description 常驻系统提示（目录） | `find_skills`（可选，动态检索） |
| 第 2 层：Instructions | <5000 | Skill 激活时注入完整 SKILL.md body | **`use_skills(name)`**（必选） |
| 第 3 层：Resources | 按需 | scripts/references/assets 需要时读取 | — |

```cangjie
// 🚧 tool/builtin/use_skills.cj（演进方向）
public class UseSkillsTool <: Tool {
    public func name() { "use_skills" }
    public func description() {
        "按名称激活一个 Skill，将 SKILL.md 完整指令注入后续上下文。"
        "参数: name: String（技能名，如 \"data-cleaning\"）"
    }
    // execute: registry.get(name) → 返回 Skill 指令 + 目录，并记录激活状态
}

// 🚧 tool/builtin/find_skills.cj（演进方向，可选）
public class FindSkillsTool <: Tool {
    public func name() { "find_skills" }
    // execute: 列出全部 Skill 的 name + description，支持关键词过滤
}
```

**挂载方式取舍**：

| 方式 | 结论 |
|------|------|
| 工具调用（use_skills） | ✅ 主路线：AI 按需激活，token 最优，与 MCP 按需加载一致 |
| 斜杠命令 `/skill` | ✅ 用户主动触发（REPL 层，与 `/tools` 等命令并列） |
| 自动匹配（现 config.skills 静态注入） | ⚠️ 保留为"默认常驻"技能集，与 use_skills 并存 |

**冲突处理**：同名 Skill 用户自定义 > 内置（后加载覆盖，与 SkillRegistry 现状一致）；项目本地 > 全局（扫描目录优先级）。

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
| `context/compaction.cj` | ✅ | 上下文压缩（🚧 + `CompactionConfig` 可配置模板） | `compactMessages` |
| `context/tokens.cj` | ✅ | Token 本地估算 | `estimateTokens` |
| `context/model_registry.cj` | ✅ | 模型上下文窗口查表 | `ModelContextRegistry.get` |
| `tool/mcp_manager.cj` | ✅ | MCP 全量连接 + 工具注册 | `McpManager.addServer` |
| `tool/mcp_tool.cj` | ✅ | MCP 工具适配 | `MCPToolWrapper` |
| `skill/loader.cj` | ✅ | SKILL.md 解析加载 | `SkillLoader.loadDir / loadSkill` |
| `skill/validator.cj` | ✅ | frontmatter 校验 | `SkillValidator.validate` |
| `skill/registry.cj` | ✅ | Skill 注册表 | `register / get / list / loadDirectory` |
| `agent/hook*.cj` | ✅ | 决策型拦截器（上下文闸门） | `beforeTurn / afterTurn / beforeTool / afterTool` |
| `context/builder.cj` | ✅ | L2 上下文构建器（系统提示注入 + 历史组装 + ChatRequest） | `initMessages / buildChatRequest` |
| `context/system_prompt_builder.cj` | ✅ | 系统提示分段构建（4 段：systemPrompt/Skills/AGENTS.md/SessionContext） | `build` |
| `tool/archive_history.cj` | 🚧 | AI 自主归档（LLM 摘要落 L1） | `execute(start, end, summary)` |
| `tool/load_mcp_toolset.cj` | 🚧 | MCP 按服务加载 | `execute(server_id)` |
| `tool/builtin/use_skills.cj` | 🚧 | Skill 按需激活（渐进披露第 2 层） | `execute(name)` |
| `tool/builtin/find_skills.cj` | 🚧 | Skill 检索（第 1 层辅助） | `execute(keyword?)` |

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

### 10.3 P1：MCP 按服务加载（依赖 P0）

**目标**：从"启动全量注册"改为"目录 + 按需加载"，Token 最优。

**任务**：

1. `SystemPromptBuilder.withMcpCatalog(servers)`：注入服务目录段（服务名 + 描述 + 工具数 + `load_mcp_toolset` 引导语）
2. `McpManager` 增加按需注册方法（复用现有 connect/listTools/MCPToolWrapper，不重写连接管理）
3. 新建 `tool/load_mcp_toolset.cj` 工具：校验服务存在 → 连接 → 注册 `mcp_<server>_<name>` → 返回工具清单
4. `AgentRuntime` 增加会话级状态 `activeMcpServers: Set<String>` 与 `serverLastUsed`（运行时、不持久化）；`resolveTools()` 按激活状态过滤 + 冷却期（20 轮）自动卸载
5. 工具名需加入 `config.tools` 白名单才能被 LLM 调用（现有 `resolveTools` 机制），文档化配置方式

**验收**：单元测试覆盖——未激活服务工具不在列表、`load_mcp_toolset` 后出现、重复加载幂等、冷却期后自动卸载、未知服务报错；集成测试可沿用现有 `ProviderIntegrationTest` 标签模式跳过网络。

### 10.4 P2：Skills 渐进式披露（依赖 P0，可与 P1/P3 并行）

**目标**：从"config.skills 静态全量注入"改为"目录常驻 + `use_skills` 按需激活"。

**任务**：

1. `SystemPromptBuilder.withSkillCatalog(catalog)`：注入 Skill 目录段（name + description + `use_skills` 引导语）；现状的 `withSkillsInstructions`（全量指令）保留为兼容路径
2. 新建 `tool/builtin/use_skills.cj`：按名激活，返回 SKILL.md 指令 + 目录，记录激活状态；未知 skill 报错；重复激活幂等
3. （可选）`tool/builtin/find_skills.cj`：关键词过滤列出目录
4. `AgentRuntime` 会话级 `loadedSkills` 状态（运行时、不持久化）；激活后的指令注入后续轮次系统提示

**验收**：单元测试覆盖——目录段格式、激活后指令进入上下文、幂等、未知名报错、config.skills 旧方式仍工作（兼容）；补 skills 相关回归测试。

### 10.5 P3：AI 自主归档（依赖 P0，可与 P1/P2 并行）

**目标**：LLM 通过 `archive_history` 自主压缩历史，L1 只增不改。

**任务**：

1. Message 密封接口新增 `ArchiveMessage {startIndex, endIndex, summary, timestamp}`；`serialize.cj` 的 `readMessageFromJson`/`Entry.toJson` 加分支（旧文件加载不受影响）
2. 新建 `tool/archive_history.cj`：校验范围（0 ≤ start ≤ end < 当前消息数）→ `store.appendBranch` 追加 ArchiveMessage Entry → 返回确认
3. `ContextBuilder` 解析归档标记：范围内消息跳过，插入摘要；范围外的旧归档标记（startIndex 变化后）按"仅跳过未越界部分"容错

**验收**：单元测试覆盖——序列化往返（新消息类型 + 旧文件兼容）、范围校验边界（负值/越界/倒序）、解析后消息替换正确、多条归档叠加、store 追加语义（原消息仍在 L1）。

### 10.6 P4：压缩增强（依赖 P3）

**目标**：压缩判定更准、摘要更有用、摘要格式可配置。设计细节见 4.3。

**任务**：

1. Provider 用量优先：`ChatResponse.message.usage.promptTokens`（openai.cj:67 已解析）优先于本地估算触发判定（`compactMessages` 增加入参或改造判定入口）
2. `CompactionConfig` 结构 + `AgentConfig.compaction: Option<CompactionConfig>` 可选字段（平铺三字段保留，fromJson 双来源兼容）
3. 模板渲染：接入 `mustache-cj`（cjpm.toml 加依赖）——`CompactionContext` 结构实现 `MustacheComponent` + `Template.parse/render`，`{{#previous_summary}}` 条件块语义由引擎 `truth()` 保证，补单元测试
4. 独立子调用：压缩触发时 `provider.chat(ChatRequest(summaryModel ?? 主模型, [UserMessage(prompt)], 0.2, reserveTokens, []))`，结果生成 `CompactionMessage`；子调用失败/超时回退占位文本
5. 极简 outputSchema 校验：`{required, types}` 解析 + `cast<T>()` 风格断言；失败降级原文摘要

**验收**：单元测试覆盖——有 usage 时按实际值判定、无 usage 时回退本地估算；模板变量插值正确、条件块有无 previous_summary 两种渲染；schema 校验通过/必填缺失/类型不符三类降级；子调用失败回退占位文本（不中断运行）；旧配置（无 compaction 字段）加载后行为不变。

### 10.7 执行约定

- 每阶段按「新功能先写单元测试 → 全量 `cjpm test -j 16 --no-progress` 通过 → 独立提交」推进
- 每阶段完成一个功能分支（`feat/<name>`），合并 master 后进入下一阶段
- 阶段内任务粒度细化到具体测试用例在实施计划（`docs/plans/YYYY-MM-DD-<phase>-plan.md`）中展开，执行时遵循 writing-plans 的 TDD 节奏

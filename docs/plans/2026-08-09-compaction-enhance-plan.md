# 压缩增强实施计划（P4）

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 压缩判定更准（Provider 用量优先）、摘要更有用（LLM 结构化摘要）、摘要格式可配置（`CompactionConfig` 模板 + 极简 schema 校验）。设计细节见设计文档 4.3。

**Architecture:** `CompactionConfig`（enabled/reserveTokens/keepRecentTokens/promptTemplate/outputSchema/summaryModel）定义在 `context/compaction.cj`；模板渲染用 **mustache-cj v1.2.1**（中心仓已验证，cjpm build success）——`CompactionContext` 实现 `MustacheComponent` 返回 `DataModelStruct`，`{{#previous_summary}}` 条件块由引擎 truth() 保证；`AgentConfig.compaction: Option<CompactionConfig>`（平铺三字段保留，fromJson 双来源兼容）；runtime 压缩调用点改造：用量优先判定（`assistantMsg.usage.inputTokens > 0` 优先，本地估算兜底）→ 超阈值时**独立子调用** `provider.chat(ChatRequest(summaryModel ?? 主模型, [UserMessage(prompt)], 0.2, reserveTokens, None, []))`（无 system/tools，缓存 Key 独立不污染主对话）→ outputSchema 校验失败/异常降级占位文本 → `compactWithSummary` 切点替换；`compactMessages` 保持纯函数不动。

**Tech Stack:** 仓颉（cjpm）、mustache 1.2.1（已加依赖验证通过）。

**前置：** P3 已合并（master 77c2e44）。分支 feat/compaction-enhance 已开，cjpm.toml 已加 `"mustache" = "1.2.1"` 且 build success。

---

### Task 1: CompactionConfig + 模板渲染 + 极简 schema 校验

**Files:**
- Modify: `src/context/compaction.cj`（CompactionConfig + DEFAULT_PROMPT_TEMPLATE + CompactionContext + renderCompactionPrompt + validateSummary + compactWithSummary）
- Test: `src/context/context_test.cj`（追加）

**Step 1: 写失败测试**

追加到 `src/context/context_test.cj`（package atelier.context；需要 `import atelier.message.*`（已有）+ `import jsonvalue.*`（缺则补）+ `import atelier.session.*`（SessionEnvironment 不需要）；渲染函数签名以 Step 3 为准）：

```cangjie
import jsonvalue.*

@Test
func compactionConfig_defaultTemplateRenders() {
    let cfg = CompactionConfig()
    let out = renderCompactionPrompt(cfg, "对话内容", None, 16384)
    @Expect(out.contains("对话内容"), true)
    @Expect(out.contains("16384"), true)
    @Expect(out.contains("previous_summary"), false)
}

@Test
func compactionConfig_previousSummaryConditional() {
    let cfg = CompactionConfig()
    let out = renderCompactionPrompt(cfg, "对话内容", Some("历史摘要"), 16384)
    @Expect(out.contains("历史摘要"), true)
}

@Test
func compactionConfig_customTemplate() {
    let cfg = CompactionConfig(
        true, 16384, 20000,
        "压缩以下对话：\n{{conversation}}\n{{#previous_summary}}旧摘要：{{previous_summary}}{{/previous_summary}}",
        None, None)
    let out = renderCompactionPrompt(cfg, "对话", Some("旧"), 16384)
    @Expect(out.contains("旧摘要：旧"), true)
    let out2 = renderCompactionPrompt(cfg, "对话", None, 16384)
    @Expect(out2.contains("旧摘要"), false)
}

@Test
func compactionConfig_schemaValid() {
    let cfg = CompactionConfig()
    let schema = JsonValue.parse("{\"required\":[\"goal\"],\"types\":{\"goal\":\"string\"}}")
    match (schema) {
        case JsonValue.Map(m) =>
            @Expect(validateSummary(cfg, m, "{\"goal\":\"完成\"}"), true)
            @Expect(validateSummary(cfg, m, "{\"goal\":123}"), false)
            @Expect(validateSummary(cfg, m, "{\"other\":\"x\"}"), false)
        case _ => @Fail("schema parse failed")
    }
}

@Test
func compactionConfig_noSchemaAlwaysValid() {
    let cfg = CompactionConfig()
    let out = compactWithSummary(ArrayList<Message>([UserMessage(ContentList.ofText("a"), 0)]), 0, "摘要", 10)
    @Expect(out.size, 1)
    match (out[0]) {
        case cm: CompactionMessage => @Expect(cm.summary, "摘要")
        case _ => @Fail("expected CompactionMessage")
    }
}
```

（最后一个测试实际验证 compactWithSummary；若签名不同以 Step 3 为准调整）

**Step 2: 跑测试确认失败**

Run: `cjpm test -j 16 --filter '*compactionConfig*'`
Expected: 编译失败（CompactionConfig/renderCompactionPrompt/validateSummary 未定义）。

**Step 3: 实现**

`src/context/compaction.cj` 追加（文件现有 compactMessages；import 需要加 `import atelier.message.*`（已有？compaction.cj 顶部有 import atelier.message.* ✅）、`import mustache.*`、`import stdx.serialization.serialization.*`（DataModelStruct/Field 等）、`import jsonvalue.*`、`import std.collection.*`（已有））：

```cangjie
import mustache.*
import stdx.serialization.serialization.*

public struct CompactionConfig {
    public let enabled: Bool
    public let reserveTokens: Int64
    public let keepRecentTokens: Int64
    public let promptTemplate: String
    public let outputSchema: Option<JsonValue>
    public let summaryModel: Option<String>

    public init() {
        this.enabled = true
        this.reserveTokens = 16384
        this.keepRecentTokens = 20000
        this.promptTemplate = DEFAULT_PROMPT_TEMPLATE
        this.outputSchema = None
        this.summaryModel = None
    }

    public init(enabled: Bool, reserveTokens: Int64, keepRecentTokens: Int64,
        promptTemplate: String, outputSchema: Option<JsonValue>, summaryModel: Option<String>) {
        this.enabled = enabled
        this.reserveTokens = reserveTokens
        this.keepRecentTokens = keepRecentTokens
        this.promptTemplate = promptTemplate
        this.outputSchema = outputSchema
        this.summaryModel = summaryModel
    }
}

public let DEFAULT_PROMPT_TEMPLATE = """你是一个上下文压缩引擎。请将以下对话压缩成一份结构化的摘要，以便另一个 AI 能够无缝接续工作。

<conversation>
{{conversation}}
</conversation>

{{#previous_summary}}
<previous_summary>
{{previous_summary}}
</previous_summary>
{{/previous_summary}}

输出要求：
1. 严格输出 JSON 格式
2. 必须包含以下字段：
   - goal: 用户的核心目标
   - key_findings: 关键发现列表
   - files_modified: 修改过的文件路径列表
   - errors: 遇到的错误及解决方案
   - pending_actions: 下一步待办事项
3. 不要添加任何额外的解释或散文。"""

// 模板渲染上下文：实现 MustacheComponent（mustache-cj 1.2.1）
public class CompactionContext <: MustacheComponent {
    public let conversation: String
    public let previousSummary: Option<String>
    public let maxTokens: Int64

    public init(conversation: String, previousSummary: Option<String>, maxTokens: Int64) {
        this.conversation = conversation
        this.previousSummary = previousSummary
        this.maxTokens = maxTokens
    }

    public func mustache(): DataModel {
        let sb = DataModelStruct()
        sb.add(field<String>("conversation", this.conversation))
        match (this.previousSummary) {
            case Some(s) => sb.add(field<String>("previous_summary", s))
            case None => ()
        }
        sb.add(field<Int64>("max_tokens", this.maxTokens))
        sb
    }
}

// 渲染压缩提示词（模板 + 变量；无变量时原样返回）
public func renderCompactionPrompt(config: CompactionConfig, conversationText: String,
    previousSummary: Option<String>, maxTokens: Int64): String {
    let template = Template()
    template.parse(config.promptTemplate)
    let ctx = CompactionContext(conversationText, previousSummary, maxTokens)
    let arr = Array<CompactionContext>(1, item: ctx)
    template.render(arr)
}

// 极简 schema 校验：{required: [...], types: {name: "string|array|number|bool|object"}}
// 校验失败/解析失败返回 false（调用方降级原文）
public func validateSummary(config: CompactionConfig, schema: HashMap<String, JsonValue>, text: String): Bool {
    let parsed = try { JsonValue.parse(text) } catch (_) { return false }
    let obj = match (parsed) {
        case JsonValue.Map(m) => m
        case _ => return false
    }
    match (schema.get("required")) {
        case Some(JsonValue.Array(items)) =>
            for (item in items) {
                match (item) {
                    case JsonValue.String(key) =>
                        if (!obj.contains(key)) { return false }
                    case _ => ()
                }
            }
        case _ => ()
    }
    match (schema.get("types")) {
        case Some(JsonValue.Map(types)) =>
            for ((key, typeVal) in types) {
                match (obj.get(key), typeVal) {
                    case (Some(JsonValue.String(_)), JsonValue.String("string")) => ()
                    case (Some(JsonValue.Array(_)), JsonValue.String("array")) => ()
                    case (Some(JsonValue.Number(_)), JsonValue.String("number")) => ()
                    case (Some(JsonValue.Bool(_)), JsonValue.String("bool")) => ()
                    case (Some(JsonValue.Map(_)), JsonValue.String("object")) => ()
                    case (None, _) => ()  // 类型约束仅作用于存在的字段
                    case (Some(_), _) => return false
                }
            }
        case _ => ()
    }
    true
}

// 切点替换：保留最近 keepRecentTokens，之前替换为 CompactionMessage(summary, tokensBefore, 0)
// keepRecentTokens <= 0 时全部替换（用于测试/极端场景）
public func compactWithSummary(messages: ArrayList<Message>, keepRecentTokens: Int64,
    summary: String, tokensBefore: Int64): ArrayList<Message> {
    if (keepRecentTokens <= 0) {
        let r = ArrayList<Message>()
        r.add(CompactionMessage(summary, tokensBefore, 0))
        return r
    }
    var running: Int64 = 0
    var cutIndex: Int64 = 0
    var i = messages.size - 1
    while (i >= 0 && running < keepRecentTokens) {
        running += estimateMessageTokens(messages[i])
        i--
    }
    cutIndex = i + 1
    if (cutIndex <= 0) { return messages }
    let compacted = ArrayList<Message>()
    compacted.add(CompactionMessage(summary, tokensBefore, 0))
    for (j in cutIndex..Int64(messages.size)) {
        compacted.add(messages[Int64(j)])
    }
    compacted
}
```

注意：
- `Array<T>(n, item: x)` 的构造语法以仓颉为准（或 `let arr = [ctx]` 数组字面量）。`template.render(arr)` 返回 String（render<T>(context: Array<T>): String）。
- `field<String>` / `DataModelStruct().add(...)` 用法参考 server/config.cj 的 TomlProvider（已有先例）。
- 若 `JsonValue.parse(text)` 抛异常（try/catch）——jsonvalue 的 parse 签名确认（util/json.cj 或 provider 里用过 `JsonValue.parse(...)`，返回 JsonValue，异常行为确认）。
- 若 `estimateMessageTokens` 是私有函数（tokens.cj 里 `func estimateMessageTokens` 包内）——compaction.cj 同包可访问 ✅。

**Step 4: 跑测试确认通过**

Run: `cjpm test -j 16 --filter '*compactionConfig*'`
Expected: 5 个测试全 PASSED。

**Step 5: Commit**

```bash
git add src/context/compaction.cj src/context/context_test.cj
git commit -m "feat(context): CompactionConfig 配置结构 + mustache 模板渲染 + 极简 schema 校验 + compactWithSummary"
```

---

### Task 2: AgentConfig.compaction 字段（序列化双来源兼容）

**Files:**
- Modify: `src/agent/config.cj`
- Test: `src/agent/config_test.cj`（追加）

**Step 1: 写失败测试**

追加到 `src/agent/config_test.cj`（先看现有测试的构造方式）：

```cangjie
@Test
func config_compactionDefaultNone() {
    let cfg = AgentConfig.default()
    @Expect(cfg.compaction, None)
}

@Test
func config_compactionRoundTrip() {
    let opts = HashMap<String, JsonValue>()
    opts["required"] = JsonValue.Array(ArrayList([JsonValue.String("goal")]))
    let cc = CompactionConfig(false, 8192, 5000, "自定义模板", Some(JsonValue.Map(opts)), Some("summary-model"))
    let cfg = ... // 构造 AgentConfig（现有完整构造 + compaction: Some(cc)）
    let json = toJsonString(cfg)
    let back = fromJsonString<AgentConfig>(json)
    match (back.compaction) {
        case Some(c) =>
            @Expect(c.enabled, false)
            @Expect(c.reserveTokens, 8192)
            @Expect(c.promptTemplate, "自定义模板")
            @Expect(c.summaryModel, Some("summary-model"))
        case None => @Fail("expected compaction config")
    }
}

@Test
func config_compactionMissingFieldDefaultsNone() {
    // 旧格式 JSON（无 compaction 字段）→ None
    let json = "{\"name\":\"x\",\"systemPrompt\":\"\",\"model\":\"m\",\"maxTurns\":20,\"temperature\":0.7,\"maxOutputTokens\":4096,\"compactionEnabled\":true,\"compactionReserveTokens\":16384,\"keepRecentTokens\":20000,\"maxToolCalls\":50,\"toolTimeout\":30,\"minToolInterval\":0,\"createdAt\":0,\"updatedAt\":0,\"tools\":[],\"skills\":[],\"tags\":[]}"
    let back = fromJsonString<AgentConfig>(json)
    @Expect(back.compaction, None)
    @Expect(back.compactionEnabled, true)
}
```

（AgentConfig 构造示例以 config.cj 实际签名为准——compaction 参数加在末尾或 compaction 相关字段附近，按实际实现调整测试构造）

**Step 2: 跑测试确认失败**

Run: `cjpm test -j 16 --filter '*config_compaction*'`
Expected: 编译失败（cfg.compaction 不存在）。

**Step 3: 实现**

`src/agent/config.cj`：
- import 加 `import atelier.context.{CompactionConfig}`（agent 包依赖 context 包——检查循环：context 包不依赖 agent ✅）
- 字段 `public let compaction: Option<CompactionConfig>`
- 构造参数 +1（放在 compactionEnabled/compactionReserveTokens/keepRecentTokens 附近，例如 keepRecentTokens 之后）
- `default()` 传 None
- `toJson`：`w.writeName("compaction")` 手写嵌套对象（Some 时）：
  ```cangjie
  w.writeName("compaction").writeValue(this.compaction)
  ```
  问题：CompactionConfig 需要 JsonSerializable 才能 writeValue——**CompactionConfig 加 extend JsonSerializable**（context/compaction.cj，参照 AgentConfig 风格写 toJson/fromJson）？或 AgentConfig.toJson 手写嵌套。更干净：CompactionConfig 实现 JsonSerializable & JsonDeserializable<CompactionConfig>（可复用，config_test 直接测）。放 compaction.cj 加 extend。
- `fromJson`：`case "compaction" => compaction = r.readValue<Option<CompactionConfig>>()`（默认 None）
- **所有 AgentConfig 显式构造调用点 +1 参数（None）**：搜索 `AgentConfig(`——config.cj 内部 2 处（default/fromJson）、config_test.cj 4 处、handler.cj configFromDTO、server/config.cj agentConfigFrom、repl.cj makeRuntime

**Step 4: 跑测试确认通过 + 全量回归**

Run: `cjpm test -j 16 --filter '*config_compaction*'` → 3 PASSED
Run: `cjpm build -j 16` → success（所有调用点对齐）
Run: `cjpm test -j 16 --no-progress` → 全部 PASSED（209 基线 + 新增）

**Step 5: Commit**

```bash
git add src/agent/config.cj src/agent/config_test.cj src/context/compaction.cj
git commit -m "feat(config): AgentConfig.compaction 可选配置（序列化双来源兼容：嵌套优先，平铺兜底）"
```

---

### Task 3: runtime 压缩调用点改造（用量优先 + LLM 子调用 + 降级）

**Files:**
- Modify: `src/agent/runtime.cj`（压缩调用点）
- Test: `src/agent/runtime_test.cj`（追加，用 StubProvider）

**Step 1: 写失败测试**

追加到 `src/agent/runtime_test.cj`（该文件已有 StubProvider + makeMcpRuntime + CaptureToolsHook；压缩测试需要定制 StubProvider 返回**摘要文本**（chat 返回 AssistantMessage 文本即摘要）+ 配置压缩参数）：

```cangjie
// 返回固定摘要文本的 provider（chat 非流式）
class StubSummaryProvider <: Provider {
    private let summaryText: String
    public init(summaryText: String) { this.summaryText = summaryText }
    public func name(): String { "stub" }
    public func chat(req: ChatRequest): ChatResponse {
        ChatResponse(AssistantMessage(ContentList.ofText(this.summaryText), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0))
    }
    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        let stream = EventStream<ChatDelta, AssistantMessage>()
        stream.setResult(AssistantMessage(ContentList.ofText("ok"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0))
        stream
    }
}
```

（压缩集成测试的触发条件：contextWindow 小（model 未知默认 8192）或 reserveTokens 大——`config.compactionReserveTokens` 设大 + 消息多。**难度评估：触发链路长（turn 循环 → 压缩调用 → provider.chat 子调用 → 断言 messages 含 CompactionMessage），且 runtime.chat 异步。若实现复杂度过高，此测试可降级为不写（Task 3 只做单元级验证 + 手工验证），以 Task 4 验收清单为准。** 建议先做纯函数级验证，runtime 集成测试视情况。）

**Step 2: 实现**

`src/agent/runtime.cj` 压缩调用点（约 322-328 行）改造：

```cangjie
            if (this.config.compactionEnabled || match (this.config.compaction) { case Some(c) => c.enabled; case None => false }) {
                let contextWindow = this.modelRegistry.get(actualModel)
                // 合并配置：compaction 嵌套优先，平铺兜底
                let cc = match (this.config.compaction) {
                    case Some(c) => c
                    case None => CompactionConfig()
                }
                let reserve = match (this.config.compaction) {
                    case Some(c) => c.reserveTokens
                    case None => Int64(this.config.compactionReserveTokens)
                }
                let keepRecent = match (this.config.compaction) {
                    case Some(c) => c.keepRecentTokens
                    case None => Int64(this.config.keepRecentTokens)
                }
                // 用量优先：assistantMsg.usage.inputTokens > 0 用实际用量，否则本地估算
                let total = if (assistantMsg.usage.inputTokens > 0) { assistantMsg.usage.inputTokens }
                    else { estimateTokens(currentMessages) }
                if (total > reserve && contextWindow != 0 && total > contextWindow - reserve) {
                    // 压缩子调用（独立请求体：无 system/tools，不污染主对话缓存）
                    let summary = try {
                        let conversation = summarizeText(currentMessages, reserve)
                        let prompt = renderCompactionPrompt(cc, conversation, None, reserve)
                        let summaryModel = match (cc.summaryModel) {
                            case Some(m) => m
                            case None => actualModel
                        }
                        let req = ChatRequest(summaryModel, ArrayList<Message>([UserMessage(ContentList.ofText(prompt), 0)]),
                            Float64(0.2), reserve, None, ArrayList<OpenAITool>())
                        let resp = this.provider.chat(req)
                        let raw = contentToPlainText(resp.message)
                        match (cc.outputSchema) {
                            case Some(JsonValue.Map(schema)) =>
                                if (!validateSummary(cc, schema, raw)) {
                                    throw Exception("summary failed schema validation")
                                }
                            case _ => ()
                        }
                        raw
                    } catch (e: Exception) {
                        log.warn("compaction summary failed: ${e.message}, fallback to placeholder", Array<Attr>())
                        "... ${total} previous tokens summarized ..."
                    }
                    currentMessages = compactWithSummary(currentMessages, keepRecent, summary, total)
                } else {
                    currentMessages = compactMessages(currentMessages, contextWindow, reserve, keepRecent)
                }
            }
```

辅助函数（runtime.cj 文件底部或 context 包）：

```cangjie
// 待压缩对话文本（截取到 reserve 上限前，避免子调用超长）
func summarizeText(msgs: ArrayList<Message>, limit: Int64): String {
    let sb = StringBuilder()
    var used: Int64 = 0
    for (m in msgs) {
        let t = match (m) {
            case um: UserMessage => textOf(um.content)
            case am: AssistantMessage => textOf(am.content)
            case tm: ToolResultMessage => "[tool " + tm.toolName + "]: " + textOf(tm.content)
            case cm: CompactionMessage => "[summary] " + cm.summary
            case _ => ""
        }
        if (t == "") { continue }
        if (used + Int64(t.size) > limit * 4) { break }
        sb.append(t)
        sb.append("\n")
        used += Int64(t.size)
    }
    sb.toString()
}
```

（textOf = 提取 ContentList 文本，可复用 runtime 或 message 包的工具函数——检查现有 `textFrom`/`contentToText` 是否 public，或新写包内函数。）

**注意**：上面实现是参考骨架。**请以"行为等价 + 可编译"为准则实现**：
- 配置合并逻辑清晰（嵌套优先）
- 用量优先判定
- 子调用失败（异常）→ 占位文本回退（现状行为保留）
- `compactWithSummary` 替换
- 若 `JsonValue`/`estimateTokens` 等 import 缺失，补 import
- 尽量复用现有函数（contentToText 在 provider 包是私有的——runtime 包内写 textOf）

**Step 3: 验证**

Run: `cjpm build -j 16` → success
Run: `cjpm test -j 16 --no-progress` → 全部 PASSED（209 基线 + Task1/2 新增；runtime 集成测试按 Step 1 评估决定是否写）

**Step 4: Commit**

```bash
git add src/agent/runtime.cj src/agent/runtime_test.cj
git commit -m "feat(runtime): 压缩增强接线（用量优先 + LLM 摘要子调用 + schema 校验 + 占位降级）"
```

---

### Task 4: 文档同步 + 最终验证 + 合并

**Files:**
- Modify: `docs/plans/2026-08-09-context-extension-design.md`（4.3 节 ✅ + 9.1 卡片 + 10.6 勾选）
- Modify: `docs/configuration.md`（agent.compaction 配置示例）
- Modify: `docs/plans/2026-08-09-compaction-enhance-plan.md`（本文件验收清单）

**Step 1: 设计文档更新**

- 4.3 节标注「✅ P4 已实现」：CompactionConfig 6 字段；mustache-cj 1.2.1（`{{#previous_summary}}` 条件块由 truth() 保证）；CompactionContext 实现 MustacheComponent；极简 schema 校验（{required, types}，失败降级原文）；独立子调用（无 system/tools 缓存隔离）；用量优先判定（usage.inputTokens > 0 优先）；AgentConfig.compaction 双来源兼容
- 9.1 模块卡片：context/compaction.cj 更新（CompactionConfig/renderCompactionPrompt/validateSummary/compactWithSummary）
- 10.6 P4 标注「✅ 已完成（2026-08-09）」

**Step 2: configuration.md**

[[agent]] 示例加：

```toml
# 压缩增强（可选，不配置时用平铺字段 compactionEnabled 等）
# [agent.compaction]
# enabled = true
# promptTemplate = "压缩以下对话：\n{{conversation}}"
# outputSchema = { required = ["goal"], types = { goal = "string" } }
```

**Step 3: 最终验证 + Commit + 合并**

Run: `cjpm test -j 16 --no-progress` → 全部 PASSED

```bash
git add docs/plans/2026-08-09-context-extension-design.md docs/configuration.md docs/plans/2026-08-09-compaction-enhance-plan.md
git commit -m "docs: P4 压缩增强完成，同步设计文档/配置文档/实施计划"

git checkout master && git pull
git merge --no-ff feat/compaction-enhance -m "merge: P4 压缩增强（CompactionConfig 模板 + LLM 摘要子调用 + 用量优先）"
git push
git branch -d feat/compaction-enhance
```

---

## 验收清单（✅ 已完成，2026-08-09）

- [x] mustache 1.2.1 依赖解析 + build success（已预验证）
- [x] CompactionConfig 6 单测：默认模板渲染（变量替换/无 previous_summary）、条件块（有/无）、自定义模板、schema 校验（通过/类型不符/缺必填）、compactWithSummary
- [x] AgentConfig.compaction 3 单测（含 outputSchema 往返断言）：默认 None、嵌套往返、旧格式缺字段 None + 平铺字段保留
- [x] runtime 压缩调用点：用量优先 + 子调用 + schema 校验失败降级 + 异常降级占位（5 集成测试）
- [x] `cjpm test -j 16 --no-progress` 全绿（226 PASSED + 6 SKIPPED；含切点 bug 修复回归）
- [x] 文档同步（4.3/9.1/10.6 + configuration.md）

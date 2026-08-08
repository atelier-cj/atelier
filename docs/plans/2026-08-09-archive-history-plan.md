# AI 自主归档实施计划（P3）

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** LLM 通过 `archive_history(start_index, end_index, summary)` 工具自主压缩对话历史：调用后的下一轮，指定范围的消息被替换为归档摘要，判断权交给 AI，代码只做校验与容错。

**Architecture:** Message 密封接口新增第 5 个实现类 `ArchiveMessage {startIndex, endIndex, summary, timestamp}`（Entry/store 零改动，序列化加一个 case，旧文件兼容）；新建 `archive_history` 工具（纯校验 + 返回确认，不碰 store）；`ContextBuilder.applyArchives(messages)` 每轮应用：扫描 `archive_history` 调用对（ToolCall + ToolResult），钳制范围后替换为 ArchiveMessage，移除调用对自身（天然幂等）；`AgentRuntime` 每轮构建 ChatRequest 前调用；三个 provider 的消息转换加 ArchiveMessage case（转 `[Archived <start>-<end>: <summary>]`）。

**持久化策略（务实版）：** 归档在 run 内应用（内存替换），run 结束 REPL save 时 ArchiveMessage 随消息序列化入库（store 保留归档痕迹：范围 + 摘要）。**严格 L1 只增不改**（appendBranch 追加归档 Entry，原始消息不删）需要 runtime 会话链路（sessionId/parentLeafId），当前 runtime 无会话对象——标注为后续演进。

**Tech Stack:** 仓颉（cjpm）、无新外部依赖。

**前置：** P2 已合并（master e1f9ab1）。开分支 `git checkout -b feat/archive-history`。

---

### Task 1: ArchiveMessage 角色 + 序列化 + provider 转换

**Files:**
- Modify: `src/message/role.cj`（MessageRole 加 Archive）
- Modify: `src/message/message.cj`（ArchiveMessage 类）
- Modify: `src/message/serialize.cj`（toJson + readMessageFromJson）
- Modify: `src/provider/openai.cj`、`src/provider/anthropic.cj`、`src/provider/ollama.cj`（消息转换加 case）
- Test: `src/message/message_test.cj`（追加）

**Step 1: 写失败测试**

追加到 `src/message/message_test.cj`（先看该文件现有风格）：

```cangjie
@Test
func archiveMessage_roleAndFields() {
    let m = ArchiveMessage(3, 8, "已归档的摘要", 0)
    @Expect(m.role(), MessageRole.Archive)
    @Expect(m.startIndex, 3)
    @Expect(m.endIndex, 8)
    @Expect(m.summary, "已归档的摘要")
}

@Test
func archiveMessage_serializeRoundTrip() {
    let m = ArchiveMessage(3, 8, "已归档的摘要", 0)
    let json = toJsonString(m)
    let back = readMessageFromJson(StringReader(json))
    match (back) {
        case am: ArchiveMessage =>
            @Expect(am.startIndex, 3)
            @Expect(am.endIndex, 8)
            @Expect(am.summary, "已归档的摘要")
        case _ => @Fail("expected ArchiveMessage")
    }
}
```

（`toJsonString`/`readMessageFromJson` 的用法参考 message_test.cj 现有测试——先读文件确认导入与辅助函数）

**Step 2: 跑测试确认失败**

Run: `cjpm test -j 16 --filter '*archiveMessage*'`
Expected: 编译失败（ArchiveMessage 未定义、MessageRole.Archive 不存在）。

**Step 3: 实现**

1. `role.cj`：MessageRole 加 `| Archive`
2. `message.cj` 追加：

```cangjie
public class ArchiveMessage <: Message {
    public let startIndex: Int64
    public let endIndex: Int64
    public let summary: String
    public let timestamp: Int64

    public init(startIndex: Int64, endIndex: Int64, summary: String, timestamp: Int64) {
        this.startIndex = startIndex
        this.endIndex = endIndex
        this.summary = summary
        this.timestamp = timestamp
    }

    public func role(): MessageRole {
        MessageRole.Archive
    }
}
```

3. `serialize.cj`：

```cangjie
extend ArchiveMessage <: JsonSerializable {
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("role").writeValue("archive")
        w.writeName("startIndex").writeValue(this.startIndex)
        w.writeName("endIndex").writeValue(this.endIndex)
        w.writeName("summary").writeValue(this.summary)
        w.writeName("timestamp").writeValue(this.timestamp)
        w.endObject()
    }
}
```

`readMessageFromJson`：加局部变量 `var startIndex = Int64(0); var endIndex = Int64(0)`，case 加 `"startIndex" => startIndex = r.readValue<Int64>()`、`"endIndex" => endIndex = r.readValue<Int64>()`，match role 加 `case "archive" => ArchiveMessage(startIndex, endIndex, summary, ts)`

4. 三个 provider 的消息转换：在 CompactionMessage case 后加：

```cangjie
            case am: ArchiveMessage =>
                result.add(OpenAIMessage("user", "[Archived " + am.startIndex.toString() + "-" + am.endIndex.toString() + ": " + am.summary + "]", Option<String>.None, "", ArrayList<JsonValue>()))
```

（anthropic.cj / ollama.cj 用各自的消息类型构造，对齐各自现有 CompactionMessage case 的写法）

**Step 4: 跑测试确认通过**

Run: `cjpm test -j 16 --filter '*archiveMessage*'`、`cjpm test -j 16 --filter '*message*'`
Expected: 全部 PASSED（含新增 2 个；原有不回归）。

**Step 5: Commit**

```bash
git add src/message/role.cj src/message/message.cj src/message/serialize.cj src/message/message_test.cj src/provider/openai.cj src/provider/anthropic.cj src/provider/ollama.cj
git commit -m "feat(message): ArchiveMessage 第 5 角色 + 序列化 + 三 Provider 消息转换"
```

---

### Task 2: archive_history 工具

**Files:**
- Create: `src/tool/archive_history.cj`
- Test: `src/tool/builtin/tools_test.cj` 或新 `src/tool/archive_history_test.cj`（package atelier.tool，新建更清晰）

**Step 1: 写失败测试**

创建 `src/tool/archive_history_test.cj`（package atelier.tool；参考 mcp_manager_test.cj 风格）：

```cangjie
package atelier.tool

import jsonvalue.*
import std.collection.*

func archiveArgs(start: Int64, end: Int64, summary: String): JsonValue {
    let m = HashMap<String, JsonValue>()
    m["start_index"] = JsonValue.Number(Float64(start))
    m["end_index"] = JsonValue.Number(Float64(end))
    m["summary"] = JsonValue.String(summary)
    JsonValue.Map(m)
}

@Test
func archiveHistory_validRange() {
    let tool = ArchiveHistoryTool()
    let r = tool.execute(ToolContext("."), archiveArgs(3, 8, "关键决策：改用 bstorm"))
    @Expect(r.isError, false)
    @Expect(r.text.contains("已归档"), true)
    @Expect(r.text.contains("3"), true)
    @Expect(r.text.contains("8"), true)
}

@Test
func archiveHistory_negativeStartError() {
    let tool = ArchiveHistoryTool()
    let r = tool.execute(ToolContext("."), archiveArgs(-1, 8, "s"))
    @Expect(r.isError, true)
}

@Test
func archiveHistory_endBeforeStartError() {
    let tool = ArchiveHistoryTool()
    let r = tool.execute(ToolContext("."), archiveArgs(8, 3, "s"))
    @Expect(r.isError, true)
}

@Test
func archiveHistory_emptySummaryError() {
    let tool = ArchiveHistoryTool()
    let r = tool.execute(ToolContext("."), archiveArgs(3, 8, ""))
    @Expect(r.isError, true)
}

@Test
func archiveHistory_missingParamError() {
    let tool = ArchiveHistoryTool()
    let r = tool.execute(ToolContext("."), JsonValue.Map(HashMap()))
    @Expect(r.isError, true)
}
```

注意：`JsonValue.Number(Float64(start))`——先确认 jsonvalue 的数值变体构造方式（`JsonValue.Number(Float64)`），若不对用 Int64 转换或其他方式，以 jsonvalue 库实际 API 为准。

**Step 2: 跑测试确认失败**

Run: `cjpm test -j 16 --filter '*archiveHistory*'`
Expected: 编译失败（ArchiveHistoryTool 未定义）。

**Step 3: 实现**

创建 `src/tool/archive_history.cj`（package atelier.tool）：

```cangjie
package atelier.tool

import jsonvalue.*
import std.collection.*

public class ArchiveHistoryTool <: Tool {
    public init() {}

    public func name(): String { "archive_history" }

    public func description(): String {
        "将对话历史中指定的消息范围压缩成一条摘要，下次对话轮次生效。参数: start_index（起始消息序号，0-based）、" +
        "end_index（结束消息序号，包含）、summary（你要保留的摘要文本）。" +
        "注意：此操作不删除原始会话数据（持久化记录保留归档痕迹），只影响后续 LLM 看到的上下文。"
    }

    public func schema(): JsonValue {
        SchemaBuilder()
            .addInteger("start_index", "起始消息序号（0-based）", required: true)
            .addInteger("end_index", "结束消息序号（包含）", required: true)
            .addString("summary", "保留的摘要文本", required: true)
            .build()
    }

    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        let start: Int64 = match (args["start_index"]) {
            case Some(JsonValue.Number(n)) => Int64(n)
            case _ => return ToolResult("Missing or invalid parameter: start_index", None, true, false)
        }
        let end: Int64 = match (args["end_index"]) {
            case Some(JsonValue.Number(n)) => Int64(n)
            case _ => return ToolResult("Missing or invalid parameter: end_index", None, true, false)
        }
        let summary: String = match (args["summary"]) {
            case Some(JsonValue.String(s)) => s
            case _ => return ToolResult("Missing or invalid parameter: summary", None, true, false)
        }
        if (start < 0) {
            return ToolResult("Invalid range: start_index must be >= 0", None, true, false)
        }
        if (end < start) {
            return ToolResult("Invalid range: end_index must be >= start_index", None, true, false)
        }
        if (summary.trimAscii() == "") {
            return ToolResult("Invalid summary: must not be empty", None, true, false)
        }
        ToolResult("已归档第 " + start.toString() + " 到 " + end.toString() + " 条消息（共 " +
            (end - start + 1).toString() + " 条），摘要: " + summary, None, false, false)
    }

    public func executionMode(): ToolExecutionMode { ToolExecutionMode.Parallel }
}
```

**Step 4: 跑测试确认通过**

Run: `cjpm test -j 16 --filter '*archiveHistory*'`
Expected: 5 个测试全 PASSED。

**Step 5: Commit**

```bash
git add src/tool/archive_history.cj src/tool/archive_history_test.cj
git commit -m "feat(tool): archive_history 工具（范围/摘要校验 + 归档确认）"
```

---

### Task 3: ContextBuilder.applyArchives + runtime 集成

**Files:**
- Modify: `src/context/builder.cj`（applyArchives 方法）
- Modify: `src/agent/runtime.cj`（每轮构建前应用）
- Test: `src/context/builder_test.cj`（追加）

**Step 1: 写失败测试**

追加到 `src/context/builder_test.cj`（需要 `import atelier.tool.*` 已有；构造 archive_history 调用对消息的辅助函数）：

```cangjie
// 构造一条含 archive_history 调用对的消息序列：assistant(toolCall) + toolResult
func archivedPair(msgs: ArrayList<Message>, start: Int64, end: Int64, summary: String): ArrayList<Message> {
    let args = HashMap<String, JsonValue>()
    args["start_index"] = JsonValue.Number(Float64(start))
    args["end_index"] = JsonValue.Number(Float64(end))
    args["summary"] = JsonValue.String(summary)
    let tc = ToolCallBlock("call_1", "archive_history", JsonValue.Map(args))
    let blocks = ArrayList<ContentBlock>()
    blocks.add(ContentBlock.ToolCall(tc))
    msgs.add(AssistantMessage(ContentList(blocks), "", "", StopReason.ToolUse, TokenUsage(0, 0), 0))
    msgs.add(ToolResultMessage("call_1", "archive_history", ContentList.ofText("已归档..."), false, 0))
    msgs
}

func plainMsg(text: String): Message {
    UserMessage(ContentList.ofText(text), 0)
}

@Test
func applyArchives_replacesRange() {
    let b = ContextBuilder(SkillRegistry(), SessionEnvironment())
    let msgs = ArrayList<Message>()
    msgs.add(plainMsg("m0"))
    msgs.add(plainMsg("m1"))
    msgs.add(plainMsg("m2"))
    archivedPair(msgs, 1, 1, "摘要内容")
    let out = b.applyArchives(msgs)
    @Expect(out.size, 2)
    match (out[1]) {
        case am: ArchiveMessage =>
            @Expect(am.summary, "摘要内容")
            @Expect(am.startIndex, 1)
            @Expect(am.endIndex, 1)
        case _ => @Fail("expected ArchiveMessage at index 1")
    }
}

@Test
func applyArchives_clampsOutOfRange() {
    let b = ContextBuilder(SkillRegistry(), SessionEnvironment())
    let msgs = ArrayList<Message>()
    msgs.add(plainMsg("m0"))
    msgs.add(plainMsg("m1"))
    archivedPair(msgs, 0, 99, "摘要")  // end 越界 → 钳制到 size-1=1
    let out = b.applyArchives(msgs)
    @Expect(out.size, 1)
    match (out[0]) {
        case am: ArchiveMessage =>
            @Expect(am.startIndex, 0)
            @Expect(am.endIndex, 1)
        case _ => @Fail("expected ArchiveMessage")
    }
}

@Test
func applyArchives_noPairUnchanged() {
    let b = ContextBuilder(SkillRegistry(), SessionEnvironment())
    let msgs = ArrayList<Message>()
    msgs.add(plainMsg("m0"))
    msgs.add(plainMsg("m1"))
    let out = b.applyArchives(msgs)
    @Expect(out.size, 2)
}

@Test
func applyArchives_idempotent() {
    let b = ContextBuilder(SkillRegistry(), SessionEnvironment())
    let msgs = ArrayList<Message>()
    msgs.add(plainMsg("m0"))
    archivedPair(msgs, 0, 0, "摘要")
    let once = b.applyArchives(msgs)
    let twice = b.applyArchives(once)
    @Expect(twice.size, 1)
    match (twice[0]) {
        case am: ArchiveMessage => @Expect(am.summary, "摘要")
        case _ => @Fail("expected ArchiveMessage")
    }
}

@Test
func applyArchives_nonArchiveToolPairIgnored() {
    let b = ContextBuilder(SkillRegistry(), SessionEnvironment())
    let msgs = ArrayList<Message>()
    msgs.add(plainMsg("m0"))
    // 普通工具调用对（非 archive_history）不处理
    let args = HashMap<String, JsonValue>()
    args["path"] = JsonValue.String("/tmp/a")
    let tc = ToolCallBlock("call_x", "read_file", JsonValue.Map(args))
    let blocks = ArrayList<ContentBlock>()
    blocks.add(ContentBlock.ToolCall(tc))
    msgs.add(AssistantMessage(ContentList(blocks), "", "", StopReason.ToolUse, TokenUsage(0, 0), 0))
    msgs.add(ToolResultMessage("call_x", "read_file", ContentList.ofText("内容"), false, 0))
    let out = b.applyArchives(msgs)
    @Expect(out.size, 3)
}
```

**Step 2: 跑测试确认失败**

Run: `cjpm test -j 16 --filter '*applyArchives*'`
Expected: 编译失败（applyArchives 不存在）。

**Step 3: 实现**

`ContextBuilder` 追加（src/context/builder.cj；需要 import atelier.tool.ToolCallBlock——已在 atelier.message.* 里（content.cj 的 ToolCallBlock 在 atelier.message 包），无需新 import；JsonValue 需要 `import jsonvalue.*`——检查 builder.cj 现有 import，缺则补）：

```cangjie
    // 扫描 archive_history 调用对（ToolCall + ToolResult），钳制范围后替换为 ArchiveMessage
    // 调用对自身移除 → 天然幂等；无调用对返回原列表
    public func applyArchives(messages: ArrayList<Message>): ArrayList<Message> {
        let result = ArrayList<Message>()
        var i: Int64 = 0
        var applied = false
        while (i < messages.size) {
            let m = messages[Int64(i)]
            match (m) {
                case tr: ToolResultMessage if (tr.toolName == "archive_history") =>
                    // 向前找对应的 ToolCall（最近的 AssistantMessage 中 id 匹配）
                    var callArgs: Option<JsonValue> = None
                    var j = i - 1
                    while (j >= 0) {
                        match (messages[Int64(j)]) {
                            case am: AssistantMessage =>
                                for (tc in am.toolCalls()) {
                                    if (tc.id == tr.toolCallId && tc.name == "archive_history") {
                                        callArgs = Some(tc.args)
                                    }
                                }
                            case _ => ()
                        }
                        if (let Some(_) <- callArgs) { break }
                        j--
                    }
                    match (callArgs) {
                        case Some(args) =>
                            let start = extractIndex(args, "start_index")
                            let end = extractIndex(args, "end_index")
                            let summary = extractSummary(args)
                            match (start, end, summary) {
                                case (Some(s), Some(e), Some(sum)) =>
                                    var ss = s
                                    var ee = e
                                    if (ss < 0) { ss = 0 }
                                    if (ss >= messages.size) { ss = messages.size - 1 }
                                    if (ee > messages.size - 1) { ee = messages.size - 1 }
                                    if (ee < ss) { ee = ss }
                                    if (ss >= 0 && ss < messages.size) {
                                        // 移除范围内的消息（本结果已收集的 + 后续跳过）
                                        var k = result.size - 1
                                        while (k >= 0 && result.size - Int64(k) <= (Int64(ss) + 1)) {
                                            if (result.size - Int64(k) <= Int64(ss)) {
                                                result.remove(Int64(k))
                                            }
                                            k--
                                        }
                                        result.add(ArchiveMessage(ss, ee, sum, 0))
                                        applied = true
                                        i = ee + 1
                                        // 跳过范围内的消息和本调用对
                                        while (i <= ee && i < messages.size) {
                                            i++
                                        }
                                        i++  // 跳过 ToolResult 自身
                                        continue
                                    }
                                case _ => ()
                            }
                        case None => ()
                    }
                    result.add(m)
                case _ => result.add(m)
            }
            i++
        }
        result
    }
```

**注意：上面的 applyArchives 实现有缺陷（移除已收集消息的索引计算复杂易错）。请用更简洁可靠的方式实现，满足测试语义即可：**

- 输入消息中，archive_history 调用对 = AssistantMessage(含 toolCall name=="archive_history") + 紧邻的 ToolResultMessage(toolCallId 匹配)
- 应用：最终结果 = [0, start) 的消息 + ArchiveMessage + (end, 范围外] 的消息（调用对整体移除）
- 实现建议：两遍扫描。第一遍收集所有归档对（callStartIdx, callEndIdx, start, end, summary）到列表；按 start 排序后**从后往前**处理（后面的先处理，前面的索引不受影响），每处理一个对就重建列表（或就地标记）。最稳妥：递归/循环"找第一个对 → 应用 → 继续"，直到无对（消息量小，O(n²) 可接受）。
- 辅助函数 `extractIndex(args, key): Option<Int64>`（JsonValue.Number(n) → Int64(n)）、`extractSummary(args): Option<String>` 放到 builder.cj 包内顶层函数。

`runtime.cj` 集成：chatWithEnv 的 turn 循环开头（`stream.emit(TurnStartEvent())` 之后、`MessageStartEvent` 之前）加：

```cangjie
                    currentMessages = this.ctxBuilder.applyArchives(currentMessages)
```

（ctxBuilder 在 chatWithEnv 内已创建）

**Step 4: 跑测试确认通过**

Run: `cjpm test -j 16 --filter '*applyArchives*'`
Expected: 5 个测试全 PASSED。

**Step 5: 全量回归 + Commit**

Run: `cjpm build -j 16` → success
Run: `cjpm test -j 16 --no-progress` → 全部 PASSED（197 基线 + 新增）

```bash
git add src/context/builder.cj src/agent/runtime.cj src/context/builder_test.cj
git commit -m "feat(context): ContextBuilder.applyArchives 归档应用（范围钳制 + 幂等）+ runtime 每轮集成"
```

---

### Task 4: 文档同步 + 最终验证 + 合并

**Files:**
- Modify: `docs/plans/2026-08-09-context-extension-design.md`（4.2 节 + 9.1 卡片 + 10.5 勾选）
- Modify: `docs/plans/2026-08-09-archive-history-plan.md`（本文件验收清单）

**Step 1: 设计文档更新**

- 4.2 节标注「✅ P3 已实现」：ArchiveMessage 第 5 角色（Entry/store 零改动，serialize 加 case，旧文件兼容）；archive_history 工具（校验 + 确认）；applyArchives（钳制 + 幂等）；runtime 每轮应用；provider 转换 `[Archived <start>-<end>: <summary>]`；**持久化策略**：run 内应用 + REPL save 序列化保留归档痕迹；严格 L1 追加（appendBranch）标注后续演进（runtime 无会话链路）
- 9.1 模块卡片：`tool/archive_history.cj` 🚧→✅；`context/builder.cj` 关键接口补 applyArchives
- 10.5 P3 任务标注「✅ 已完成（2026-08-09）」

**Step 2: 最终验证 + Commit + 合并**

Run: `cjpm test -j 16 --no-progress` → 全部 PASSED

```bash
git add docs/plans/2026-08-09-context-extension-design.md docs/plans/2026-08-09-archive-history-plan.md
git commit -m "docs: P3 AI 自主归档完成，同步设计文档/实施计划"

git checkout master && git pull
git merge --no-ff feat/archive-history -m "merge: P3 AI 自主归档（archive_history 工具 + ArchiveMessage 角色 + applyArchives）"
git push
git branch -d feat/archive-history
```

---

## 验收清单（✅ 已完成，2026-08-09）

- [x] `cjpm test -j 16 --no-progress`：197 基线 + 新增全 PASSED
- [x] ArchiveMessage：role/字段 + 序列化往返 + 旧格式兼容（readMessageFromJson 无 archive 字段不崩）
- [x] 三 provider 消息转换加 ArchiveMessage case（`[Archived <start>-<end>: <summary>]`）
- [x] archive_history 工具 5 单测：正常/负 start/end<start/空摘要/缺参
- [x] applyArchives 5 单测：范围替换/越界钳制/无对不变/幂等/非归档调用对忽略
- [x] runtime 每轮构建前应用归档
- [x] 文档同步（4.2/9.1/10.5）

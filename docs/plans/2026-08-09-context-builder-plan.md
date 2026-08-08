# ContextBuilder + SystemPromptBuilder 抽取实施计划（P0）

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 从 `AgentRuntime` 抽出独立的 `ContextBuilder`（L2 上下文构建）与 `SystemPromptBuilder`（系统提示分段构建），行为零变化，为 P1-P4 提供挂载点。

**Architecture:** 新建 `atelier.context` 包的两个类，逐行移植 `runtime.cj` 的 `buildSystemPromptWithEnv`/`buildSystemPrompt`/`readFile`；`AgentRuntime.chatWithEnv` 改为委托调用。`ContextBuilder` 每 run 创建（持有 `SkillRegistry` + `SessionEnvironment`），`initMessages` 组装首条系统消息 + 历史，`buildChatRequest` 组装每轮请求。为避免 `context → agent` 包循环依赖，**不引入 `AgentConfig` 参数**，改用拆开的标量/列表参数。

**Tech Stack:** 仓颉（cjpm）、stdx、无新外部依赖。

**前置：** `git pull` 同步 master，开分支 `git checkout -b feat/context-builder`。

---

### Task 1: SystemPromptBuilder 类（含失败测试先行）

**Files:**
- Create: `src/context/system_prompt_builder.cj`
- Test: `src/context/builder_test.cj`（本任务先写 SystemPromptBuilder 部分，Task 2 追加）

**Step 1: 写失败测试**

创建 `src/context/builder_test.cj`：

```cangjie
package atelier.context

import atelier.message.*
import atelier.session.*
import atelier.skill.*
import std.collection.*
import std.fs.*

func fakeSkill(name: String, instructions: String): Skill {
    Skill(name, "desc", None, None, HashMap(), ArrayList(), instructions, "")
}

func buildText(spb: SystemPromptBuilder, sp: String, names: ArrayList<String>,
    skills: SkillRegistry, env: SessionEnvironment): String {
    spb.build(sp, names, skills, env)
}

@Test
func sysPrompt_emptyEverything() {
    let spb = SystemPromptBuilder()
    @Expect(buildText(spb, "", ArrayList(), SkillRegistry(), SessionEnvironment()), "")
}

@Test
func sysPrompt_systemPromptInjected() {
    let spb = SystemPromptBuilder()
    let out = buildText(spb, "你是助手", ArrayList(), SkillRegistry(), SessionEnvironment())
    @Expect(out.startsWith("你是助手\n\n"), true)
}

@Test
func sysPrompt_skillInjected() {
    let reg = SkillRegistry()
    reg.register(fakeSkill("code-review", "## 审查流程\n1. 读文件"))
    let spb = SystemPromptBuilder()
    let names = ArrayList<String>(["code-review"])
    let out = buildText(spb, "prompt", names, reg, SessionEnvironment())
    @Expect(out.contains("## 审查流程"), true)
}

@Test
func sysPrompt_unknownSkillSkipped() {
    let spb = SystemPromptBuilder()
    let names = ArrayList<String>(["not-exist"])
    let out = buildText(spb, "prompt", names, SkillRegistry(), SessionEnvironment())
    @Expect(out, "prompt\n\n")
}

@Test
func sysPrompt_projectRulesFromAgentsMd() {
    let dir = Directory.createTemp(Path("/tmp"))
    File.writeTo(dir.toString() + "/AGENTS.md", "项目规则内容".toArray())
    let env = SessionEnvironment(dir.toString(), HashMap())
    let spb = SystemPromptBuilder()
    let out = buildText(spb, "", ArrayList(), SkillRegistry(), env)
    @Expect(out.contains("[Project Rules]"), true)
    @Expect(out.contains("项目规则内容"), true)
}

@Test
func sysPrompt_missingDirNoRules() {
    let env = SessionEnvironment("/nonexistent-dir-12345", HashMap())
    let spb = SystemPromptBuilder()
    let out = buildText(spb, "", ArrayList(), SkillRegistry(), env)
    @Expect(out.contains("[Project Rules]"), false)
}

@Test
func sysPrompt_sessionContextInjected() {
    let ctx = HashMap<String, String>()
    ctx["workDir"] = "/home/x"
    let env = SessionEnvironment("", ctx)
    let spb = SystemPromptBuilder()
    let out = buildText(spb, "", ArrayList(), SkillRegistry(), env)
    @Expect(out.contains("[Session Context]"), true)
    @Expect(out.contains("workDir = /home/x"), true)
}

@Test
func sysPrompt_noContextNoSection() {
    let spb = SystemPromptBuilder()
    let out = buildText(spb, "", ArrayList(), SkillRegistry(), SessionEnvironment())
    @Expect(out.contains("[Session Context]"), false)
}

@Test
func sysPrompt_sectionOrder() {
    let reg = SkillRegistry()
    reg.register(fakeSkill("s1", "SKILL-BODY"))
    let ctx = HashMap<String, String>()
    ctx["k"] = "v"
    let env = SessionEnvironment("", ctx)
    let spb = SystemPromptBuilder()
    let names = ArrayList<String>(["s1"])
    let out = buildText(spb, "SYS", names, reg, env)
    @Expect(out.indexOf("SYS") < out.indexOf("SKILL-BODY"), true)
    @Expect(out.indexOf("SKILL-BODY") < out.indexOf("[Session Context]"), true)
}
```

**Step 2: 跑测试确认失败**

Run: `cjpm test -j 16 --filter 'sysPrompt_.*'`
Expected: 编译失败，`SystemPromptBuilder` 未定义（`error: unresolved name`）。

**Step 3: 实现**

创建 `src/context/system_prompt_builder.cj`（逐行移植 `runtime.cj:524-567` 的 `buildSystemPromptWithEnv` + `runtime.cj:505-518` 的 `readFile`）：

```cangjie
package atelier.context

import atelier.skill.*
import atelier.session.*
import std.collection.*
import std.fs.*

public class SystemPromptBuilder {
    public init() {}

    public func build(systemPrompt: String, skillNames: ArrayList<String>,
        skills: SkillRegistry, env: SessionEnvironment): String {
        let sb = StringBuilder()
        if (systemPrompt != "") {
            sb.append(systemPrompt)
            sb.append("\n\n")
        }
        for (name in skillNames) {
            match (skills.get(name)) {
                case Some(skill) =>
                    sb.append(skill.instructions)
                    sb.append("\n\n")
                case None => ()
            }
        }
        if (env.directory != "") {
            try {
                let agentsPath = env.directory + "/AGENTS.md"
                let p = Path(agentsPath)
                if (exists(p)) {
                    let content = readFileText(p)
                    if (content != "") {
                        sb.append("[Project Rules]\n")
                        sb.append(content)
                        sb.append("\n\n")
                    }
                }
            } catch (_: Exception) {}
        }
        if (env.context.size > 0) {
            sb.append("[Session Context]\n")
            for ((k, v) in env.context) {
                sb.append(k)
                sb.append(" = ")
                sb.append(v)
                sb.append("\n")
            }
            sb.append("\n")
        }
        sb.toString()
    }
}

func readFileText(p: Path): String {
    let f = File(p, OpenMode.Read)
    let buf = Array<Byte>(4096, repeat: 0)
    let all = ArrayList<Byte>()
    while (true) {
        let n = f.read(buf)
        if (n <= 0) { break }
        for (i in 0..n) { all.add(buf[Int64(i)]) }
    }
    f.close()
    let raw = Array<Byte>(all.size, repeat: 0)
    for (i in 0..all.size) { raw[i] = all[i] }
    String.fromUtf8(raw)
}
```

**Step 4: 跑测试确认通过**

Run: `cjpm test -j 16 --filter 'sysPrompt_.*'`
Expected: 9 个测试全 `PASSED`。

**Step 5: Commit**

```bash
git add src/context/system_prompt_builder.cj src/context/builder_test.cj
git commit -m "feat(context): SystemPromptBuilder 系统提示分段构建（4 段：systemPrompt/Skills/AGENTS.md/SessionContext）"
```

---

### Task 2: ContextBuilder 类

**Files:**
- Create: `src/context/builder.cj`
- Test: `src/context/builder_test.cj`（追加）

**Step 1: 写失败测试**

追加到 `src/context/builder_test.cj`：

```cangjie
import atelier.provider.*

@Test
func ctxBuilder_initMessages_injectsSystemMessage() {
    let b = ContextBuilder(SkillRegistry(), SessionEnvironment())
    let history = ArrayList<Message>([UserMessage(ContentList.ofText("hi"), 0)])
    let msgs = b.initMessages("sys", ArrayList(), history)
    @Expect(msgs.size, 2)
    match (msgs[0]) {
        case um: UserMessage =>
            match (um.content.blocks()[0]) {
                case ContentBlock.TextBlock(t) => @Expect(t.startsWith("sys"), true)
                case _ => @Expect(false, true)
            }
        case _ => @Expect(false, true)
    }
}

@Test
func ctxBuilder_initMessages_emptySystemNoInjection() {
    let b = ContextBuilder(SkillRegistry(), SessionEnvironment())
    let history = ArrayList<Message>([UserMessage(ContentList.ofText("hi"), 0)])
    let msgs = b.initMessages("", ArrayList(), history)
    @Expect(msgs.size, 1)
}

@Test
func ctxBuilder_initMessages_appendsHistory() {
    let b = ContextBuilder(SkillRegistry(), SessionEnvironment())
    let history = ArrayList<Message>()
    history.add(UserMessage(ContentList.ofText("a"), 0))
    history.add(UserMessage(ContentList.ofText("b"), 0))
    let msgs = b.initMessages("sys", ArrayList(), history)
    @Expect(msgs.size, 3)
    match (msgs[1]) {
        case um: UserMessage =>
            match (um.content.blocks()[0]) {
                case ContentBlock.TextBlock(t) => @Expect(t, "a")
                case _ => @Expect(false, true)
            }
        case _ => @Expect(false, true)
    }
}

@Test
func ctxBuilder_buildChatRequest_fields() {
    let b = ContextBuilder(SkillRegistry(), SessionEnvironment())
    let msgs = ArrayList<Message>([UserMessage(ContentList.ofText("hi"), 0)])
    let req = b.buildChatRequest("deepseek-chat", msgs, 0.3, 4096, Some("low"), ArrayList())
    @Expect(req.model, "deepseek-chat")
    @Expect(req.messages.size, 1)
    @Expect(req.temperature, 0.3)
    @Expect(req.maxTokens, 4096)
    @Expect(req.reasoningEffort, Some("low"))
    @Expect(req.tools.size, 0)
}
```

**Step 2: 跑测试确认失败**

Run: `cjpm test -j 16 --filter 'ctxBuilder_.*'`
Expected: 编译失败，`ContextBuilder` 未定义。

**Step 3: 实现**

创建 `src/context/builder.cj`：

```cangjie
package atelier.context

import atelier.message.*
import atelier.provider.*
import atelier.session.*
import atelier.skill.*
import std.collection.*

public class ContextBuilder {
    private let skills: SkillRegistry
    private let env: SessionEnvironment
    private let promptBuilder: SystemPromptBuilder

    public init(skills: SkillRegistry, env: SessionEnvironment) {
        this.skills = skills
        this.env = env
        this.promptBuilder = SystemPromptBuilder()
    }

    // run 一次：系统提示（若有）作为首条 UserMessage，再追加历史
    public func initMessages(systemPrompt: String, skillNames: ArrayList<String>,
        history: ArrayList<Message>): ArrayList<Message> {
        let result = ArrayList<Message>()
        let text = this.promptBuilder.build(systemPrompt, skillNames, this.skills, this.env)
        if (text != "") {
            result.add(UserMessage(ContentList.ofText(text), 0))
        }
        for (m in history) { result.add(m) }
        result
    }

    // 每轮：组装 ChatRequest（后续 P1 工具过滤 / P3 归档解析在此挂载）
    public func buildChatRequest(model: String, messages: ArrayList<Message>,
        temperature: Float64, maxOutputTokens: Int64,
        thinkingLevel: Option<String>, tools: ArrayList<OpenAITool>): ChatRequest {
        ChatRequest(model, messages, temperature, maxOutputTokens, thinkingLevel, tools)
    }
}
```

**Step 4: 跑测试确认通过**

Run: `cjpm test -j 16 --filter 'ctxBuilder_.*'`
Expected: 4 个测试全 `PASSED`。

**Step 5: Commit**

```bash
git add src/context/builder.cj src/context/builder_test.cj
git commit -m "feat(context): ContextBuilder L2 构建器（initMessages + buildChatRequest）"
```

---

### Task 3: runtime.cj 改造为委托调用

**Files:**
- Modify: `src/agent/runtime.cj:102-127, 137-139`（chatWithEnv 构建段）
- Modify: `src/agent/runtime.cj:505-567`（删除 `readFile`/`buildSystemPrompt`/`buildSystemPromptWithEnv`）
- Modify: `src/agent/runtime.cj:9, 14, 19`（import 调整）

**Step 1: 改造**

1. import 调整（第 9 行后加一行；第 14、19 行的 `std.fs.File`/`std.fs.*` 删除——`readFile`/`buildSystemPromptWithEnv` 删除后无其他 fs 用法）：

```cangjie
import atelier.context.compactMessages
import atelier.context.ContextBuilder
```

2. `chatWithEnv` 开头（`sessionId` 赋值后）创建构建器：

```cangjie
        let ctx = ToolContext(workDir, this.askUser, se.context)
        let sessionId = "sess_0"
        let ctxBuilder = ContextBuilder(this.skillRegistry, se)
```

3. 替换系统提示 + 首条消息组装（原 117-123 行）：

```cangjie
                // Build system prompt + assemble initial messages (L2)
                var currentMessages = ctxBuilder.initMessages(
                    this.config.systemPrompt, this.config.skills, messages)
```

4. 替换每轮 ChatRequest 组装（原 137-139 行）：

```cangjie
                    var chatReq = ctxBuilder.buildChatRequest(actualModel, currentMessages,
                        Float64(this.config.temperature), Int64(this.config.maxOutputTokens),
                        this.config.thinkingLevel, tools)
```

5. 删除文件末尾 `readFile`（505-518）、`buildSystemPrompt`（520-522）、`buildSystemPromptWithEnv`（524-567）三个函数。

**Step 2: 编译验证**

Run: `cjpm build -j 16`
Expected: `build success`，无编译错误（若报 unused import 警告属正常，确认删干净两个 fs import）。

**Step 3: 全量回归**

Run: `cjpm test -j 16 --no-progress`
Expected: `PASSED: 148, SKIPPED: 6, FAILED: 0`（基线不变，行为零变化）。

**Step 4: Commit**

```bash
git add src/agent/runtime.cj
git commit -m "refactor(runtime): 上下文构建委托 ContextBuilder/SystemPromptBuilder，删除内联 buildSystemPromptWithEnv"
```

---

### Task 4: 文档同步 + 最终验证

**Files:**
- Modify: `docs/design.md`（6.1 目录结构的 `context/` 段补两个文件）
- Modify: `docs/plans/2026-08-09-context-extension-design.md`（P0 相关标记更新）

**Step 1: 更新 design.md 目录结构**

`docs/design.md` 的 `context/` 段（当前为 `compaction.cj` / `tokens.cj` / `cutpoint.cj`）追加：

```text
│   ├── context/
│   │   ├── builder.cj              # L2 上下文构建器（系统提示 + 消息组装 + ChatRequest）
│   │   ├── system_prompt_builder.cj # 系统提示分段构建（固定前缀 + 动态后缀）
│   │   ├── compaction.cj           # 上下文压缩
```

**Step 2: 更新设计文档**

`docs/plans/2026-08-09-context-extension-design.md`：
- 9.1 模块卡片：`context/builder.cj`、`context/system_prompt_builder.cj` 两行状态从 🚧 改 ✅
- 3.2/3.3 节标注「已实现（P0）」，接口签名按实际代码替换示意代码

**Step 3: 最终验证**

Run: `cjpm test -j 16 --no-progress`
Expected: `PASSED: 148, SKIPPED: 6, FAILED: 0`

**Step 4: Commit + 合并**

```bash
git add docs/design.md docs/plans/2026-08-09-context-extension-design.md
git commit -m "docs: P0 构建器抽取完成，同步设计文档与目录结构"

# 合并回 master（按项目约定 --no-ff）
git checkout master && git pull
git merge --no-ff feat/context-builder -m "merge: P0 上下文构建器抽取（ContextBuilder + SystemPromptBuilder）"
git push
git branch -d feat/context-builder
```

---

## 验收清单（✅ 已完成，2026-08-09）

- [x] `cjpm test -j 16 --no-progress`：162 PASSED + 6 SKIPPED（148 基线 + 14 新测试，行为零变化）
- [x] SystemPromptBuilder 9 个单测：空配置/系统提示/Skills 注入/未知名跳过/AGENTS.md/目录缺失/会话上下文/无上下文/段顺序（含 AGENTS.md 段）
- [x] ContextBuilder 5 个单测：系统消息注入（精确 "sys\n\n"）/空系统不注入/历史追加（msgs[0]/msgs[2] 验证）/ChatRequest 直通/集成注入（skill + context）
- [x] `runtime.cj` 无 `buildSystemPromptWithEnv`/`buildSystemPrompt`/`readFile` 残留
- [x] 无 `context → agent` 依赖（参数拆开传递，AgentConfig 未引入）

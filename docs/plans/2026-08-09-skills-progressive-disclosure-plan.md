# Skills 渐进式披露实施计划（P2）

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Skill 从"config.skills 静态全量注入"升级为"目录常驻 + `use_skills` 按需激活"——LLM 通过系统提示中的 Skill 目录（name+description）发现能力，调用 `use_skills(name)` 获取完整指令。

**Architecture（方案 B：工具结果即指令，用户确认）:** `use_skills(name)` 工具直接返回 SKILL.md 指令全文作为 ToolResult 文本 → 指令进入对话历史，LLM 下一轮即可见。**无激活状态管理**（无 loadedSkills 状态、无系统提示注入改造）；天然幂等；跨请求靠会话历史保持（持久化后保留，被压缩 LLM 可再调用）。`SystemPromptBuilder` 新增 `buildSkillCatalog(skillRegistry)` 目录段（对称 `buildMcpCatalog`）；`ContextBuilder.initMessages` 拼接目录段（skills 字段 P0 已有，无需改构造）。`config.skills` 全量注入保留为兼容路径。

**Tech Stack:** 仓颉（cjpm）、无新外部依赖。

**与设计文档 10.4 的差异（已确认）：** 原设计"loadedSkills 状态 + 系统提示注入"不可行——REPL 每次消息创建新 runtime（无会话对象），状态放进程级会跨 agent 污染、放请求级每次丢失；改为"工具结果即指令"，无需状态。

**前置：** P1 已合并（master dbd6fab）。开分支 `git checkout -b feat/skills-on-demand`。

---

### Task 1: UseSkillsTool 工具

**Files:**
- Create: `src/tool/builtin/use_skills.cj`
- Test: `src/tool/builtin/tools_test.cj`（追加）

**Step 1: 写失败测试**

追加到 `src/tool/builtin/tools_test.cj`（先看该文件现有测试风格与 import——需要 `atelier.skill.*` 和 `jsonvalue.*`，缺则补 import）：

```cangjie
import atelier.skill.*

func fakeSkillEntry(name: String, desc: String, instructions: String): Skill {
    Skill(name, desc, None, None, HashMap(), ArrayList(), instructions, "")
}

@Test
func useSkills_returnsInstructions() {
    let reg = SkillRegistry()
    reg.register(fakeSkillEntry("code-review", "代码审查", "## 审查流程\n1. 读文件"))
    let tool = UseSkillsTool(reg)
    let args = HashMap<String, JsonValue>()
    args["name"] = JsonValue.String("code-review")
    let r = tool.execute(ToolContext("."), JsonValue.Map(args))
    @Expect(r.isError, false)
    @Expect(r.text.contains("## 审查流程"), true)
}

@Test
func useSkills_unknownSkillError() {
    let reg = SkillRegistry()
    let tool = UseSkillsTool(reg)
    let args = HashMap<String, JsonValue>()
    args["name"] = JsonValue.String("not-exist")
    let r = tool.execute(ToolContext("."), JsonValue.Map(args))
    @Expect(r.isError, true)
    @Expect(r.text.contains("未知"), true)
}

@Test
func useSkills_missingParamError() {
    let reg = SkillRegistry()
    let tool = UseSkillsTool(reg)
    let r = tool.execute(ToolContext("."), JsonValue.Map(HashMap()))
    @Expect(r.isError, true)
}
```

**Step 2: 跑测试确认失败**

Run: `cjpm test -j 16 --filter '*useSkills*'`
Expected: 编译失败（UseSkillsTool 未定义）。

**Step 3: 实现**

创建 `src/tool/builtin/use_skills.cj`（package atelier.tool.builtin；注意 builtin 包已有 ReadFileTool 等，参考其风格；Skill 在 atelier.skill 包；ToolContext 在 atelier.tool 包——builtin 包需要 import atelier.tool.*）：

```cangjie
package atelier.tool.builtin

import atelier.skill.*
import atelier.tool.*
import jsonvalue.*
import std.collection.*

public class UseSkillsTool <: Tool {
    private let skillRegistry: SkillRegistry

    public init(skillRegistry: SkillRegistry) {
        this.skillRegistry = skillRegistry
    }

    public func name(): String { "use_skills" }

    public func description(): String {
        "按名称加载一个 Skill 的完整指令到对话上下文。参数: name（技能名，如 \"code-review\"）。" +
        "加载后指令立即生效，后续对话按技能流程执行。"
    }

    public func schema(): JsonValue {
        SchemaBuilder()
            .addString("name", "Skill 名称", required: true)
            .build()
    }

    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        let name: String = match (args["name"]) {
            case Some(JsonValue.String(s)) => s
            case _ => return ToolResult("Missing required parameter: name", None, true, false)
        }
        match (this.skillRegistry.get(name)) {
            case Some(skill) =>
                let text = "# Skill: " + skill.name + "\n\n" + skill.instructions
                ToolResult(text, None, false, false)
            case None =>
                ToolResult("未知 Skill: " + name + "（可用工具列表查看可用技能）", None, true, false)
        }
    }

    public func executionMode(): ToolExecutionMode { ToolExecutionMode.Parallel }
}
```

**Step 4: 跑测试确认通过**

Run: `cjpm test -j 16 --filter '*useSkills*'`
Expected: 3 个测试全 PASSED。

**Step 5: Commit**

```bash
git add src/tool/builtin/use_skills.cj src/tool/builtin/tools_test.cj
git commit -m "feat(skill): use_skills 工具（按需加载 SKILL.md 指令，工具结果即指令）"
```

---

### Task 2: Skill 目录段（buildSkillCatalog + ContextBuilder 拼接）

**Files:**
- Modify: `src/context/system_prompt_builder.cj`（加 `buildSkillCatalog`）
- Modify: `src/context/builder.cj`（initMessages 拼接目录段）
- Test: `src/context/builder_test.cj`（追加）

**Step 1: 写失败测试**

追加到 `src/context/builder_test.cj`（文件已有 import atelier.skill.* 和 atelier.tool.*）：

```cangjie
func skillRegWith(name: String, desc: String): SkillRegistry {
    let reg = SkillRegistry()
    reg.register(Skill(name, desc, None, None, HashMap(), ArrayList(), "SKILL-BODY", ""))
    reg
}

@Test
func sysPrompt_skillCatalogInjected() {
    let spb = SystemPromptBuilder()
    let out = spb.buildSkillCatalog(skillRegWith("code-review", "代码审查技能"))
    @Expect(out.contains("use_skills"), true)
    @Expect(out.contains("code-review"), true)
    @Expect(out.contains("代码审查技能"), true)
}

@Test
func sysPrompt_skillCatalogEmptyWithoutSkills() {
    let spb = SystemPromptBuilder()
    @Expect(spb.buildSkillCatalog(SkillRegistry()), "")
}

@Test
func ctxBuilder_skillCatalogInSystemMessage() {
    let b = ContextBuilder(skillRegWith("code-review", "代码审查技能"), SessionEnvironment())
    let msgs = b.initMessages("sys", ArrayList(), ArrayList())
    @Expect(msgs.size, 1)
    match (msgs[0]) {
        case um: UserMessage =>
            match (um.content.blocks()[0]) {
                case ContentBlock.TextBlock(t) =>
                    @Expect(t.contains("use_skills"), true)
                    @Expect(t.contains("code-review"), true)
                case _ => @Expect(false, true)
            }
        case _ => @Expect(false, true)
    }
}
```

**Step 2: 跑测试确认失败**

Run: `cjpm test -j 16 --filter '*skillCatalog*'`
Expected: 编译失败（buildSkillCatalog 不存在）。

**Step 3: 实现**

`SystemPromptBuilder` 追加（src/context/system_prompt_builder.cj，SkillRegistry 已 import）：

```cangjie
    // 渐进披露第 1 层：Skill 目录段（name + description + use_skills 引导语；无 skill 返回 ""）
    public func buildSkillCatalog(skillRegistry: SkillRegistry): String {
        let skills = skillRegistry.list()
        if (skills.size == 0) { return "" }
        let sb = StringBuilder()
        sb.append("[可用 Skills]\n")
        sb.append("调用 use_skills(name) 加载对应技能的完整指令。\n")
        for (s in skills) {
            sb.append("- ")
            sb.append(s.name)
            if (s.description != "") {
                sb.append(": ")
                sb.append(s.description)
            }
            sb.append("\n")
        }
        sb.append("\n")
        sb.toString()
    }
```

`ContextBuilder.initMessages` 追加（src/context/builder.cj，在 mcpCatalog 拼接之后）：

```cangjie
        match (this.mcpManager) {
            case Some(m) =>
                let catalog = this.promptBuilder.buildMcpCatalog(m)
                if (catalog != "") { text = text + catalog }
            case None => ()
        }
        let skillCatalog = this.promptBuilder.buildSkillCatalog(this.skills)
        if (skillCatalog != "") { text = text + skillCatalog }
```

**Step 4: 跑测试确认通过**

Run: `cjpm test -j 16 --filter '*skillCatalog*'`、`cjpm test -j 16 --filter '*ctxBuilder*'`、`cjpm test -j 16 --filter '*sysPrompt*'`
Expected: 全部 PASSED（含新增 3 个；原有不回归）。

**Step 5: Commit**

```bash
git add src/context/system_prompt_builder.cj src/context/builder.cj src/context/builder_test.cj
git commit -m "feat(skill): 系统提示 Skill 目录段（name+description+use_skills 引导语）+ ContextBuilder 拼接"
```

---

### Task 3: main.cj 注册 + 文档同步 + 合并

**Files:**
- Modify: `src/cli/main.cj`（注册 UseSkillsTool）
- Modify: `docs/plans/2026-08-09-context-extension-design.md`（6.2/7.x 节 + 9.1 卡片 + 10.4 勾选）
- Modify: `docs/skills.md`（use_skills 用法）
- Modify: `docs/plans/2026-08-09-skills-progressive-disclosure-plan.md`（本文件验收清单）

**Step 1: main.cj 注册**

`skillReg` 创建后（约 29 行 `let skillReg = SkillRegistry()` 之后、`skillReg.loadDirectory` 之前或之后均可）加：

```cangjie
    toolReg.register(UseSkillsTool(skillReg))
```

（UseSkillsTool 在 atelier.tool.builtin 包，main.cj 已有 `import atelier.tool.builtin.*`）

**Step 2: 文档同步**

设计文档 `docs/plans/2026-08-09-context-extension-design.md`：
- 6.2 节「🚧 演进：渐进式披露」更新为「✅ P2 已实现」：方案 B（工具结果即指令）——`use_skills(name)` 返回 SKILL.md 指令全文进入对话历史；目录段 `[可用 Skills]`（name+description+引导语）；无激活状态（REPL 每次消息新建 runtime，会话级状态不可行）；`config.skills` 全量注入保留兼容；find_skills 不实现（YAGNI，目录段已含检索所需信息）
- 9.1 模块卡片：`tool/builtin/use_skills.cj` 加行（✅）
- 10.4 P2 任务标注「✅ 已完成（2026-08-09）」

`docs/skills.md`：追加"动态加载"小节：

```markdown
## 动态加载（use_skills）

Agent 通过调用 `use_skills(name)` 工具按需加载 Skill 指令：

- 系统提示中的 `[可用 Skills]` 目录段列出全部已注册技能（name + description）
- LLM 判断需要时调用 `use_skills(name)`，指令全文进入对话历史立即生效
- 与 `config.skills` 静态声明并存：静态声明的技能始终注入，动态技能按需加载
- 重复调用幂等；技能被上下文压缩后可再次调用加载
```

**Step 3: 最终验证**

Run: `cjpm build -j 16` → success
Run: `cjpm test -j 16 --no-progress` → 全部 PASSED（191 基线 + 新增 6）

**Step 4: 本文件验收清单勾选 + Commit + 合并**

```bash
git add src/cli/main.cj docs/plans/2026-08-09-context-extension-design.md docs/skills.md docs/plans/2026-08-09-skills-progressive-disclosure-plan.md
git commit -m "docs: P2 Skills 渐进式披露完成，同步设计文档/技能文档/实施计划"

git checkout master && git pull
git merge --no-ff feat/skills-on-demand -m "merge: P2 Skills 渐进式披露（use_skills 按需激活 + 目录段）"
git push
git branch -d feat/skills-on-demand
```

---

## 验收清单（✅ 已完成，2026-08-09）

- [x] `cjpm test -j 16 --no-progress`：191 基线 + 新增 6 全 PASSED
- [x] UseSkillsTool 3 单测：命中返回指令全文（含标题前缀）、未知 skill 报错、缺参报错
- [x] Skill 目录段 3 单测：有 skill 含引导语/name/description、无 skill 空、ContextBuilder 首条含目录段
- [x] `config.skills` 全量注入保留（兼容路径，无回归）
- [x] main.cj 注册 UseSkillsTool（serve/repl/run 三模式均可用）
- [x] find_skills 不实现（YAGNI，已确认）

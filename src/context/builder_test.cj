package atelier.context

import atelier.message.*
import atelier.provider.*
import atelier.session.*
import atelier.skill.*
import atelier.tool.*
import jsonvalue.*
import std.collection.*
import std.fs.*

func fakeSkill(name: String, instructions: String): Skill {
    Skill(name, "desc", None, None, HashMap(), ArrayList(), instructions, "")
}

func buildText(spb: SystemPromptBuilder, sp: String, names: ArrayList<String>,
    skills: SkillRegistry, env: SessionEnvironment): String {
    spb.build(sp, names, skills, env)
}

func pos(out: String, needle: String): Int64 {
    match (out.indexOf(needle)) {
        case Some(i) => i
        case None => -1
    }
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
    try {
        File.writeTo(dir.toString() + "/AGENTS.md", "项目规则内容".toArray())
        let env = SessionEnvironment(dir.toString(), HashMap())
        let spb = SystemPromptBuilder()
        let out = buildText(spb, "", ArrayList(), SkillRegistry(), env)
        @Expect(out.contains("[Project Rules]"), true)
        @Expect(out.contains("项目规则内容"), true)
    } finally {
        try { remove(Path(dir.toString()), recursive: true) } catch (_: Exception) {}
    }
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
    let dir = Directory.createTemp(Path("/tmp"))
    File.writeTo(dir.toString() + "/AGENTS.md", "AGENTS-CONTENT".toArray())
    try {
        let reg = SkillRegistry()
        reg.register(fakeSkill("s1", "SKILL-BODY"))
        let ctx = HashMap<String, String>()
        ctx["k"] = "v"
        let env = SessionEnvironment(dir.toString(), ctx)
        let spb = SystemPromptBuilder()
        let names = ArrayList<String>(["s1"])
        let out = buildText(spb, "SYS", names, reg, env)
        @Expect(pos(out, "SYS") < pos(out, "SKILL-BODY"), true)
        @Expect(pos(out, "SKILL-BODY") < pos(out, "[Project Rules]"), true)
        @Expect(pos(out, "[Project Rules]") < pos(out, "[Session Context]"), true)
    } finally {
        try { remove(Path(dir.toString()), recursive: true) } catch (_: Exception) {}
    }
}

@Test
func ctxBuilder_buildSystemText_returnsSystem() {
    let b = ContextBuilder(SkillRegistry(), SessionEnvironment())
    @Expect(b.buildSystemText("sys", ArrayList()), "sys\n\n")
}

@Test
func ctxBuilder_buildSystemText_empty() {
    let b = ContextBuilder(SkillRegistry(), SessionEnvironment())
    @Expect(b.buildSystemText("", ArrayList()), "")
}

@Test
func ctxBuilder_buildSystemText_withSkillAndContext() {
    let reg = SkillRegistry()
    reg.register(fakeSkill("code-review", "## 审查流程\n1. 读文件"))
    let ctx = HashMap<String, String>()
    ctx["workDir"] = "/home/x"
    let env = SessionEnvironment("", ctx)
    let b = ContextBuilder(reg, env)
    let names = ArrayList<String>(["code-review"])
    let text = b.buildSystemText("sys", names)
    @Expect(text.contains("sys"), true)
    @Expect(text.contains("## 审查流程"), true)
    @Expect(text.contains("[Session Context]"), true)
    @Expect(text.contains("workDir = /home/x"), true)
}

@Test
func ctxBuilder_buildChatRequest_fields() {
    let b = ContextBuilder(SkillRegistry(), SessionEnvironment())
    let msgs = ArrayList<Message>([UserMessage(ContentList.ofText("hi"), 0)])
    let req = b.buildChatRequest("deepseek-chat", "你是助手", msgs, 0.3, 4096, Some("low"), ArrayList())
    @Expect(req.model, "deepseek-chat")
    @Expect(req.messages.size, 1)
    @Expect(req.temperature, 0.3)
    @Expect(req.maxTokens, 4096)
    @Expect(req.reasoningEffort, Some("low"))
    @Expect(req.tools.size, 0)
    @Expect(req.systemPrompt, "你是助手")
}

func mcpManagerWithTools(name: String): McpManager {
    let m = McpManager()
    m.registerServer(McpServerConfig(name, "stdio", "echo", ""))
    m.updateServerInfo(name, "1.2.3", 2)
    let tools = ArrayList<(String, String)>()
    tools.add(("search_repos", "在 GitHub 上搜索仓库"))
    tools.add(("list_issues", "列出仓库 issues"))
    m.cacheServerTools(name, tools)
    m
}

@Test
func sysPrompt_mcpCatalogInjected() {
    let spb = SystemPromptBuilder()
    let out = spb.buildMcpCatalog(mcpManagerWithTools("github"))
    @Expect(out.contains("load_mcp_toolset"), true)
    @Expect(out.contains("github (v1.2.3, 2 个工具)"), true)
    @Expect(out.contains("search_repos"), true)
    @Expect(out.contains("在 GitHub 上搜索仓库"), true)
}

@Test
func sysPrompt_mcpCatalogActiveMarked() {
    let m = mcpManagerWithTools("github")
    m.activate("github")
    let spb = SystemPromptBuilder()
    let out = spb.buildMcpCatalog(m)
    @Expect(out.contains("[已加载]"), true)
}

@Test
func sysPrompt_mcpCatalogMissingVersionFallback() {
    let m = McpManager()
    m.registerServer(McpServerConfig("github", "stdio", "echo", ""))
    let tools = ArrayList<(String, String)>()
    tools.add(("search_repos", "在 GitHub 上搜索仓库"))
    m.cacheServerTools("github", tools)
    let spb = SystemPromptBuilder()
    let out = spb.buildMcpCatalog(m)
    @Expect(out.contains("github (v?, 1 个工具)"), true)
}

@Test
func sysPrompt_mcpCatalogEmptyWithoutServers() {
    let spb = SystemPromptBuilder()
    @Expect(spb.buildMcpCatalog(McpManager()), "")
}

@Test
func ctxBuilder_mcpCatalogInSystemText() {
    let b = ContextBuilder(SkillRegistry(), SessionEnvironment(), mcpManagerWithTools("github"))
    let text = b.buildSystemText("sys", ArrayList())
    @Expect(text.contains("load_mcp_toolset"), true)
    @Expect(text.contains("github"), true)
    @Expect(text.contains("sys"), true)
}

@Test
func ctxBuilder_noMcpNoCatalog() {
    let b = ContextBuilder(SkillRegistry(), SessionEnvironment())
    let text = b.buildSystemText("sys", ArrayList())
    @Expect(text.contains("load_mcp_toolset"), false)
    @Expect(text.contains("sys"), true)
}

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
func ctxBuilder_skillCatalogInSystemText() {
    let b = ContextBuilder(skillRegWith("code-review", "代码审查技能"), SessionEnvironment())
    let text = b.buildSystemText("sys", ArrayList())
    @Expect(text.contains("use_skills"), true)
    @Expect(text.contains("code-review"), true)
    @Expect(text.contains("sys"), true)
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
    archivedPair(msgs, 0, 99, "摘要")
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
func applyArchiveMarks_skipsRange() {
    let b = ContextBuilder(SkillRegistry(), SessionEnvironment())
    let msgs = ArrayList<Message>()
    msgs.add(plainMsg("m0"))
    msgs.add(plainMsg("m1"))
    msgs.add(plainMsg("m2"))
    msgs.add(ArchiveMessage(1, 2, "摘要", 0))
    let out = b.applyArchiveMarks(msgs)
    @Expect(out.size, 2)
    match (out[1]) {
        case am: ArchiveMessage => @Expect(am.summary, "摘要")
        case _ => @Fail("expected ArchiveMessage")
    }
}

@Test
func applyArchiveMarks_noMarkUnchanged() {
    let b = ContextBuilder(SkillRegistry(), SessionEnvironment())
    let msgs = ArrayList<Message>()
    msgs.add(plainMsg("m0"))
    msgs.add(plainMsg("m1"))
    @Expect(b.applyArchiveMarks(msgs).size, 2)
}

// 历史标记范围覆盖全部消息 → 结果为空 → 回退原列表（防空上下文）
@Test
func applyArchiveMarks_emptyResultFallsBack() {
    let b = ContextBuilder(SkillRegistry(), SessionEnvironment())
    let msgs = ArrayList<Message>()
    msgs.add(ArchiveMessage(0, 2, "摘要", 0))  // 范围 [0,2] 覆盖全部
    msgs.add(plainMsg("m0"))
    msgs.add(plainMsg("m1"))
    let out = b.applyArchiveMarks(msgs)
    @Expect(out.size, 3)
}

@Test
func applyArchives_nonArchiveToolPairIgnored() {
    let b = ContextBuilder(SkillRegistry(), SessionEnvironment())
    let msgs = ArrayList<Message>()
    msgs.add(plainMsg("m0"))
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

// 历史归档标记语义：标记在末尾、范围指向前面的消息 → 范围内消息被跳过，标记自身保留
@Test
func applyArchiveMarks_beforeArchives_order() {
    let b = ContextBuilder(SkillRegistry(), SessionEnvironment())
    let msgs = ArrayList<Message>()
    msgs.add(plainMsg("m0"))
    msgs.add(plainMsg("m1"))
    msgs.add(ArchiveMessage(0, 0, "旧摘要", 0))  // 历史标记在末尾，范围 [0,0]
    let out = b.applyArchiveMarks(msgs)
    @Expect(out.size, 2)
    match (out[0]) {
        case um: UserMessage =>
            match (um.content.blocks()[0]) {
                case ContentBlock.TextBlock(t) => @Expect(t, "m1")
                case _ => @Expect(false, true)
            }
        case _ => @Fail("expected m1 at index 0")
    }
}

// 完整链路顺序（Issue 2）：先 applyArchiveMarks 处理历史标记，再 applyArchives 处理本轮调用对
// 反向顺序会吞掉历史 Arch 标记，且新 Arch 的范围会跳过自身（摘要丢失）
@Test
func applyArchives_afterMarks_fullChain() {
    let b = ContextBuilder(SkillRegistry(), SessionEnvironment())
    let msgs = ArrayList<Message>()
    msgs.add(plainMsg("m0"))
    msgs.add(plainMsg("m1"))
    msgs.add(ArchiveMessage(0, 0, "旧摘要", 0))  // 历史标记在末尾，范围 [0,0]
    archivedPair(msgs, 1, 1, "本轮摘要")         // 本轮归档调用对 [m1]
    // 正向顺序：标记阶段跳过 m0（历史范围），归档阶段把调用对替换为 ArchiveMessage
    let marked = b.applyArchiveMarks(msgs)
    @Expect(marked.size, 4)
    let out = b.applyArchives(marked)
    @Expect(out.size, 2)
    match (out[0]) {
        case um: UserMessage =>
            match (um.content.blocks()[0]) {
                case ContentBlock.TextBlock(t) => @Expect(t, "m1")
                case _ => @Expect(false, true)
            }
        case _ => @Fail("expected m1 at index 0")
    }
    match (out[1]) {
        case am: ArchiveMessage =>
            @Expect(am.startIndex, 1)
            @Expect(am.endIndex, 1)
            @Expect(am.summary, "本轮摘要")
        case _ => @Fail("expected ArchiveMessage at index 1")
    }
    // 反向顺序对照：先归档会吞掉历史 Arch(0,0) 与新 Arch 标记自身，只剩 m0
    let reversed = b.applyArchiveMarks(b.applyArchives(msgs))
    @Expect(reversed.size, 1)
    match (reversed[0]) {
        case um: UserMessage =>
            match (um.content.blocks()[0]) {
                case ContentBlock.TextBlock(t) => @Expect(t, "m0")
                case _ => @Expect(false, true)
            }
        case _ => @Fail("expected m0 at index 0")
    }
}

// ========== PromptSegmentContributor：自定义系统提示段（宿主扩展点） ==========

class StubContributor <: PromptSegmentContributor {
    public var calls: Int64 = 0
    private let text: String
    public init(text: String) { this.text = text }
    public func render(env: SessionEnvironment): String {
        this.calls++
        this.text
    }
}

@Test
func sysPrompt_contributorAppended() {
    let spb = SystemPromptBuilder()
    let cs = ArrayList<PromptSegmentContributor>()
    cs.add(StubContributor("[Tenant Rules]\n内部数据不得外泄"))
    let out = spb.build("你是助手", ArrayList(), SkillRegistry(), SessionEnvironment(), contributors: cs)
    @Expect(out.contains("[Tenant Rules]"), true)
    @Expect(out.endsWith("内部数据不得外泄\n\n"), true)
}

@Test
func sysPrompt_contributorEmptySkipped() {
    let spb = SystemPromptBuilder()
    let cs = ArrayList<PromptSegmentContributor>()
    cs.add(StubContributor(""))
    let out = spb.build("你是助手", ArrayList(), SkillRegistry(), SessionEnvironment(), contributors: cs)
    @Expect(out, "你是助手\n\n")
}

@Test
func sysPrompt_multipleContributorsInOrder() {
    let spb = SystemPromptBuilder()
    let cs = ArrayList<PromptSegmentContributor>()
    cs.add(StubContributor("[段一]"))
    cs.add(StubContributor("[段二]"))
    let out = spb.build("", ArrayList(), SkillRegistry(), SessionEnvironment(), contributors: cs)
    @Expect(pos(out, "[段一]") >= Int64(0), true)
    @Expect(pos(out, "[段二]") > pos(out, "[段一]"), true)
}
func archivedPair(msgs: ArrayList<Message>, start: Int64, end: Int64, summary: String): Unit {
    let args = HashMap<String, JsonValue>()
    args["start_index"] = JsonValue.Number(Float64(start))
    args["end_index"] = JsonValue.Number(Float64(end))
    args["summary"] = JsonValue.String(summary)
    let tc = ToolCallBlock("call_1", "archive_history", JsonValue.Map(args))
    let blocks = ArrayList<ContentBlock>()
    blocks.add(ContentBlock.ToolCall(tc))
    msgs.add(AssistantMessage(ContentList(blocks), "", "", StopReason.ToolUse, TokenUsage(0, 0), 0))
    msgs.add(ToolResultMessage("call_1", "archive_history", ContentList.ofText("已归档..."), false, 0))
}

func plainMsg(text: String): Message {
    UserMessage(ContentList.ofText(text), 0)
}


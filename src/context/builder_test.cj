package atelier.context

import atelier.message.*
import atelier.provider.*
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
    let reg = SkillRegistry()
    reg.register(fakeSkill("s1", "SKILL-BODY"))
    let ctx = HashMap<String, String>()
    ctx["k"] = "v"
    let env = SessionEnvironment("", ctx)
    let spb = SystemPromptBuilder()
    let names = ArrayList<String>(["s1"])
    let out = buildText(spb, "SYS", names, reg, env)
    @Expect(pos(out, "SYS") < pos(out, "SKILL-BODY"), true)
    @Expect(pos(out, "SKILL-BODY") < pos(out, "[Session Context]"), true)
}

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

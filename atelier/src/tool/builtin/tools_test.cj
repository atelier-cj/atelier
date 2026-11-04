package atelier.tool.builtin

import std.fs.*
import std.collection.*
import jsonvalue.*
import atelier.tool.*
import atelier.interaction.*
import atelier.skill.*

func makeCtx(): ToolContext {
    ToolContext("/tmp")
}

func createTempDir(): String {
    Directory.createTemp(Path("/tmp")).toString()
}

func removeDir(p: String) {
    remove(Path(p), recursive: true)
}

@Test
func readFile_toolMetadata() {
    let tool = ReadFileTool()
    @Expect(tool.name(), "read_file")
    @Expect(tool.description() != "", true)
}

@Test
func readFile_fileExists() {
    let dir = createTempDir()
    File.writeTo(Path(dir + "/test.txt"), "hello\nworld".toArray())
    let ctx = ToolContext(dir)
    let args = HashMap<String, JsonValue>()
    args.add("path", JsonValue.String("test.txt"))
    let result = ReadFileTool().execute(ctx, JsonValue.Map(args))
    @Expect(result.isError, false)
    @Expect(result.text.contains("hello"), true)
    removeDir(dir)
}

@Test
func readFile_notFound() {
    let ctx = ToolContext("/tmp")
    let args = HashMap<String, JsonValue>()
    args.add("path", JsonValue.String("nonexistent.txt"))
    let result = ReadFileTool().execute(ctx, JsonValue.Map(args))
    @Expect(result.isError, true)
}

@Test
func writeFile_createsNew() {
    let dir = createTempDir()
    let ctx = ToolContext(dir)
    let args = HashMap<String, JsonValue>()
    args.add("path", JsonValue.String("new.txt"))
    args.add("content", JsonValue.String("hello"))
    let result = WriteFileTool().execute(ctx, JsonValue.Map(args))
    @Expect(result.isError, false)
    removeDir(dir)
}

@Test
func writeFile_existingFails() {
    let dir = createTempDir()
    File.writeTo(Path(dir + "/existing.txt"), "old".toArray())
    let ctx = ToolContext(dir)
    let args = HashMap<String, JsonValue>()
    args.add("path", JsonValue.String("existing.txt"))
    args.add("content", JsonValue.String("new"))
    let result = WriteFileTool().execute(ctx, JsonValue.Map(args))
    @Expect(result.isError, true)
    removeDir(dir)
}

@Test
func bash_echo() {
    let ctx = makeCtx()
    let args = HashMap<String, JsonValue>()
    args.add("command", JsonValue.String("echo hello"))
    let result = BashTool().execute(ctx, JsonValue.Map(args))
    @Expect(result.isError, false)
    @Expect(result.text.contains("hello"), true)
}

@Test
func bash_failure() {
    let ctx = makeCtx()
    let args = HashMap<String, JsonValue>()
    args.add("command", JsonValue.String("exit 1"))
    let result = BashTool().execute(ctx, JsonValue.Map(args))
    @Expect(result.isError, true)
}

@Test
func todo_addAndList() {
    let tool = TodoTool()
    let ctx = makeCtx()

    let addArgs = HashMap<String, JsonValue>()
    addArgs.add("action", JsonValue.String("add"))
    addArgs.add("item", JsonValue.String("my task"))
    let r1 = tool.execute(ctx, JsonValue.Map(addArgs))
    @Expect(r1.isError, false)

    let listArgs = HashMap<String, JsonValue>()
    listArgs.add("action", JsonValue.String("list"))
    let r2 = tool.execute(ctx, JsonValue.Map(listArgs))
    @Expect(r2.isError, false)
    @Expect(r2.text.contains("my task"), true)
}

@Test
func executor_unknownTool() {
    let reg = ToolRegistry()
    let exec = ToolExecutor(reg)
    let args = HashMap<String, JsonValue>()
    args.add("path", JsonValue.String("x"))
    let result = exec.execute("nonexistent", makeCtx(), JsonValue.Map(args))
    @Expect(result.isError, true)
    @Expect(result.text.contains("not found"), true)
}

@Test
func tool_glob() {
    let dir = createTempDir()
    File.writeTo(Path(dir + "/a.txt"), "".toArray())
    File.writeTo(Path(dir + "/b.txt"), "".toArray())
    let ctx = ToolContext(dir)
    let args = HashMap<String, JsonValue>()
    args.add("pattern", JsonValue.String("*"))
    let result = GlobTool().execute(ctx, JsonValue.Map(args))
    @Expect(result.isError, false)
    @Expect(result.text.contains("a.txt"), true)
    @Expect(result.text.contains("b.txt"), true)
    removeDir(dir)
}

@Test
func tool_grep() {
    let dir = createTempDir()
    File.writeTo(Path(dir + "/data.txt"), "apple\nbanana\ncherry".toArray())
    let ctx = ToolContext(dir)
    let args = HashMap<String, JsonValue>()
    args.add("pattern", JsonValue.String("apple"))
    let result = GrepTool().execute(ctx, JsonValue.Map(args))
    @Expect(result.isError, false)
    @Expect(result.text.contains("apple"), true)
    removeDir(dir)
}

@Test
func tool_glob_respectsGitignore() {
    let ctx = ToolContext(".")
    let args = HashMap<String, JsonValue>()
    args.add("pattern", JsonValue.String("*"))
    let result = GlobTool().execute(ctx, JsonValue.Map(args))
    @Expect(result.isError, false)
    // .gitignore excludes target dir
    @Expect(result.text.contains("target"), false)
}

@Test
func tool_glob_noIgnoreIncludesAll() {
    let ctx = ToolContext(".")
    let args = HashMap<String, JsonValue>()
    // 递归要用 `**/*`：`*` 按 glob 语义只匹配顶层（本用例要验的是 noIgnore 绕过 gitignore，
    // 原先写 `*` 其实依赖了"`*` 会递归"这个错误行为）
    args.add("pattern", JsonValue.String("**/*"))
    args.add("noIgnore", JsonValue.String("true"))
    let result = GlobTool().execute(ctx, JsonValue.Map(args))
    @Expect(result.isError, false)
    // With noIgnore=true, target dir should appear
    @Expect(result.text.contains("target"), true)
}

func fakeSkillEntry(name: String, desc: String, instructions: String): Skill {
    Skill(name, desc, None, None, HashMap(), ArrayList(), instructions, "")
}

@Test
func useSkills_returnsInstructions() {
    let reg = SkillRegistry()
    reg.register(fakeSkillEntry("code-review", "代码审查", "## 审查流程\n1. 读文件"))
    let tool = UseSkillsTool(reg)
    let args = HashMap<String, JsonValue>()
    args.add("name", JsonValue.String("code-review"))
    let r = tool.execute(ToolContext("."), JsonValue.Map(args))
    @Expect(r.isError, false)
    @Expect(r.text.contains("## 审查流程"), true)
}

@Test
func useSkills_unknownSkillError() {
    let reg = SkillRegistry()
    let tool = UseSkillsTool(reg)
    let args = HashMap<String, JsonValue>()
    args.add("name", JsonValue.String("not-exist"))
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

@Test
func useSkills_listsResources() {
    let dir = createTempDir()
    Directory.create(dir + "/references", recursive: true)
    Directory.create(dir + "/scripts", recursive: true)
    File.writeTo(Path(dir + "/references/REFERENCE.md"), "参考内容".toArray())
    File.writeTo(Path(dir + "/scripts/run.sh"), "echo hi".toArray())
    File.writeTo(Path(dir + "/SKILL.md"), "---\nname: demo\n---\n指令".toArray())
    try {
        let reg = SkillRegistry()
        reg.register(Skill("demo", "desc", None, None, HashMap(), ArrayList(),
            "指令", dir))
        let tool = UseSkillsTool(reg)
        let args = HashMap<String, JsonValue>()
        args.add("name", JsonValue.String("demo"))
        let r = tool.execute(ToolContext("."), JsonValue.Map(args))
        @Expect(r.isError, false)
        @Expect(r.text.contains("REFERENCE.md"), true)
        @Expect(r.text.contains("run.sh"), true)
        @Expect(r.text.contains("SKILL.md"), false)
    } finally {
        removeDir(dir)
    }
}

@Test
func useSkills_noResourcesNoSection() {
    let reg = SkillRegistry()
    reg.register(Skill("plain", "desc", None, None, HashMap(), ArrayList(),
        "指令", ""))
    let tool = UseSkillsTool(reg)
    let args = HashMap<String, JsonValue>()
    args.add("name", JsonValue.String("plain"))
    let r = tool.execute(ToolContext("."), JsonValue.Map(args))
    @Expect(r.isError, false)
    @Expect(r.text.contains("资源文件"), false)
}

@Test
func askUserTool_declaresUnboundedBudget() {
    // 本工具的时间花在等人回答上：套上框架预算的后果是「用户想了 31 秒，
    // 模型却收到一句超时」——人思考多久都不算工具卡死
    let tool = AskUserTool()
    match (tool.timeoutBudget()) {
        case ToolBudget.Unbounded => ()
        case ToolBudget.Default => @Fail("ask_user must declare Unbounded, not Default")
        case ToolBudget.Limit(_) => @Fail("ask_user must not declare a limit")
    }
    // 而且即使框架两类预算都配了，它也不吃
    let policy = ToolBudgetPolicy(
        Some(Duration.second * 30), Some(Duration.second * 300))
    match (policy.forTool(tool)) {
        case None => ()
        case Some(_) => @Fail("read-only/side-effect budgets must not apply to ask_user")
    }
}

// ── ask_user 三形态 ─────────────────────────────────────────────────────────
// 旧的 ask_user 只能问一句、拿一段字符串；现在同一入口覆盖 纯提问 / 选择 / 表单，
// 且答复一律过 runtime 侧校验（校验失败时退化为"把原文交给模型并标注降级"，
// 因为纯文本通道的宿主没有渲染选项/表单的能力）。

@Test
func askUser_plainQuestionBecomesSingleTextFieldForm() {
    let args = HashMap<String, JsonValue>()
    args.add("question", JsonValue.String("你的名字？"))
    // 纯文本宿主（默认 ToolContext）答空 → 视为取消，工具必须明确报错而不是返回空结果
    let r = AskUserTool().execute(ToolContext("."), JsonValue.Map(args))
    @Expect(r.isError, true)
}

@Test
func askUser_optionsBuildsChoiceRequest() {
    // 参数解析：["a","b"] 与 [{id,label}] 两种写法都要收
    let opts = JsonValue.parse("[\"dev\",{\"id\":\"ops\",\"label\":\"运维\"}]")
    let parsed = parseOptions(Some(opts))
    @Expect(parsed.size, 2)
    @Expect(parsed[0].id, "dev")
    @Expect(parsed[1].label, "运维")
}

@Test
func askUser_fieldsParsesTypesAndRequired() {
    let raw = JsonValue.parse(
        "[{\"name\":\"env\",\"type\":\"select\",\"required\":true,\"options\":[\"prod\",\"test\"]}," +
        "{\"name\":\"count\",\"type\":\"number\"},{\"name\":\"note\"}]")
    let fields = parseFields(Some(raw))
    @Expect(fields.size, 3)
    @Expect(fields[0].required, true)
    @Expect(fields[0].options.size, 2)
    let t1 = fieldTypeName(fields[1].fieldType)
    @Expect(t1, "number")
    let t2 = fieldTypeName(fields[2].fieldType)
    @Expect(t2, "text")
}

@Test
func askUser_missingQuestionIsAnError() {
    let r = AskUserTool().execute(ToolContext("."), JsonValue.parse("{}"))
    @Expect(r.isError, true)
    @Expect(r.text.contains("question"), true)
}

// ---------- bash 后台模式 ----------

// 后台通道替身：同步执行 work 并记下结果，测试里不必和线程赛跑
class CapturingBackground {
    public let submitted = ArrayList<String>()
    public var text = ""
    public var failed = false
    public let done = ArrayList<String>()

    public func submit(requestId: String, toolCallId: String, toolName: String,
        work: BackgroundWork): Unit {
        this.submitted.add(requestId)
        let (t, f) = work()
        this.text = t
        this.failed = f
        this.done.add(requestId)
    }
}

@Test
func bash_backgroundReturnsImmediately() {
    // 关键行为：带 background=true 时**不等待命令完成**，立刻返回挂起请求
    let cap = CapturingBackground()
    let ctx = ToolContext(".", HashMap<String, String>(), "",
        toolCallId: "call-42", background: Some({ r, c, n, w => cap.submit(r, c, n, w) }))
    let args = HashMap<String, JsonValue>()
    args.add("command", JsonValue.String("echo backgrounded"))
    args.add("background", JsonValue.Boolean(true))
    let result = BashTool().execute(ctx, JsonValue.Map(args))

    // 必须声明挂起（external），否则 run 不会中断，等于还是同步
    @Expect(result.external.isSome(), true)
    match (result.external) {
        case Some(req) =>
            @Expect(req.reason, AsyncTaskReason)
            @Expect(req.toolCallId, "call-42")
            @Expect(req.id, "async-call-42")
        case None => @Fail("应带 external")
    }
    // 不是错误
    @Expect(result.isError, false)
    // 任务确实交出去了，且跑出了结果
    @Expect(cap.submitted.size, 1)
    @Expect(cap.text.contains("backgrounded"), true)
    @Expect(cap.failed, false)
}

@Test
func bash_backgroundFallbackWhenNoChannel() {
    // 没有后台通道时必须**回退同步执行**——不能因为宿主没实现就静默不干活
    let ctx = ToolContext(".", HashMap<String, String>(), "", toolCallId: "c1")
    let args = HashMap<String, JsonValue>()
    args.add("command", JsonValue.String("echo sync-fallback"))
    args.add("background", JsonValue.Boolean(true))
    let result = BashTool().execute(ctx, JsonValue.Map(args))
    // 没有挂起：直接在本次调用里给出了结果
    @Expect(result.external.isNone(), true)
    @Expect(result.text.contains("sync-fallback"), true)
}

@Test
func bash_backgroundCapturesFailure() {
    // 后台任务失败也要如实上报，不能吞成成功
    let cap = CapturingBackground()
    let ctx = ToolContext(".", HashMap<String, String>(), "",
        toolCallId: "c9", background: Some({ r, c, n, w => cap.submit(r, c, n, w) }))
    let args = HashMap<String, JsonValue>()
    args.add("command", JsonValue.String("exit 3"))
    args.add("background", JsonValue.Boolean(true))
    BashTool().execute(ctx, JsonValue.Map(args))
    @Expect(cap.failed, true)
}

@Test
func bash_noBackgroundParamStaysSync() {
    // 不传 background 时行为完全不变（向后兼容）
    let ctx = makeCtx()
    let args = HashMap<String, JsonValue>()
    args.add("command", JsonValue.String("echo plain"))
    let result = BashTool().execute(ctx, JsonValue.Map(args))
    @Expect(result.external.isNone(), true)
    @Expect(result.text.contains("plain"), true)
}

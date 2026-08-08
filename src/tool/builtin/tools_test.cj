package atelier.tool.builtin

import std.fs.*
import std.collection.*
import jsonvalue.*
import atelier.tool.*
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
    args.add("pattern", JsonValue.String("*"))
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

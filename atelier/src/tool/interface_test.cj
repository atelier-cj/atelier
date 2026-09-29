package atelier.tool

import std.collection.*
import jsonvalue.*

// ── Helper: MockTool for testing ─────────────────────────────

class MockTool <: Tool {
    let _name: String
    let _description: String
    let _schema: JsonValue
    let _executionMode: ToolExecutionMode
    let _result: ToolResult

    public init(
        name: String,
        description: String,
        schema: JsonValue,
        executionMode: ToolExecutionMode,
        result: ToolResult
    ) {
        this._name = name
        this._description = description
        this._schema = schema
        this._executionMode = executionMode
        this._result = result
    }

    public func name(): String {
        this._name
    }

    public func description(): String {
        this._description
    }

    public func schema(): JsonValue {
        this._schema
    }

    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        this._result
    }

    public func executionMode(): ToolExecutionMode {
        this._executionMode
    }
}

// ── Test 1: ToolResult creation with various fields ──────────

@Test
func toolResult_defaultSuccess() {
    let result = ToolResult("operation completed", None, false, false)
    @Expect(result.text, "operation completed")
    match (result.details) {
        case None => ()
        case Some(_) => @Fail("expected None details")
    }
    @Expect(result.isError, false)
    @Expect(result.terminate, false)
}

@Test
func toolResult_withDetails() {
    let detailsObj = HashMap<String, JsonValue>()
    detailsObj.add("key", JsonValue.String("value"))
    let details = JsonValue.Map(detailsObj)
    let result = ToolResult("data processed", Some(details), false, false)
    @Expect(result.text, "data processed")
    match (result.details) {
        case Some(jv) =>
            match (jv["key"]) {
                case Some(JsonValue.String(s)) => @Expect(s, "value")
                case _ => @Fail("expected string value")
            }
        case None => @Fail("expected Some details")
    }
    @Expect(result.isError, false)
    @Expect(result.terminate, false)
}

@Test
func toolResult_error() {
    let result = ToolResult("file not found", None, true, false)
    @Expect(result.text, "file not found")
    @Expect(result.isError, true)
    @Expect(result.terminate, false)
}

@Test
func toolResult_terminate() {
    let result = ToolResult("fatal error", None, true, true)
    @Expect(result.text, "fatal error")
    @Expect(result.isError, true)
    @Expect(result.terminate, true)
}

// ── Test 2: ToolContext creation ─────────────────────────────

@Test
func toolContext_creation() {
    let ctx = ToolContext("/home/user/projects")
    @Expect(ctx.workDir, "/home/user/projects")
}

@Test
func toolContext_emptyWorkDir() {
    let ctx = ToolContext("")
    @Expect(ctx.workDir, "")
}

// ── Test 3: MockTool implementing Tool interface ─────────────

@Test
func mockTool_name() {
    let schema = JsonValue.Map(HashMap<String, JsonValue>())
    let result = ToolResult("ok", None, false, false)
    let tool = MockTool("get_weather", "Get current weather", schema, ToolExecutionMode.Sequential, result)
    @Expect(tool.name(), "get_weather")
}

@Test
func mockTool_description() {
    let schema = JsonValue.Map(HashMap<String, JsonValue>())
    let result = ToolResult("ok", None, false, false)
    let tool = MockTool("get_time", "Get the current time", schema, ToolExecutionMode.Parallel, result)
    @Expect(tool.description(), "Get the current time")
}

@Test
func mockTool_schema() {
    let schemaObj = HashMap<String, JsonValue>()
    schemaObj.add("type", JsonValue.String("object"))
    let schema = JsonValue.Map(schemaObj)
    let result = ToolResult("ok", None, false, false)
    let tool = MockTool("echo", "Echo input", schema, ToolExecutionMode.Sequential, result)
    let gotSchema = tool.schema()
    match (gotSchema["type"]) {
        case Some(JsonValue.String(s)) => @Expect(s, "object")
        case _ => @Fail("expected type string")
    }
}

@Test
func mockTool_executionMode() {
    let schema = JsonValue.Map(HashMap<String, JsonValue>())
    let result = ToolResult("ok", None, false, false)
    let tool = MockTool("parallel_tool", "A parallel tool", schema, ToolExecutionMode.Parallel, result)
    match (tool.executionMode()) {
        case ToolExecutionMode.Parallel => ()
        case _ => @Fail("expected Parallel mode")
    }
}

@Test
func mockTool_sequentialExecutionMode() {
    let schema = JsonValue.Map(HashMap<String, JsonValue>())
    let result = ToolResult("ok", None, false, false)
    let tool = MockTool("sequential_tool", "A sequential tool", schema, ToolExecutionMode.Sequential, result)
    match (tool.executionMode()) {
        case ToolExecutionMode.Sequential => ()
        case _ => @Fail("expected Sequential mode")
    }
}

@Test
func mockTool_execute() {
    let schema = JsonValue.Map(HashMap<String, JsonValue>())
    let expectedResult = ToolResult("hello world", None, false, false)
    let tool = MockTool("greet", "Greets the user", schema, ToolExecutionMode.Sequential, expectedResult)
    let ctx = ToolContext("/tmp")
    let args = JsonValue.Map(HashMap<String, JsonValue>())
    let result = tool.execute(ctx, args)
    @Expect(result.text, "hello world")
    @Expect(result.isError, false)
}

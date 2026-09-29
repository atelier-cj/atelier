package atelier.tool

import std.collection.*
import jsonvalue.*

// ── Helper: create a MockTool ────────────────────────────────

func makeMockTool(name: String, description: String, mode: ToolExecutionMode): MockTool {
    let schema = JsonValue.Map(HashMap<String, JsonValue>())
    let result = ToolResult("done", None, false, false)
    return MockTool(name, description, schema, mode, result)
}

func makeDefaultResult(): ToolResult {
    return ToolResult("done", None, false, false)
}

// ── Test 1: ToolRegistry: register, get, list, has, remove ──

@Test
func registry_registerAndGet() {
    let registry = ToolRegistry()
    let tool = makeMockTool("read_file", "Read a file", ToolExecutionMode.Sequential)
    registry.register(tool)

    let retrieved = registry.get("read_file")
    match (retrieved) {
        case Some(t) => @Expect(t.name(), "read_file")
        case None => @Fail("expected to find read_file tool")
    }
}

@Test
func registry_get_returnsNoneForMissing() {
    let registry = ToolRegistry()
    let retrieved = registry.get("non_existent")
    match (retrieved) {
        case None => ()
        case Some(_) => @Fail("expected None for non-existent tool")
    }
}

@Test
func registry_has() {
    let registry = ToolRegistry()
    let tool = makeMockTool("bash", "Run bash commands", ToolExecutionMode.Sequential)
    registry.register(tool)
    @Expect(registry.has("bash"), true)
    @Expect(registry.has("non_existent"), false)
}

@Test
func registry_list() {
    let registry = ToolRegistry()
    registry.register(makeMockTool("tool_a", "Tool A", ToolExecutionMode.Parallel))
    registry.register(makeMockTool("tool_b", "Tool B", ToolExecutionMode.Sequential))
    registry.register(makeMockTool("tool_c", "Tool C", ToolExecutionMode.Parallel))

    let tools = registry.list()
    @Expect(tools.size, 3)

    // Verify all names are present
    let names = ArrayList<String>()
    for (t in tools) {
        names.add(t.name())
    }
    @Expect(names.contains("tool_a"), true)
    @Expect(names.contains("tool_b"), true)
    @Expect(names.contains("tool_c"), true)
}

@Test
func registry_list_empty() {
    let registry = ToolRegistry()
    let tools = registry.list()
    @Expect(tools.size, 0)
}

@Test
func registry_remove() {
    let registry = ToolRegistry()
    registry.register(makeMockTool("temp_tool", "Temporary", ToolExecutionMode.Sequential))
    @Expect(registry.has("temp_tool"), true)

    registry.remove("temp_tool")
    @Expect(registry.has("temp_tool"), false)
}

@Test
func registry_remove_nonExistent() {
    let registry = ToolRegistry()
    // Should not throw
    registry.remove("does_not_exist")
    @Expect(registry.list().size, 0)
}

// ── Test 2: Duplicate name overwrites ────────────────────────

@Test
func registry_registerDuplicate_overwrites() {
    let registry = ToolRegistry()

    let tool1 = MockTool(
        "duplicate",
        "First version",
        JsonValue.Map(HashMap<String, JsonValue>()),
        ToolExecutionMode.Sequential,
        ToolResult("v1", None, false, false)
    )
    registry.register(tool1)

    let tool2 = MockTool(
        "duplicate",
        "Second version",
        JsonValue.Map(HashMap<String, JsonValue>()),
        ToolExecutionMode.Parallel,
        ToolResult("v2", None, false, false)
    )
    registry.register(tool2)

    // Should only have one tool with name "duplicate"
    let tools = registry.list()
    @Expect(tools.size, 1)

    // Should be the second one (overwritten)
    let retrieved = registry.get("duplicate")
    match (retrieved) {
        case Some(t) => @Expect(t.description(), "Second version")
        case None => @Fail("expected duplicate tool to exist")
    }
}

// ── Test 3: Full lifecycle ───────────────────────────────────

@Test
func registry_fullLifecycle() {
    let registry = ToolRegistry()

    // Initially empty
    @Expect(registry.list().size, 0)
    @Expect(registry.has("any"), false)

    // Register tools
    registry.register(makeMockTool("tool1", "First tool", ToolExecutionMode.Sequential))
    registry.register(makeMockTool("tool2", "Second tool", ToolExecutionMode.Parallel))
    @Expect(registry.list().size, 2)
    @Expect(registry.has("tool1"), true)
    @Expect(registry.has("tool2"), true)

    // Get each tool
    match (registry.get("tool1")) {
        case Some(t) => @Expect(t.name(), "tool1")
        case None => @Fail("tool1 should exist")
    }

    // Remove one
    registry.remove("tool1")
    @Expect(registry.list().size, 1)
    @Expect(registry.has("tool1"), false)
    @Expect(registry.has("tool2"), true)

    // Remove the other
    registry.remove("tool2")
    @Expect(registry.list().size, 0)
    @Expect(registry.has("tool2"), false)
}

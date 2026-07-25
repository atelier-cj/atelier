package atelier.tool.builtin

import std.collection.*
import jsonvalue.*
import atelier.tool.*

/**
 * Stateful todo list tool.
 * Maintains an in-memory list of todo items.
 * Supports: list, add, complete, remove.
 */
public class TodoTool <: Tool {
    // Shared state across all invocations
    let items: ArrayList<TodoItem>

    public init() {
        this.items = ArrayList<TodoItem>()
    }

    public func name(): String {
        "todo"
    }

    public func description(): String {
        "Manage a todo list. Supports actions: list, add, complete, remove."
    }

    public func schema(): JsonValue {
        let obj = HashMap<String, JsonValue>()
        obj.add("type", JsonValue.String("object"))

        let properties = HashMap<String, JsonValue>()

        let actionProp = HashMap<String, JsonValue>()
        actionProp.add("type", JsonValue.String("string"))
        actionProp.add("description", JsonValue.String("Action to perform: list, add, complete, or remove"))
        actionProp.add("enum", createEnumArray())
        properties.add("action", JsonValue.Map(actionProp))

        let itemProp = HashMap<String, JsonValue>()
        itemProp.add("type", JsonValue.String("string"))
        itemProp.add("description", JsonValue.String("Item text (required for add, complete, remove actions)"))
        properties.add("item", JsonValue.Map(itemProp))

        obj.add("properties", JsonValue.Map(properties))

        let required = ArrayList<JsonValue>()
        required.add(JsonValue.String("action"))
        obj.add("required", JsonValue.Array(required))

        JsonValue.Map(obj)
    }

    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        let action: String = match (args["action"]) {
            case Some(JsonValue.String(s)) => s
            case _ => return ToolResult("Missing required parameter: action", None, true, false)
        }
        let item: String = match (args["item"]) {
            case Some(JsonValue.String(s)) => s
            case _ => ""
        }

        match (action) {
            case "list" =>
                return handleList()
            case "add" =>
                return handleAdd(item)
            case "complete" =>
                return handleComplete(item)
            case "remove" =>
                return handleRemove(item)
            case _ =>
                return ToolResult("Unknown action: ${action}. Supported actions: list, add, complete, remove", None, true, false)
        }
    }

    public func executionMode(): ToolExecutionMode {
        ToolExecutionMode.Sequential
    }

    func createEnumArray(): JsonValue {
        let arr = ArrayList<JsonValue>()
        arr.add(JsonValue.String("list"))
        arr.add(JsonValue.String("add"))
        arr.add(JsonValue.String("complete"))
        arr.add(JsonValue.String("remove"))
        JsonValue.Array(arr)
    }

    func handleList(): ToolResult {
        if (items.size == 0) {
            return ToolResult("No todo items", None, false, false)
        }

        let output = StringBuilder()
        for (i in 0..items.size) {
            if (i > 0) { output.append("\n") }
            let prefix = if (items[i].done) { "[x]" } else { "[ ]" }
            output.append("${i + 1}. ${prefix} ${items[i].text}")
        }

        return ToolResult(output.toString(), None, false, false)
    }

    func handleAdd(item: String): ToolResult {
        if (item == "") {
            return ToolResult("Item text is required for add action", None, true, false)
        }
        items.add(TodoItem(item, false))
        return ToolResult("Added todo item: ${item}", None, false, false)
    }

    func handleComplete(item: String): ToolResult {
        if (item == "") {
            return ToolResult("Item text is required for complete action", None, true, false)
        }

        // Find the item by text (first incomplete match)
        for (i in 0..items.size) {
            if (!items[i].done && items[i].text == item) {
                items[i] = TodoItem(items[i].text, true)
                return ToolResult("Completed todo item: ${item}", None, false, false)
            }
        }

        return ToolResult("Todo item not found (or already completed): ${item}", None, true, false)
    }

    func handleRemove(item: String): ToolResult {
        if (item == "") {
            return ToolResult("Item text is required for remove action", None, true, false)
        }

        // Find and remove the item by text
        for (i in 0..items.size) {
            if (items[i].text == item) {
                items.remove(i..(i + 1))
                return ToolResult("Removed todo item: ${item}", None, false, false)
            }
        }

        return ToolResult("Todo item not found: ${item}", None, true, false)
    }
}

struct TodoItem {
    let text: String
    let done: Bool

    public init(text: String, done: Bool) {
        this.text = text
        this.done = done
    }
}

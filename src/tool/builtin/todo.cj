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
        SchemaBuilder()
            .addEnum("action", "Action to perform: list, add, complete, or remove",
                ArrayList<String>(["list", "add", "complete", "remove"]), required: true)
            .addString("item", "Item text (required for add, complete, remove actions)")
            .build()
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

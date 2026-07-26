# 工具

## Tool 接口

```cangjie
interface Tool {
    func name(): String
    func description(): String
    func schema(): JsonValue
    func execute(ctx: ToolContext, args: JsonValue): ToolResult
    func executionMode(): ToolExecutionMode
}
```

### ToolContext

| 字段 | 类型 | 说明 |
|------|------|------|
| `workDir` | `String` | 工作目录 |
| `askUser` | `AskUserFn` | 向用户提问的回调 |

### ToolResult

| 字段 | 类型 | 说明 |
|------|------|------|
| `text` | `String` | 输出文本 |
| `details` | `Option<JsonValue>` | 结构化详情（可选） |
| `isError` | `Bool` | 是否错误 |
| `terminate` | `Bool` | 是否终止整个 Run |

### ToolExecutionMode

```cangjie
enum ToolExecutionMode {
    Parallel   // 可并发执行（只读工具）
    Sequential // 必须串行执行（有状态/副作用）
}
```

## 内置工具

| 工具 | 模式 | 信任闸门 | 说明 |
|------|------|----------|------|
| `read_file` | Parallel | 放行 | 读文件，支持分页/行号/截断 |
| `write_file` | Sequential | 过闸 | 写文件，覆盖检测 |
| `edit_file` | Sequential | 过闸 | 精确字符串替换，唯一性检查 |
| `bash` | Sequential | 过闸 | Shell 执行，流式/超时/取消 |
| `grep` | Parallel | 放行 | 正则搜索文件内容 |
| `glob` | Parallel | 放行 | 文件模式匹配，支持 gitignore |
| `todo` | Sequential | 放行 | 待办列表管理（有状态） |
| `ask_user` | Parallel | 放行 | AI 向用户提问，暂停等待回答 |

### 注册内置工具

```cangjie
import atelier.tool.*
import atelier.tool.builtin.*

let reg = ToolRegistry()
reg.register(ReadFileTool())
reg.register(WriteFileTool())
reg.register(EditFileTool())
reg.register(BashTool())
reg.register(GrepTool())
reg.register(GlobTool())
reg.register(TodoTool())
reg.register(AskUserTool())
```

## 自定义工具

实现 `Tool` 接口即可：

```cangjie
import atelier.tool.*
import jsonvalue.*

class WeatherTool <: Tool {
    public func name(): String { "get_weather" }
    public func description(): String {
        "获取指定城市的天气信息"
    }
    public func schema(): JsonValue {
        SchemaBuilder()
            .addString("city", "城市名称", required: true)
            .addString("unit", "温度单位：celsius/fahrenheit", required: false)
            .build()
    }
    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        let city = match (args["city"]) {
            case Some(JsonValue.String(s)) => s
            case _ => return ToolResult("缺少 city 参数", None, true, false)
        }
        let result = fetchWeather(city)
        ToolResult(result, None, false, false)
    }
    public func executionMode(): ToolExecutionMode {
        ToolExecutionMode.Parallel
    }
}

// 注册
reg.register(WeatherTool())
```

### SchemaBuilder

`SchemaBuilder` 帮助构建 JSON Schema：

```cangjie
let schema = SchemaBuilder()
    .addString("name", "名称", required: true)
    .addInteger("count", "数量", required: false)
    .addEnum("type", "类型", ArrayList<String>(["a", "b", "c"]), required: true)
    .build()
```

可用方法：

| 方法 | 说明 |
|------|------|
| `addString(name, desc, required?)` | 字符串参数 |
| `addInteger(name, desc, required?)` | 整数参数 |
| `addEnum(name, desc, values, required?)` | 枚举参数 |

所有 `required` 参数为命名参数，默认 `false`。

## MCP 工具

通过 `ystyle::mcp` 接入任意 MCP 服务器：

### TOML 配置

```toml
[[mcpServer]]
name = "playwright"
transport = "stdio"
command = "npx @playwright/mcp"

[[mcpServer]]
name = "filesystem"
transport = "streamable-http"
url = "http://localhost:3100"

[[mcpServer]]
name = "custom"
transport = "session-http"
url = "http://localhost:3200"
```

传输方式：`stdio` / `streamable-http` / `session-http`。

### 工具命名

MCP 工具自动注册为 `mcp_<server>_<name>` 格式：

```
mcp_playwright_navigate
mcp_playwright_click
mcp_filesystem_read
mcp_filesystem_write
```

### 通配符

Agent 配置工具时支持通配符 `_*` 批量添加：

```toml
tools = ["bash", "read_file", "mcp_playwright_*"]
```

## Agent-as-Tool

可将一个 Agent 包装为工具，供其他 Agent 通过工具调用委派子任务：

```toml
[[agent]]
name = "writer"
model = "gpt-4o"
systemPrompt = "你是一个专业写手"
tools = ["read_file", "edit_file"]

[[agent]]
name = "supervisor"
model = "gpt-4o"
systemPrompt = "你是一个编辑主管，可委派写作任务"
tools = ["agent_writer", "read_file"]
```

子 Agent 有独立的上下文、工具集和模型，同进程隔离运行。工具名按 `agent_<name>` 格式注册。

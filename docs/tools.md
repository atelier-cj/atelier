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
| `askFn` | `Option<AskFn>` | 提问通道（`ctx.ask(req)`）；不传时提问返回 `Cancelled` |

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
| `ask_user` | Parallel | 放行 | AI 向用户提问（纯提问 / 选择 / 表单三形态）；宿主可同 run 等待，也可返回 `Pending` 挂起本次 run |

### 路径与通配语义

所有内置工具的路径参数走同一套解析（`atelier.tool.builtin.resolveToolPath`）：

- **绝对路径原样使用**（不会被拼到工作目录后面报"文件不存在"）；相对路径一律相对 `ctx.workDir` 解析；
- `write_file` **自动创建缺失的父目录**；
- `glob` 的通配支持 `*`（段内任意字符）、`?`（段内单字符）、`**`（跨任意层目录）、`{a,b}`（择一），
  且**目录前缀里也可以带通配** —— `src/**/*.cj`、`**/*.mjs` 按字面理解即可，不必把目录部分写成无通配的搜索根；
  默认尊重 `.gitignore`（`noIgnore: true` 关闭）。

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

## PTC 模式

PTC（Programmatic Tool Calling）换一种工具呈现方式：模型不再逐次发出工具调用，
而是**写一段程序**，程序内通过绑定调用工具，只有程序返回或打印的内容回到上下文。

它针对逐次调用的两个固有成本：每次调用一次完整模型往返，以及每个中间结果都回灌
上下文。多步编排（遍历结果集、按中间值分支、扇出后汇合）收益最大；单次调用用 PTC
是纯负担，因此默认不开启。

### 开启

```toml
[agent]
name = "coder"
toolPresentation = "ptc"     # native（默认）/ ptc / both
ptcTimeoutSeconds = 30       # 单次程序的经过时间预算
ptcMaxSubCalls = 64          # 单次程序允许的子调用上限
```

`ptc` 模式下模型只看到 `run_xisp` 一个工具，其余可见工具经 SDK 提示段以 xisp 类型
签名暴露。`both` 同时携带两种呈现（提示词成本翻倍，仅用于灰度对比）。

### 程序写法

SDK 段随系统提示自动注入，模型据此编写程序：

```lisp
;; 逐个读取文件，只把结果返回
(map (lambda (f) (tools::read_file {:path f}))
     '("src/agent/runtime.cj" "src/tool/registry.cj"))
```

- 工具调用写作 `(tools::<工具名> {参数})`；参数是 hashmap 字面量，键带冒号
- 最后一个表达式的值即本次调用的返回值
- 布尔字面量是 `#t` / `#f`（不是 `true` / `false`）
- 环境提供算术、比较、逻辑、列表、高阶（`map` / `filter` / `reduce`）、谓词、
  hashmap；**没有**文件、进程、模块能力——需要这些必须通过工具调用

### 安全语义

- 每个子调用都走与模型直调**完全相同**的策略链：信任闸门 → 交互审批 →
  `beforeTool` 钩子（钩子改写后的参数同样生效）；
- `run_xisp` 自身声明为 `Sequential`，因此外层调用必定过闸门——`ToolExecutionMode`
  同时是闸门判据，声明 `Parallel` 会直接被放行；
- 脚本环境是干净的：只注册当轮可见工具与审核过的纯函数子集。边界用「不注册」
  表达而不是「注册后过滤」——权限检查对 `eval` / `apply` / `map` 等特殊形式无效，
  只有「环境里不存在」才是可靠的禁止。

### 限制

- **工具失败会中止程序**：失败以错误值表达，而错误值进入参数位置会短路传播
  （xisp 既有语义），因此脚本无法「尝试 A，失败就做 B」；
- 子调用**串行**执行（脚本内仍可用 `map` / `filter` / `reduce` 做纯计算）；
- 超时或取消后，已提交的副作用不回滚、也不自动重放；
- 每次 `run_xisp` 使用全新环境，程序之间不共享状态。

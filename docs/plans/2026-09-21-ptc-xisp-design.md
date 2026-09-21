# PTC 模式设计 —— 以 xisp 作为程序执行引擎

> **日期:** 2026-09-21
> **状态:** 设计已定稿（三项关键决策已拍板），待实现
> **调研基础:** xisp 三轮探针实测（10 个用例，见附录 A）+ atelier/xisp 现状盘点
> **基线:** atelier master `1dea655`（`cjpm test` 314 passed / 0 failed）；xisp `v0.4.0`（已发中心仓）

## 背景与目标

模型逐次发出 `tool-call` 的方式有两个固有成本：

1. **每次调用一次完整模型往返**——遍历结果集、按中间值分支、扇出、后处理，每一步都要回到模型；
2. **每个中间 `tool-result` 都回灌上下文**——不管模型是否真的需要。

PTC（Programmatic Tool Calling）换一种呈现：模型不再逐步发工具调用，而是**写一段程序**，程序通过宿主注入的绑定调用工具，只有程序显式返回或打印的内容回到上下文。

目标：

- atelier 增加一个**可配置的工具呈现模式**，与现有 native 模式并存、可灰度；
- 执行引擎用 **xisp**（仓颉嵌入式 Lisp，`ystyle::xisp`）；
- **不削弱任何现有安全语义**：信任闸门、交互审批、6 相位钩子、事件流、取消、上限。

### 为什么这不是 MCP-Term 的重演

早前有一个在讨论阶段即放弃的设想——[MCP-Term：一个未出生即夭折的想法](https://ystyle.top/2026/03/19/mcp-term-abandoned/)（2026-03-19，无代码产出）：把工具的 JSON Schema 投影成 S-表达式以省 token。本方案在表面上与它相似——同样是把 JSON Schema 换成更紧凑的 S-表达式表示——**但两者不在同一个层次，因此不共享同一个失败原因**。

| | MCP-Term | PTC |
|---|---|---|
| 层次 | **表示层**：把一次调用写得更短 | **执行层**：让模型少调用几次 |
| 解决的问题 | 复杂嵌套参数难写 | 往返次数 + 中间结果回灌 |
| 收益性质 | 常数倍（省 schema token，可被 prompt cache 摊销，**有天花板**） | 随工具调用步数**线性增长**，无天花板 |
| 有无更简单的答案 | 有：Skills 模板封装、管道 + base64、原生 CLI 兴起 | **无**（见下） |
| 与 Skills 的关系 | 被 Skills 取代 | **正交**：Skills 前置知识，PTC 承接控制流 |

一个能说明层次差异的佐证：MCP-Term 需要专门发明 `(batch ...)` 语法来支持批量调用，而 PTC 不需要——程序本身就是批量的，`map` / `for-each` 即它。**表示层要发明批量的语法，执行层天生就有循环。**

用那次复盘得出的判据检验本方案——「**当目标场景被简化方案覆盖时，放弃**」——结论是不会被覆盖：PTC 唯一可能的"替代品"是模型厂商在 API 层原生支持「一条消息里表达控制流」，而那个东西的真身就是**让模型写代码**。PTC 不是被绕过的那一层，它就是终点。

> 当年目标场景（CLI 嵌套参数）确实被 Skills 覆盖了，但那是因为它解决的问题属于「知识」层。PTC 解决的是「控制流归属」层；Skills 封装得再好也不会减少往返次数。

**需要警惕的同一条风险仍然成立。** 那篇复盘的「根本原因」是「大模型进化快，中间层易被端到端替代」；对本方案的版本是「上下文变便宜则收益缩水」。对冲在于：PTC 有一块收益**不依赖 token 成本**——逐次调用时，模型的"遍历/分支/扇出"意图被摊在 N 轮对话里，每轮都要重看历史才能决定下一步；PTC 把这段控制流表达在一处，减少的是**上下文漂移**与**重复读取**，与窗口大小无关。

代价是适用范围收窄：PTC 的价值取决于任务的**控制流复杂度**，单次调用（`read` / `bash`）用 PTC 是纯负担，故默认模式保持 `Native`（D1）。判断准则见 §5.6。

> **存档意义。** 那篇复盘记录了一次**正确的技术判断落在错误场景**上的失败——「类型声明优于 JSON Schema、S-表达式优于 JSON」这个判断本身成立，只是当年挂在了「CLI 参数编码」这个会被 Skills 覆盖的位置上。本方案把它挂到「PTC 的 SDK 呈现」上：模型必须先理解这套 API 才能写出程序，此时紧凑的类型表达不再是可选项而是必需品。同一份判断，换一个场景即成立——这也是保留那篇文章的理由。

## 一、参考实现的三个抽象

对照实现（工作区外的 `deepseek-harness`）解决同一问题的做法，它把 PTC 拆成三个互不耦合的抽象。本设计对齐其语义，但不复制其实现（那边是 TypeScript/Node，工具是 async 的，本仓工具是同步的，很多复杂度在此不成立）：

1. **呈现模式属于注册表**。`native` 通告 N 个工具 schema；`ptc` 只通告 1 个保留工具 `run_code` 加一段生成的 SDK 声明。原生 schema 与 SDK 声明是**同一个可见存储的两种投影**，不是两次独立注册。
2. **执行是一个能力 seam，语言无关**。运行时只接收「一段程序 + 命名的异步绑定」，执行后返回 `{ value, logs, error }`；它对工具、会话、权限一无所知。语言与执行基底都是后端属性，因此换语言等于换 provider。
3. **宿主桥**。每个可见工具对应一个绑定；子调用保留父子关联、继承取消信号、自带并发分类，并走完整工具流水线（而不是绕过策略层）。

本设计采纳 1 与 3 的语义；第 2 点在仓颉侧落为一个普通模块边界（本仓没有 DI 容器，见 `docs/design.md:1161-1164`「组合模型 = 接口/注册表 + 构造注入」）。

## 二、决策记录

| # | 决策 | 依据 |
|---|---|---|
| **D1** | 呈现模式三态 `Native`（默认）/ `Ptc` / `Both`，由 `AgentConfig` 配置 | 与参考实现同构；默认不改现网行为 |
| **D2** | 执行引擎用**进程内 xisp**，不起子进程 | atelier 工具是同步的（`Tool.execute(ctx, args): ToolResult`），绑定可直接同步调用，无需 IPC；子进程方案留给「需要 OS 级隔离」时再议 |
| **D3** | 绑定语法 `(tools::read_file {:path "src/main.cj"})` | 已拍板。xisp 原生命名空间习惯，求值器零改动 |
| **D4** | 脚本环境 = **干净 `Environment` + 只注册可见工具 + 经审纯函数子集** | 已拍板。实测唯一可靠的边界（见 §7.1） |
| **D5** | 参数编码：脚本的 `{...}` 字面量**就是** `LispValue.HashMap`，键为无冒号字符串 | 实测（附录 A·P3）：`{:path "a.cj"}` → `HashMap{path: Str("a.cj")}`，与 JSON object 一对一 |
| **D6** | 完成值 = **最后一个顶层表达式的结果**（xisp 无 `return`） | Lisp 惯例；`Evaluator.eval` 已如此返回 |
| **D7** | `run_xisp` 声明 `ToolExecutionMode.Sequential` | `ToolExecutionMode` 一字段两用（`src/trust/gate.cj:16-27`）：`Parallel` 会**直接放行绕过信任闸门** |
| **D8** | 中断由 **xisp 求值检查点**实现；超时由 `run_xisp` 自带 | 实测 xisp 现行超时是「放弃等待」（附录 A·P5），副作用会继续 |
| **D9** | 首版子调用**串行**；脚本内可用 `map`/`filter`/`reduce` 做纯计算 | 同一 `Environment` 非线程安全（`Environment.bindings` 是 `HashMap`，全仓无同步原语） |
| **D10** | SDK 提示词段由**当轮已解析的可见工具**驱动，作为 `buildSystemText` 的输入传入（而非挂在 `PromptSegmentContributor` 上） | `PromptSegmentContributor.render(env)` 只拿到 `SessionEnvironment`（仅 `directory` + `context`，`src/session/session.cj:7-18`），拿不到工具列表；若闭包捕获注册表，SDK 段会与 `resolveTools()` 的动态结果（`agent_<name>` 惰性注册、MCP 冷却过滤）不一致 |
| **D11** | SDK 段的参数类型用 S-表达式类型标记表达（`(opt T)` / `(or :a :b)` / `(list T)` / `{k T}`），重复子结构抽成 `deftype`；**不引入短码** | 见「为什么不是 MCP-Term 的重演」；JSON Schema 无可靠类型复用（MCP 适配原样透传 `type`/`properties`/`required`，`$ref` 直接丢失，`src/tool/mcp_tool.cj:27-38`）而 MCP 工具 schema 不可控；短码损害可读性且 xisp 符号本允许 `-` |

## 三、架构

### 3.1 模块划分

```
atelier/
├── src/ptc/                       # 新增包 atelier.ptc
│   ├── root.cj                    # 对外导出
│   ├── types.cj                   # PtcRunRequest / PtcRunResult / 失败分类
│   ├── runtime.cj                 # XispRuntime：环境构造、绑定桥、求值、日志、错误
│   ├── json_bridge.cj             # JsonValue ↔ LispValue 双向转换
│   ├── sdk.cj                     # 工具 schema → xisp SDK 提示词段
│   ├── binding.cj                 # 工具 → 绑定函数（含闸门/hook/上限复用）
│   ├── run_xisp_tool.cj           # run_xisp 工具本体（<: Tool）
│   └── *_test.cj                  # 单测（包内，@Test 风格）
├── src/agent/runtime.cj           # resolveTools() 按模式投影（改）
├── src/agent/config.cj            # AgentConfig 增 ptc 配置（改）
└── src/context/…                  # buildSystemText 支持 SDK 段入参（改）
```

不引入「可插拔运行时后端注册表」：本仓没有该抽象，且当前只需要一个后端。若将来要加第二个语言后端，再照 `llm_api/src/provider/registry.cj:11-36` 的 `registerFactory` 模式抽出接口。

### 3.2 运行时视图

```
AgentRuntime.chatWithSessionId（回合循环，spawn 线程）
  │
  ├─ resolveTools()  ── Native/Both ──▶ 各工具 OpenAITool（现状）
  │                  └─ Ptc           ──▶ 仅 run_xisp 的 OpenAITool
  │                                        输出同时喂给 SDK 段生成器（D10）
  │
  └─ ToolExecutor.executeBatch
       └─ run_xisp(code, description)   [Sequential → 过信任闸门]
            │
            ├─ 组装干净 Environment：
            │     Environment()                     # 无内建、无 std.io/std.fs
            │     + registerPure(env)               # xisp 导出：算术/比较/逻辑/列表/谓词/哈希表
            │     + 宿主 logs 接收器（println 等）
            │     + 每个"当前可见"工具 → tools::<name> 绑定
            │
            ├─ XispRuntime.run(request)
            │     ├─ 求值（带中断检查点，见 §4.2）
            │     └─ 绑定回调 ──▶ 宿主：
            │            shouldAllowFor(...)  →  shouldAllowFor 判定（与直调一致）
            │            beforeTool hook      →  可 Deny / Modify
            │            计数 maxToolCalls    →  超限即拒
            │            Tool.execute(...)    →  同步执行
            │            afterTool hook
            │            emit(ToolExecutionStart/EndEvent)，callId = "<parent>:ptc:<n>"
            │
            └─ ToolResult(text = logs + 完成值渲染, details = 结构化, isError)
```

### 3.3 关键接口草案

```cangjie
package atelier.ptc

import jsonvalue.*
import std.collection.*
import std.time.Duration

/** 工具呈现模式（D1）。 */
public enum ToolPresentationMode {
    | Native   // 默认：工具以 JSON Schema 逐次通告（现网行为）
    | Ptc      // 只通告 run_xisp，工具经 SDK 绑定暴露
    | Both     // 原生 schema 与 SDK 并存
}

/** 绑定函数的返回：失败以值表达，而不是抛异常穿过求值器。 */
public enum PtcBindingOutcome {
    | Ok(JsonValue)
    | Err(String)
}

/** 一个宿主绑定：接收无损 JSON 参数，同步返回结果。 */
public type PtcBindingFunction = (JsonValue) -> PtcBindingOutcome

/** 一个绑定命名空间；当前只有 "tools"。 */
public struct PtcBindingNamespace {
    public let global: String
    public let functions: HashMap<String, PtcBindingFunction>
    public init(global: String, functions: HashMap<String, PtcBindingFunction>) { ... }
}

/** 一次程序执行的全部输入。 */
public struct PtcRunRequest {
    public let program: String
    public let bindings: ArrayList<PtcBindingNamespace>
    public let workDir: String
    /** 经过时间预算；None 表示用默认值。 */
    public let timeout: Option<Duration>
    /** 外层取消检查（来自 AgentRuntime 的 cancelFlag）。 */
    public let cancelled: () -> Bool
    /** 日志回调（脚本 println 的落点）。 */
    public let onLog: (String) -> Unit
}

/** 失败分类；与「程序正常返回 nil」严格可区分（D8）。 */
public enum PtcFailureKind {
    | Exception      // 脚本运行时错误
    | SyntaxError    // 解析失败
    | Timeout        // 经过时间预算耗尽
    | Cancelled      // 外层取消
    | OutputLimit    // 日志/完成值超限
}

public struct PtcRunFailure {
    public let kind: PtcFailureKind
    public let message: String
}

/** 一次执行的结果；error 是字段，不是异常路径。 */
public struct PtcRunResult {
    /** 最后一个顶层表达式的值；未能跨 JSON 边界或运行失败时为 None。 */
    public let value: Option<JsonValue>
    public let logs: ArrayList<String>
    public let error: Option<PtcRunFailure>
}

/** 执行引擎。 */
public class XispRuntime {
    public init(config: PtcRuntimeConfig) { ... }
    public func run(request: PtcRunRequest): PtcRunResult { ... }
}
```

```cangjie
// src/agent/config.cj 增量
public struct AgentConfig {
    // ... 现有字段
    /** 工具呈现模式；默认 Native（现网行为不变）。 */
    public let toolPresentation: ToolPresentationMode
    /** PTC 程序的经过时间预算（秒）。 */
    public let ptcTimeoutSeconds: UInt32
    /** PTC 单次程序内允许的子调用上限。 */
    public let ptcMaxSubCalls: UInt32
}
```

## 四、xisp 侧改动

三处，按必要性排序。改动均为**通用增强**（对其它嵌入方同样有价值），不引入 PTC 专属概念。

### 4.1 【必须】导出纯函数子集 `registerPure`

现状：`BuiltinFunctions` 的 `registerArithmetic` / `registerModulo` / `registerMath` / `registerComparison` / `registerListOps` / `registerHigherOrder` / `registerLogic` / `registerPredicates` / `registerPrint` **全部是包内 `static func`**（`src/core/builtin/*.cj`），只有 `registerAll`（含 IO 桥接）与 `registerHashMap` 是 public。外部包无法构造「有表达力但无 IO」的环境。

新增：

```cangjie
// src/core/builtin/builtin.cj
extend BuiltinFunctions {
    /**
     * 注册纯函数子集：不涉及文件、进程、模块加载与求值逃逸的表达式能力。
     * 供嵌入式宿主构造最小权限环境使用（含 nil 字面量与不涉及 IO 的宏）。
     */
    public static func registerPure(env: Environment): Unit {
        env.define("nil", Nil)
        registerArithmetic(env)
        registerModulo(env)
        registerMath(env)
        registerComparison(env)
        registerListOps(env)
        registerHigherOrder(env)
        registerLogic(env)
        registerPredicates(env)
        registerHashMap(env)
        BuiltinMacros.registerAll(env)   // 已是 public static
        // 不含 registerPrint：宿主自行接管日志通道（见 §5.5）
        // 不含 registerRedisAliases / registerModernAliases：别名，冗余
        // 不含任何 cangjie::* 桥接（read-file/write-file/list-dir…）：最小权限的关键
    }
}
```

> `error` / `raise` / `assert` 由 `registerErrorHelpers` 注册，当前是包内可见（`src/core/builtin/builtin.cj:36`）。若希望脚本能主动报错，建议一并改为 public 并纳入 `registerPure`；否则由宿主自行注册同名绑定。

> `registerPrint` 不纳入：宿主需要把 `println`/`print`/`princ`/`display`/`newline` 接到自己的日志通道（见 §5.5），而不是打到进程 stdout。

### 4.2 【必须】求值中断检查点

现状（实测印证）：`LispInterpreter.evalInSandboxInternal` 用 `spawn` + `fut.get(timeout)`，超时后 `fut.cancel()`；仓颉 `Future.cancel()` 的语义是「**发送取消请求，不会立即停止线程执行**」，而 xisp 的求值路径（AST / VM / JIT 三层）**没有任何取消检查点**。实测：超时 1005ms 准时返回，但被"取消"的宿主函数在 5 秒后仍然跑完并置位（附录 A·P5）。对 PTC 而言这意味着**超时后副作用继续产生**，不可接受。

新增：

```cangjie
// src/core/eval/evaluator.cj
public class Evaluator {
    /** 协作式中断检查：返回 true 表示应停止求值。 */
    public func setInterruptChecker(checker: () -> Bool): Unit { ... }
    public func isInterrupted(): Bool { ... }
}
```

检查点落位（每处都要有，缺一处就会留下跑不完的长循环）：

1. `src/core/eval/core.cj` 的 `eval(expr)` 入口——覆盖普通递归与函数体；
2. `src/core/eval/higher_order.cj` 的 `map` / `filter` / `reduce` / `apply` 迭代体内（这三个是特殊形式，内建循环最容易长时间不返回）；
3. `src/core/eval/vm.cj` 的指令派发循环（开了字节码后 AST 检查点不再经过）；
4. **NativeFunc 调用前后各一次**（`core.cj:286`、`vm.cj:1151/1214/1232`）——宿主绑定可能长时间阻塞，返回后必须立刻有机会停下。

中断的**表达方式**：优先返回 `LispValue.Error(XispError(ErrorType.RuntimeError, "interrupted"))`，让宿主能拿到结构化结果；不要依赖抛仓颉异常（现有 `eval` 的 catch 会把它降级成 stdout 打印 + `Nil`）。

> 若某处确实需要抛异常穿透（例如正在 `sleep` 的宿主绑定），约定抛一个专用异常类型，并在 `eval` 的 catch 里识别后转成 `Error` 值返回。

### 4.3 【建议】解析错误的可靠报告

现状：`Parser` 对不完整输入宽容，`(+ 1 ` 会静默返回 `1`；`eval` 的 catch 分支用 `println("Error: ...")` 输出后返回 `Nil`，宿主既拿不到「这是语法错误」也拿不到消息。

建议：给 `Parser` 增加严格模式（未消费完的 token / 悬空括号 → 返回结构化错误），供嵌入式场景选用。不改默认行为以免影响 REPL 与现有 314 项测试。

## 五、atelier 侧改动

### 5.1 呈现投影（`resolveTools()`）

`src/agent/runtime.cj:513-549` 按 `toolPresentation` 分派：

- `Native`：现状不变；
- `Ptc`：只产出 `run_xisp` 一个 `OpenAITool`，其余工具不进请求；
- `Both`：两者都产出（注意提示词成本翻倍，默认不建议）。

`run_xisp` 的 schema：

```json
{
  "type": "object",
  "properties": {
    "code":        {"type": "string", "description": "要执行的 xisp 程序"},
    "description": {"type": "string", "description": "本次调用的简短说明（用于 UI 标注）"}
  },
  "required": ["code", "description"]
}
```

`code` 与 `description` 都设为必填：只发 `code` 的模型会因参数校验失败而**丢掉整段已写好的程序**，与参考实现同样的理由。

### 5.2 SDK 提示词段（`src/ptc/sdk.cj`）

由当前 scope 的**可见工具**生成，按字典序排列以保证字节稳定（提示词前缀缓存友好）：

```
你可以用 xisp（Lisp 方言）编写程序来组合调用工具。

约定：
- 工具调用写作 (tools::<工具名> {参数})；参数是 hashmap 字面量，**键带冒号**（:path），
  但取出来是普通字符串键。
- 程序是一个或多个顶层表达式，顺序求值；**最后一个表达式的值即本次调用的返回值**。
- (println ...) 的内容会作为日志一并返回给你，不会中断程序。
- 工具失败会中止程序：失败以错误值表达，而错误值在参数位置会短路传播
  （xisp 既有语义，等价于异常向上抛），失败的调用不会被静默跳过。
- 已提供纯函数：算术、比较、逻辑、列表、高阶（map/filter/reduce）、谓词、hashmap。
  没有文件、进程、模块、eval 能力；需要这些请通过工具调用。

类型写法：
  T              基础类型：string / number / bool / any
  (opt T)        可省略（也可传 nil）
  (or :a :b)     枚举，取其中之一
  (list T)       同质数组
  (map K V)      映射
  {k T, ...}     对象；键写 :k，值按上面的类型写

可用工具：

;; (tools::read_file {:path string, :offset (opt number), :limit (opt number)}) -> string
;;   读取文件内容，支持分页
;; (tools::grep {:pattern string, :path (opt string), :glob (opt string)}) -> (list string)
;;   正则搜索

;; 参数结构复杂时，把共享部分抽成 deftype 再引用：
;; (deftype Source
;;   (sql   {:driver (or :pg :my :ch), :host string, :db string, :q string})
;;   (mongo {:uri string, :collection string})
;;   (api   {:url string, :method (or :get :post)}))
;; (tools::query {:sources (list Source), :out string}) -> any

示例：
(map (lambda (f) (tools::read_file {:path f}))
     '("src/agent/runtime.cj" "src/tool/registry.cj"))
```

**生成规则。** 生成器消费 `Tool.schema()` 的 JSON Schema（`SchemaBuilder` 产出的子集），按上表映射为 xisp 类型标记：

| JSON Schema | SDK 段写法 |
|---|---|
| `{"type":"string"}` | `string` |
| `{"type":"number"}` / `{"type":"integer"}` | `number` |
| `{"type":"boolean"}` | `bool` |
| `{"type":"array","items":T}` | `(list T)` |
| `{"type":"object","properties":{...}}` | `{:k T, ...}`（`required` 之外的键标 `(opt T)`） |
| `{"enum":[...]}` | `(or :a :b)` |
| `{"type":["string","null"]}` | `(opt string)` |
| `{"oneOf":[...]}` / `{"anyOf":[...]}` | `(or T1 T2)` |
| 无 `type` / 未知构造 | `any` |

**为什么需要 `deftype`（这是参考 MCP-Term 的核心收获）。** JSON Schema 几乎没有可靠的类型复用机制：`$ref` / `$defs` 在实践中常被透传层丢掉——本仓的 MCP 适配就是原样搬 `inputSchema` 的 `type` / `properties` / `required`（`src/tool/mcp_tool.cj:27-38`），`$ref` 会直接消失。而 **MCP 工具的 schema 恰恰完全不可控**：内置 8 个工具的参数都很平（`{path, content}` 这种），但外部 MCP server 送来的可能是任意深度的嵌套结构，冗长问题在最需要的地方最严重。

`deftype` 让生成器**自己造复用**，不依赖 schema 里原本有 `$ref`：同一子结构在工具集内出现 ≥2 次时抽成一个命名类型，工具签名里引用它。这是纯机械的、可单测的变换。

**关于短码。** MCP-Term 当年为省 token 引入了 1–4 字符短码（`fr` = `file_read`），**本设计不采用**：模型接下来要写的是代码，可读性直接影响写对率与用户 review 成本；一层别名映射本身就是一类新错误源；且 xisp 的符号允许 `-`，`tools::read-file` 与 `tools::read_file` 都合法，本就无需缩短。

**挂载方式（D10）：** 不复用 `PromptSegmentContributor`——它的 `render(env: SessionEnvironment)` 只能拿到 `directory` 与 `context`（`src/session/session.cj:7-18`），拿不到工具列表。而 SDK 段必须与**当轮真正暴露的工具**逐一对齐，否则模型会看到并不存在的绑定（或漏看存在的）。

做法：调整 `AgentRuntime` 内的组装顺序，让 `resolveTools()` 的输出先于系统提示文本生成，再把可见工具列表传给 `buildSystemText`：

```cangjie
// src/agent/runtime.cj 组装顺序（现为 :167-168 提示 → :188 resolveTools）
let tools = this.resolveTools()                       // 先解析可见工具
let systemText = this.ctxBuilder.buildSystemText(     // 再把 SDK 段一并产出
    ..., this.config.toolPresentation, tools)         // Native 下该参数被忽略
```

这样 SDK 段天然覆盖 `agent_<name>` 惰性注册与 MCP 冷却过滤的结果，不存在两处可见性口径分叉的问题。

### 5.3 绑定桥（`src/ptc/binding.cj`）

每个可见工具生成一个 `PtcBindingFunction`，闭包捕获 `ToolContext`、`ToolCallBlock` 等价信息与子调用计数器。**子调用必须复用与模型直调完全相同的策略链**，否则 PTC 就是绕过闸门的后门：

```cangjie
let binding = { (args: JsonValue): PtcBindingOutcome =>
    // 1) 运行是否已结束（外层取消 / 程序已返回）
    if (runOver()) { return PtcBindingOutcome.Err("run is over"); }
    // 2) 子调用上限
    if (subCalls.load() >= maxSubCalls) { return Err("sub-call budget exhausted"); }
    // 3) 信任闸门（与 runtime.cj:291 一致；run_xisp 自身已过闸，这里是子调用的那一层）
    match (shouldAllowFor(tool, workDir, trustManager, sessionId)) {
        case Allowed => ()
        case NeedsApproval => /* 复用 toolApprovalFn；拒绝则 Err */
        case Denied => return Err("tool not allowed: workDir is untrusted")
    }
    // 4) beforeTool hook（可 Deny / Modify(args)）
    // 5) 计数 + emit(ToolExecutionStartEvent(subCallId, name))
    // 6) tool.execute(ctx, args)   —— 同步
    // 7) emit(ToolExecutionEndEvent(...)) + afterTool hook
    // 8) 映射 ToolResult → Ok(JsonValue) / Err(text)；isError 也要作为值返回而不是异常
}
```

子调用 id 用 `<parent-callId>:ptc:<n>`（n 从 1 递增，按提交顺序编号）。前端按该前缀分组即可把子调用折叠进 `run_xisp` 卡片；`ToolExecutionUpdateEvent`（`src/agent/event.cj:62-66`，目前从未 emit）可用于子分发进度。

**上下文延后**：子调用产生的图片等多模态内容不进程序返回值，而是按 DSH 的 `deferContext` 语义挂到外层结果之后。首版可先只支持文本，多模态留 P2。

### 5.4 配置与接线

- `AgentConfig` 增 `toolPresentation` / `ptcTimeoutSeconds` / `ptcMaxSubCalls`（JSON 序列化与 `fromJson` 同步，缺省值保持现网行为）；
- `buildSystemText` 支持 SDK 段入参（仅 `Ptc`/`Both` 下产出非空文本，`Native` 下忽略）；组装顺序按 D10 调整为「先 `resolveTools()`，后提示文本」；
- 组合根注册 `run_xisp`：`cli/src/app/main.cj:226-235` 附近；库用户自行 `toolReg.register(RunXispTool(...))`；
- 依赖：根 `cjpm.toml` 增 `"ystyle::xisp" = "0.4.0"`（`cli` 成员已在用同版本，可用性无风险）。

### 5.5 日志与输出上限

- logs：`onLog` 回调收集，累计字节数超过 `ptcMaxLogBytes` 时截断并追加提示（参考实现有同类上限，防止程序用 `println` 撑爆外层结果）；
- 完成值：`JsonValue` 与 logs 合计超限时，按 `OutputLimit` 失败并在 message 里说明（不要把截断后的字符串冒充完成值）。

### 5.6 什么时候用 Ptc

D1 让呈现模式按部署配置，但**每个使用方都需要一条判据**。PTC 的价值来自两处，且只有第二处不依赖 token 成本：

1. **省往返与中间结果**——与任务的工具调用步数成正比。步数少时收益为负（SDK 段本身占提示词）。
2. **控制流归属**——模型的"遍历/分支/扇出"意图表达在一处，而不是摊在 N 轮对话里逐步重建。与窗口大小、缓存命中率无关。

据此的取舍：

| 任务形态 | 建议 |
|---|---|
| 单次调用（`read` / `bash` / 一次性编辑） | `Native`。逐次调用已是最优，套一层程序是纯负担 |
| 多步编排：遍历结果集、按中间值分支、扇出后汇合、批量后处理 | `Ptc`。这正是逐次调用结构上做不到的部分 |
| 结果集大、中间结果只需部分回流 | `Ptc`。中间态不进上下文是主要收益 |
| 需要逐步人工确认 | `Native`。程序内部的子调用是连续执行的，交互审批只在工具粒度 |

`Both` 仅用于灰度期对比：它同时携带 native schema 与 SDK 段，提示词成本翻倍，不建议长期启用。

> 这条判据也是「为什么不会重蹈 MCP-Term 覆辙」的落点：PTC 的适用面确实**窄于**"所有工具调用"，但它窄得有理由（控制流复杂度），而不是像当年那样被更简单的方案从外部覆盖。

## 六、错误 / 超时 / 取消语义

| 情形 | `PtcRunResult` | 外层 `ToolResult` |
|---|---|---|
| 程序正常返回 | `value = Some(...)`，`error = None` | `isError = false`，text 渲染 logs + 完成值 |
| 脚本运行时错误 | `error = Exception(msg)` | `isError = true` |
| 解析失败 | `error = SyntaxError(msg)` | `isError = true` |
| 经过时间耗尽 | `error = Timeout(msg)` | `isError = true`，message 里含「已产生副作用的子调用不可重放」提示 |
| 外层取消 | `error = Cancelled(msg)` | `isError = true` |
| 日志/完成值超限 | `error = OutputLimit(msg)` | `isError = true` |

关键约束：

- **不隐式重放**：超时或中断后，程序已提交的副作用一律保留，绝不自动重跑（与参考实现一致）；
- **取消必须真的停下来**：`run_xisp` 的 `execute` 里把 `cancelFlag` 包成 `cancelled: () -> Bool` 交给 `XispRuntime`，由 §4.2 的检查点消费；不能只依赖 atelier 现有的「回合/工具边界」检查（`src/agent/runtime.cj:113-114` 原文：「正在执行的工具不强制中断」）；
- `AgentConfig.toolTimeout` 目前是**死字段**（无任何执行路径读取），本设计不复活它；PTC 超时由 `ptcTimeoutSeconds` 独立承担。

### 6.1 工具失败会中止程序（实现期确认的语义约束）

原设计设想「工具失败返回可检出的错误值，用条件分支决定是否继续」。实现时确认这条**做不到**，原因在 xisp 的求值语义：

```cangjie
// src/core/eval/core.cj —— 函数调用的参数位置
for (arg in args) {
    match (arg) {
        case Error(_) => return this.injectStack(arg)   // ← 错误值短路传播
        case _ => ()
    }
}
```

错误值一旦进入**参数位置**就短路返回，后续函数不再执行。于是 `(null? r)`（r 绑定到错误值）根本不会调用 `null?`，而是直接返回那个错误——任何「检查一个值是不是错误」的写法都需要把它作为参数传递，因而都会被短路。

结论与取舍：

- **接受短路语义**：工具失败 → 错误值 → 程序中止 → `run_xisp` 返回 `isError = true` 与工具的错误文本；
- 这与 **native 模式行为一致**（工具失败、模型看到错误、再决定下一步），两种呈现下的语义不因模式而变；
- 代价是脚本无法「尝试 A，失败就做 B」。要支持它需要给 xisp 引入容错的参数求值（例如带标记的宽容函数），属于对求值器核心语义的改动，不在本次范围。

> §5.2 的 SDK 说明文字已按此修正；`binding_errorValueShortCircuitsArgumentPosition` 用例把这条语义固定下来，避免以后被误当作 bug「修掉」。

## 七、安全模型

### 7.1 唯一可靠边界是「环境里没有」

实测（附录 A·P2）：白名单**可以被绕过**——`(tools::secret)` 被拒，但 `(apply tools::secret '())` 返回了 `"SECRET-LEAKED"`。根因是特殊形式先于权限检查返回：

```cangjie
// src/core/eval/core.cj:166-168
case Symbol(sym) =>
    if (let Some(result) <- this.trySpecialForm(sym, rest)) {
        return result          // ← funcChecker 没有机会运行
    }
```

`trySpecialForm` 名单含 `eval` / `apply` / `map` / `filter` / `reduce` / `for-each` / `import`（`core.cj:117-154`）；且绑定是**一等值**（`(list tools::only_visible)` → `(#<native-function>)`），可被当作参数传递。

因此本设计的姿态是 **D4**：绑定只按「当前可见工具」注册，不把不该暴露的能力放进环境，**不依赖注册后过滤**。同一实测也确认这条路可行且无副作用：干净环境里 `(eval '(+ 1 2))` 因 `+` 不存在而返回 `UndefinedFunction`（附录 A·P2A），而 `(map (lambda (x) (tools::echo x)) '(1 2 3))` 正常工作——高阶函数由求值器内建驱动，不需要环境里有东西。

### 7.2 分层

| 层 | 机制 |
|---|---|
| 进程/OS | 本设计**不提供** OS 级隔离。xisp 官方文档亦明确「沙箱是软件层防御，不能替代操作系统级隔离」。若需要，见 §11 风险 |
| 呈现层 | `Ptc` 模式下模型只看到 `run_xisp` 与可见工具的 SDK 声明 |
| 环境层 | 干净 `Environment` + `registerPure` + 仅可见工具绑定（§7.1） |
| 工具层 | 子调用走完整策略链：信任闸门 + `beforeTool` hook + 子调用上限（§5.3） |
| 资源层 | 求值中断检查点（§4.2）+ 经过时间预算 + 日志/输出上限（§5.5） |

### 7.3 不采用的手段（实测无效）

- xisp 的 `setAllowedFunctions` / `blockFunction`：可被 `apply` / `map` / `for-each` 等特殊形式绕过；
- xisp 的路径白名单：仅挂在 `cangjie::read-file` / `write-file` / `append-file` 三个函数上，`exists?` / `list-dir` 不过检查；且是纯字符串前缀匹配，不解析 `..` 与软链。**本设计不使用这些函数**，因此不依赖它；
- `setMaxMemory`：`checkMemoryLimit()` 全仓无人调用，是死代码。

## 八、里程碑（TDD，每阶段独立提交）

### M1 — xisp 侧增强（仓 `xisp`，从 master 切 `feat/pure-subset-and-interrupt`）

1. `registerPure(env)` + 单测（覆盖：可用的纯函数清单、不可用的能力清单——文件/进程/模块/eval 均不在环境中）；
2. 中断检查点：`Evaluator.setInterruptChecker` + 四处落位 + 单测（长循环可被中断、`map`/`reduce` 内可被中断、开字节码后仍可被中断、NativeFunc 返回后立刻生效）；
3. 解析错误报告（建议项）+ 单测（不完整输入不再静默返回部分结果）。

验收：`cjpm test` 全绿；新增用例覆盖上述边界。M1 完成后 xisp 需**发版**（atelier 依赖版本号）。

### M2 — atelier 侧运行时（仓 `atelier`，从 master 切 `feat/ptc-mode`）

1. `src/ptc/types.cj` + `json_bridge.cj`（含双向转换单测，重点覆盖 `HashMap` / `Cons` 列表 / 标量 / `nil` / 嵌套）；
2. `src/ptc/runtime.cj`：环境组装、绑定桥、求值、日志收集、失败分类；单测覆盖成功/异常/超时/取消/超限五条路径；
3. `src/ptc/binding.cj`：闸门/hook/上限复用；单测覆盖「子调用受闸门约束」「子调用计入上限」「被 hook Deny 的子调用」；
4. `src/ptc/run_xisp_tool.cj`：`Sequential` + 自带超时 + 事件发射；单测覆盖 `ToolResult` 形状与 `isError` 语义。

验收：`cjpm build` + `cjpm test` 314 项基线不回归，新增用例全绿。

### M3 — 呈现与配置接线

1. `AgentConfig` 三字段 + 序列化 + 单测；
2. `resolveTools()` 三态投影 + 单测（`Ptc` 下只剩 `run_xisp`）；
3. `src/ptc/sdk.cj` 生成器 + 单测（字节稳定、字典序、必填标注、`(opt T)`/`(or ...)`/嵌套对象映射、`deftype` 抽取与引用、未知构造降级 `any`、示例）；
4. SDK 段接入 `buildSystemText`（按 D10 调整组装顺序）+ 单测（`Native` 下产物为空、`Ptc` 下与 `resolveTools()` 输出逐项一致）；
5. `cli/src/app/main.cj` 注册 `run_xisp`；
6. `docs/tools.md` / `docs/design.md` 增补章节。

### M4 — 端到端与体验

1. 用 `EchoProvider` 与真实 provider 各跑一条 e2e：模型在一个程序里组合两次 `read_file` + 一次 `grep`；
2. 前端折叠：子调用事件按 `<parent>:ptc:<n>` 归组（TUI 先做，HTTP 事件已在流里）；
3. 子分发进度事件（`ToolExecutionUpdateEvent`）；
4. 文档补充「什么时候用 Ptc / 什么时候用 Native」。

## 九、验证方式

- **单测**：上述每个里程碑内的用例（仓颉 `@Test`，包内 `*_test.cj`）；
- **不回归**：`cjpm test -j 16 --no-progress` 314 项基线；
- **安全回归**：专门的用例断言「Ptc 模式下脚本无法访问文件系统/模块/进程」与「子调用受信任闸门约束」——这两条是本设计的核心承诺，必须有测试守住；
- **实测核对**（手工，一次性）：`Both` 模式下确认请求头里工具列表同时含 native schema 与 `run_xisp`。

> **`cjpm test --filter` 的语法（实现期查清）。** `--filter` 是**通配符**匹配，不是正则
> （见 cjpm 文档：`过滤测试用例（通配符匹配，如 * / *.* / *.*Test）`）。此前误用正则写法
> `--filter 'jsonBridge.*'` 导致 `PASSED: 0`，一度被误判为工具链失效；实际上
> `.*` 在通配符语义下要求被测名里**含一个点**，因此只对 class 风格的用例名
> （`PureEnvTest.testArithmetic`）有效，对顶层函数风格（`jsonBridge_scalars`）无效。
>
> 正确用法：
> - 子串：`cjpm test --filter '*jsonBridge*'` → 实测 `PASSED: 12, SKIPPED: 390`
> - 前缀：`cjpm test --filter 'jsonBridge_*'`
> - 全选：`cjpm test --filter '*'`
> - class 风格：`cjpm test --filter 'PureEnvTest.*'`（类名后确有 `.`，故可用）
>
> 根 `cjpm.toml` 的 `[profile.test] filter` 与本项无关——cjpm 文档中 `[profile.test]`
> 的合法字段只有 `compile-option` / `mock` / `env`，该字段未见记载，也不影响命令行过滤。

## 十、风险与边界

| 风险 | 说明 | 缓解 |
|---|---|---|
| **无 OS 级隔离** | 脚本与宿主同进程；xisp 的「沙箱」是软件层防御 | 环境层已最小化（无文件/进程/模块能力）；若需更强隔离，后续加「子进程后端」（xisp 可编译为独立可执行，用 fd 通道，参考实现即此形态） |
| **中断检查点可能遗漏** | 少一处检查点 = 存在跑不完的程序 | M1 用「长循环 / map 内 / 字节码 / NativeFunc 返回后」四类用例守住 |
| **同步绑定会占住求值线程** | 这是设计选择而非缺陷：atelier 工具本就同步 | 与 `SendMessageTool.waitFn` 的既有先例一致（`src/agent/send_message_tool.cj:8-15`） |
| **并发受限** | 同一 `Environment` 非线程安全 → 首版子调用串行 | 脚本内纯计算仍可用 `map`/`filter`/`reduce`；真并行留待「多实例 + 扇出原语」的后续设计 |
| **提示词成本** | SDK 段与 native schema 体量相当，`Both` 下翻倍 | 默认 `Native`；`Ptc` 按部署配置；SDK 段按字典序生成以保前缀稳定 |
| **`toolOrder` 类配置** | 若将来有按名固定工具顺序的配置，`Ptc` 下会引用不到不存在的能力 | 与参考实现同样处理：组装时按模式校验并明确报错，而不是静默忽略 |
| **xisp 发版依赖** | M1 的三项改动必须先发版，atelier 才能依赖 | M1 独立成里程碑，先绿先发 |

## 十一、明确不做（Non-goals）

- **不做 REPL 式持久内核**：每次 `run_xisp` 用全新 `Environment`，程序之间不共享状态。理由是会话日志可重建性——跨调用的隐藏状态会让「同一份历史重放得到同一结果」不再成立。
- **不做 per-tool 呈现分层**（此工具 native、彼工具 ptc-only）：需要每工具元数据与呈现拆分，等有实际使用证据再说。
- **不做 SDK 标识符改写**：工具名原样作为 `tools::<name>` 的一部分；不做连字符↔下划线别名。
- **不复活 `AgentConfig.toolTimeout`**：它当前是死字段，是否复活是独立议题。
- **不做子进程执行后端**：留待确有隔离需求时作为第二个后端引入。

## 附录 A：探针实测记录

三轮探针，均在 `xisp` 项目内以临时 `*_test.cj` 运行，**验证后已删除**（`git status` 干净）。

| 编号 | 探针 | 结果 |
|---|---|---|
| P1 | 干净 `Environment()` + 注册宿主函数 + `Evaluator` | ✅ `(host::hello)` → `"hello-from-host"` |
| P2 | 宿主函数参数/返回/闭包捕获 | ✅ `(tools::read_file "src/main.cj")` → `HashMap{path, ok}`，宿主 `ArrayList` 捕获可见 |
| P2 | **白名单绕过** | ❌ `(tools::secret)` 被拒，但 `(apply tools::secret '())` → `"SECRET-LEAKED"` |
| P2 | **干净环境 + eval** | ✅ `(eval '(+ 1 2))` → `UndefinedFunction: '+'`（环境里没有 `+`，故无害） |
| P2 | **干净环境 + 高阶函数** | ✅ `(map (lambda (x) (tools::echo x)) '(1 2 3))` → `("E:1" "E:2" "E:3")` |
| P2 | 绑定是一等值 | `(list tools::only_visible)` → `(#<native-function>)` |
| P3 | `{...}` 字面量的实际类型 | ✅ **就是 `LispValue.HashMap`**，`{:path "a.cj" :limit 10}` → size=2，键为 `path` / `limit`（无冒号） |
| P3 | 无参 / 裸标量参数 | ✅ `(tools::probe)` → `args.size == 0`；`"plain"` → `Str("plain")` |
| P5 | 超时语义 | ❌ `elapsed=1005ms`（准时返回），但被取消的宿主函数 `after5s(exited=true)` —— **放弃等待，不是停止执行** |
| P4 | 输出捕获 | ❌ `withOutputFn` 后 `buf.size == 0`，脚本 `print` 直接落进程 stdout（`outputFn` 的 30 处调用点全在 `interpreter.cj` 内，均为诊断信息） |
| P4 | 错误值 | ✅ 未定义函数 / `(error "boom")` 均返回结构化 `LispValue.Error`；❌ 语法错误 `(+ 1 ` 静默返回 `1` |

## 附录 B：关键证据索引

**xisp**

| 事项 | 位置 |
|---|---|
| 求值入口 `eval(expr)` | `src/core/eval/core.cj:16` |
| 权限检查点（仅 Symbol 调用） | `src/core/eval/core.cj:227-238` |
| 特殊形式抢先返回（绕过根因） | `src/core/eval/core.cj:159-200`（`:166-168`） |
| `trySpecialForm` 名单 | `src/core/eval/core.cj:117-154` |
| 沙箱超时（放弃等待） | `src/interpreter.cj:598-653`（`:632`、`:646`） |
| 默认注册 IO 桥接 | `src/interpreter.cj:126-131` |
| `LispValue` 15 分支 | `src/types/types.cj:589-882` |
| 宿主函数签名 | `src/interpreter.cj:742-761`、`src/bridge/bridge.cj:22/29` |
| 命名空间分隔符分歧 | `bridge_manager.cj:40`（单冒号） vs `bridge.cj:35`（双冒号） |
| 内建注册可见性 | `src/core/builtin/builtin.cj:16`（public `registerAll`）与各 `registerXxx`（包内） |
| 打印内建绕过 outputFn | `src/core/builtin/print.cj:95-139` |

**atelier**

| 事项 | 位置 |
|---|---|
| 工具接口 | `src/tool/interface.cj:62-68` |
| `ToolExecutionMode` | `src/tool/interface.cj:11-14` |
| **闸门判据复用该字段** | `src/trust/gate.cj:16-27` |
| 批量执行（并行批） | `src/tool/executor.cj:43-130`（`spawn` 在 `:105-108`） |
| 工具分发与策略链 | `src/agent/runtime.cj:287-391` |
| `resolveTools()` | `src/agent/runtime.cj:513-549` |
| 取消检查点（仅边界） | `src/agent/runtime.cj:176/213/247/397`，注释 `:113-114` |
| `toolTimeout` 死字段 | `src/agent/config.cj:26`（无执行路径读取） |
| 提示段扩展点（**不用于 SDK 段**，见 D10） | `src/context/system_prompt_builder.cj:12-14`；`SessionEnvironment` 定义 `src/session/session.cj:7-18` |
| 工具可见性覆盖接缝 | `src/agent/session_loop.cj:68-77`（`toolRegOverride!`） |
| 未 emit 的进度事件 | `src/agent/event.cj:62-66` |
| 组合根注册 | `cli/src/app/main.cj:226-235` |
| MCP 工具 schema 原样透传（`$ref`/`$defs` 会丢失） | `src/tool/mcp_tool.cj:27-38` |
| 依赖位置 | `cli/cjpm.toml:16`（`ystyle::xisp 0.4.0`）；根 `cjpm.toml` 尚无 |

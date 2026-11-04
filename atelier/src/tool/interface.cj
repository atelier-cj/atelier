package atelier.tool

import std.collection.*
import jsonvalue.*
import atelier.interaction.{UserRequest, UserAnswer, UserAnswerStatus, UserRequestKind}
import std.collection.HashMap

/**
 * Execution mode for a tool.
 * - Parallel: the tool can be executed concurrently with other tools.
 * - Sequential: the tool must be executed sequentially (e.g., stateful tools).
 */
public enum ToolExecutionMode {
    | Parallel
    | Sequential
}

/**
 * Context passed to tool execution.
 * Provides runtime information such as working directory and user interaction.
 */

// 结构化提问（宿主实现它就能回答"审批/选择/表单"，并可用 Pending 表示挂起）。
// 未提供时一律按"取消"处理 —— 空答复无法与"拒绝/答了个空"区分，不能当默认值用。
public type AskFn = (UserRequest) -> UserAnswer

/**
 * 后台任务的工作体：跑完返回 (文本, 是否失败)。
 *
 * 用「返回」而不是「回调」：工作体只管干活与产出，什么时候交回去由宿主决定，
 * 工具不需要知道结果最终进了哪个会话。
 */
// 异步任务的 reason 取值。
//
// 放在 tool 层（而不是 agent 层）是因为工具要构造它；agent 层只**读**它做判断，
// 方向是 agent → tool，不会形成环。
public const AsyncTaskReason: String = "async_task"

public type BackgroundWork = () -> (String, Bool)

/**
 * 后台执行通道：工具把一段耗时工作交出去，立刻返回 `asyncToolResult` 挂起本次 run。
 *
 * 宿主实现它（通常是起一个线程跑 work，跑完把结果登记进自己的待回填表），
 * 然后在**下一次 run** 里把结果作为配对的工具结果消息写回历史。
 *
 * 为什么由宿主提供而不是工具自己 spawn：
 *   · 工具不该管理线程生命周期（谁启谁停、宿主关闭时怎么收）；
 *   · 结果必须回到宿主的会话里，工具没有那条通路；
 *   · 测试里可以塞一个同步执行的替身，不必和线程赛跑。
 *
 * 参数：requestId（回填时的关联键）、toolCallId、toolName、work。
 *
 * 未提供时工具**必须回退到同步执行**——不能因为"没有后台通道"就静默不干活。
 */
public type BackgroundSubmit = (String, String, String, BackgroundWork) -> Unit


/**
 * 结构化提问入口（审批 / 选择 / 表单）。
 *
 * 宿主没给实现时返回 `Cancelled`：这表示"这条通道不存在"，而不是"用户拒绝了"。
 * 需要交互的宿主（TUI / ACP / AG-UI）各自提供自己的 `askFn`。
 */
extend ToolContext {
    public func ask(req: UserRequest): UserAnswer {
        match (this.askFn) {
            case Some(f) => f(req)
            case None => UserAnswer(req.id, UserAnswerStatus.Cancelled)
        }
    }
}

public struct ToolContext {
    public let workDir: String
    public let env: HashMap<String, String>
    // 当前运行会话 id（无会话上下文时为空 ""）；子 agent 父向调度等场景使用
    public let sessionId: String
    // 本次工具调用的 id（LLM 侧 tool_call id；无调用上下文时为空 ""）。
    // 工具要把自己的执行与协议/UI 上的同一次调用对上（进度上报、等外部执行结果）时用得到它：
    // 一次调用一份上下文，而不是一个会话共用一份。
    public let toolCallId: String
    // 结构化提问实现（None = 无交互通道，提问即取消）
    public let askFn: Option<AskFn>
    // 后台执行通道（None = 不支持后台，工具须回退同步执行）
    public let backgroundFn: Option<BackgroundSubmit>

    public init(workDir: String) {
        this.workDir = workDir
        this.env = HashMap()
        this.sessionId = ""
        this.toolCallId = ""
        this.askFn = None
        this.backgroundFn = None
    }

    public init(workDir: String, env: HashMap<String, String>) {
        this.workDir = workDir
        this.env = env
        this.sessionId = ""
        this.toolCallId = ""
        this.askFn = None
        this.backgroundFn = None
    }

    public init(workDir: String, env: HashMap<String, String>, sessionId: String,
        toolCallId!: String = "", ask!: Option<AskFn> = None,
        background!: Option<BackgroundSubmit> = None) {
        this.workDir = workDir
        this.env = env
        this.sessionId = sessionId
        this.toolCallId = toolCallId
        this.askFn = ask
        this.backgroundFn = background
    }
}

extend ToolContext {
    /**
     * 提交一个后台任务；没有后台通道时返回 false（调用方须回退同步执行）。
     *
     * 刻意返回 Bool 而不是静默 no-op：工具必须能区分"交出去了"与"没人接"，
     * 后者的正确反应是同步跑，而不是返回一句"已提交"却什么也没发生。
     */
    public func submitBackground(requestId: String, toolName: String,
        work: BackgroundWork): Bool {
        match (this.backgroundFn) {
            case Some(f) =>
                f(requestId, this.toolCallId, toolName, work)
                true
            case None => false
        }
    }
}

/**
 * Tool interface.
 * All tools must implement this interface to be registered in the ToolRegistry.
 */
public interface Tool {
    func name(): String
    func description(): String
    func schema(): JsonValue
    func execute(ctx: ToolContext, args: JsonValue): ToolResult
    func executionMode(): ToolExecutionMode
    /**
     * 该工具对自己时间预算的声明。
     *
     * 默认 `ToolBudget.Default`：交由框架策略决定。工具比框架更清楚自己需要多久，
     * 所以有两种更具体的声明方式——见 {@link ToolBudget}（声明额度 / 声明不该有预算）。
     */
    func timeoutBudget(): ToolBudget {
        ToolBudget.Default
    }
}

/**
 * Result of a tool execution.
 *
 * At this level, tools output plain text. The runtime wraps this into
 * a ToolResultMessage if needed for conversation history.
 */
public struct ToolResult {
    /** Primary text output of the tool execution. */
    public let text: String
    /** Structured details for UI/logging (optional). */
    public let details: Option<JsonValue>
    /** Whether the execution resulted in an error. */
    public let isError: Bool
    /** Whether this result should terminate the entire Run. */
    public let terminate: Bool
    /**
     * 本次调用要由**外部**给结果（前端执行、用户确认……）。
     *
     * 非 None 表示：本进程不产出结果，运行时挂起这次 run（不写结果消息，历史停在
     * assistant(tool_calls)），把中断交给调用方；调用方在**下一次** run 里带回结果。
     */
    public let external: Option<ExternalRequest>

    public init(
        text: String,
        details: Option<JsonValue>,
        isError: Bool,
        terminate: Bool,
        external!: Option<ExternalRequest> = None
    ) {
        this.text = text
        this.details = details
        this.isError = isError
        this.terminate = terminate
        this.external = external
    }
}

/**
 * 挂起请求：这次运行需要外部在之后提供结果。
 *
 * id 是跨 run 的关联键（调用方在恢复时原样回填）：同一个挂起被重复提交要幂等。
 */
public class ExternalRequest {
    public let id: String
    /** 分类：tool_call（绑定某次工具调用）/ input_required（要一段结构化输入） */
    public let reason: String
    /** 给人看的一句话（前端没有专用 UI 时的兜底展示） */
    public let message: String
    /** reason=tool_call 时绑定到的工具调用 id，否则为空 */
    public let toolCallId: String
    /**
     * 触发挂起的原始提问（审批 / 选择 / 表单）。
     *
     * 挂起的是「一个待回答的问题」，而不是一句提示语：候选、字段、类型、必填都在
     * `UserRequest` 里。协议适配层据此生成答复契约（如 AG-UI 的 `responseSchema`），
     * 不然前端只拿到一句 message，只能靠猜该收什么。
     *
     * 核心层不认识任何具体协议的 schema 表达，只把提问原样带出来。
     * `tool_call` 类挂起（前端执行工具）没有提问，为 None。
     */
    public let request: Option<UserRequest>

    public init(id: String, reason: String, message: String, toolCallId!: String = "",
        request!: Option<UserRequest> = None) {
        this.id = id
        this.reason = reason
        this.message = message
        this.toolCallId = toolCallId
        this.request = request
    }
}

// ---------- 异步工具的构造辅助（放在 tool 层，避免 agent ↔ tool.builtin 循环依赖）----------

// 异步工具声明的统一入口：工具返回它，运行时就会挂起这次 run，
// 并登记一个待回填的后台任务。
//
// 为什么做成构造器而不是让工具自己 new ExternalRequest：
//   · reason 必须统一（`async_task`），否则消费方分不清"等后台"与"等人"；
//   · requestId 的生成规则必须一致（幂等回填靠它）；
//   · 挂起登记与挂起请求是**同一件事的两面**，分开写一定会漏一边——
//     漏了登记，后台跑完也没人知道该填给谁。
//
// 用法：
//
//   public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
//       let reqId = newAsyncRequestId(ctx.toolCallId)
//       spawn { /* 干活 */ ; sendResultBack(reqId, ...) }
//       asyncToolResult(reqId, "已提交后台执行", ctx.toolCallId)
//   }
public func newAsyncRequestId(toolCallId: String): String {
    "async-" + toolCallId
}

// 构造"这次由后台执行"的工具结果。
//
// `text` 是给模型看的一句话（"已提交后台执行，结果稍后送达"）——它不会写进历史
// （挂起时不产生结果消息），但会出现在工具执行结束事件里，前端可据此显示进度。
public func asyncToolResult(requestId: String, text: String, toolCallId: String,
    toolName!: String = ""): ToolResult {
    ToolResult(text, None, false, false,
        external: Some(ExternalRequest(requestId, AsyncTaskReason, text,
            toolCallId: toolCallId)))
}

// 判断一个挂起是不是"等后台任务"（相对于"等人答复/前端执行"）。
//
// 消费方据此决定要不要设超时：等后台一定会来，等人可能永远不来。
public func isAsyncTaskRequest(req: ExternalRequest): Bool {
    req.reason == AsyncTaskReason
}


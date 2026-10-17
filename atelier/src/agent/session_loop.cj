package atelier.agent

import std.collection.*
import std.core.Duration
import atelier.message.*
import atelier.provider.*
import atelier.tool.*
import atelier.interaction.*
import atelier.session.*
import atelier.trust.*
import atelier.skill.*
import stdx.log.*
import atelier.event.EventStream
import atelier.context.PromptSegmentContributor

// 一次回合的结果：最终消息列表（含历史与新增）与是否被 close 打断
public class TurnOutcome {
    public let messages: ArrayList<Message>
    public let stoppedByClose: Bool
    public init(messages: ArrayList<Message>, stoppedByClose: Bool) {
        this.messages = messages
        this.stoppedByClose = stoppedByClose
    }
}

// SessionLoop：统一「消息驱动的单回合执行」——历史 + 输入文本 → chatWithSessionId →
// 事件消费（可选逐事件回调；支持协作式取消与关闭）→ persistAppend 落库。
// 子 Agent worker、ACP 会话桥、未来宿主循环共用同一回合语义（runtime 本身零改动）。
public class SessionLoop {
    // 装配束：一次回合所需组件全在这里（会话存储、工具表、信任、技能、MCP……）
    private let spec: HarnessSpec

    public init(spec: HarnessSpec) {
        this.spec = spec
    }

    // 执行一次回合。requestStop：close 请求（打断且不回信语义由调用方判定）；
    // requestCancel：cancel 请求（中断进行中回合，回合正常收敛收尾）。
    // onEvent：可选的逐事件钩子（如 ACP 事件翻译），在事件被内部消费前调用。
    // parentSession：首轮落库写入 header.parentSession 的提示（子 agent 标记父会话用）。
    // askFn：结构化提问实现（信任闸门审批、ask_user 的问答都由它出去；None = 无交互通道）。
    // maxLoad：历史加载截断窗口（0=不截断；>0 语义同 truncateMessages，保留 Archive 头部）。
    public func run(sessionId: String, inputText: String,
        config: AgentConfig, provider: Provider, toolRegOverride: ?ToolRegistry,
        env: SessionEnvironment,
        requestStop: () -> Bool, requestCancel: () -> Bool,
        onEvent!: ?(AgentEvent) -> Unit = None,
        parentSession!: ?String = None,
        askFn!: Option<AskFn> = None,
        maxLoad!: Int64 = 0,
        attachments!: ArrayList<ContentBlock> = ArrayList()): TurnOutcome {
        var oldLoaded = ArrayList<Message>()
        try { oldLoaded = this.spec.store.load(sessionId) } catch (e: Exception) {
            // 历史加载失败若不留痕，表现为「会话凭空变空」——下游只能看到模型失忆
            eprintln("[atelier] session load failed (sessionId=${sessionId}): ${e.toString()}")
        }
        let loaded = if (maxLoad > 0) { truncateMessages(oldLoaded, maxLoad) } else { oldLoaded }
        let msgs = ArrayList<Message>(loaded)
        if (inputText != "" || attachments.size > 0) {
            let blocks = ArrayList<ContentBlock>()
            if (inputText != "") { blocks.add(ContentBlock.TextBlock(inputText)) }
            for (b in attachments) { blocks.add(b) }
            msgs.add(UserMessage(ContentList(blocks), 0))
        }
        // 本回合的装配束：显式传入的 provider / 工具表 / 提问通道在本回合内生效，
        // 其余组件与装配期一致
        var turnSpec = this.spec
        turnSpec = turnSpec.withProvider(providerNameOf(config), provider)
        match (toolRegOverride) {
            case Some(r) => turnSpec = turnSpec.withToolRegistry(r)
            case None => ()
        }
        match (askFn) {
            case Some(f) => turnSpec = turnSpec.withAsk(f)
            case None => ()
        }
        let runtime = turnSpec.createLoop(config, sessionEnv: env)
        let stream = runtime.chatWithSessionId(sessionId, msgs, env)
        // 事件消费 + 控制轮询收敛成一个独立函数（便于用构造出来的流单测：见
        // session_loop_test 的 consumeTurnStream 用例）
        let outcome = consumeTurnStream(stream, requestStop, requestCancel, onEvent,
            { => runtime.cancelSession(sessionId) })
        var stoppedByClose = false
        match (outcome) {
            case ConsumeOutcome.Ended => ()
            case ConsumeOutcome.Stopped => stoppedByClose = true
            case ConsumeOutcome.ClosedNoEnd =>
                // 生产端已收尾却没有终止事件：以前这里会永远每 200ms 空转一轮
                eprintln("[atelier] turn stream closed without AgentEndEvent (sessionId=${sessionId})")
        }
        let all = try { stream.result() } catch (e: Exception) {
            // 回合结果不可得：降级为「仅历史」返回；不留痕则表现为「这一轮回复凭空消失」
            eprintln("[atelier] turn result unavailable (sessionId=${sessionId}): ${e.toString()}")
            ArrayList<Message>(oldLoaded)
        }
        // 落库（错误由调用方按日志策略处理）
        match (persistAppendWithParent(this.spec.store, sessionId, oldLoaded, all, parentSession)) {
            case Some(err) => getGlobalLogger([("name", "SessionLoop")]).error("persist: ${err}", Array<Attr>())
            case None => ()
        }
        TurnOutcome(all, stoppedByClose)
    }
}

// 回合事件流的收敛结果
enum ConsumeOutcome {
    | Ended          // 收到 AgentEndEvent（正常收敛）
    | Stopped        // 调用方请求 close（打断本回合）
    | ClosedNoEnd    // 生产端已收尾，但 AgentEndEvent 始终没来
}

// 消费一个回合的事件流直到收敛。
//
// 原先这段内联在 run() 里且只认 AgentEndEvent 与 requestStop：生产端线程一旦被
// Error 带走（既不发终止事件也不 setError），消费循环就无限空转、result() 永久
// 阻塞。现在多了流生命周期兜底——生产端收尾时一定 close()，这里在 receive 超时
// 后用它判定「别再等了」。抽成独立函数是为了能用构造出来的流直接单测。
// AgentStartEvent 到达 ⇔ runtime 已注册 cancelFlag：早到的取消请求在事件到达后补发（幂等）。
func consumeTurnStream(stream: EventStream<AgentEvent, ArrayList<Message>>,
    requestStop: () -> Bool, requestCancel: () -> Bool,
    onEvent: ?(AgentEvent) -> Unit, cancelTurn: () -> Unit): ConsumeOutcome {
    var cancelArmed = false
    var outcome = ConsumeOutcome.ClosedNoEnd
    var done = false
    while (!done) {
        if (requestStop()) {
            cancelTurn()
            outcome = ConsumeOutcome.Stopped
            done = true
        } else {
            if (cancelArmed && requestCancel()) {
                cancelTurn()
            }
            match (stream.receive(Duration.millisecond * 200)) {
                case Some(ev: AgentStartEvent) =>
                    cancelArmed = true
                    if (requestCancel()) {
                        cancelTurn()
                    }
                    if (let Some(cb) <- onEvent) { cb(ev) }
                case Some(ev: AgentEndEvent) =>
                    if (let Some(cb) <- onEvent) { cb(ev) }
                    outcome = ConsumeOutcome.Ended
                    done = true
                case Some(ev) =>
                    if (requestCancel()) {
                        cancelTurn()
                    }
                    if (let Some(cb) <- onEvent) { cb(ev) }
                case None =>
                    if (stream.isClosed()) {
                        outcome = ConsumeOutcome.ClosedNoEnd
                        done = true
                    }
            }
        }
    }
    outcome
}

package cli

import atelier.agent.*
import std.collection.*
import std.sync.*
import std.time.MonoTime

/** 保留的脚本日志行数上限：脚本可能打印几千行，活动区不能跟着涨。 */
const ACTIVITY_LOG_KEEP: Int64 = 40
/** 快照里显示的脚本日志行数（更早的折成一行提示）。 */
const ACTIVITY_LOG_SHOW: Int64 = 5

/** 一次进行中的调用（顶层工具或 PTC 子调用）。 */
class ActiveCall {
    let callId: String
    let name: String
    let start: MonoTime
    let subCall: Bool

    init(callId: String, name: String, start: MonoTime, subCall: Bool) {
        this.callId = callId
        this.name = name
        this.start = start
        this.subCall = subCall
    }
}

/** 经过时间的可读形式：一秒内给毫秒，十秒内给一位小数，更长给整秒。 */
func formatElapsed(ms: Int64): String {
    if (ms < 1000) {
        return "${ms}ms"
    }
    if (ms < 10000) {
        return "${ms / 1000}.${(ms % 1000) / 100}s"
    }
    "${ms / 1000}s"
}

/**
 * 回合内的实时活动：把 Agent 事件归约成「哪个工具在跑、跑了多久、脚本刚打印了什么」。
 *
 * 不消费事件流的前端只能显示读秒——工具卡住、脚本在长循环里、写操作超时后还在后台跑，
 * 这些状态在界面上长得一模一样。事件流本来就是为这个准备的（{@link ToolExecutionStartEvent}
 * / {@link ToolExecutionUpdateEvent} / {@link ToolExecutionEndEvent}）。
 *
 * 两个消费者共用同一份归约：
 * - TUI：整帧重绘，用 {@link snapshotLines} 取当前状态；
 * - 只追加的场景（一次性运行 / 未来的流式前端）：用 {@link drainNewLines} 取新增行。
 *
 * 事件由回合线程写入、界面线程读取，内部加锁；快照返回副本，调用方拿到即可安全渲染。
 */
public class TurnActivity {
    private let lock = Mutex()
    /** 正在跑的调用，按开始顺序（并行批次可能同时有多个）。 */
    private let running = ArrayList<ActiveCall>()
    /** 最近的脚本日志行。 */
    private let logs = ArrayList<String>()
    /** 增量模式待取走的新行。 */
    private let pending = ArrayList<String>()
    private var started: Int64 = 0

    init() {}

    /** 归约一个事件。非工具/回合类事件一律忽略。 */
    public func onEvent(e: AgentEvent, now: MonoTime): Unit {
        synchronized(this.lock) {
            match (e) {
                case _: TurnStartEvent => this.resetLocked()
                case s: ToolExecutionStartEvent =>
                    // 子调用的 id 形如 run_xisp#1:ptc:2（见 RunXispHost.nextCallId）
                    let sub = s.toolCallId.contains(":ptc:")
                    this.started = this.started + 1
                    this.running.add(ActiveCall(s.toolCallId, s.toolName, now, sub))
                    this.pending.add(if (sub) { "    ↳ ${s.toolName}" } else { "  ▶ ${s.toolName}" })
                case u: ToolExecutionUpdateEvent =>
                    // PTC 脚本的 println 走这里：一次可能带多行
                    for (line in u.progress.split("\n")) {
                        this.logs.add(line)
                        this.pending.add("  │ ${line}")
                    }
                    while (this.logs.size > ACTIVITY_LOG_KEEP) {
                        this.logs.remove(at: 0)
                    }
                case x: ToolExecutionEndEvent =>
                    let call = this.takeLocked(x.toolCallId)
                    let sub = match (call) {
                        case Some(c) => c.subCall
                        case None => x.toolCallId.contains(":ptc:")
                    }
                    let name = match (call) {
                        case Some(c) => c.name
                        case None => x.toolCallId
                    }
                    let spent = match (call) {
                        case Some(c) => "  (" + formatElapsed((now - c.start).toMilliseconds()) + ")"
                        case None => ""
                    }
                    let indent = if (sub) { "    " } else { "  " }
                    this.pending.add("${indent}${if (x.isError) { "✗" } else { "✓" }} ${name}${spent}")
                case _ => ()
            }
        }
    }

    /**
     * 当前状态的快照（TUI 整帧重绘用）。
     *
     * 没有任何活动时返回空——空块不该占掉会话区。
     */
    public func snapshotLines(now: MonoTime, width: Int64): ArrayList<String> {
        synchronized(this.lock) {
            let out = ArrayList<String>()
            if (this.started == 0 && this.running.size == 0 && this.logs.size == 0) {
                return out
            }
            let head = if (this.running.size > 0) {
                "· 工具 ${this.started} 次 · 进行中 ${this.running.size}"
            } else {
                "· 工具 ${this.started} 次"
            }
            out.add(colorize(truncateLine(head, width), C_DIM))
            for (call in this.running) {
                let spent = formatElapsed((now - call.start).toMilliseconds())
                let line = if (call.subCall) {
                    "    ↳ ${call.name}  (${spent})"
                } else {
                    "  ▶ ${call.name}  (${spent})"
                }
                out.add(colorize(truncateLine(line, width), C_TOOL))
            }
            let hidden = if (this.logs.size > ACTIVITY_LOG_SHOW) { this.logs.size - ACTIVITY_LOG_SHOW } else { 0 }
            if (hidden > 0) {
                out.add(colorize(truncateLine("  │ … 前面还有 ${hidden} 行", width), C_DIM))
            }
            for (i in hidden..this.logs.size) {
                out.add(colorize("  │ " + truncateLine(this.logs[i], width - 4), C_TOOL))
            }
            out
        }
    }

    /** 取走本次新增的进度行（只追加的呈现用）。 */
    public func drainNewLines(): ArrayList<String> {
        synchronized(this.lock) {
            let out = ArrayList<String>()
            for (line in this.pending) {
                out.add(line)
            }
            this.pending.clear()
            out
        }
    }

    /** 回合结束：清空（活动块只在回合进行中有意义）。 */
    public func clear(): Unit {
        synchronized(this.lock) {
            this.resetLocked()
        }
    }

    private func resetLocked(): Unit {
        this.running.clear()
        this.logs.clear()
        this.pending.clear()
        this.started = 0
    }

    /** 摘出并返回该 callId 的调用；没有则 None（事件可能来自未被观察的调用）。 */
    private func takeLocked(callId: String): ?ActiveCall {
        var found: ?ActiveCall = None
        var i: Int64 = 0
        while (i < this.running.size) {
            if (this.running[i].callId == callId) {
                found = Some(this.running[i])
                this.running.remove(at: i)
            } else {
                i = i + 1
            }
        }
        found
    }
}

/**
 * 边等边把进度行交给 `sink`，流收敛后返回。
 *
 * 事件不会因此丢失：调用方随后照常 `stream.result()` 取消息。
 * sink 的目标由调用方决定——当前 `cli.app run` 打到 stderr
 * （stdout 留给答案，便于管道）。
 */
public func pumpProgress(stream: LoopEventStream, sink: (String) -> Unit): Unit {
    pumpProgress(stream, sink, { _ => () })
}

/**
 * 同上，并在消费事件时逐个回调给 `onEvent`（`run --json-events` 用它产出结构化日志）。
 *
 * 必须与进度呈现**共用同一个消费循环**：事件流只能被读一次、读到的事件不回放，
 * 另起一个循环去读就会两边各拿一半事件——JSONL 会缺回合，进度条也会卡住。
 */
public func pumpProgress(stream: LoopEventStream, sink: (String) -> Unit,
    onEvent: (AgentEvent) -> Unit): Unit {
    let activity = TurnActivity()
    var done = false
    while (!done) {
        match (stream.receive(200 * Duration.millisecond)) {
            case Some(e) =>
                onEvent(e)
                activity.onEvent(e, MonoTime.now())
                for (line in activity.drainNewLines()) {
                    sink(line)
                }
            case None =>
                if (stream.isClosed()) {
                    done = true
                }
        }
    }
}

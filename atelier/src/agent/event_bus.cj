package atelier.agent

import std.collection.*
import std.sync.*

// 全局事件总线：把 AgentRuntime 回合内的事件流转发为进程级发布/订阅
// （跨会话审计/监控/UI 聚合；父+多子场景无需各自接线消费）。
// - 订阅过滤：filter 谓词（按事件类型 is / 事件字段判断），默认全收；
// - publish 在发射线程同步调用 handler（handler 需快且线程安全；重活请自行排队）；
// - 订阅者 handler 抛异常不影响其它订阅者与发射线程（逐个容错）；
// - 可选挂载：AgentRuntime / SessionLoop 构造 eventBus（默认 None，零行为变化）。
public class EventBus {
    private let lock = Mutex()
    private var seq: Int64 = 0
    private let subs = HashMap<Int64, (AgentEvent) -> Unit>()

    public init() {}

    // 订阅；返回订阅 id（unsubscribe 用）。filter 返回 true 才投递。
    public func subscribe(handler: (AgentEvent) -> Unit,
        filter!: (AgentEvent) -> Bool = { ev => true }): Int64 {
        synchronized(this.lock) {
            this.seq++
            this.subs[this.seq] = { ev =>
                if (filter(ev)) { handler(ev) }
            }
            this.seq
        }
    }

    public func unsubscribe(id: Int64): Unit {
        synchronized(this.lock) { this.subs.remove(id) }
    }

    public func publish(ev: AgentEvent): Unit {
        // 快照后逐个投递（容忍投递期间订阅变更）；单订阅者异常不连坐
        let targets = synchronized(this.lock) {
            let arr = ArrayList<(AgentEvent) -> Unit>()
            for ((_, h) in this.subs) { arr.add(h) }
            arr
        }
        for (h in targets) {
            // 单订阅者异常不连坐（语义不变），但必须留痕：否则事件静默丢失，订阅方无从得知
            try { h(ev) } catch (e: Exception) {
                eprintln("[atelier] event subscriber failed: ${e.toString()}")
            }
        }
    }

    public func subscriberCount(): Int64 {
        synchronized(this.lock) { this.subs.size }
    }
}

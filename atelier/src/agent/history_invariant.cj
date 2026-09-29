package atelier.agent

import std.collection.*
import atelier.message.*

// 请求历史的**不变式**：assistant 带 tool_calls 的消息，后面必须紧跟「每个 call 各一条」工具结果。
//
// OpenAI 兼容接口对违反该不变式的请求直接判 400
// （`An assistant message with 'tool_calls' must be followed by tool messages responding to
// each 'tool_call_id'. (insufficient tool messages following tool_calls message)`），
// 而 400 属于「重试也不会好」的客户端错误 —— 整轮就此作废，宿主那头只看到一次报错。
//
// 能破坏该不变式的路径不止一条：回合末上下文压缩改写历史、afterTurn/beforeTurn 钩子替换消息列表、
// 工具批次整体抛异常的兜底分支、以及**回复被截断/终止原因缺失时消息里已经带上完整 tool_call**
// 却被当成纯文本回合处理（后面追加 user 消息）。因此校验放在**发请求前的唯一收口处**，
// 而不是要求每条路径各自维护不变式 —— 新增路径时不必记得这条规则。
//
// 返回补入的占位结果条数（0 = 历史本来就合法）。占位只是兜底：调用方应按非 0 打警告，
// 出现即说明有路径破坏了不变式，需要定位。

// 占位结果正文：明确「没执行」而不是「执行失败」，否则模型会以为工具跑过并据此推理。
func unansweredToolCallNote(toolName: String): String {
    "[no result recorded for tool '" + toolName + "'] 该调用没有产生结果（历史被改写，" +
        "或回合在结果写入前就结束了）。需要它的信息请重新调用，不要假设它已经执行。"
}

// 就地补齐缺失的工具结果。幂等：补齐后再跑一次不会重复插入。
func ensureToolCallResults(messages: ArrayList<Message>): Int64 {
    var inserted: Int64 = 0
    var i: Int64 = 0
    while (i < messages.size) {
        match (messages[i]) {
            case am: AssistantMessage =>
                let calls = am.toolCalls()
                if (calls.size == 0) {
                    i++
                    continue
                }
                // 紧跟在 assistant 之后的一串工具结果，就是这条消息的结果区
                let answered = HashSet<String>()
                var j = i + 1
                var scanning = true
                while (scanning && j < messages.size) {
                    match (messages[j]) {
                        case tr: ToolResultMessage =>
                            answered.add(tr.toolCallId)
                            j++
                        case _ => scanning = false
                    }
                }
                // 按模型给出的调用顺序补齐，缺哪个补哪个，统一补在结果区末尾
                var at = j
                for (tc in calls) {
                    if (!answered.contains(tc.id)) {
                        messages.add(
                            ToolResultMessage(tc.id, tc.name,
                                ContentList.ofText(unansweredToolCallNote(tc.name)), true, 0),
                            at: at)
                        at++
                        inserted++
                    }
                }
                i = at
            case _ => i++
        }
    }
    inserted
}

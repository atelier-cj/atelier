package atelier.agent

import std.collection.*
import atelier.message.*
import atelier.interaction.*

// 恢复：把宿主带回的答复从输入消息里收集出来（编码见 interaction/user_answer_codec.cj）。
//
// 为什么要从消息里收集而不是用构造参数：恢复走的是"同 thread 的第二次 run"，
// 宿主把答复随消息一起发上来（元数据通道），运行时开跑时收集一次，
// 审批/提问处**先查这份映射**（命中即用，不再问宿主），这样"重放同一回合"才能对上答复。

// 消息的元数据通道（五种角色的消息都带 metadata）
func metadataOf(m: Message): HashMap<String, String> {
    match (m) {
        case um: UserMessage => um.metadata
        case am: AssistantMessage => am.metadata
        case tm: ToolResultMessage => tm.metadata
        case cm: CompactionMessage => cm.metadata
        case am: ArchiveMessage => am.metadata
        case _ => HashMap<String, String>()   // 未来新增角色：无元数据通道时按无答复处理
    }
}

public func collectResumedAnswers(msgs: ArrayList<Message>): HashMap<String, UserAnswer> {
    let out = HashMap<String, UserAnswer>()
    for (m in msgs) {
        let md = metadataOf(m)
        if (!isAnswerMetadata(md)) { continue }
        match (decodeAnswer(md)) {
            case Some(a) => out[a.requestId] = a
            case None => ()      // 坏数据当作没答复：宁可再问一次，也不拿半个答复执行
        }
    }
    out
}

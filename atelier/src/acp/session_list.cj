package atelier.acp

import std.collection.*
import acp.SessionRecord
import acp.types.SessionInfo

// session/list 的两条协议语义（与 bridge 的回调解耦，便于单测）：
//
// 1) `cwd` 是**过滤条件**，不是提示：只返回工作目录与之一致的会话；
//    没有任何会话匹配时返回空数组（而不是全量、也不是错误）。
// 2) `cursor` 是分页游标。本 Agent 不分页（响应从不带 nextCursor），
//    因此任何非空 cursor 都不可能由它签发 → 必须 -32602（Invalid params），
//    而不是忽略后照常返回一页——那会让 Client 以为自己拿到的是「下一页」。

// 按 cwd 过滤并转成协议对象：cwd 缺省 = 不过滤（返回全部）
func listSessionInfos(records: ArrayList<SessionRecord>, cwd: ?String): ArrayList<SessionInfo> {
    let out = ArrayList<SessionInfo>()
    for (r in records) {
        match (cwd) {
            case Some(want) =>
                if (r.cwd != want) { continue }
            case None => ()
        }
        let info = SessionInfo()
        info.sessionId = r.sessionId
        info.cwd = r.cwd
        out.add(info)
    }
    out
}

// cursor 校验：返回 Some(消息) 表示必须拒绝该请求（调用方映射为 -32602）。
// 空串同样不是本 Agent 签发过的值，一并拒绝。
func listSessionsCursorError(cursor: ?String): ?String {
    match (cursor) {
        case Some(c) => Some("Unknown cursor: ${c}")
        case None => None
    }
}

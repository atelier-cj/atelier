package atelier.acp

import std.collection.*
import acp.SessionRecord

func listRecords(): ArrayList<SessionRecord> {
    let records = ArrayList<SessionRecord>()
    records.add(SessionRecord("sess_a", "/work/alpha", "backend_a"))
    records.add(SessionRecord("sess_b", "/work/beta", "backend_b"))
    records.add(SessionRecord("sess_c", "/work/alpha", "backend_c"))
    records
}

// cwd 精确匹配：只返回该工作目录下的会话（这也是 TCK ACP-LIST-002 的语义）
@Test
func sessionList_cwdFilterKeepsMatchingOnly() {
    let infos = listSessionInfos(listRecords(), Some("/work/alpha"))
    @Expect(infos.size, 2)
    @Expect(infos[0].sessionId, "sess_a")
    @Expect(infos[1].sessionId, "sess_c")
    for (i in infos) { @Expect(i.cwd, "/work/alpha") }
}

// 没有任何会话匹配该 cwd → 空数组（不是全量，也不是错误）
@Test
func sessionList_cwdFilterUnmatchedReturnsEmpty() {
    let infos = listSessionInfos(listRecords(), Some("/work/no-such-dir"))
    @Expect(infos.size, 0)
}

// 不带 cwd → 不过滤
@Test
func sessionList_noCwdReturnsAll() {
    let infos = listSessionInfos(listRecords(), None)
    @Expect(infos.size, 3)
}

// cwd 是精确匹配而非前缀/子目录匹配：/work 不会命中 /work/alpha
@Test
func sessionList_cwdFilterIsExactNotPrefix() {
    let infos = listSessionInfos(listRecords(), Some("/work"))
    @Expect(infos.size, 0)
}

// 不带 cursor → 不拒绝
@Test
func sessionList_noCursorAccepted() {
    @Expect(listSessionsCursorError(None).isNone(), true)
}

// 本实现不分页，任何 cursor 都不是它签发过的 → 必须拒绝（-32602）
@Test
func sessionList_anyCursorRejected() {
    match (listSessionsCursorError(Some("_tck-never-issued-cursor"))) {
        case Some(msg) =>
            @Expect(msg.contains("_tck-never-issued-cursor"), true)
        case None => @Fail("never-issued cursor must be rejected")
    }
    // 空串同样不是签发值
    @Expect(listSessionsCursorError(Some("")).isSome(), true)
}

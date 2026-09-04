package atelier.acp

import std.collection.*
import std.fs.*

func mapTempDir(): String {
    Directory.createTemp(Path("/tmp")).toString()
}

func cleanupMapDir(dir: String): Unit {
    try { remove(Path(dir), recursive: true) } catch (_) { () }
}

// 新建 → active 可查；字段完整（acp id 前缀 / atelier id / cwd）
@Test
func sessionMap_newAndLookup() {
    let dir = mapTempDir()
    let mgr = AcpSessionManager(dir + "/map.json")
    let s = mgr.newSession("/tmp/proj")
    @Expect(s.acpId.startsWith("acp_"), true)
    @Expect(s.atelierId != "", true)
    @Expect(s.cwd, "/tmp/proj")
    match (mgr.lookup(s.acpId)) {
        case Some(v) =>
            @Expect(v.atelierId, s.atelierId)
            @Expect(v.acpId, s.acpId)
        case None => @Fail("lookup active session failed")
    }
    cleanupMapDir(dir)
}

// 未知 id → None
@Test
func sessionMap_lookupUnknownIsNone() {
    let dir = mapTempDir()
    let mgr = AcpSessionManager(dir + "/map.json")
    @Expect(mgr.lookup("acp_unknown").isNone(), true)
    @Expect(mgr.getActive("acp_unknown").isNone(), true)
    cleanupMapDir(dir)
}

// dropActive（session/close）后：active 清除，lookup 从持久化恢复同 atelierId
@Test
func sessionMap_dropActiveKeepsMapping() {
    let dir = mapTempDir()
    let mgr = AcpSessionManager(dir + "/map.json")
    let s = mgr.newSession("/p")
    mgr.dropActive(s.acpId)
    @Expect(mgr.getActive(s.acpId).isNone(), true)
    match (mgr.lookup(s.acpId)) {
        case Some(v) => @Expect(v.atelierId, s.atelierId)
        case None => @Fail("mapping lost after dropActive")
    }
    cleanupMapDir(dir)
}

// deleteMapping（session/delete）后：映射彻底删除
@Test
func sessionMap_deleteMappingRemoves() {
    let dir = mapTempDir()
    let mgr = AcpSessionManager(dir + "/map.json")
    let s = mgr.newSession("/p")
    mgr.deleteMapping(s.acpId)
    @Expect(mgr.lookup(s.acpId).isNone(), true)
    @Expect(mgr.size(), Int64(0))
    cleanupMapDir(dir)
}

// 跨实例恢复：新 manager 读同一映射文件，lookup 能找回（进程重启场景）
@Test
func sessionMap_persistsAcrossInstances() {
    let dir = mapTempDir()
    let file = dir + "/map.json"
    let mgr1 = AcpSessionManager(file)
    let s = mgr1.newSession("/work")
    let mgr2 = AcpSessionManager(file)
    match (mgr2.lookup(s.acpId)) {
        case Some(v) =>
            @Expect(v.atelierId, s.atelierId)
            @Expect(v.cwd, "/work")
        case None => @Fail("mapping not persisted")
    }
    @Expect(mgr2.size(), Int64(1))
    cleanupMapDir(dir)
}

// list 反映全部记录
@Test
func sessionMap_listCounts() {
    let dir = mapTempDir()
    let mgr = AcpSessionManager(dir + "/map.json")
    let a = mgr.newSession("/a")
    let b = mgr.newSession("/b")
    @Expect(mgr.size(), Int64(2))
    @Expect(mgr.list().size, 2)
    mgr.dropActive(a.acpId)
    @Expect(mgr.size(), Int64(2))
    @Expect(b.acpId != a.acpId, true)
    cleanupMapDir(dir)
}

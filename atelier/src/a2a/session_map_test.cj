package atelier.a2a

import std.collection.*
import std.fs.*

private func a2aMapTempDir(): String {
    Directory.createTemp(Path("/tmp")).toString()
}

private func a2aCleanupMapDir(dir: String): Unit {
    try { remove(Path(dir), recursive: true) } catch (_) { () }
}

// 新建 → active 可查；字段完整（contextId / atelier id / cwd / createdAt）
@Test
func a2aSessionMap_newAndLookup() {
    let dir = a2aMapTempDir()
    let mgr = A2aSessionManager(dir + "/a2a-sessions.json")
    let s = mgr.newSession("/tmp/proj")
    @Expect(s.contextId.startsWith("ctx_"), true)
    @Expect(s.atelierId != "", true)
    @Expect(s.cwd, "/tmp/proj")
    @Expect(s.createdAt != "", true)
    match (mgr.lookup(s.contextId)) {
        case Some(v) =>
            @Expect(v.atelierId, s.atelierId)
            @Expect(v.contextId, s.contextId)
        case None => @Fail("lookup active session failed")
    }
    a2aCleanupMapDir(dir)
}

// 未知 id → None
@Test
func a2aSessionMap_lookupUnknownIsNone() {
    let dir = a2aMapTempDir()
    let mgr = A2aSessionManager(dir + "/a2a-sessions.json")
    @Expect(mgr.lookup("ctx_unknown").isNone(), true)
    @Expect(mgr.getActive("ctx_unknown").isNone(), true)
    @Expect(mgr.lookupTask("task_unknown").isNone(), true)
    a2aCleanupMapDir(dir)
}

// close（dropActive）后：active 清除，lookup 从持久化恢复同 atelierId；任务索引不受影响
@Test
func a2aSessionMap_dropActiveKeepsMappingAndTasks() {
    let dir = a2aMapTempDir()
    let mgr = A2aSessionManager(dir + "/a2a-sessions.json")
    let s = mgr.newSession("/p")
    mgr.bindTask("task_1", s.contextId, 2)
    mgr.dropActive(s.contextId)
    @Expect(mgr.getActive(s.contextId).isNone(), true)
    match (mgr.lookup(s.contextId)) {
        case Some(v) => @Expect(v.atelierId, s.atelierId)
        case None => @Fail("mapping lost after dropActive")
    }
    match (mgr.lookupTask("task_1")) {
        case Some(b) =>
            @Expect(b.contextId, s.contextId)
            @Expect(b.turn, 2)
        case None => @Fail("task binding lost after dropActive")
    }
    a2aCleanupMapDir(dir)
}

// delete（deleteMapping）后：映射与「该 context 下的任务索引」一并清除，别的 context 不受影响
@Test
func a2aSessionMap_deleteMappingRemovesAndCascadesTasks() {
    let dir = a2aMapTempDir()
    let mgr = A2aSessionManager(dir + "/a2a-sessions.json")
    let a = mgr.newSessionWithId("ctx_a", "/a")
    let b = mgr.newSessionWithId("ctx_b", "/b")
    mgr.bindTask("task_a1", "ctx_a", 1)
    mgr.bindTask("task_b1", "ctx_b", 1)
    @Expect(mgr.taskSize(), Int64(2))

    mgr.deleteMapping("ctx_a")
    @Expect(mgr.lookup("ctx_a").isNone(), true)
    @Expect(mgr.lookupTask("task_a1").isNone(), true)
    @Expect(mgr.size(), Int64(1))
    @Expect(mgr.taskSize(), Int64(1))
    match (mgr.lookupTask("task_b1")) {
        case Some(v) => @Expect(v.contextId, "ctx_b")
        case None => @Fail("other context's task binding removed")
    }
    match (mgr.lookup("ctx_b")) {
        case Some(v) => @Expect(v.atelierId, b.atelierId)
        case None => @Fail("other session removed")
    }
    @Expect(a.contextId, "ctx_a")
    a2aCleanupMapDir(dir)
}

// 跨实例恢复（进程重启场景）：会话映射与任务索引都从同一 JSON 文件恢复
@Test
func a2aSessionMap_persistsAcrossInstances() {
    let dir = a2aMapTempDir()
    let file = dir + "/a2a-sessions.json"
    let mgr1 = A2aSessionManager(file)
    let s = mgr1.newSessionWithId("ctx_proj", "/work")
    mgr1.bindTask("task_x", "ctx_proj", 7)
    mgr1.dropActive("ctx_proj")

    let mgr2 = A2aSessionManager(file)
    @Expect(mgr2.size(), Int64(1))
    @Expect(mgr2.taskSize(), Int64(1))
    match (mgr2.lookup("ctx_proj")) {
        case Some(v) =>
            @Expect(v.atelierId, s.atelierId)
            @Expect(v.cwd, "/work")
            @Expect(v.createdAt, s.createdAt)
        case None => @Fail("session mapping not persisted")
    }
    match (mgr2.lookupTask("task_x")) {
        case Some(b) =>
            @Expect(b.contextId, "ctx_proj")
            @Expect(b.turn, 7)
        case None => @Fail("task binding not persisted")
    }
    @Expect(mgr2.tasksOf("ctx_proj").size, 1)
    a2aCleanupMapDir(dir)
}

// 同一 contextId 重复登记幂等：返回既有映射，不会另发 atelier 会话把上一个变成孤儿
@Test
func a2aSessionMap_newSessionWithIdIsIdempotent() {
    let dir = a2aMapTempDir()
    let mgr = A2aSessionManager(dir + "/a2a-sessions.json")
    let first = mgr.newSessionWithId("ctx_same", "/p1")
    let again = mgr.newSessionWithId("ctx_same", "/p2")
    @Expect(again.atelierId, first.atelierId)
    @Expect(again.cwd, "/p1")
    @Expect(mgr.size(), Int64(1))
    a2aCleanupMapDir(dir)
}

// taskId 级寻址：一个 context 多个任务，tasksOf 只返回该 context 的，turn 覆盖推进
@Test
func a2aSessionMap_taskBindingAddressing() {
    let dir = a2aMapTempDir()
    let mgr = A2aSessionManager(dir + "/a2a-sessions.json")
    let a = mgr.newSessionWithId("ctx_a", "/a")
    let b = mgr.newSessionWithId("ctx_b", "/b")
    mgr.bindTask("task_a1", "ctx_a", 1)
    mgr.bindTask("task_a2", "ctx_a", 3)
    mgr.bindTask("task_b1", "ctx_b", 1)
    @Expect(mgr.taskSize(), Int64(3))
    @Expect(mgr.listTasks().size, 3)

    @Expect(mgr.tasksOf("ctx_a").size, 2)
    @Expect(mgr.tasksOf("ctx_b").size, 1)
    @Expect(mgr.tasksOf("ctx_none").size, 0)

    // 同一 taskId 再绑定视为推进（续聊推进回合）
    mgr.bindTask("task_a1", "ctx_a", 4)
    match (mgr.lookupTask("task_a1")) {
        case Some(v) =>
            @Expect(v.contextId, "ctx_a")
            @Expect(v.turn, 4)
            @Expect(v.createdAt != "", true)
        case None => @Fail("task binding missing")
    }
    @Expect(mgr.taskSize(), Int64(3))
    @Expect(a.contextId, "ctx_a")
    @Expect(b.contextId, "ctx_b")
    a2aCleanupMapDir(dir)
}

// 绑定未登记的 contextId → 直接拒绝（悬挂索引会让 tasks/get 指回不存在的上下文）
@Test
func a2aSessionMap_taskBindingRejectsUnknownContext() {
    let dir = a2aMapTempDir()
    let mgr = A2aSessionManager(dir + "/a2a-sessions.json")
    var threw = false
    try {
        mgr.bindTask("task_x", "ctx_missing", 1)
    } catch (e: Exception) {
        threw = true
    }
    @Expect(threw, true)
    @Expect(mgr.taskSize(), Int64(0))
    a2aCleanupMapDir(dir)
}

// 任务 id 由管理器统一生成：前缀一致且互不相同
@Test
func a2aSessionMap_newTaskIdUnique() {
    let dir = a2aMapTempDir()
    let mgr = A2aSessionManager(dir + "/a2a-sessions.json")
    let id1 = mgr.newTaskId()
    let id2 = mgr.newTaskId()
    @Expect(id1.startsWith("task_"), true)
    @Expect(id1 != id2, true)
    a2aCleanupMapDir(dir)
}

// list 反映全部已记录映射（close 不清除）
@Test
func a2aSessionMap_listReflectsAllMappings() {
    let dir = a2aMapTempDir()
    let mgr = A2aSessionManager(dir + "/a2a-sessions.json")
    let a = mgr.newSessionWithId("ctx_1", "/1")
    let b = mgr.newSessionWithId("ctx_2", "/2")
    @Expect(mgr.list().size, 2)
    mgr.dropActive("ctx_1")
    @Expect(mgr.size(), Int64(2))
    @Expect(mgr.list().size, 2)
    @Expect(a.atelierId != b.atelierId, true)
    a2aCleanupMapDir(dir)
}

// 映射文件损坏时不崩溃：视为空库（跨进程恢复失效，但进程可用）
@Test
func a2aSessionMap_corruptFileFallsBackToEmpty() {
    let dir = a2aMapTempDir()
    let file = dir + "/a2a-sessions.json"
    File.writeTo(Path(file), "not json at all".toArray())
    let mgr = A2aSessionManager(file)
    @Expect(mgr.size(), Int64(0))
    @Expect(mgr.lookup("ctx_x").isNone(), true)
    let s = mgr.newSessionWithId("ctx_x", "/p")
    @Expect(s.atelierId != "", true)
    a2aCleanupMapDir(dir)
}

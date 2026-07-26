# 会话管理

## 树形数据模型

Atelier 采用 Entry + ParentID 树模型，支持分叉与历史回溯。

```
Entry A (parentId: None)
  └── Entry B (parentId: A)
       ├── Entry C (parentId: B)   ← 主线
       └── Entry D (parentId: B)   ← 分叉
```

线性会话就是每个 entry 的 parentId 都指向前一条的特例。

### SessionHeader

```cangjie
struct SessionHeader {
    version: Int32
    id: String
    createdAt: Int64
    updatedAt: Int64
    model: String
    provider: String
    systemPrompt: String
    parentSession: Option<String>
}
```

### Entry

```cangjie
struct Entry {
    id: String         // 唯一标识（内存实现为递增序列号，持久化为 "sessionId_index"）
    parentId: Option<String>  // 上一条 entry ID
    timestamp: Int64
    message: Message
}
```

### 路径重建

```cangjie
let entries: ArrayList<Entry> = session.entries
let leafId = "entry_C"
let path = pathToLeaf(entries, leafId)
// 返回 [Entry A, Entry B, Entry C]
```

## SessionStore 接口

```cangjie
interface SessionStore {
    func save(id: String, header: SessionHeader, messages: ArrayList<Message>): Unit
    func appendBranch(id: String, parentLeafId: String, messages: ArrayList<Message>): String
    func load(id: String): ArrayList<Message>
    func loadEntries(id: String): SessionData
    func list(): ArrayList<SessionHeader>
    func delete(id: String): Unit
    func fork(sourceId: String, leafId: String): SessionData
    func close(): Unit
}
```

### 实现

| 实现 | 说明 | 默认 |
|------|------|------|
| `MemorySessionStore` | 内存存储，进程重启丢失 | — |
| `StormSessionStore` | bstorm 持久化到 `~/.atelier/sessions/` | ✅ |

## 导出

支持导出为 JSONL 和 HTML 回放：

```bash
# REPL 导出
/session export <id> jsonl
/session export <id> html

# HTTP API
curl -X POST http://localhost:8080/session/export \
  -H "Content-Type: application/json" \
  -d '{"sessionId":"sess_xxx","format":"html"}'
```

HTML 导出为自足页面，包含完整对话记录和样式。

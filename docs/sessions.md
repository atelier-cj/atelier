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

## 自定义 SessionStore

实现 `SessionStore` 接口可使用自己的存储后端：

```cangjie
import atelier.session.*
import std.collection.ArrayList

class MySessionStore <: SessionStore {
    public func save(id: String, header: SessionHeader, messages: ArrayList<Message>): Unit {
        // 写入数据库 / Redis / 文件
    }
    public func appendBranch(id: String, parentLeafId: String, messages: ArrayList<Message>): String {
        // 增量追加消息，返回新叶子 ID
        ""
    }
    public func load(id: String): ArrayList<Message> {
        // 加载线性消息列表
        ArrayList()
    }
    public func loadEntries(id: String): SessionData {
        // 加载完整 Entry 树
        SessionData(SessionHeader(0, "", 0, 0, "", "", "", None), ArrayList())
    }
    public func list(): ArrayList<SessionHeader> {
        // 列出所有会话元数据
        ArrayList()
    }
    public func delete(id: String): Unit {
        // 删除会话
    }
    public func fork(sourceId: String, leafId: String): SessionData {
        // 从源会话的 leafId 处克隆为新会话
        SessionData(SessionHeader(0, "", 0, 0, "", "", "", None), ArrayList())
    }
}

let store = MySessionStore()
```

## 会话环境

每个会话可关联一个环境，包含工作目录和自定义上下文：

```cangjie
struct SessionEnvironment {
    directory: String                // 工作目录
    context: HashMap<String, String> // 扩展上下文
}
```

### 工作目录

会话的 `directory` 决定工具执行的工作目录：

```bash
# REPL 指定工作目录
atelier repl --workdir /home/user/project

# HTTP API
POST /session/new
{
  "directory": "/home/user/project"
}
```

自动加载 `directory/AGENTS.md` 中的项目规则，拼入 system prompt。

### 上下文信息

`context` 携带会话级扩展信息，自动注入 system prompt，工具通过 `ctx.env` 读取：

```http
POST /agent/run
{
  "agent": "assistant",
  "messages": [...],
  "context": {
    "current_page": "/orders/123",
    "user_role": "admin"
  }
}
```

System prompt 中自动注入：

```
[Session Context]
current_page = /orders/123
user_role = admin
```

### 继承规则

- Session fork 时继承父 session 的 environment
- 子 session 可覆盖 `directory` 和 `context`
- 未指定时使用当前目录 + 空上下文

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

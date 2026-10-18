# A2A 接入（Agent 侧 + Client 侧）

Atelier 实现 [A2A (Agent2Agent) v1.0](https://a2a-protocol.org/) 的 **Agent 侧（服务端）** 与
**Client 侧（远端子代理）**：协议层复用 `a2a` 包（[a2a-cj](../a2a-cj)），Atelier 侧负责把
AgentRuntime / 会话持久化 / 信任闸门 / 提问通道接入其执行器与流式事件。

- 服务端：`atelier a2a [agent] [port]` 起一个 A2A Agent（Agent Card 发现 + **JSON-RPC 与 HTTP+JSON 双绑定** + SSE 流式 + 推通知），
  实现 `a2a.A2aExecutor`（`src/a2a/bridge.cj`）；
- 客户端：把远端 A2A agent 当作可持续子代理驱动（`src/agent/remote_a2a_subagent.cj`），
  父侧既有 `subagent_*` 工具零改动可用。

## 快速开始

```bash
# 1. 构建
eval "$(cjvs env zsh)" && eval "$(cjvs stdx-env zsh)"
cjpm build -j 16

# 2. 起服务（默认端口 8931；工作目录 = 当前目录）
cli.app a2a [agent] [port]

# 3. 发现 + 调用（JSON-RPC 绑定；HTTP+JSON 亦支持，见「能力矩阵」的传输绑定行）
curl -s http://127.0.0.1:8931/.well-known/agent-card.json
curl -sN -H 'Content-Type: application/json' -H 'A2A-Version: 1.0' \
  -d '{"jsonrpc":"2.0","id":1,"method":"SendStreamingMessage","params":{"message":{"messageId":"m1","role":"ROLE_USER","parts":[{"text":"你好"}]}}}' \
  http://127.0.0.1:8931/
```

离线冒烟（不连真实 LLM）：`ATELIER_PROVIDER=echo` 用 `EchoProvider`，`ATELIER_ECHO_DELAY_MS` 可加延时。
`A2A-Version` 头是必须的：缺失按 0.3 处理并回 `VERSION_NOT_SUPPORTED`（a2a-cj 的版本协商）。

## 能力矩阵（A2A 操作）

| A2A 操作 | 支持 | 说明 |
|---|---|---|
| `/.well-known/agent-card.json` | ✅ | 由 agent 配置 + 技能注册表生成；`supportedInterfaces` 声明 JSONRPC，`capabilities.streaming=true` |
| `SendMessage` | ✅ | 一条消息 = atelier 一次 `SessionLoop` 回合 |
| `SendStreamingMessage` | ✅ | SSE；任务快照 → `statusUpdate` / `artifactUpdate` → 终态关流 |
| `GetTask` | ✅ | 任务与产物落在 a2a-cj 的 TaskStore（进程内） |
| `ListTasks` | ✅ | 支持 `contextId` / `state` 过滤与分页（a2a-cj 实现） |
| `CancelTask` | ✅ | 协作式：置取消标志，运行中回合收敛为 `TASK_STATE_CANCELED` |
| `SubscribeToTask` | ✅ | 任务级订阅：中断态后继续挂流，终态关流 |
| `PushNotificationConfig` 系列 | ❌ | 未声明（`pushNotifications=false`），a2a-cj 已有 HTTP 投递器可后续开启 |
| `GetExtendedAgentCard` / 认证 | ❌ | 未声明（无鉴权场景） |
| **传输绑定** | JSON-RPC ✅ + HTTP+JSON ✅ | CLI 同时声明两种（`cli/src/a2a_cmd.cj` 的 `bindings`），客户端按 `supportedInterfaces` 偏好自选（JSON-RPC 在前）；库层（`a2a-cj`）两者都实现，语义收敛到同一处 |
| gRPC 绑定 | ❌ | 规范 §1.3 把传输绑定列为并列的可选项（JSON-RPC / gRPC / HTTP+JSON / 自定义），**不要求全实现**；未实现不影响合规 |

## 概念映射（A2A ↔ Atelier）

| A2A | Atelier |
|---|---|
| `contextId` | 会话映射 key（持久化于 `<sessionDir>/a2a-sessions.json`）→ atelier 会话 id |
| `taskId` | 任务级寻址：索引到 `(contextId, turn)`（`tasks/get`、`resubscribe` 用） |
| `message/send` 文本 | `UserMessage` → `SessionLoop.run`（唯一回合执行器） |
| `statusUpdate` | `TurnStart` → WORKING；挂起 → INPUT_REQUIRED；回合终态 → COMPLETED / FAILED / CANCELED |
| `artifactUpdate` | assistant 文本分片、工具调用的声明 / 进度 / 结果 |
| `Task.history` | 交互消息序列（用户消息 + 状态更新携带的 agent 消息）；产物在 `Task.artifacts` |
| 多轮（同 `taskId` 续发消息） | 中断态任务继续推进；终态任务拒绝新消息（协议要求） |

## 流式与产物语义（`src/a2a/translator.cj`）

规范 §3.1.2 规定 Task 生命周期流只能以 Task 起始、随后只允许 `statusUpdate` / `artifactUpdate`，
因此 **assistant 文本以 artifact 分片下发**（不走 `Message` 载荷 —— 那是 message-only 流的形态）：

- 首片 `append=false` 建立产物，后续片 `append=true`，最后一片 `lastChunk=true`。
  `append=true` 而产物不存在时参考实现会**丢弃该片**，故首片必须是 `append=false`；
- 每个文本增量先缓冲一片、下一个增量到达时才发出上一片：这样 `lastChunk=true` 落在**有内容**的
  分片上（代价是流式展示滞后一个增量）；非流式 provider（只有 `MessageEnd`/`TurnEnd` 带文本）
  在收尾时补发整片；
- 工具调用 = 独立产物（`tool_t<turn>_<toolCallId>`，入参 data part + `metadata{toolCallId,status}`），
  `ToolExecutionStart/Update/End` 往同一 artifactId 追加；声明了却没跑到的（被跳过 / 等待外部执行）
  在回合收尾时补 `lastChunk=true`（`status=skipped`），不留半开产物；
- **终态判定**：`TurnEnd` 是「每回合」事件（工具回合会多次出现），只有
  `EndTurn` 且无待执行工具才算 COMPLETED；`Error → FAILED`、`Aborted → CANCELED`，
  截断续跑 / 工具批次保持 WORKING，运行收尾（`AgentEndEvent`）兜底收口。

## 反向提问（input-required）

A2A 没有 ACP elicitation 那样的同步反向调用，因此走**任务级续聊**：

1. 运行的某个检查点（信任闸门审批 / `ask_user` / 外部执行工具）请求输入时，桥的 `askFn`
   返回 `UserAnswer(Pending)` → runtime 发 `SuspendEvent` → 翻译器下发 `INPUT_REQUIRED` +
   状态消息（问题正文）；
2. 客户端用**同一 `taskId`** 续发一条消息，桥把文本折算成结构化答复
   （候选选项 id/label 精确匹配优先，审批再认常见肯定/否定说法），随后 `askFn` 命中答复、
   回合继续推进 —— 任务始终没有被终态关闭，订阅流一直挂着。

## 远端 A2A 子代理（Client 侧）

`RemoteA2aSubAgentHandle <: SubAgentHandle`：`SubAgentManager.startRemoteA2a(baseUrl, parent, prompt)`
按 Agent Card 发现远端、用 `sendStreamingMessage` 跑一轮，把 artifact / 状态消息累积成回信
（首回合 `done`、其后 `reply`）。与 ACP 版（子进程 + stdio）相比：走 HTTP 不拉子进程；
支持 input-required 续聊（远端挂起时问题作为来信投回父，父的下一条消息即答复）。
终态后清 `taskId`、保留 `contextId`，下一条消息在同一段远端对话里开新任务。

## 限制

- 只支持文本消息（未声明图片/文件等多模态能力）；
- 任务状态在进程内（a2a-cj 的 `InMemoryTaskStore`），进程重启后 `tasks/get` 不再可见；
  会话映射与任务索引是持久化的，重启后同 `contextId` 的续聊仍可继续；
- 同一 `contextId` 的任务串行执行：会话历史是单一序列，并发 run 会交错写入；
- 服务端鉴权见「入站认证」：默认匿名，可开启 Bearer / API Key 静态 token；静态 token
  无 scope 与过期语义，任务级鉴权（按调用方过滤 `ListTasks`、`AUTH_REQUIRED`）未做。


## 入站认证

默认是**匿名**形态（`[a2a].auth` 缺省 `false`），仅限本机/内网使用。开启后除公共
Agent Card 外，所有请求都要带凭据。

```toml
# ~/.atelier.toml
[a2a]
auth = true
token = "…"            # 留空则回退环境变量 ATELIER_A2A_TOKEN
apiKeyHeader = ""      # 留空用默认 X-API-Key
```

```bash
# 环境变量兜底（与模型名读 OPENAI_MODEL 同一惯例）
export ATELIER_A2A_TOKEN=…
cli.app a2a default 8931
```

两种凭据**任选其一**（对应卡片里两条 OR 安全要求）：

```bash
curl -H 'Authorization: Bearer <token>' …
curl -H 'X-API-Key: <token>' …
```

行为约定：

| 情形 | 结果 |
|---|---|
| `/.well-known/agent-card.json` | 匿名可读 —— 客户端必须先拿到卡片才知道该带哪种凭据 |
| 其它端点缺凭据 / 凭据错误 | `401` + `WWW-Authenticate: Bearer realm="a2a", ApiKey header="X-API-Key"` |
| `auth = true` 但 TOML 与 env 都没有 token | **拒绝启动并以退出码 1 结束**（否则会起一个 401 掉所有请求的服务，日志上极难定位） |

token 是**不透明串，不要求 JWT**：A2A 不签发凭据，认证始终是带外的，协议只声明用哪种
scheme。token 校验走恒定时间比较，避免时序侧信道。

> ⚠️ 两个边界：① 当前监听是**明文 HTTP**，凭据会在信道上裸奔，生产必须前置 TLS 反代或
> 限制在回环/内网；② 静态 token 无法表达 scope 与过期，且「任务级鉴权」（`AUTH_REQUIRED`
> 状态、按调用方过滤 `ListTasks`）尚未实现 —— 认证只解决「能不能进」，还没解决「能看什么」。

<!-- 协议一致性验证 -->
## 部署在 LB / 反向代理后面

TLS 交给 LB 或反向代理终止、后端只监听内网，这是推荐形态（证书轮换、密码套件、
可观测性都收敛在一层，应用不必自己管 TLS）。

```toml
[a2a]
listen = "127.0.0.1"                      # 后端只监听回环；LB 在别的容器/主机时用 0.0.0.0
publicUrl = "https://agent.example.com"   # 卡片发布给客户端的地址
```

环境变量可覆盖：`ATELIER_A2A_LISTEN`、`ATELIER_A2A_PUBLIC_URL`。

**`publicUrl` 不是可选项。** Agent Card 的 `supportedInterfaces[].url` 是客户端**真正去连**的
地址（规范要求生产环境为 absolute HTTPS）。留空时它按监听地址拼成 `http://127.0.0.1:8931`，
客户端拿到后连的是它自己的回环 —— 必然失败。

nginx 示例：

```nginx
location / {
    proxy_pass http://127.0.0.1:8931;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_read_timeout 3600s;   # SSE 是长连接，别被默认 60s 掐断
}
```

**SSE 别被缓冲**：nginx 默认缓冲响应，流式事件会被攒着不发（表现为客户端长时间收不到
事件）。服务端已为每个 SSE 响应带上 `X-Accel-Buffering: no`，nginx 会据此对该响应关闭
缓冲；若你的代理不认这个头，再显式加 `proxy_buffering off;`。

其它要点：

- 健康检查可直接探 `/.well-known/agent-card.json`（开启认证后它仍匿名可读）；
- LB → 后端这一段是明文（回环/内网）；跨不可信网络时用 mTLS 或网络隔离；
- 将来做按调用方限流/鉴权时，`X-Forwarded-For` 的信任边界要明确（只允许 LB 设置它）。

## 与 server 成员共用端口

默认 `atelier a2a` 独立起一个端口。若要让 A2A 与 agent API / AG-UI 共用一个端口：

```toml
[a2a]
mountToServer = true
```

```bash
cli.app serve 8931     # 一个端口同时提供既有服务与 A2A
```

**不需要路径前缀**：A2A 的路径族（`/`、`/tasks*`、`/message:*`、`/.well-known/agent-card.json`、
`/extendedAgentCard`）与既有服务（`/agent`、`/session`、`/ag-ui`、`/health`）没有交集。

路由规则（`server.MountedDistributor`）：

1. **精确注册的既有路由优先** —— 挂载服务不会抢走既有路径；
2. 未命中精确表时，按路径族转交 A2A；
3. 都未命中 → 404。

两个容易踩的点：

- **根路径 `/` 按精确处理，不做前缀匹配。** `/` 是所有路径的前缀，若按前缀用，挂载服务会吃掉
  每一个未注册路径 —— 包括将来新加的路由，而且症状是「新路由静默落到 A2A 的 404」。
- **带参路径靠 `/tasks/` 前缀命中**（`/tasks/{id}`、`/tasks/{id}:cancel`）。stdx 的
  `register` 是精确匹配，表达不了这类路径，这正是需要组合分发器的原因。

装配失败（例如声明了认证却没配 token）时，`serve` **退回纯 HTTP 服务**并留日志，
不因为可选能力而阻断既有服务。

## 协议一致性验证

本实现的服务端方向用官方一致性套件
[a2a-tck](https://github.com/a2aproject/a2a-tck) 做过互操作验证（`--transport jsonrpc --level must`）：

```
67 passed / 5 failed / 163 skipped
```

通过的 67 条覆盖 Agent Card 发现、任务生命周期、多轮与上下文归属、流式（SSE）、
取消、GetTask / ListTasks、错误映射与版本协商 —— 即**协议行为层面的 MUST 全部通过**。

5 条失败集中在 `DM-ART-001` / `DM-MSG-001`：TCK 通过 `messageId` 魔法前缀
（`tck-artifact-text` / `tck-artifact-file` / `tck-artifact-data` / `tck-message-response` …）
要求 SUT 产出**特定内容的** Part，这属于 TCK 对被测对象的场景约定，不是协议要求。
atelier 是真实 agent（回复由 provider 决定），不响应该约定；
协议一致性用例请以 `a2a-cj` 的示例 SUT（`a2a.examples.tck_sut`，同一套用例 175 passed / 0 failed）为准。

另外，客户端 ↔ 服务端的完整链路（discover → sendStreamingMessage → 子代理回信）在
`atelier/src/a2a/a2a_e2e_test.cj` 中有进程内端到端用例覆盖。

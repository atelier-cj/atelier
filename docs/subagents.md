# 可持续子 Agent（双向 send_message）

Atelier 的 **Agent-as-Tool** 升级形态：子 Agent 不再是「一次性委派后即弃」，而是**常驻 worker**——
父、子各自持有邮箱，消息双向传递；子的中间汇报（progress）、提问与最终报告（done）都会送达父，
父可随时唤醒空闲子开新回合。单向 report 工具被对称的 `send_message` 取代（对齐 dsh 0.1.2-alpha.4
语义：**父 Agent 与可继续子 Agent 通过 send_message 交换 follow-up 消息**）。

> `send_message` 在父、子两个工具上下文各有一个同名工具（注册表隔离，schema 不同）：
> **父上下文** `send_message {id, text}` 发往子（追问/续聊，原 `subagent_send` 更名）；
> **子上下文** `send_message {text, kind, waitReply}` 发往父（汇报/提问）。父端另有
> `subagent_reply {id, text}` 即时应答子的 waitReply 提问。

```
父 Agent（会话回合驱动）                        子 Agent（SubAgentWorker 常驻线程）
┌─────────────────────────────┐   ┌─────────┐  ┌────────────────────────────────┐
│ send_message / start /      │ ⇄ │ 队列/状态 │⇄ │ 首回合(start 消息)             │
│ reply / await / watch /     │   │ inbox/   │  │ 来信 → 子会话历史+UserMessage   │
│ close（父端工具）            │ ⇄ │ outbox/  │  │  → chatWithSessionId → 落库    │
│ 收到子消息 → 回合继续/收尾    │   │ reply   │  │  → 回信(done/reply) → 挂起等信  │
└─────────────────────────────┘   └─────────┘  │ send_message（子端工具）         │
                                               └────────────────────────────────┘
```

## 生命周期

- **启动**：`start`（库 API）或 `subagent_start`（父回合内工具）立即返回句柄（`sub_*`），
  首回合异步执行，完成后向父投递 `done`（最终报告）。
- **唤醒**：父 `send` 消息 / 父端 `send_message {id, text}` → 子空闲时开新回合处理并回 `reply`；
  子 `send_message(waitReply=true)` 提问 → 父 `respond`（库 API）或 `subagent_reply`（父端工具）
  → 子当前回合继续（无需新回合）。
- **respond 状态感知**：回复按子状态分派——子正阻塞在 waitReply 提问 → 专用通道即时解锁当前回合；
  子空闲 / 回合中未等待（含跨进程子）→ 转投 follow-up 消息，子在回合边界开新回合消化
  （不滞留、不错配、不打断当前回合；「子跑完 → 父追问」走 respond 或 send_message 均成立）。
  分派判据是句柄上的「正在等待回复」登记，**它在提问投递之前就已置位**（`isWaitingForReply()`
  可查）：否则父在「提问已投递、登记未置位」那道窗口里的回复会被当成回合中消息排到下一回合，
  子的 waitReply 只能干等到超时——表现为「父明明回了，子却报超时」，且随负载时快时慢。
- **等待（父自决）**：父回合内 `subagent_await(id)` 阻塞收指定子的信；`subagent_watch` 收任一子的信
  （聚合收件箱）——**收到即当前回合继续**，不等待 = 回合结束由宿主决定，子消息保留在收件箱。
- **终止**：`close`（库 API）/ `subagent_close`（工具）请求停止 worker（幂等）；
  父会话级联 `closeForParent` 关闭全部子；会话历史保留。
- **空闲自动回收（可配，默认关）**：`SubAgentManager(..., idleTimeoutSec: N)`（N>0 时）本地子
  worker 连续空闲 N 秒自动回收（等效 close + 从注册表摘除；会话历史保留，`resumeSession` 可重建；
  句柄 send 此后 no-op）。来信/回合重置计时。适合「一次性委派不复用」场景控制长驻线程；
  默认 0 = 永不自动回收（可持续子语义）。远程子无 idle 探测通道，仅显式 close。

## 消息信封

`AgentMail { from, to, kind, text }`，kind：`user_text`（委派/续聊，父→子）、`progress`（进度汇报）、
`reply`（回合回复/提问）、`done`（最终报告，start 的首回合结果）、`cancel/close`（控制语义由句柄方法表达）。

> 最终报告没有特殊通道：`done` 只是一封带标记的普通消息，与 `progress`/`reply` 一样投递并唤醒父。

## 库 API（`atelier.agent`）

| 类型 | 说明 |
|---|---|
| `SubAgentManager(toolReg, trustMgr, skillReg, agentReg, providerReg, sessionStore, mcpMgr, idleTimeoutSec!: Int64 = 0)` | 注册表 + worker 启动器；`idleTimeoutSec` 开启本地子空闲自动回收（0=不回收） |
| `manager.start(config, provider, parentSessionId, initialPrompt)` | 启动子（立即返回句柄） |
| `manager.startByName(agentName, parentSessionId, prompt)` | 按注册名启动（config/provider 自动解析） |
| `manager.get / has / closeForParent / awaitChildren(parentId, timeout)` | 查询/级联关闭/聚合收信 |
| `SubAgentHandle.send(mail)` | 投递（异步，唤醒空闲子） |
| `SubAgentHandle.recv(timeout)` | 收该子来信（阻塞可超时） |
| `SubAgentHandle.respond(text)` | 回复子（状态感知：waitReply 阻塞中=解锁当前回合；空闲/未等待=follow-up 唤醒新回合） |
| `SubAgentHandle.pollOnce()` | 非阻塞尝试取一封（宿主输入循环轮询用） |
| `manager.pollChildren(parentId)` | 该父全部子的未读来信（非阻塞聚合） |
| `SubAgentHandle.cancel() / close()` | 中断当前回合 / 请求终止 |

```cangjie
import atelier.agent.*
// 宿主（父会话）组装一次 manager 并注册父工具
let mgr = SubAgentManager(toolReg, trustMgr, skillReg, agentReg, providerReg, store, mcpMgr)
registerParentSubagentTools(toolReg, mgr)   // send_message/start/reply/await/watch/close
// 库方式启动
let h = mgr.startByName("code_assistant", parentSessionId, "审计 src/ 目录")
// … 父回合内（或宿主逻辑）收结果：
match (h.recv(timeout: 5 * Duration.minute)) {
    case Some(m) if m.kind == AgentMailKindDone => // 最终报告 m.text
    case _ => ()
}
```

## 子 Agent 端工具（`send_message`，取代 report）

子回合中调用（工具自动装配进子工具列表；父端同名工具方向相反，见「父 Agent 端工具」）：
`SendMessageTool` 在子回合工具表构造时覆盖父表复制进来的同名父版（ToolRegistry 同名覆盖）。

| 参数 | 说明 |
|---|---|
| `text`（必填） | 消息内容 |
| `kind` | `progress`（默认，父可见不等待）/ `reply`（提问/回复） |
| `waitReply` | 是否阻塞等待父回复（`false` 默认）；父 `respond` 后本回合继续 |
| `timeoutMs` | waitReply 超时（默认 300000），超时提示由子自决继续 |

```json
{"text": "进度 50%，遇到一个 API 疑问", "kind": "progress"}
{"text": "是否允许改用方案 B？", "kind": "reply", "waitReply": true}
```

## 宿主集成与回合外消息可见

- **回合执行统一**：本地子 worker 与 ACP 会话桥均基于 `SessionLoop`（同一回合语义：历史装载/事件消费/取消/落库）。
- **回合外消息可见**：宿主输入循环可用 `manager.pollChildren(parentSessionId)` / `handle.pollOnce()`
  非阻塞查看子来信（真正「父被唤醒开新回合」由宿主按自身输入模型决定；`awaitChildren` 提供阻塞原语）。
- **TUI**（进程内父宿主）：
  - 回合内工具：`send_message / subagent_start / subagent_reply / subagent_await / subagent_watch / subagent_close`（自动注册）
  - `/subagent list | poll | start [--remote] <agent> <prompt> | send <id> <text> | respond <id> <text> | close <id>`
  - `start` 默认本地子；`start --remote` 以当前进程（`/proc/self/exe`）启动独立 `cli.app acp`
    子进程，数据隔离于 `<sessionDir>/remote-sub/<childId>`（不与父会话共享 bstorm/映射）
  - 每回合收尾自动展示该父子的未读消息（poll 结果）
- **跨进程子（ACP 桥）在 TUI 的兼容**：`/subagent list/send/close` 对远程句柄同样有效
  （send=一次远程自主回合）；`respond` 对远程子 = follow-up 追问（新回合）——
  回合内插话（waitReply 即时解锁）受 ACP v1 限制，跨进程退化为分回合问答。

## 父 Agent 端工具

| 工具 | 说明 |
|---|---|
| `subagent_start {agent, prompt}` | 启动注册的子 agent（异步返回 id） |
| `send_message {id, text}` | （父上下文）向子发 follow-up，唤醒空闲子开新回合——追问已汇报完成的子（dsh 对齐；子端同名工具方向相反） |
| `subagent_reply {id, text}` | 即时应答子回合内 waitReply 提问；子空闲/未等待时等效 follow-up 唤醒（respond 状态分派） |
| `subagent_await {id, timeoutMs}` | 阻塞收指定子消息 → 回合继续 |
| `subagent_watch {timeoutMs}` | 阻塞收任一子消息（done/reply/progress）→ 回合继续 |
| `subagent_close {id}` | 请求终止子 |

这些工具为 Parallel 执行模式（免信任闸门审批——调度类工具由父自主决定）。
> 历史名 `subagent_send` 于 2026-09 更名 `send_message`（对齐 dsh 措辞），代码类名 `SubagentSendTool` 未变。

## 会话与持久化

- 子会话历史独立存于 SessionStore（每回合自动落库，树形可续接）；父回信/进度在子上下文中体现为工具结果消息。
- **重启边界**：进程重启后子句柄不存活（worker 随进程消亡）；子会话数据保留在 store。
  恢复方式：`manager.resumeSession(config, provider, parentSessionId, childStoreId, env)` 复用既有
  子会话历史重建可持续句柄（worker 不再投 initial，首封信即续聊输入）；会话不存在/已活跃 → None。
- 父子共享同进程组件（toolReg/trustMgr/mcpMgr）；信任判定已 per-session 化（父子并发授权互不干扰）。

## 与其它形态的关系

- TUI/HTTP/ACP 会话循环当前仍由各自宿主驱动；`awaitChildren` 与父工具为宿主集成提供
  「子消息唤醒父」的阻塞原语（宿主输入循环可轮询），统一 SessionRunner（输入源可插拔）属后续演进。
## 跨进程子 Agent（ACP 桥）

`manager.startRemote(executable, agentName, parentSessionId, prompt, cwd, sessionDir)`：
子 Agent 运行在独立 `cli.app acp <agent> <sessionDir>` 进程（同一可执行文件），协议经 acp-cj
`AcpClient` 桥接——句柄语义与本地子一致（done/reply/recv/close），**send = 一次子自主回合**。

- sessionDir：子进程独立会话/映射目录（勿与父共享，父若为 TUI/HTTP/ACP 会同目录争用 bstorm）
- 验证：`scripts/remote_subagent_e2e.sh`（隔离 HOME + echo 模式跑条件 e2e：握手→首回合 done→续聊 reply→close）
- **限制（ACP v1）**：回合内 waitReply 不可跨进程（子以分回合提问表达）；子无法主动唤醒空闲父
  （父在自身回合内 await/watch 不受影响——本地子全能力保留）

## 测试

```bash
cjpm test -j 16 --no-progress   # 全量（含 subagent P0-P2 用例）
```

覆盖：消息唤醒/多轮、recv 超时、close 幂等与级联、cancel 快速收敛、progress 先于 done 可见、
waitReply 父回复回流子上下文、超时路径、respond 状态分派（空闲/回合中 follow-up 不滞留不串线）、
父端 send_message 更名与两上下文同名覆盖、subagent_reply 即时应答、父回合完整编排
（start→watch 收 done）、跨进程 respond=follow-up 追问、空闲回收（超时回收/来信重置/默认关）、
`/subagent start --remote` 参数解析（本地/远程/缺参/多词 prompt）、信任隔离。

## 远端子 Agent（A2A）

`RemoteSubAgentHandle` 让子 Agent 跑在**另一个进程或另一台机器**上：本地句柄通过 A2A
协议驱动远端 Agent，父侧仍用同一套 `subagent_*` 工具（`send_message` 的双向语义、提问与
汇报都保留）。

```cangjie
// 远端 Agent 以 A2A 服务暴露（对端可以是任何 A2A 实现，不限于 atelier）
let remote = RemoteSubAgentHandle("http://127.0.0.1:8931", agentName: "default")
```

对端需要提供 Agent Card（`/.well-known/agent-card.json`）；本端按卡片声明的绑定与能力
选择通路（JSON-RPC 优先，其次 HTTP+JSON），流式事件翻译回本地事件流。

细节与部署注意事项见《[A2A 接入](a2a.md)》。

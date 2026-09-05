# 可持续子 Agent（双向 send_message）

Atelier 的 **Agent-as-Tool** 升级形态：子 Agent 不再是「一次性委派后即弃」，而是**常驻 worker**——
父、子各自持有邮箱，消息双向传递；子的中间汇报（progress）、提问与最终报告（done）都会送达父，
父可随时唤醒空闲子开新回合。单向 report 工具被对称的 `send_message` 取代。

```
父 Agent（会话回合驱动）                        子 Agent（SubAgentWorker 常驻线程）
┌─────────────────────────────┐   ┌─────────┐  ┌────────────────────────────────┐
│ subagent_start / send /     │ ⇄ │ 队列/状态 │⇄ │ 首回合(start 消息)             │
│ await / watch / close（工具）│   │ inbox/   │  │ 来信 → 子会话历史+UserMessage   │
│ 收到子消息 → 回合继续/收尾    │ ⇄ │ outbox/  │  │  → chatWithSessionId → 落库    │
└─────────────────────────────┘   │ reply   │  │  → 回信(done/reply) → 挂起等信  │
                                  └─────────┘  │ send_message（子端工具）         │
                                               └────────────────────────────────┘
```

## 生命周期

- **启动**：`start`（库 API）或 `subagent_start`（父回合内工具）立即返回句柄（`sub_*`），
  首回合异步执行，完成后向父投递 `done`（最终报告）。
- **唤醒**：父 `send` 消息 → 子空闲时开新回合处理并回 `reply`；子 `send_message(waitReply=true)`
  提问 → 父 `respond` → 子当前回合继续（无需新回合）。
- **等待（父自决）**：父回合内 `subagent_await(id)` 阻塞收指定子的信；`subagent_watch` 收任一子的信
  （聚合收件箱）——**收到即当前回合继续**，不等待 = 回合结束由宿主决定，子消息保留在收件箱。
- **终止**：`close`（库 API）/ `subagent_close`（工具）请求停止 worker（幂等）；
  父会话级联 `closeForParent` 关闭全部子；会话历史保留。

## 消息信封

`AgentMail { from, to, kind, text }`，kind：`user_text`（委派/续聊，父→子）、`progress`（进度汇报）、
`reply`（回合回复/提问）、`done`（最终报告，start 的首回合结果）、`cancel/close`（控制语义由句柄方法表达）。

> 最终报告没有特殊通道：`done` 只是一封带标记的普通消息，与 `progress`/`reply` 一样投递并唤醒父。

## 库 API（`atelier.agent`）

| 类型 | 说明 |
|---|---|
| `SubAgentManager(toolReg, trustMgr, skillReg, agentReg, providerReg, sessionStore, mcpMgr)` | 注册表 + worker 启动器 |
| `manager.start(config, provider, parentSessionId, initialPrompt)` | 启动子（立即返回句柄） |
| `manager.startByName(agentName, parentSessionId, prompt)` | 按注册名启动（config/provider 自动解析） |
| `manager.get / has / closeForParent / awaitChildren(parentId, timeout)` | 查询/级联关闭/聚合收信 |
| `SubAgentHandle.send(mail)` | 投递（异步，唤醒空闲子） |
| `SubAgentHandle.recv(timeout)` | 收该子来信（阻塞可超时） |
| `SubAgentHandle.respond(text)` | 回复子回合内提问（replyQueue） |
| `SubAgentHandle.cancel() / close()` | 中断当前回合 / 请求终止 |

```cangjie
import atelier.agent.*
// 宿主（父会话）组装一次 manager 并注册父工具
let mgr = SubAgentManager(toolReg, trustMgr, skillReg, agentReg, providerReg, store, mcpMgr)
registerParentSubagentTools(toolReg, mgr)   // subagent_start/send/await/watch/close
// 库方式启动
let h = mgr.startByName("code_assistant", parentSessionId, "审计 src/ 目录")
// … 父回合内（或宿主逻辑）收结果：
match (h.recv(timeout: 5 * Duration.minute)) {
    case Some(m) if m.kind == AgentMailKindDone => // 最终报告 m.text
    case _ => ()
}
```

## 子 Agent 端工具（`send_message`，取代 report）

子回合中调用（工具自动装配进子工具列表，父侧不可见）：

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

## 父 Agent 端工具

| 工具 | 说明 |
|---|---|
| `subagent_start {agent, prompt}` | 启动注册的子 agent（异步返回 id） |
| `subagent_send {id, text}` | 投递消息（唤醒空闲子） |
| `subagent_await {id, timeoutMs}` | 阻塞收指定子消息 → 回合继续 |
| `subagent_watch {timeoutMs}` | 阻塞收任一子消息（done/reply/progress）→ 回合继续 |
| `subagent_close {id}` | 请求终止子 |

这些工具为 Parallel 执行模式（免信任闸门审批——调度类工具由父自主决定）。

## 会话与持久化

- 子会话历史独立存于 SessionStore（每回合自动落库，树形可续接）；父回信/进度在子上下文中体现为工具结果消息。
- **重启边界**：进程重启后子句柄不存活（worker 随进程消亡）；子会话数据保留在 store。
  恢复方式（当前版本）：应用层在父会话续期时按需重建子（历史可加载续聊的 Runner 恢复属后续增强）。
- 父子共享同进程组件（toolReg/trustMgr/mcpMgr）；信任判定已 per-session 化（父子并发授权互不干扰）。

## 与其它形态的关系

- REPL/HTTP/ACP 会话循环当前仍由各自宿主驱动；`awaitChildren` 与父工具为宿主集成提供
  「子消息唤醒父」的阻塞原语（宿主输入循环可轮询），统一 SessionRunner（输入源可插拔）属后续演进。
## 跨进程子 Agent（ACP 桥）

`manager.startRemote(executable, agentName, parentSessionId, prompt, cwd, sessionDir)`：
子 Agent 运行在独立 `atelier acp <agent> <sessionDir>` 进程（同一可执行文件），协议经 acp-cj
`AcpClient` 桥接——句柄语义与本地子一致（done/reply/recv/close），**send = 一次子自主回合**。

- sessionDir：子进程独立会话/映射目录（勿与父共享，父若为 REPL/HTTP/ACP 会同目录争用 bstorm）
- 验证：`scripts/remote_subagent_e2e.sh`（隔离 HOME + echo 模式跑条件 e2e：握手→首回合 done→续聊 reply→close）
- **限制（ACP v1）**：回合内 waitReply 不可跨进程（子以分回合提问表达）；子无法主动唤醒空闲父
  （父在自身回合内 await/watch 不受影响——本地子全能力保留）

## 测试

```bash
cjpm test -j 16 --no-progress   # 全量（含 subagent P0-P2 用例）
```

覆盖：消息唤醒/多轮、recv 超时、close 幂等与级联、cancel 快速收敛、progress 先于 done 可见、
waitReply 父回复回流子上下文、超时路径、父回合完整编排（start→watch 收 done）、信任隔离。

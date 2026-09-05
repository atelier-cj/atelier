# 可持续子 Agent + 双向 send_message 实施计划

> 设计方向已确认（2026-09-05）：场景 b（父回合间常驻后台子 agent，异步分工、随时唤醒）；
> b 覆盖 a（父可在回合内 `await` 决定是否等待）；子 agent 的**中间回复与最终报告都经消息唤醒父**，
> 单向 report 工具被对称消息取代。

**Goal:** 把 atelier 的 Agent-as-Tool 从「一次性单向委派」升级为**可持续子 Agent**：
父、子各自拥有**常驻会话 Runner（消息驱动）**与**双向邮箱**，`send_message` 语义双向可用；
子 agent 跨父回合存活并可被唤醒续聊；父由子消息（进度/回复/最终报告）唤醒继续工作。

**现状（要替换的语义）:** `src/agent/agent_tool.cj` 的 `AgentTool.execute()` = new AgentRuntime →
发一条 UserMessage → `stream.result()` 阻塞到整个 run 结束 → 取末段文本返回 → runtime 即弃。
无句柄、无双向、不落库、回合间不可见。

**核心架构洞察:** 被唤醒的父/子 = **输入源换成消息队列的会话循环**。REPL 已经是
`loop { 读输入 → chatWithSessionId → 落库 }`，ACP prompt runner 也是同构循环。
因此把「会话循环 + 输入源」提升为公共组件 **SessionRunner**，输入源可插拔
（终端 / 子队列 / ACP prompt / HTTP），AgentRuntime 本身**零改动**。

---

## 一、架构设计

### 1.1 运行时视图

```
父 Agent（Runner 循环，可同时 watch 多个子）          子 Agent（每个一个 Runner/Worker 线程）
┌──────────────────────────────┐       ┌──────────────┐ ┌─────────────────────────────┐
│ AgentRuntime.chat(每回合)     │       │ SubAgentMgr  │ │ SubAgentWorker（spawn 循环）│
│  · subagent_start/send/await/│ inbox │ (注册表句柄)  │ │ inbox │  · send_message 工具 │
│    watch/close（工具调用）     │ ⇄     │ id/状态/队列  │ │ outbox │    → outbox 投递     │
│  · 回合 end_turn → Runner 挂起│ outbox│ 父会话级联关闭 │ │  · 回合 end_turn → 继续等  │
└──────────────────────────────┘       └──────────────┘ └─────────────────────────────┘
       历史: 父会话树                                   历史: 子会话树（SessionStore 独立）
```

- 每回合仍调用现有 `AgentRuntime.chatWithSessionId`（**runtime 不改**）；
- 常驻/唤醒/邮箱全部在 **SessionRunner + SubAgentManager** 层；
- 父子会话历史独立走树形 SessionStore（多轮续接免费获得），`parentSession` 字段可标记父子关系。

### 1.2 消息与唤醒语义

**消息信封 `AgentMail`**：`{ from, to(sessionId), seq, kind, text, meta }`
kind：`user_text`（对话/委派）、`progress`（子进度）、`reply`（子/父回复）、
`done`（最终报告，携带结果摘要）、`close`（终止）、`cancel`（打断进行中回合）。

**唤醒两条路径（由 agent 自己决定）：**

| 路径 | 机制 | 父端工具 |
|---|---|---|
| 回合内等待 | 父回合中 `subagent_await` 阻塞取 outbox（可超时），子回信 → **当前回合继续**（AskUserFn 同款同步等待链） | `subagent_await(id, timeout?)` |
| 回合间唤醒 | 父回合 `end_turn` 后 Runner **挂起在 inbox**；任意子来信 → 父开**新回合**（信封转 UserMessage 注入，事件带来源标记） | 父上回合调 `subagent_watch(id)` 登记；default = 自动 watch 已 start 的子 |

`done` 信封无特殊通道：照常投递 → 唤醒父 → 父收尾（可 close 该子）。
子 agent 侧对称：`send_message` 可只投递（异步），父回信也会唤醒子 Runner。

### 1.3 组件清单（全部新增，包 atelier.agent 或 atelier.subagent）

| 组件 | 职责 |
|---|---|
| `SubAgentManager` | 注册表：句柄创建/查询/关闭；父会话级联（父会话结束 → 子 close）；空闲超时回收（可配） |
| `SubAgentHandle` | 公开句柄：id/父 sessionId/状态（idle/running/closed）/inbox/outbox（BlockingQueue 或自旋+信号量） |
| `SubAgentWorker` | 子端常驻循环：接 inbox → 组 UserMessage → `chatWithSessionId`（子历史）→ 落库 → 回 outbox → 回挂起 |
| `SessionRunner`（可选先行抽象） | 消息驱动会话循环：输入源接口 + 回合执行 + 落库；REPL/ACP 后续可迁移，本期先服务父子两端的 runner 形态（父 Runner 与子 Worker 共用实现） |
| 子端工具 `SendMessageTool` | 替代 report：`toParent(text, kind, waitReply?)`；`waitReply=true` 时阻塞等父回信（复用 askUser 注入点阻塞模式） |
| 父端工具 | `SubagentStartTool`、`SubagentSendTool`、`SubagentAwaitTool`、`SubagentWatchTool`、`SubagentCloseTool`（父回合内 LLM 可自主调用） |

### 1.4 关键接口草案

```cangjie
public enum SubagentState { | Idle | Running | Closed }

public class AgentMail {
    public let from: String   // 发送方 session id
    public let to: String     // 接收方 session id
    public let kind: String   // user_text/progress/reply/done/close/cancel
    public let text: String
}

public class SubAgentHandle {
    public let subSessionId: String   // 子会话（SessionStore 中）
    public let parentSessionId: String
    public func send(mail: AgentMail): Unit            // 投递 inbox（异步）
    public func tryRecv(timeout!: Duration): ?AgentMail // 从 outbox 取（阻塞可超时）
    public func state(): SubagentState
    public func close(): Unit                          // 终止 worker + 状态清理（历史保留）
}

public class SubAgentManager {
    public func start(parentSessionId: String, config: AgentConfig, provider: Provider,
        components…): Result<SubAgentHandle>
    public func get(subSessionId: String): ?SubAgentHandle
    public func closeForParent(parentSessionId: String): Unit   // 级联
    // Runner 集成：父会话回合结束时调用（watch 集合 → 挂起），父回合开始前检查 inbox
}
```

### 1.5 并发与共享（必须处理）

- 子 Worker 线程与父共享 toolReg/trustMgr/mcpMgr——沿用 Agent-as-Tool 同进程共享先例；
- **修复 `TrustManager.sessionTrusts`**：当前全局 HashMap，父子并发信任会互踩 →
  改 per-session（`sessionTrusts` 键 = sessionId + workDir，或由运行时传 session 上下文；
  与 runtime 取消表同款 Mutex 模式）；同时验证工具调用并发安全（只读工具并行无碍，
  todo/ask_user 等有状态工具需在父子间隔离——按工具维度评估，必要时 per-run 实例化）；
- 子回合与父回合的 cancel：沿用 `cancelSession`（sessionId 隔离，天然支持）。

### 1.6 持久化与恢复

- 子会话历史：SessionStore 独立条目，`SessionHeader.parentSession = Some(父会话 id)`；
- 进程重启后句柄重建：`start` 前检查 store 中 parentSession 指向本父的子会话 →
  （策略待定：自动重建 vs 应用层选择，首版只做会话数据保留 + 文档说明）。

---

## 二、任务拆分（TDD，每阶段独立提交）

### P0：基础设施 —— SubAgentManager/Handle/邮箱 + 消息驱动 Runner 骨架

**Files:**
- Add: `src/agent/subagent.cj`（AgentMail/SubagentState/SubAgentHandle/SubAgentManager/SubAgentWorker）
- Add: `src/agent/subagent_test.cj`

**Step 1 失败测试**（先钉语义）：
1. `start` 返回句柄（子会话 id 生成、状态 Idle）；`get` 可查；
2. `send` 投递后子回合被触发：用 StubProvider（记录收到的消息文本）断言**新消息唤醒**
   （worker 先 idle，send 后它开新回合、provider 收到该文本）；多轮 send 多次触发；
3. `tryRecv(timeout)`：父侧先取空（超时 None）→ 子回信后取到（阻塞唤醒）；
4. `close`：worker 终止（不再响应 send）、句柄状态 Closed、幂等；
5. `closeForParent` 级联关闭全部子句柄；
6. 取消：子回合运行中 send `cancel`/调 `cancelSession(子)` → 回合尽快收敛。

**Step 2 实现：**
- 队列用 `LinkedBlockingQueue`（EventStream 同款，已在 llm_api.event 依赖内）；worker
  spawn 常驻循环：`inbox.take()` → 组装消息 → `chatWithSessionId`（子历史 load +
  追加 UserMessage）→ 消费事件（进度事件发 outbox kind=progress）→ `extractNewMessages`
  落库 → `result` 摘要 → outbox 投 `reply`/`done` → 回循环；
- 父侧等待原语（供后续父工具与库调用）：`recvFromSub(sessionId, timeout)`。

**提交点:** `feat(subagent): 可持续子 Agent 基础设施（句柄/邮箱/worker 循环，消息唤醒）`

### P1：子端 send_message 工具（替代 report）+ 父子第一程 e2e

**Files:**
- Add: `src/tool/builtin/send_message.cj`（`SendMessageTool`：name=`send_message`，参数
  `text/kind/waitReply`）
- Modify: `src/agent/subagent.cj`（worker 装配工具集：子 runtime 的 toolRegistry 注入
  SendMessageTool——注入方式：worker 构造独立 ToolRegistry = 共享 + SendMessageTool，
  或 AgentTool 同款传参——实现时定，倾向 worker 内组合注册表避免污染共享注册表）
- Add: `src/agent/subagent_test.cj` 追加用例

**用例：**
- 子回合内调用 `send_message(text:"进度1", kind:"progress")` → 父 outbox 收到 progress；
- `waitReply=true` 阻塞 → 父回信 → 子回合继续（Stub 编排：父先 await 子首信 → 回信 →
  断言子第二轮 provider 收到父回信文本）；
- 最终报告：子 end_turn → 父收到 `done`（含最后文本）；**父被唤醒断言**（父 Runner
  挂起态收信后开新回合，provider 收到信封转成的 UserMessage）。

**提交点:** `feat(subagent): 子端 send_message 工具（异步投递/等待回复，取代 report）`

### P2：父端工具集 + 信任并发修复

**Files:**
- Add: `src/tool/builtin/subagent_*.cj`（start/send/await/watch/close 五个工具）
- Modify: `src/trust/manager.cj` + `src/trust/trust_test.cj`（sessionTrusts per-session 化）
- Modify: runtime（如有必要）把 sessionId 传给 trust 判定（实现时评估影响面：
  `TrustManager.setSessionTrust(sessionId, workDir, state)` 变体 + 调用点适配）
- Add: `src/tool/builtin/tools_test.cj` 追加

**用例：**
- `subagent_start(name, prompt)` 立即返回子句柄 id（不阻塞到 run 结束）；
- `subagent_send` / `subagent_await(timeout)`：父回合内收子 progress → 回信继续；
- `subagent_watch`：父回合 end_turn 后子来信 → 父新回合（Runner 集成测试）；
- `subagent_close`；
- 信任隔离：父子分别对同一目录 setSessionTrust 互不影响（per-session 修复回归）。

**提交点:** `feat(subagent): 父端 start/send/await/watch/close 工具 + 信任 per-session 化`

### P3：收尾 —— 文档、恢复策略、全量回归

**Files:**
- Add: `docs/subagents.md`（概念/API/工具/生命周期/与 ACP·HTTP·REPL 的关系）
- Modify: `docs/design.md`（路线图 Phase 4 增补/新 Phase 条目、架构图）、`README.md`、
  `docs/tools.md`（新工具表）、`AGENTS.md`（如需）
- 会话数据持久化说明 + 重启恢复策略记录（首版：数据保留、句柄应用层重建）

**收尾:** 功能分支 `feat/subagent-duplex` 全量回归 → `merge --no-ff` 回 master → 删分支。

---

## 三、决策记录（2026-09-05 已确认）

1. **场景 b 优先**：父回合间常驻后台子 agent + 消息唤醒；b 内含 a（回合内 await 由 agent 自决）。
2. **取代 report**：子端 `send_message`（progress/reply/done 统一信封），无单独 report 工具。
3. **唤醒对称**：子回复与最终报告都走父 inbox → 父开新回合；父回信同理唤醒子。
4. **runtime 零改动**：常驻/唤醒/邮箱在 SessionRunner/SubAgentManager 层；AgentRuntime.chat 保持一次性回合。
5. 生命周期：显式 `close` + 父会话级联关闭；detach 成全局后台 agent **不做**（后置）；空闲回收可配、默认关。
6. 非目标（首版）：跨进程子 agent（另开会话进程/ACP 拉起）、父子共享上下文压缩、detach、HTTP/REPL 统一 Runner 迁移（仅说明可行性）。

## 四、风险与边界

- Worker 线程生命周期：父进程退出/会话删除时的清理路径要覆盖（Manager.close 在宿主关闭链上）。
- 有状态工具（todo/ask_user/mcp 连接状态）在父子共享下的语义：ask_user 阻塞在子回合内不阻塞父（线程隔离 OK）；todo 等按工具评估隔离。
- 父子同时跑大回合的资源：首版同进程线程模型，文档注明建议并发度。
- `sessionTrusts` per-session 化是**行为兼容修复**：现 API 调用点（runtime/REPL/HTTP）逐一适配并回归，默认行为不变（无 session 上下文时退化为当前行为）。

---

# 二期（2026-09-05 追加）：宿主集成与演进

P0-P3 已完成并合并（f51200c）。二期四项：

## P4：SessionLoop 统一回合执行层
把「历史 + 输入文本 → chatWithSessionId → 事件消费（可挂 cancel/事件回调）→ 落库 → 结果」从
SubAgentWorker.runTurn 抽为公共组件（atelier.agent.SessionLoop），worker/ACP bridge/未来宿主共用；
worker 保留消息循环与收发信职责。验收：现有 subagent P0-P2 用例全绿（无行为变化）。

## P5：子句柄进程重启恢复
- 会话落库 header 记录 parentSession（子会话 → 父会话 id）
- manager.resumeSession(parentSessionId, childStoreId, env) → 复用既有子会话历史的句柄
  （worker 载入历史，不再投 initial；首封消息走来信）
验收：新 manager + 旧 store（模拟重启）resume → 续聊上下文包含历史；恢复失败路径返回 None。

## P6：REPL 宿主集成
- REPL 构建 SubAgentManager 并注册父端工具（回合内 start/watch 可用）
- `/subagent` 斜杠命令：list / send <id> <text> / respond <id> <text> / close <id> / status
- 每回合结束提示未处理子消息数（回合边界感知；终端阻塞读行不强行轮询）
验收：REPL 会话中可启动子任务、跨回合查看状态与手动收发；父回合内 watch 可用。

## P7：跨进程子 agent（方案先行）
进程隔离的子 worker。候选方案：
1) ACP 桥：父内 SubAgentHandle 后端 = AcpClient(SubprocessTransport("atelier acp <agent>"))，
   回合语义映射 prompt/update（消息驱动 + 回合内等待均可映射，复用 acp 0.2.0）；
2) 同进程线程（现状）仅加崩溃隔离声明；
3) 一次性 exec（`atelier run`）——不支持双向，弃。
推荐方案 1。先出设计评审（消息信封↔ACP 方法映射、生命周期/取消/关闭语义、acp client 复用点），
再按设计实施（TDD）。

---

# P7 设计评审：跨进程子 Agent（ACP 桥）

## 目标与候选

进程隔离的子 worker：子 Agent 跑在独立 `atelier acp <agent>` 进程（协议边界复用 acp 0.2.0）。
候选 2（同进程线程+崩溃隔离声明）、候选 3（一次性 exec 无双向）被否；**采用候选 1：ACP 桥**。

## 拓扑

```
父进程（宿主会话/父 Agent）                     子进程（独立 atelier acp <agent>）
  SubAgentManager ── RemoteSubAgentHandle ──> AcpClient(SubprocessTransport)
       │  （本地 SubAgentHandle 不变）              ├─ initialize / session/new(cwd)
       │                                            ├─ prompt(text)  ← 父 send / 首回合
       │  setOnSessionUpdate → 收集流式进度         └─ session/cancel | close
```

## 方法映射（ACP v1 能力内）

| 本地语义 | ACP 映射 | 说明 |
|---|---|---|
| start(agent, prompt) | connect + `session/new` + 首回合 `prompt(initial)` | 返回句柄后首回合异步（spawn 线程） |
| send(text)（续聊/委派） | `prompt(新 user_text)` 阻塞至回合结束 | 一次 prompt = 子一次**自主回合**（含工具循环） |
| 回信 done/reply | prompt 响应 stopReason + 最后文本 | 写 handle.outbox（聚合盒同本地） |
| 子回合内 progress | `session/update`（tool_call/文本 chunk 等） | 经 `setOnSessionUpdate` 过滤转 progress 通知（可选增强） |
| cancel | `session/cancel` | 子进程回合取消 → 响应 cancelled |
| close | `session/close` + terminate 进程 | 幂等 |
| **waitReply（回合中等待父回复）** | ❌ 不支持 | ACP v1 prompt 回合中不可插话；子需自行决策或分回合提问（父在**下一封**回复）——跨进程语义降级为「分回合问答」，文档明示 |
| **子主动唤醒空闲父** | ❌ 不支持 | v1 无 agent 主动发起；父在回合内 watch（本地）不受影响 |

## 复用点

- acp 0.2.0 `AcpClient` / `SubprocessTransport` / `setOnSessionUpdate`（acp-cj 已全量验证）
- 会话目录隔离：子进程 `HOME=独立目录`（防共享 ~/.atelier 生产数据；复用 e2e 同款临时 HOME 姿势）
- 取消语义：client.cancel + handle 状态机复用本地实现骨架

## 落地方式（建议分两步）

1. **RemoteSubAgentHandle**：`SubAgentHandle` 子类覆写 send/recv/cancel/close（基类字段复用：
   outbox 由远程结果回调写入）；manager 增加 `startRemote(agentName, parentId, prompt, cwd, envs)` 与注册表统一
   `get()`（本地/远程并存）。父工具经 manager 调用天然同时支持两者（无接口重构）。
2. **验证**：库行为单测用「传输抽象」注入（若 AcpClient 可注入内存对端则走 PipePair + 伪 agent；
   否则脚本 e2e：父进程 @Test 外驱动——`scripts/` 起父（REPL 管道或独立 driver）→ 子 atelier acp
   真实子进程 → 断言 done/reply/cancel）。全量回归 + 文档更新（跨进程能力矩阵与限制）。

## 限制记录（首版接受）

- 跨进程 send 为**回合式**（无回合内插话）；waitReply 跨进程 → 建议子以「分回合提问」表达
- 子进程资源：每个远程子 = 1 个 OS 进程；close/崩溃后句柄清理路径要覆盖（进程退出检测）

---

# 完成记录（2026-09-05 收尾回标）

P0–P3 ✅、P4（SessionLoop 统一回合层）✅、P5（resumeSession 重启恢复）✅、
P6（REPL 集成：父工具 + /subagent list/send/respond/close + 回合边界未读展示）✅、
P7（跨进程 ACP 桥 RemoteSubAgentHandle + startRemote + 条件 e2e）✅ —— 均合入 master。

超出原计划的后续演进（全部 ✅）：
- SessionLoop 迁移 ACP 桥（回合语义统一 + 回合外消息可见 + poll 原语）
- REPL `/subagent start/poll` + 每回合未读展示；respond 状态感知（空闲/未等待 = follow-up
  唤醒，远程子由此从无效变为有效追问）——send_message 对齐 dsh 双向语义（父端更名 +
  subagent_reply 工具）
- REPL `/subagent start --remote`（当前进程拉起独立 atelier acp 子，隔离目录）
- 空闲超时自动回收（`idleTimeoutSec` 可配，默认 0 不回收）

有意边界（维持）：
- 跨进程 waitReply 回合内插话 ❌（ACP v1 限制，分回合问答降级，文档明示）
- 子主动唤醒空闲父 ❌（v1 无 agent 主动发起；父回合内 await/watch 不受影响）
- detach 成全局后台 agent：不做（后置）
- 父自动开新回合（LLM 自动应答策略）：有意不做（回合循环/成本；交付 = 原语 + REPL
  回合边界展示 + 手动 poll/respond/subagent_reply；受控版宿主事件注入留作候选）
- SessionLoop 迁移 REPL 主循环：暂缓（REPL oldMsgs 差集落库语义，回归风险 > 收益）
- 统一 SessionRunner（输入源可插拔）：后续演进

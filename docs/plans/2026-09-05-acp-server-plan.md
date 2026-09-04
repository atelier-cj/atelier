# ACP Server（Agent 侧）接入实施计划

**Goal:** 让 atelier 以 **ACP v1 Agent（服务端）** 身份被任意 ACP Client（Zed / opencode / JetBrains / 自研 UI）通过 stdio 拉起：`initialize → session/new → session/prompt → 流式 session/update → cancel/close/list/load/resume/delete` 全生命周期可用，且复用 atelier 现有的 Provider / 工具 / 会话持久化 / 信任闸门；通过 **Session Config Options** 暴露模型选择与压缩开关等可调项（Client 原生渲染切换 UI）；多 agent 不做运行期切换——**启动时选择**（`atelier acp [agent]`），文档中说明。

**角色澄清：** atelier 是「Agent 运行时」，因此实现的是 ACP 协议中 **Agent 侧（服务端）**，对接的是外部 **ACP Client**。协议层不自研——复用 `acp` 包（acp-cj）已实现并注册全部方法、双工能力的 `AcpAgent` 框架，本次把 atelier 的 `AgentRuntime` 接进它的回调。

**Architecture:**

```
┌────────────────────────────────────────────┐
│  ACP Client（Zed / opencode / testclient）  │  ← 外部宿主
└──────────────┬─────────────────────────────┘
               │ stdio，\n 帧（JSON-RPC 2.0）
┌──────────────▼─────────────────────────────┐
│  AcpAgent（ystyle::acp，已注册全部方法）      │  协议边界
│    └─ 回调：setPromptHandler / setOn*…      │
├──────────────┬─────────────────────────────┤
│  atelier.acp 适配层（本次新增 src/acp/）     │
│   · AcpBridge     组装 + serve()             │
│   · SessionMap    ACP sid ↔ atelier sid     │
│   · PromptRunner  回合执行 + 事件消费        │
│   · Translator    AgentEvent → SessionUpdate │
│   · Permission    信任闸门 → request_permission│
│   · ConfigOptions 模型/开关 → session config options│
│   · CancelBridge  session/cancel → runtime  │
├──────────────┼─────────────────────────────┤
│  atelier 核心（AgentRuntime/Provider/工具/   │
│  StormSessionStore/TrustManager/…）         │
└─────────────────────────────────────────────┘
```

**Tech Stack:** 仓颉（cjpm）、`acp`（acp-cj，先 path 依赖）、`llm_api`（path，已用）。

**前置：** master 工作区干净（2026-09-05 确认）。分支 `feat/acp-server` 待开。

---

### 阶段 0：依赖前置 —— acp-cj jsonrpc 升级 + path 依赖（跨仓库）

**背景：** atelier 依赖 `ystyle::jsonrpc` 0.7.4（cjpm.lock 单一版本），acp 0.1.2（中心仓）依赖 jsonrpc 0.7.3，同包双版本无法共存；acp-cj 本地源码即 0.1.2，jsonrpc 0.7.3 → 0.7.4 应为纯增量（atelier/mcp 均已跑在 0.7.4）。

**Files（acp-cj 仓库）:**
- Modify: `cjpm.toml`（`"ystyle::jsonrpc" = "0.7.3"` → `"0.7.4"`）
- 验证：acp-cj `cjpm test -j 16 --no-progress` 全绿（39 用例）

**Files（atelier 仓库）:**
- Modify: `cjpm.toml`（新增 `"acp" = { path = "../acp-cj" }`；`cjpm build` 验证解析）
- 依赖版本核对：acp 依赖 sonyflake 1.0.9 / jsonvalue 1.1.0，与 atelier 已用版本一致（无需动）

**提交点：** 每仓库独立 commit（acp-cj 先提交升级，atelier 提交加依赖）。acp 0.1.3 发版**不在本期**——功能稳定后再走发版流程（cangjie-publish），届时 atelier 切注册表版本并更新 AGENTS.md 外部依赖表。

---

### 阶段 1：atelier 核心补缺 —— AgentRuntime 运行时可取消

**背景：** ACP `session/cancel` 与 `$/cancel_request` 要求 agent 能中断进行中的 prompt 回合并返回 `cancelled`；当前 `AgentRuntime` 主循环（`src/agent/runtime.cj`）一旦 `chat()` 就没有任何中断点（连 REPL 都没有取消），Provider 流式接收为同步循环。本阶段为其补「会话级取消」，REPL/HTTP 未来同样受益（本期只接入 ACP，不改 REPL/HTTP 行为）。

**Files:**
- Modify: `src/agent/runtime.cj`（取消通道 + 检查点）
- Modify: `src/agent/event.cj`（如需取消专属事件）
- Modify: `src/agent/runtime_test.cj`（追加用例）
- Investigate: `src/tool/executor.cj` + `src/tool/builtin/bash.cj`（工具批执行中取消的可行边界）

**Step 1: 写失败测试（先定语义）**

到 `src/agent/runtime_test.cj` 追加（沿用既有 `StubProvider` 模式，另加慢流式 Stub）：

1. `cancelStopsRunPromptly`：慢流式 StubProvider（每个 delta 间 sleep 50ms，发多段文本并返回 end_turn）→ `chatWithSessionId` 后消费一个 delta → 调 `runtime.cancelSession(sid)` → 断言流在限时内结束（事件流 `AgentEndEvent` 到达 / `result()` 可返回），且 StubProvider 计数显示**没有发起第二个 provider 请求**（取消发生在外层循环检查点）。
2. `cancelBeforeRunIsNoop`：对不存在/已结束的 sid 调 cancel 不抛异常、不影响其它会话。
3. `cancelDuringToolBatch`（尽力而为层）：工具批次**之间/之后**不再发起新一轮 provider 请求（用会连续 ToolUse 的 StubProvider：第一个回合返回 ToolUse，工具结果后第二轮返回 ToolUse → 取消后断言没有第二轮 provider 请求）。

**Step 2: 实现**

- `AgentRuntime` 内部维护 `sessionId → AtomicBool` 取消表（Mutex 保护，chat 结束清理）；公开 `func cancelSession(sessionId: String): Unit`（幂等，`chatWithSessionId` 注册、结束注销）。
- 检查点（取消后尽快收敛、不抛未处理异常）：
  1. `while` 回合循环顶部（turn 边界）；
  2. provider 流式 `receive(5s)` 循环内（现有超时循环天然可醒来检查，最长延迟 ~5s）；
  3. 工具批次执行前后（`executeBatch` 前后）；
  4. 压缩子调用前。
- 取消语义：置 finished 后按正常路径收尾——`TurnEndEvent`（当前已得内容）→ `callHooks("afterRun")` → `stream.setResult(currentMessages)` → `AgentEndEvent`。不向 `stream.setError` 抛异常（REPL/HTTP 消费方均按正常结束处理）。**不做**批内 Future 的强杀（仓颉 Future 无 cancel）；`bash` 工具内部已有超时/取消能力，是否在批内传播取消由 Investigation 结论决定（Phase 2 的 cancel e2e 只承诺"尽力尽早"）。
- 若 Investigation 发现 ToolExecutor 已持有可复用取消点（如 ToolContext 取消回调），则顺带接上并补测试；否则记录为已知边界。

**Step 3: 全量回归** `cjpm test -j 16 --no-progress`（当前基线在新用例前记录）。

**提交点：** `feat(runtime): 会话级取消支持（cancelSession + 检查点），供 ACP session/cancel 使用`（单测先行）。

---

### 阶段 2：ACP 适配层 —— atelier 新增 `src/acp/`

**Files（全部新增）:**
- `src/acp/translator.cj`（纯函数翻译，重点单测对象）
- `src/acp/session_map.cj`（ACP sid ↔ atelier sid 映射，复用 `acp.SessionStore` 持久化）
- `src/acp/prompt_runner.cj`（prompt 回合执行）
- `src/acp/permission_bridge.cj`（信任闸门 ↔ request_permission）
- `src/acp/bridge.cj`（`AcpBridge`：组装 AcpAgent + 注册全部回调 + serve）
- Modify: `src/context/model_registry.cj`（`list()` + `register()`，config options 枚举模型候选的前置小改）
- 对应 `*_test.cj`

**2.1 事件翻译矩阵（translator.cj，AgentEvent → SessionUpdate）**

| atelier 事件 | ACP `session/update` | 载荷要点 |
|---|---|---|
| `MessageStartEvent` | （可选）记录 messageId 起点 | messageId 生成：优先复用消息自带 id，否则 `msg_<acpSid>_<turn>_<n>` |
| `MessageUpdateEvent(delta)` | `agent_message_chunk` | content=delta（累积按 chunk 发），同 messageId |
| `MessageEndEvent(assistantMsg)` | （若带 toolCalls）`tool_call`（status=pending/running） | toolCallId=tc.id、title=tc.name、kind 映射（read/write/command/…按工具名归类，未知归 custom）、rawInput=tc.arguments |
| `ToolExecutionStartEvent/UpdateEvent` | `tool_call_update`（status=running + progress→content 文本） | 复用 toolCallId |
| `ToolExecutionEndEvent` | `tool_call_update`（status=completed/failed + content 结果） | isError → failed |
| `TurnEndEvent.message.usage` | `usage_update`（可选） | used=inputTokens、size=contextWindow（拿不到时省略） |
| `CompactionEvent` | 不发送 | 可转日志 |
| `AgentEndEvent` | （结束信号） | 决定 `PromptResponse.stopReason` |

**StopReason 映射：** atelier `EndTurn→end_turn`；`MaxTokens→max_tokens`；`Error/Refusal→refusal`；取消 → 由 AcpAgent 侧 cancelFlag 统一转 `cancelled`（协议笔记：即使底层异常也要 catch 后返回 cancelled 语义）。

**2.2 会话生命周期（session_map.cj + bridge 回调）**

- `session/new(cwd, mcpServers)`：`acp.SessionStore` 建映射（ACP sid → 新建 atelier sid，atelier sid 用现有 `nextId()`/store 规则）；记录 cwd → `SessionEnvironment.directory`（AGENTS.md 自动注入、工具 workDir）。mcpServers 本期忽略（与 acp-cj 结论一致：不实际建立 MCP 子进程，类型上可收发）。
- `session/load`：恢复映射 + atelier 会话历史 load，**主动重放历史 update 通知**（按序发 agent_message_chunk / tool_call_update，对齐 v1 load 语义）。
- `session/resume`：恢复状态不重放（atelier store 已持久化，直接可继续）。
- `session/list`：遍历映射持久化记录 + atelier `SessionStore.list()` 补 title/updatedAt → `ListSessionsResponse`。
- `session/delete`：删映射 + atelier `SessionStore.delete`（记录为已知策略：硬删）。
- `session/close`：cancel 进行中回合 + 清理运行期状态（映射保留，供 load/resume 恢复——close 不删历史）。
- `capabilities`：`loadSession=true`；`sessionCapabilities.{list,delete,close,resume}=Some(EmptyCapability())`；`promptCapabilities.{image,audio,embeddedContext}=false`（保持默认）；`additionalDirectories` 先不声明（记入后续项）。
- `session/set_mode`：不实现（旧 Modes API，config options 已覆盖；支持 config options 的 Client 会忽略 modes）。
- `session/set_config_option`：**本期实现**——见 2.5 Session Config Options。

**2.3 prompt 回合（prompt_runner.cj）**

1. 输入：`PromptContext.prompt`（ContentBlock）→ 文本转 `UserMessage(ContentList.ofText(...), 0)`（图片等其它 block：capabilities 已声明不支持，见到即忽略并记日志）；按 atelier 主流程：`store.load(atelierSid)`（无则空）→ 追加 user 消息 → `runtime.chatWithSessionId(atelierSid, msgs, SessionEnvironment(directory=cwd))`。
2. 事件消费循环（spawn 内，与 pi_bridge 同款组织）：`for (event in stream)` → translator → `agent.sessionUpdate(acpSid, update)` 逐条推送；`stream.result()` 收尾。
3. 落库：回合结束后按 REPL 模式 `sessionStore.appendBranch / save`（header 含 model/provider/systemPrompt/env.directory）。
4. 返回 `PromptResponse(stopReason)`。
5. 取消：`session/cancel` / `$/cancel_request` 回调 → `runtime.cancelSession(atelierSid)` + AcpAgent cancelFlag 由框架处理（handler 返回 end_turn 时自动转 cancelled，见 agent.cj doPrompt）。

**2.4 权限与提问（permission_bridge.cj）**

- 现状：`TrustDecision.NeedsApproval` 时 runtime 同步调注入的 `askUser`（返回 y/a/n 字符串），9 参构造默认 `{q => ""}`（直接 deny）。ACP 模式注入新 `AskUserFn`：
  - 组装 `ToolCallUpdate`（toolCallId/name/arguments/kind）→ `agent.requestPermission(acpSid, toolCall, [Allow Once / Always Allow / Deny])`（同步等待 client 响应，jsonrpc 反向请求在接收线程外 spawn 处理，无死锁——acp-cj pi_bridge 已验证此链路）；
  - 结果映射：allow once → `setSessionTrust`；always → `setTrust`；deny → 返回 ""（沿用 runtime deny 分支）。
- 异步交互（HTTP 现有 `/agent/input` 模式）在 ACP 下不适用——回合模型要求 prompt 阻塞到结束。
- `ask_user` 工具（AI 主动提问）：本期**映射为文本回合**——工具返回提示文本「(ACP 模式) 请直接在对话中回答」，agent 把问题写进回复，用户下一条 prompt 作答（决策记录：elicitation 已稳定但 acp-cj 仅类型级支持，单列后续任务）。

**2.5 Session Config Options（本期）**

把 atelier 可调配置映射为 ACP 会话配置项，Client 可原生渲染切换 UI（官方语义：session/new 下发初始列表，set_config_option 修改后**回完整最新列表**，agent 可主动 config_option_update）：

1. **初始下发**（`session/new` 响应 `NewSessionResponse.configOptions`）：
   - `select` 型 `model`（name「模型」，`category: "model_config"`，让 Client 渲染在模型选择器旁）：候选集 = AgentRegistry 各 agent 配置出现过的 model ∪ `ModelContextRegistry` 已知模型（去重）——**前置小改**：`ModelContextRegistry` 增加 `list()` 与自定义 `register(model, window)`（现 only get()）；`currentValue` = 当前 ACP 会话生效模型；
   - `boolean` 型 `compaction`（name「上下文压缩」）：`currentBool` = 会话生效开关；
   - 仅当 Client `clientCapabilities.session.configOptions` 已声明才下发；boolean 项需按 schema 对齐 Client 的 `session.configOptions.boolean` 特判（acp-cj 类型层已有承载位，序列化细节实施时对齐官方 schema）。
2. **会话级覆盖**：覆盖状态 per-ACP-session 维护（内存 Map，load/resume 时随映射恢复）；`session/set_config_option` 回调校验 id/value（未知 id / 非法 value → `-32602`）后写入，响应回完整最新列表（协议要求）。
3. **生效点**：PromptRunner 每回合前把覆盖应用到本次运行的 AgentConfig（model 覆盖 → `pickModel` 路径解析 provider；compaction 开关覆盖 compactionEnabled），**只影响该 ACP 会话，不改全局 agent 配置**。
4. `config_option_update` 主动推送本期不主动使用（类型层已有，留作后续 fallback）。
5. **多 agent 不进 config options**：agent 在启动时选定（阶段 3 的 `atelier acp [agent]`，默认 default），运行期一个 ACP 进程对应一个 agent；文档（docs/acp.md + CLI help）说明此取舍。

**2.6 AcpBridge 组装（bridge.cj）**

```cangjie
let bridge = AcpBridge(
    agentName,            // 默认 "default"（~/.atelier.toml [[agent]] 选择）
    runtime 组件…,         // toolReg/trustMgr/agentReg/providerReg/sessionStore/skillReg/mcpMgr
    acpName: "atelier", acpVersion: "0.1.0")
bridge.serve()   // StdioTransport，阻塞
```

- 日志纪律：stdout **只允许** ACP 帧；所有诊断走 stderr / 文件日志（pi_bridge 的 `logErr` 同款封装）。
- 内部结构可参考 acp-cj `examples/pi_bridge/main.cj`（SessionStore 映射 + prompt 转发组织方式），但后端从 AcpClient 换成 atelier 自家 AgentRuntime。

**提交点：** 按 2.1→2.5 拆分多个 commit，每个先补测试后实现（translator 纯函数先行，桥接组装殿后）。

---

### 阶段 3：CLI 入口 `atelier acp`

**Files:**
- Modify: `src/cli/main.cj`（新增 `case "acp"`，复用已加载的 config/组件；参数 `[agent]` 可选；不启动 HTTP；`agent.serve()` 阻塞，退出后 `sessionStore.close()`）
- Modify: `src/cli/repl_test.cj` 或新增 main 分支测试（视可测性）

**行为：** `atelier acp [agent]` → 打印一条 stderr 启动日志后 serve stdin/stdout；被 `Zed`（`agent` 配置 command `atelier acp`）或 `opencode` 等以子进程拉起。agent 参数 = **启动时选择**（默认 "default"，即 `~/.atelier.toml` `[[agent]]` 中同名条目；该进程整个生命周期只服务这一个 agent，运行期不切换——CLI help 与 docs/acp.md 说明）。验证主流程里没有 `print()` 打到 stdout（ACP 分支路径检查）。

**提交点：** `feat(cli): atelier acp —— ACP Agent（stdio）入口`。

---

### 阶段 4：测试与端到端验证

**4.1 单元测试（各阶段已内嵌，汇总）**

- translator：每类事件的判别字段断言（文本累积/messageId 连续性、tool_call 生命周期、usage、StopReason 映射全矩阵）
- session_map：映射 CRUD、重启恢复（SessionStore 重载）
- prompt_runner：文本→Message 组装、cwd→SessionEnvironment、落库调用
- permission：client allow-once/always/deny 三分支 → trust 状态断言（用可注入的假 client 响应，或直接单测 AskUserFn 闭包逻辑）
- config options：模型候选枚举（model_registry list 去重）、初始列表下发（含 client 未声明 configOptions 时不发）、set 后覆盖生效（下一回合 pickModel/compaction 变化）、非法 value → -32602、load/resume 后覆盖恢复
- cancel（阶段 1 已含）

**4.2 端到端（离线、无真实 LLM）**

- 为 CLI 提供可离线运行的 provider 通道：atelier 本地注册 `echo` 类型 Provider（`ProviderRegistry` 工厂，chat 直接回显输入、支持可选的延迟开关供 cancel 用例），仅在 ACP e2e/冒烟使用（决策点：注册进 `ProviderRegistry.default()` 还是仅测试路径——实施时定，倾向放 atelier provider 模块公开，开发/调试均有价值）。
- 驱动方式 Investigation（按序选择）：
  1. 若 `acp` transport 可注入内存双端（读 stdio.cj 是否暴露可替换 reader/writer）→ `@Test` 内 AcpClient↔AcpAgent 环回，覆盖全生命周期断言，最可控；
  2. 否则 scripts 黑盒：`scripts/test-e2e-acp.sh` 构建后 spawn `atelier acp`，复用 acp-cj `testclient`（new+prompt+流式断言），其余方法（cancel/load/resume/close/list/delete）视 testclient 能力扩展或新增最小 driver；
  3. 对齐 acp-cj `scripts/test-e2e-bridge.sh` 已验证的沙箱姿势（FIFO/子进程注意点见 jsonrpc 记忆：预打开两端、pkill 精确匹配等）。
- e2e 场景：`echo provider` 下 new → prompt（断言流式 agent_message_chunk + end_turn）→ cancel（延迟模式，断言 `cancelled`）→ close → list/load/resume/delete 全链路；client 权限拒绝路径。

**4.3 真实链路（可选、人工）**：`XDG_DATA_HOME` 指向可写目录 + `opencode acp` 反向拉起 atelier 或 Zed 配置 `agent.command = "atelier acp"`。

**提交点：** e2e 脚本/驱动随对应能力阶段提交；全量回归 `cjpm test -j 16 --no-progress` + acp-cj 回归。

---

### 阶段 5：文档与收尾

**Files:**
- Add: `docs/acp.md`（协议对接说明：能力矩阵、ACP↔atelier 概念映射、**多 agent 启动时选择说明**、**Session Config Options 支持说明（模型/压缩开关）**、Zed/opencode 接入示例、已知边界：elicitation/图片/附加目录/MCP 透传/mcpServers 忽略、ask_user 文本回合策略）
- Modify: `docs/design.md`（架构图协议层补 ACP、路线图补 Phase 5 条目）
- Modify: `README.md` / `docs/README.md`（入口清单加 ACP）
- Modify: `AGENTS.md`（外部依赖表补 `ystyle::acp`——**发版后**写注册表版本；开发期写 path 说明）

**收尾：** 功能分支 `feat/acp-server` → 全量回归 → `git merge --no-ff` 回 master → 删分支；acp 0.1.3 发版作为独立后续任务（功能稳定后执行 cangjie-publish 流程，然后 atelier 依赖切注册表）。

---

## 任务顺序与依赖

```
阶段 0（依赖）→ 阶段 1（取消，独立可并行验证）
     ↘ 阶段 2（适配层，依赖 0+1 的 cancel API）
           → 阶段 3（CLI）→ 阶段 4.2（e2e，依赖 3 + echo provider）
                 → 阶段 5（文档）→ 合并 master
```

每阶段按仓库惯例：先写失败测试 → 实现 → 全量回归 → 独立 commit；允许分支内多次提交。

## 决策记录（2026-09-05 已确认）

1. 范围：stdio 服务端 + **会话生命周期全能力**（list/load/resume/delete/close）+ **Session Config Options**（select 模型选择 `model_config` 类目 + boolean 压缩开关）。
2. 依赖：acp-cj jsonrpc 升 0.7.4（本地验证），atelier path 依赖；acp 0.1.3 发版后置。
3. 取消：运行时可取消列入本期（改 AgentRuntime 核心 + 检查点；批内强杀不做）。
4. ask_user：本期映射为文本回合；elicitation 单列后续。
5. **多 agent：不做运行期切换**——`atelier acp [agent]` 启动时选择，一个进程服务一个 agent，docs/acp.md + CLI help 说明；agent 列表不进 config options。
6. 非目标：ACP v2（2026-07 Draft，官方建议不默认启用）、HTTP/WS 传输（ACP transports WG draft 中）、MCP over ACP 透传、旧 Modes API（config options 已覆盖）。

## 风险与边界

- jsonrpc 0.7.3→0.7.4 若在 acp-cj 有回归 → 停在 0.7.4 前版本单独排查（预期纯增量，atelier 已在 0.7.4 跑通）。
- 批内工具无法强杀 → cancel 延迟上界 = 当前工具最长执行时间 + receive 轮询 5s；文档中如实声明。
- atelier 会话 id / ACP sid 双向映射若因 store id 规则受限 → 改用 acp `SessionStore` 记录后端 sid（已为此设计，无阻塞）。

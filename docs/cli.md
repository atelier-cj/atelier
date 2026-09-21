# CLI 参考

## 用法

```bash
atelier <command> [args...]
```

| 命令 | 说明 |
|------|------|
| `serve [port]` | 启动 HTTP 服务 |
| `tui [agent] [sid]` | 交互式 TUI（历史命令名 `repl` 等价） |
| `run [agent] <prompt>` | 单次执行 |
| `acp [agent]` | 作为 ACP v1 Agent 跑在 stdio 上（见 [acp.md](acp.md)） |

## serve

```bash
# 默认端口 8080
cli.app serve

# 指定端口
cli.app serve 9000
```

读取 `~/.atelier.toml` 的 `[server]` 配置（host/port/sessionDir/logLevel 等）。

## tui

```bash
# 默认 agent（需配置了 default 或走环境变量）
cli.app tui

# 指定 agent
cli.app tui code-assistant

# 恢复之前会话
cli.app tui code-assistant sess_abc123
```

读取 `~/.atelier.toml` 配置的 agent 和 provider。`repl` 是历史命令名（早期另有行式
REPL，现已移除），与 `tui` 等价；不带子命令直接运行 `cli.app` 也进这里。

要求交互式终端（stdin 是 tty）；非 tty 环境请用 `cli.app run`。

### 斜杠命令

| 命令 | 说明 |
|------|------|
| `/help` | 显示帮助 |
| `/agent [name]` | 切换 Agent（无参=交互选择） |
| `/session new` | 新建会话 |
| `/session list` | 列出所有会话 |
| `/session switch <id>` | 切换会话 |
| `/session export <id> jsonl` | 导出为 JSONL |
| `/session export <id> html` | 导出为 HTML 回放 |
| `/model <name>` | 切换模型 |
| `/models` | 列出配置的所有模型 |
| `/tools` | 列出当前 agent 的可用工具 |
| `/subagent list \| poll \| start [--remote] <agent> <prompt> \| send <id> <text> \| respond <id> <text> \| close <id>` | 可持续子 Agent |
| `/trust <path>` | 信任目录 |
| `/untrust <path>` | 取消信任 |
| `/new` | 新建会话（= `/session new`） |
| `/clear` | 清空对话历史（不清终端屏幕） |
| `/exit` 或 `/quit` | 退出 |

会话在每次对话轮次后自动持久化到 `~/.atelier/sessions/`。

### 回合进行中的实时反馈

回合跑在后台线程，主线程继续读键盘，因此：

- 工具与 PTC 子调用**正在跑什么、跑了多久**实时显示在会话尾部（活动块：`▶ 工具名 (耗时)`、
  子调用 `↳`、脚本输出 `│ ...`），回合结束即消失（那时会话区已有 `tool→/tool←` 完整记录）；
- 脚本 `println` 与工具进度随事件流实时上屏——不消费事件流的前端在整个回合里只有一个
  读秒，「工具卡住」与「模型在思考」看不出区别；
- 信任闸门的询问显示在状态行，直接在输入行回答（`y`=本次 / `a`=总是 / `n`=拒绝）。

## run

```bash
# 使用默认 agent
cli.app run "你好，介绍一下你自己"

# 指定 agent
cli.app run code-assistant "审查 src/main.cj"
```

如果第一个参数匹配已注册的 agent 名称，则作为 agent 名；否则作为 prompt 并使用 default agent。

## 配置文件

| 路径 | 说明 |
|------|------|
| `~/.atelier.toml` | Agent / Provider / Server / Logging / MCP 配置 |
| `~/.atelier/sessions/` | 会话持久化目录 |
| `~/.atelier/atelier.log` | 日志文件 |
| `~/.agents/skills/<name>/SKILL.md` | Skill 定义 |

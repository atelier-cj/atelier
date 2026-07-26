# CLI 参考

## 用法

```bash
atelier <command> [args...]
```

| 命令 | 说明 |
|------|------|
| `serve [port]` | 启动 HTTP 服务 |
| `repl [agent] [sid]` | 交互式对话 |
| `run [agent] <prompt>` | 单次执行 |

## serve

```bash
# 默认端口 8080
atelier serve

# 指定端口
atelier serve 9000
```

读取 `~/.atelier.toml` 的 `[server]` 配置（host/port/sessionDir/logLevel 等）。

## repl

```bash
# 默认 agent（需配置了 default 或走环境变量）
atelier repl

# 指定 agent
atelier repl code-assistant

# 恢复之前会话
atelier repl code-assistant sess_abc123
```

读取 `~/.atelier.toml` 配置的 agent 和 provider。

### REPL 斜杠命令

| 命令 | 说明 |
|------|------|
| `/help` | 显示帮助 |
| `/exit` 或 `/quit` | 退出 |
| `/clear` | 清空对话历史（不清终端屏幕） |
| `/model <name>` | 切换模型 |
| `/tools` | 列出当前 agent 的可用工具 |
| `/session new` | 新建会话 |
| `/session list` | 列出所有会话 |
| `/session switch <id>` | 切换会话 |
| `/session export <id> jsonl` | 导出为 JSONL |
| `/session export <id> html` | 导出为 HTML 回放 |
| `/trust <path>` | 信任目录 |
| `/untrust <path>` | 取消信任 |

会话在每次对话轮次后自动持久化到 `~/.atelier/sessions/`。

## run

```bash
# 使用默认 agent
atelier run "你好，介绍一下你自己"

# 指定 agent
atelier run code-assistant "审查 src/main.cj"
```

如果第一个参数匹配已注册的 agent 名称，则作为 agent 名；否则作为 prompt 并使用 default agent。

## 配置文件

| 路径 | 说明 |
|------|------|
| `~/.atelier.toml` | Agent / Provider / Server / Logging / MCP 配置 |
| `~/.atelier/sessions/` | 会话持久化目录 |
| `~/.atelier/atelier.log` | 日志文件 |
| `~/.agents/skills/<name>/SKILL.md` | Skill 定义 |

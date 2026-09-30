# HTTP API

Base URL: `http://<host>:<port>`

## 健康检查

```
GET /health
```

```bash
curl http://localhost:8080/health
# {"status":"ok"}
```

## Agent 配置

### 创建

```
POST /agent/config
```

```bash
curl -X POST http://localhost:8080/agent/config \
  -H "Content-Type: application/json" \
  -d '{
    "name": "assistant",
    "systemPrompt": "你是一个有用的助手",
    "model": "gpt-4o",
    "provider": "default",
    "tools": ["bash", "read_file", "grep"],
    "skills": [],
    "maxTurns": 20,
    "temperature": 0.7
  }'
# {"status":"created"}
```

### 列举名称

```
GET /agent/config
```

```bash
curl http://localhost:8080/agent/config
# {"agents":["assistant","code-assistant"]}
```

### 列举详情

```
GET /agent/configs
```

```bash
curl http://localhost:8080/agent/configs
# {"agents":[{"name":"assistant","model":"gpt-4o","systemPrompt":"..."}]}
```

### 删除

```
DELETE /agent/config
```

```bash
curl -X DELETE http://localhost:8080/agent/config \
  -H "Content-Type: application/json" \
  -d '{"name": "assistant"}'
# {"status":"deleted"}
```

## Agent 运行

### 同步

```
POST /agent/run
```

```bash
curl -X POST http://localhost:8080/agent/run \
  -H "Content-Type: application/json" \
  -d '{
    "agent": "assistant",
    "messages": [{"role": "user", "content": "你好"}]
  }'
# {"content":"你好！我是 AI 助手..."}
```

### 流式

```
POST /agent/stream
```

使用 SSE 实时推送事件：

```bash
curl -N -X POST http://localhost:8080/agent/stream \
  -H "Content-Type: application/json" \
  -d '{
    "agent": "assistant",
    "messages": [{"role": "user", "content": "你好"}]
  }'
# data: {"type":"turn_start"}
# data: {"type":"message_update","delta":"你好"}
# data: {"type":"message_update","delta":"，我是"}
# data: {"type":"message_end"}
# data: {"type":"agent_end"}
```

### 提问交互（审批 / 选择 / 表单）

SSE 流式模式下，回合需要用户拍板时会推一条 `user_request` 帧，随后**阻塞等人**：

```
data: {"type":"user_request","request":{"id":"ask:sess_x:3:call_a:approval","kind":"approval",
       "message":"Tool 'bash' needs your approval.","toolCallId":"call_a","toolName":"bash",
       "options":[{"id":"allow_once","label":"允许这一次"}, ...]}}
```

客户端按 `request` 渲染（`options` 给选择/审批，`fields` 给表单），再用**同一个 id** 回复：

```
POST /agent/input
```

```bash
# 审批 / 选择：selected 是选项 id（多选按顺序给多个）
curl -X POST http://localhost:8080/agent/input \
  -H "Content-Type: application/json" \
  -d '{"requestId":"ask:sess_x:3:call_a:approval","selected":["allow_once"]}'

# 表单：values 是「字段名 → 文本」；bool 用 "true"/"false"，multi_select 用逗号分隔
curl -X POST http://localhost:8080/agent/input \
  -H "Content-Type: application/json" \
  -d '{"requestId":"ask:sess_x:5:call_b","values":{"env":"prod","tags":"a,b"}}'

# 放弃：明确回报取消（不是回一个空答复）
curl -X POST http://localhost:8080/agent/input \
  -H "Content-Type: application/json" \
  -d '{"requestId":"ask:sess_x:5:call_b","status":"cancelled"}'
# {"status":"ok"}
```

约定：

- `requestId` 必须是一条**尚未作答**的提问 id：对不上返回 `404`（静默成功会让调用方
  以为答复已生效，而回合仍在原地等人）；
- 答复按提问里的字段类型包装后过一遍校验，不合格返回 `400` + 原因；
- `status` 缺省为 `answered`，另有 `cancelled` / `timed_out` / `pending`；
- 每次提问只接受一次答复，先到的生效。

## OpenAI 兼容 API

```
POST /v1/chat/completions
```

同步：

```bash
curl -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "assistant",
    "messages": [{"role": "user", "content": "你好"}]
  }'
# {"id":"chatcmpl-0","object":"chat.completion",
#  "choices":[{"index":0,"message":{"role":"assistant","content":"你好！"},"finish_reason":"stop"}],
#  "usage":{"prompt_tokens":0,"completion_tokens":0,"total_tokens":0}}
```

流式（`stream: true`）：

```bash
curl -N -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "assistant",
    "messages": [{"role": "user", "content": "你好"}],
    "stream": true
  }'
# data: {"id":"chatcmpl-0","object":"chat.completion.chunk","choices":[{"delta":{"content":"你好"},"index":0}]}
# data: {"id":"chatcmpl-0","object":"chat.completion.chunk","choices":[{"delta":{},"index":0,"finish_reason":"stop"}]}
# data: [DONE]
```

## 会话管理

### 保存

```
POST /session/save
```

```bash
curl -X POST http://localhost:8080/session/save \
  -H "Content-Type: application/json" \
  -d '{
    "sessionId": "sess_abc123",
    "header": "{\"version\":1,\"id\":\"sess_abc123\",\"createdAt\":0,\"updatedAt\":0,\"model\":\"gpt-4o\",\"provider\":\"\",\"systemPrompt\":\"\",\"parentSession\":null}",
    "messages": [{"role": "user", "content": "你好"}]
  }'
```

### 加载

```
POST /session/load
```

```bash
curl -X POST http://localhost:8080/session/load \
  -H "Content-Type: application/json" \
  -d '{"sessionId": "sess_abc123"}'
```

### 列表

```
GET /sessions
```

```bash
curl http://localhost:8080/sessions
```

### 克隆

```
POST /session/fork
```

```bash
curl -X POST http://localhost:8080/session/fork \
  -H "Content-Type: application/json" \
  -d '{"sourceId": "sess_abc123", "leafId": "entry_xxx"}'
```

### 导出

```
POST /session/export
```

```bash
# JSONL（默认格式）
curl -X POST http://localhost:8080/session/export \
  -H "Content-Type: application/json" \
  -d '{"sessionId": "sess_abc123", "format": "jsonl"}'

# HTML 回放
curl -X POST http://localhost:8080/session/export \
  -H "Content-Type: application/json" \
  -d '{"sessionId": "sess_abc123", "format": "html"}'
```

## 信任管理

```
POST /trust
```

```bash
# 查看状态
curl -X POST http://localhost:8080/trust \
  -H "Content-Type: application/json" \
  -d '{"action":"get","path":"/home/user/project"}'

# 设置信任
curl -X POST http://localhost:8080/trust \
  -H "Content-Type: application/json" \
  -d '{"action":"set","path":"/home/user/project","trust":"trusted"}'

# 重置
curl -X POST http://localhost:8080/trust \
  -H "Content-Type: application/json" \
  -d '{"action":"reset","path":"/home/user/project"}'
```

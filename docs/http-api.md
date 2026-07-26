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

### ask_user 交互输入

SSE 流式模式下，LLM 调用 ask_user 时会发射 `user_input_request` 事件。客户端通过以下端点回复：

```
POST /agent/input
```

```bash
curl -X POST http://localhost:8080/agent/input \
  -H "Content-Type: application/json" \
  -d '{"sessionId":"sess_xxx","answer":"yes"}'
# {"status":"ok"}
```

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

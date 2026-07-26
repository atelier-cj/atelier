# Code Assistant Agent

代码助手。

```bash
# 启动 REPL
atelier repl code-assistant

# 单次运行
atelier run code-assistant "给这个函数写单元测试"

# 使用 HTTP API
curl -X POST http://localhost:8080/agent/run \
  -H "Content-Type: application/json" \
  -d '{"agent":"code-assistant","messages":[{"role":"user","content":"审查 main.cj"}]}'
```

#!/usr/bin/env node
// AG-UI 端点探针：不依赖任何 npm 包（fetch + SSE 解析），可直接进 CI。
//
// 覆盖两条最关键的链路：
//   1) 客户端工具（前端实现）→ 服务端挂起（RUN_FINISHED.outcome = interrupt）
//   2) 同 threadId 带 resume[] 再来一次 → 补发 TOOL_CALL_RESULT 并正常收尾
//
// 用法： node scripts/agui-probe.mjs [baseUrl] [agentName]
const BASE = process.argv[2] ?? "http://127.0.0.1:8791";
const AGENT = process.argv[3] ?? "default";

async function run(body) {
  const res = await fetch(`${BASE}/ag-ui/agent`, {
    method: "POST",
    headers: { "content-type": "application/json", accept: "text/event-stream" },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}: ${await res.text()}`);
  const text = await res.text();
  return text.split("\n\n")
    .filter((chunk) => chunk.startsWith("data: "))
    .map((chunk) => JSON.parse(chunk.slice(6)));
}

const kinds = (evs) => evs.map((e) => e.type);
const interruptsOf = (evs) =>
  evs.filter((e) => e.type === "RUN_FINISHED" && e.outcome?.type === "interrupt")
     .flatMap((e) => e.outcome.interrupts ?? []);

let failures = 0;
function check(name, ok, extra = "") {
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${extra ? `  — ${extra}` : ""}`);
  if (!ok) failures++;
}

const thread = `probe-${Date.now()}`;
const tools = [{
  name: "get_weather",
  description: "查询指定城市的当前天气（必须调用）",
  parameters: { type: "object", properties: { city: { type: "string" } }, required: ["city"] },
}];
const strict = { systemPrompt: "必须调用提供的工具获取信息，不要凭记忆回答。" };

console.log(`# AG-UI 探针 → ${BASE}（agent=${AGENT}, thread=${thread}）`);
const s1 = await run({
  threadId: thread, runId: "r1", forwardedProps: { agent: AGENT, ...strict },
  messages: [{ id: "m1", role: "user", content: "北京今天天气怎么样？必须用 get_weather 查询。" }],
  tools,
});
console.log(`  第一趟事件：${kinds(s1).join(",")}`);
const ints = interruptsOf(s1);
check("客户端工具触发挂起", ints.length === 1, `interrupts=${ints.length}`);
check("中断 reason=tool_call", ints[0]?.reason === "tool_call", `reason=${ints[0]?.reason}`);
check("挂起前给出消息快照", kinds(s1).includes("MESSAGES_SNAPSHOT"));

if (ints.length === 1) {
  const s2 = await run({
    threadId: thread, runId: "r2", messages: [],
    resume: [{ interruptId: ints[0].id, status: "resolved", payload: { weather: "晴 26℃" } }],
  });
  console.log(`  第二趟事件：${kinds(s2).join(",")}`);
  check("恢复时补发 TOOL_CALL_RESULT", kinds(s2).includes("TOOL_CALL_RESULT"));
  check("恢复后正常收尾", s2.some((e) => e.type === "RUN_FINISHED" && e.outcome?.type === "success"));
}

console.log(failures === 0 ? "\n全部通过 ✓" : `\n${failures} 项未通过 ✗`);
process.exit(failures === 0 ? 0 : 1);

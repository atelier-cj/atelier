#!/bin/bash
# 官方 ACP TCK（agentclientprotocol/acp-tck）固化入口：克隆/复用 → 全量跑 → JSON 报告落固定路径。
#
# 与 scripts/acp_e2e.py 的分工：
#   - acp_e2e.py 是**本仓协议行为**的回归（38+ 断言，只覆盖 atelier 自己定义的行为，全离线）
#   - 本脚本跑**官方一致性套件**：判断「atelier acp 是否实现 ACP v1 的协议要求」，
#     覆盖范围随上游演进，atelier 只对结论负责，不受本仓用例控制
#
# 两个必须预置的 env（否则不是「失败」而是「全量 skip/启动失败」）：
#   HOME                     → 工作区内可写目录。DSH 沙箱下 ~/.atelier 只读，
#                              用真 HOME 会让每个 session/new 都失败
#   ATELIER_ECHO_DELAY_MS    → 取消类用例要有「回合还在跑」的窗口，否则 ACP-CANCEL-* 全 skip
#
# 用法：
#   scripts/acp_tck.sh                 # 全量
#   scripts/acp_tck.sh -k "list or mcp"  # 只跑匹配的用例（透传给 acp-tck）
#   ATELIER_BIN=/path/to/cli.app scripts/acp_tck.sh
#
# 退出码：0 = 全量 verdict 为 CONFORMANT；1 = 有 FAIL（报告里能查到名单）；
#         2 = 环境/前置不满足（binary 缺失、TCK 拉不下来等）
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
WS_ROOT=$(cd "$REPO_ROOT/.." && pwd)

TCK_DIR=${TCK_DIR:-$WS_ROOT/.tmp-acp-tck}
TCK_REPO=${TCK_REPO:-https://github.com/agentclientprotocol/acp-tck.git}
TCK_HOME=${TCK_HOME:-$WS_ROOT/.tmp-acp-home}
ATELIER_BIN=${ATELIER_BIN:-$REPO_ROOT/target/release/bin/cli.app}
REPORT=${REPORT:-$REPO_ROOT/target/acp-tck-report.json}
ECHO_DELAY_MS=${ATELIER_ECHO_DELAY_MS:-1200}
CANCEL_PROMPT=${CANCEL_PROMPT:-写一段两千字的散文，慢慢写}

log() { echo "[acp_tck] $*" >&2; }
die() { log "ERROR: $*"; exit 2; }

[ -x "$ATELIER_BIN" ] || die "找不到可执行文件 $ATELIER_BIN（先 cjpm build -j 4）"
command -v uv >/dev/null 2>&1 || die "需要 uv 运行 TCK（uv run acp-tck）"

# TCK：没有就克隆，有就复用（不自动 pull：上游换 schema 会让历史结论不可比，
# 要升级时手动 git -C $TCK_DIR pull，升级后重跑基线并记录数字）
if [ ! -d "$TCK_DIR/.git" ]; then
    log "克隆 TCK 到 $TCK_DIR"
    git clone --depth 1 "$TCK_REPO" "$TCK_DIR" >&2 || die "克隆失败：$TCK_REPO"
fi
[ -d "$TCK_DIR/tests" ] || [ -d "$TCK_DIR/src/tck" ] || die "$TCK_DIR 不像 TCK 仓"

mkdir -p "$TCK_HOME" "$(dirname "$REPORT")"

log "agent    = $ATELIER_BIN acp"
log "tck      = $TCK_DIR ($(git -C "$TCK_DIR" rev-parse --short HEAD 2>/dev/null))"
log "HOME     = $TCK_HOME"
log "report   = $REPORT"

# 跑全量；-k 等附加参数原样透传（放前面，-- 之后是 agent 命令，不能被截走）
cd "$TCK_DIR" || die "进不去 $TCK_DIR"
uv run acp-tck \
    --agent-env ATELIER_PROVIDER=echo \
    --agent-env ATELIER_ECHO_DELAY_MS="$ECHO_DELAY_MS" \
    --agent-env HOME="$TCK_HOME" \
    --agent-cwd "$TCK_HOME" \
    --timeout 60 \
    --test-timeout 240 \
    --cancel-prompt "$CANCEL_PROMPT" \
    --report-json "$REPORT" \
    "$@" \
    -- "$ATELIER_BIN" acp
rc=$?
log "acp-tck 退出码: $rc（结论以报告为准，见下）"

# 汇总：报告里 FAIL 的 requirement 名单（acp-tck 的 stdout 很长，名单以 JSON 为准）。
# 退出码由报告判定而不是 pytest 的退出码：acp-tck 在「有 SKIP 但无 FAIL」时也会给
# NOT CONFORMANT（能力未实现属于 skip），那不是本脚本要拦的回归。
fails=0
if [ -f "$REPORT" ]; then
    python3 - "$REPORT" <<'PY' || die "报告解析失败：$REPORT"
import json, sys
from collections import Counter
rep = json.load(open(sys.argv[1]))
reqs = rep.get("requirements", [])
counts = Counter(r["status"] for r in reqs)
fails = [r for r in reqs if r["status"] == "FAIL"]
print("[acp_tck] %s requirement: %s" % (len(reqs), dict(counts)))
for r in fails:
    names = ", ".join(t["nodeid"].split("::")[-1] for t in r.get("tests", []) if t.get("status") == "FAIL")
    print("[acp_tck] FAIL %s (%s) %s" % (r["id"], r["tier"], names))
print("[acp_tck] FAIL 条数: %d" % len(fails))
sys.exit(1 if fails else 0)
PY
    fails=$?
else
    log "ERROR: 没有生成报告 $REPORT"
    fails=1
fi

exit $fails

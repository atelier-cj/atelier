#!/bin/bash
# 跨进程子 Agent（ACP 桥）端到端：隔离 HOME（子进程数据隔离，不用生产配置）+ echo 模式
set -e
cd "$(dirname "$0")/.."
eval "$(cjvs env bash)" && eval "$(cjvs stdx-env bash)"
cjpm build -j 16
(cd cli && cjpm build -j 16)          # 子进程可执行 = cli 项目的 cli.app
export HOME=$(mktemp -d /tmp/atelier-rm-XXXXXX)
export ATELIER_PROVIDER=echo
trap 'rm -rf "$HOME"' EXIT
ATELIER_PROVIDER=echo cjpm test --no-progress --filter 'subagent_remoteBridge_e2e' --show-all-output 2>&1 | grep -E "PASSED|FAILED|ERROR" | tail -4

#!/usr/bin/env bash
# copy-python-runtime.sh — 逐腿 python 运行时四子树拷贝（fail-closed）
#
# 2026-09-07（0.1.13 B1）：原 release.yml 各腿以
#   [ -d "$p" ] && cp -r "$p" "$STAGE_DIR/lib/" || true
# 静默吞缺件——C2b/U11 教训（python/TUI 子树曾整腿静默缺失，仅靠发布
# 预检兜底，浪费整条 rc run）。本脚本任一子树缺失即失败退出；调用侧
# `|| { echo ::error; exit 1; }` 保证无 set -e 的腿也中止。
# 四子树与 publish REQUIRED_SUBTREE 断言对齐，为产品完整性必需：
#   lib/{airymax_agents, airymax_agents_rs, orchestration, agentrt}
# 用法: copy-python-runtime.sh <STAGE_DIR>
set -u
STAGE_DIR="${1:-}"
if [ -z "$STAGE_DIR" ]; then
    echo "::error::copy-python-runtime: 缺 STAGE_DIR 参数" >&2
    exit 2
fi
mkdir -p "$STAGE_DIR/lib"
for p in \
    agent-workload/ecosystem/agents/airymax_agents \
    agent-workload/ecosystem/agents/airymax_agents_rs \
    agent-workload/ecosystem/agents/orchestration \
    agent-workload/sdk/sdk-python/agentrt; do
    if [ ! -d "$p" ]; then
        echo "::error::python 运行时子树缺失: ${p}（lib/ 四子树为发布完整性必需）" >&2
        exit 1
    fi
    cp -r "$p" "$STAGE_DIR/lib/" || {
        echo "::error::python 子树拷贝失败: $p -> $STAGE_DIR/lib/" >&2
        exit 1
    }
done
echo "python 运行时四子树已入包: $STAGE_DIR/lib"

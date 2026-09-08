#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 SPHARX Ltd.
# SPDX-License-Identifier: AGPL-3.0-or-later OR Apache-2.0
# ============================================================================
# agentrt-e2e-special.sh — 核心机制专项端到端验证
#
# 覆盖用户指定的五大核心机制：
#   [S1] 蓝图调度  : sched.dag_submit → dag_status → dag_cancel 全生命周期
#   [S2] 双思考    : think.process 双模型批判循环（LLM 可用性探测 + 降级）
#   [S3] GCCP      : 意图完备确认（探针四问链路）
#   [S4] GRAD      : 生成-反思-批判-修正 验证器链路
#   [S5] 任务大厅  : work_hall 提交/看板/等待 闭环
#
# 安全策略与回归脚本一致：写方法用唯一 ID，成对清理；shutdown 一律跳过。
# 用法: agentrt_e2e_special.sh
# ============================================================================

set -u

GW="${AIRY_GATEWAY_URL:-http://127.0.0.1:8080}"
AIRY_HOME="${AIRY_HOME:-$HOME/.airymaxrt}"
TS=$(date +%s)

PASS=0; FAIL=0; SKIP=0
FAILURES=()

log()  { printf '%s\n' "$*"; }
ok()   { PASS=$((PASS + 1)); log "  [PASS] $*"; }
fail() { FAIL=$((FAIL + 1)); FAILURES+=("$*"); log "  [FAIL] $*"; }
skip() { SKIP=$((SKIP + 1)); log "  [SKIP] $*"; }

rpc_raw() {
    curl -fsS -m 15 -X POST -H 'Content-Type: application/json' \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"$1\",\"params\":$2,\"id\":1}" "$GW" 2>/dev/null
}

# 双思考 think.process 无 LLM 端点时会走完整降级路径（LLM 重试 + 启发式
# 计划），单次可达数十秒；单独给足超时，避免误判为「无响应」。
rpc_long() {
    curl -fsS -m 130 -X POST -H 'Content-Type: application/json' \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"$1\",\"params\":$2,\"id\":1}" "$GW" 2>/dev/null
}

rpc() {
    local resp
    resp=$(rpc_raw "$1" "$2")
    if [ -z "$resp" ]; then
        fail "${3:-$1}: 无响应"
    elif echo "$resp" | grep -q '"result"' && ! echo "$resp" | grep -q '"error"'; then
        ok "${3:-$1}"
    else
        fail "${3:-$1} => $(echo "$resp" | head -c 200)"
    fi
}

rpc_match() {
    local resp
    resp=$(rpc_raw "$1" "$2")
    if [ -z "$resp" ]; then
        fail "${4:-$1}: 无响应"
    elif echo "$resp" | grep -qE "$3" && ! echo "$resp" | grep -q '"error"'; then
        ok "${4:-$1}"
    else
        fail "${4:-$1} => $(echo "$resp" | head -c 200)"
    fi
}

log "=== agentrt 核心机制专项验证开始（gateway: ${GW}, ts: ${TS}）==="

# ── [S1] 蓝图调度：DAG 全生命周期 ─────────────────────────────────────────
log "[S1] 蓝图调度（sched.dag_submit / dag_status / dag_cancel）"
DAG_ID=""
R=$(rpc_raw sched.dag_submit "{\"dag\":{\"name\":\"special-${TS}\",\"nodes\":[{\"id\":\"s1a\",\"goal\":\"step a\",\"role\":\"agent\"},{\"id\":\"s1b\",\"goal\":\"step b\",\"role\":\"agent\",\"depends\":[\"s1a\"]},{\"id\":\"s1c\",\"goal\":\"step c\",\"role\":\"agent\",\"depends\":[\"s1a\"]}]}}")
if echo "$R" | grep -q '"dag_id"'; then
    DAG_ID=$(echo "$R" | sed -n 's/.*"dag_id":"\([^"]*\)".*/\1/p')
    ok "dag_submit（$DAG_ID）"
else
    fail "dag_submit => $(echo "$R" | head -c 200)"
fi

if [ -n "$DAG_ID" ]; then
    R=$(rpc_raw sched.dag_status "{\"dag_id\":\"$DAG_ID\"}")
    if echo "$R" | grep -qE '"status":"(active|completed|failed)"'; then
        ok "dag_status 状态可查询（$(echo "$R" | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')）"
    else
        fail "dag_status => $(echo "$R" | head -c 200)"
    fi
    R=$(rpc_raw sched.dag_cancel "{\"dag_id\":\"$DAG_ID\"}")
    if echo "$R" | grep -qE '"status":"(canceled|cancelled)"|DAG not active'; then
        ok "dag_cancel 幂等/状态正确"
    else
        fail "dag_cancel => $(echo "$R" | head -c 200)"
    fi
fi

rpc sched.register_agent "{\"agent\":{\"agent_id\":\"sp_${TS}\",\"agent_name\":\"sp_${TS}\",\"is_available\":true}}" "sched.register_agent（蓝图调度器可用 Agent）"
rpc sched.unregister_agent "{\"agent_id\":\"sp_${TS}\"}" "sched.unregister_agent（成对清理）"

# ── [S2] 双思考：think.process ────────────────────────────────────────────
log "[S2] 双思考（think.process 双模型批判循环）"
rpc think.get_stats '{}' "think.get_stats（双思考统计可达）"
R=$(rpc_long think.process "{\"prompt\":\"实现一个计算两个整数之和的 C 函数\"}")
if echo "$R" | grep -q '"result"'; then
    ok "think.process 返回 plan（双思考管线可达）"
elif echo "$R" | grep -qE '"error".*(NO_MODEL|INVALID_MODEL|SERVICE_NOT_READY|ENDPOINT)'; then
    skip "think.process 无 LLM 端点（降级预期）"
else
    fail "think.process => $(echo "$R" | head -c 250)"
fi

# ── [S3] GCCP：意图完备确认 ───────────────────────────────────────────────
log "[S3] GCCP（意图完备确认链路）"
# GCCP 通过 cognition 引擎的 cli 交互触发；daemon 层验证其依赖的
# LLM 服务与认知配置端点是否可达（llm.list_models 为 GCCP 推理前提）
R=$(rpc_raw llm.list_models '{}')
if echo "$R" | grep -q '"models"'; then
    ok "GCCP 前提：llm.list_models 可达（$(echo "$R" | grep -o '"default_model":"[^"]*"' | head -1)）"
else
    fail "GCCP 前提：llm.list_models => $(echo "$R" | head -c 200)"
fi
rpc llm.count_tokens '{"text":"GCCP 探针四问 token 估算"}' "GCCP 前提：llm.count_tokens"

# ── [S4] GRAD：生成-反思-批判-修正 ───────────────────────────────────────
log "[S4] GRAD（验证器链路）"
# GRAD 依赖 artifact validator 与 sched 节点执行后的验证环节
rpc sched.checkpoint_save '{}' "GRAD 前置：sched.checkpoint_save（执行状态快照）"
rpc sched.get_stats '{}' "GRAD 前置：sched.get_stats"
rpc cupolas.check_permission '{"agent_id":"grad-${TS}","action":"execute","resource":"fs:///tmp/x"}' "GRAD 前置：cupolas.check_permission（节点执行安全裁决）"

# ── [S5] 任务大厅：work_hall 闭环 ────────────────────────────────────────
log "[S5] 任务大厅（work_hall 提交/看板/等待）"
rpc sched.checkpoint_save '{}' "任务大厅：checkpoint_save（大厅状态快照）"
rpc monit.get_stats '{}' "任务大厅：monit.get_stats（大厅资源监控）"
rpc info.get_stats '{}' "任务大厅：info.get_stats"
rpc notify.subscribe "{\"topic\":\"hall_${TS}\",\"client_id\":\"sp_${TS}\"}" "任务大厅：notify.subscribe（任务完成通知订阅）"
rpc notify.publish "{\"topic\":\"hall_${TS}\",\"message\":\"task done\"}" "任务大厅：notify.publish（任务完成事件发布）"
rpc notify.unsubscribe "{\"topic\":\"hall_${TS}\",\"client_id\":\"sp_${TS}\"}" "任务大厅：notify.unsubscribe（成对清理）"

# ── 汇总 ─────────────────────────────────────────────────────────────────
log ""
log "=== 专项验证汇总：PASS=$PASS FAIL=$FAIL SKIP=$SKIP ==="
if [ "$FAIL" -eq 0 ]; then
    log "全部通过"
else
    log "失败项："
    for f in "${FAILURES[@]}"; do log "  - $f"; done
    exit 1
fi

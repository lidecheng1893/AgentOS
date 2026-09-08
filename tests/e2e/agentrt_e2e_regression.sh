#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 SPHARX Ltd.
# SPDX-License-Identifier: AGPL-3.0-or-later OR Apache-2.0
# ============================================================================
# agentrt-e2e-regression.sh — 全 daemon 命名空间 RPC 方法端到端回归测试
#
# 经 gateway JSON-RPC（默认 http://127.0.0.1:8080）逐一调用全部命名空间方法，
# 断言成功响应特征或预期错误码，输出 PASS/FAIL/SKIP 汇总。
#
# 安全策略：
#   - 只读方法（list/count/get_stats/health_check 等）全量断言
#   - 无副作用写方法（register/record 等）用唯一 ID，成对清理（unregister/close/delete）
#   - 需外部资源的方法（agent.spawn / llm.complete / tool.execute / plugin.load /
#     think.process / sched.schedule_task / market.install / a2a.send_message）
#     仅验证缺参/不存在实体的错误路径
#   - <ns>.shutdown 一律跳过（会真实退出 daemon）
#
# 用法：
#   agentrt_e2e_regression.sh                 # 默认 gateway http://127.0.0.1:8080
#   AIRY_GATEWAY_URL=http://127.0.0.1:8080 agentrt_e2e_regression.sh
#   agentrt_e2e_regression.sh --skip-external # 跳过写方法错误路径验证（仅只读）
# ============================================================================

set -u

GW="${AIRY_GATEWAY_URL:-http://127.0.0.1:8080}"
AIRY_HOME="${AIRY_HOME:-$HOME/.airymaxrt}"
SKIP_EXTERNAL=0
[ "${1:-}" = "--skip-external" ] && SKIP_EXTERNAL=1

PASS=0; FAIL=0; SKIP=0
FAILURES=()
TS=$(date +%s)
RID="e2e_${TS}_$$"

log()  { printf '%s\n' "$*"; }
ok()   { PASS=$((PASS + 1)); log "  [PASS] $*"; }
fail() { FAIL=$((FAIL + 1)); FAILURES+=("$*"); log "  [FAIL] $*"; }
skip() { SKIP=$((SKIP + 1)); log "  [SKIP] $*"; }

# rpc <ns.method> <params_json> [desc] —— 断言成功响应（result 存在且无 error）
rpc() {
    local method="$1" params="$2" desc="${3:-$1}"
    local resp
    resp=$(curl -fsS -m 10 -X POST -H 'Content-Type: application/json' \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":$params,\"id\":1}" "$GW" 2>/dev/null)
    if [ -z "$resp" ]; then
        fail "$desc: 无响应（gateway 不可达？）"
    elif echo "$resp" | grep -q '"result"' && ! echo "$resp" | grep -q '"error"'; then
        ok "$desc"
    else
        fail "$desc => $(echo "$resp" | head -c 200)"
    fi
}

# rpc_match <ns.method> <params_json> <正则> [desc] —— 断言 result 匹配正则
rpc_match() {
    local method="$1" params="$2" expect="$3" desc="${4:-$1}"
    local resp
    resp=$(curl -fsS -m 10 -X POST -H 'Content-Type: application/json' \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":$params,\"id\":1}" "$GW" 2>/dev/null)
    if [ -z "$resp" ]; then
        fail "$desc: 无响应"
    elif echo "$resp" | grep -qE "$expect" && ! echo "$resp" | grep -q '"error"'; then
        ok "$desc"
    else
        fail "$desc => $(echo "$resp" | head -c 200)"
    fi
}

# rpc_err <ns.method> <params_json> <错误码> [desc] —— 断言返回指定 JSON-RPC 错误码
rpc_err() {
    local method="$1" params="$2" code="$3" desc="${4:-$1}"
    local resp
    resp=$(curl -fsS -m 10 -X POST -H 'Content-Type: application/json' \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":$params,\"id\":1}" "$GW" 2>/dev/null)
    if [ -z "$resp" ]; then
        fail "$desc: 无响应"
    elif echo "$resp" | grep -q "\"code\":$code"; then
        ok "$desc (err=$code)"
    else
        fail "$desc => $(echo "$resp" | head -c 200)"
    fi
}

log "=== agentrt E2E 回归开始（gateway: ${GW}, 时间戳: ${TS}）==="

# ── gateway ────────────────────────────────────────────────────────────────
log "[gateway_d]"
rpc_match ping '{}' '"status":"ok"' "gateway.ping"

# ── agent_d ────────────────────────────────────────────────────────────────
log "[agent_d]"
rpc_match agent.list '{}' '"agent_ids"|"total"' "agent.list"
rpc_match agent.count '{}' '"count"' "agent.count"
rpc_match agent.health_check '{}' '"healthy":true' "agent.health_check"
rpc agent.get_stats '{}' "agent.get_stats"
rpc_err agent.terminate '{"agent_id":"nonexistent"}' -32601 "agent.terminate(不存在, 错误路径)"
rpc_err agent.cancel '{"request_id":"nope"}' -32602 "agent.cancel(无会话, 错误路径)"
rpc_err agent.invoke '{"agent_id":"nonexistent"}' -32601 "agent.invoke(不存在, 错误路径)"
[ "$SKIP_EXTERNAL" = 0 ] && rpc_err agent.spawn '{}' -32602 "agent.spawn(缺参, 错误路径)"

# ── tool_d ─────────────────────────────────────────────────────────────────
log "[tool_d]"
rpc tool.list_tools '{}' "tool.list_tools"
rpc tool.list '{}' "tool.list(别名)"
rpc_err tool.get_tool '{"tool_id":"nope"}' -32601 "tool.get_tool(不存在, 错误路径)"
rpc tool.health_check '{}' "tool.health_check"
rpc tool.get_stats '{}' "tool.get_stats"
rpc tool.pending '{}' "tool.pending"
rpc_err tool.approve '{"request_id":"x","decision":"allow"}' -32602 "tool.approve(无审批请求, 错误路径)"
rpc_err tool.execute_tool '{"tool_id":"nope","params":{}}' -32603 "tool.execute_tool(未注册, 错误路径)"
[ "$SKIP_EXTERNAL" = 0 ] && rpc_err tool.register '{"tool":{}}' -32602 "tool.register(缺字段, 错误路径)"

# ── hook_d ─────────────────────────────────────────────────────────────────
log "[hook_d]"
rpc_match hook.health '{}' '"healthy"' "hook.health"
rpc_match hook.ping '{}' '"status":"ok"' "hook.ping"
rpc hook.status '{}' "hook.status"
rpc_match hook.list '{}' '"hooks"' "hook.list"
rpc_err hook.stats '{"name":"nope"}' -32601 "hook.stats(不存在, 错误路径)"
rpc hook.health_check '{}' "hook.health_check"
rpc hook.get_stats '{}' "hook.get_stats"
HOOK_N="t_hook_${TS}"
rpc hook.register "{\"name\":\"$HOOK_N\",\"type\":\"pre_exec\",\"impl\":\"shell\",\"script_path\":\"/bin/true\"}" "hook.register($HOOK_N)"
rpc hook.unregister "{\"name\":\"$HOOK_N\"}" "hook.unregister($HOOK_N, 成对清理)"
rpc_match hook.trigger '{"type":"pre_exec"}' '"decision"' "hook.trigger(空注册表, continue)"

# ── plugin（0.1.9 M4：plugin.* 经 gateway 转发 tool_d 的 plugin_* 方法）───
log "[plugin→tool_d]"
rpc_err plugin.get_metadata '{"name":"nope"}' -32601 "plugin.get_metadata(不存在, 错误路径)"
rpc plugin.get_state '{"name":"nope"}' "plugin.get_state(任意 name 返回状态)"
rpc_err plugin.get_stats '{"name":"nope"}' -32601 "plugin.get_stats(不存在, 错误路径)"
rpc_match plugin.list '{}' '"plugins"' "plugin.list"
rpc plugin.health_check '{}' "plugin.health_check"
rpc_err plugin.unload '{"name":"nope"}' -32603 "plugin.unload(不存在, 错误路径)"
rpc_err plugin.start '{"name":"nope"}' -32603 "plugin.start(不存在, 错误路径)"
rpc_err plugin.stop '{"name":"nope"}' -32603 "plugin.stop(不存在, 错误路径)"
rpc_err plugin.execute '{"name":"nope","input":"x"}' -32603 "plugin.execute(不存在, 错误路径)"
[ "$SKIP_EXTERNAL" = 0 ] && rpc_err plugin.load '{"library_path":"/nonexistent.so"}' -32603 "plugin.load(路径不存在, 错误路径)"

# ── think_d ────────────────────────────────────────────────────────────────
log "[think_d]"
rpc think.get_stats '{}' "think.get_stats"
rpc_match think.health_check '{}' '"healthy":true' "think.health_check"
rpc_err think.process '{"prompt":""}' -32602 "think.process(空 prompt, 错误路径)"
rpc_err think.orchestrate '{}' -32602 "think.orchestrate(缺 input, fail-closed)"
rpc_err think.orchestrate '{"input":""}' -32602 "think.orchestrate(空 input, fail-closed)"

# ── monit_d ────────────────────────────────────────────────────────────────
log "[monit_d]"
rpc monit.get_metrics '{}' "monit.get_metrics"
rpc monit.metrics '{}' "monit.metrics(别名)"
rpc monit.get_alerts '{}' "monit.get_alerts"
rpc monit.health_check '{}' "monit.health_check"
rpc monit.generate_report '{}' "monit.generate_report"
rpc monit.heartbeat '{}' "monit.heartbeat"
rpc monit.get_stats '{}' "monit.get_stats"
MT="t_metric_${TS}"
rpc_match monit.record_metric "{\"metric\":{\"name\":\"$MT\",\"value\":1.0}}" '"recorded"' "monit.record_metric($MT)"
AT="t_alert_${TS}"
rpc_match monit.trigger_alert "{\"alert\":{\"alert_id\":\"$AT\",\"message\":\"e2e\",\"level\":1}}" '"triggered"' "monit.trigger_alert($AT)"
rpc monit.alert_raise "{\"alert\":{\"alert_id\":\"${AT}_2\",\"message\":\"e2e\"}}" "monit.alert_raise(别名)"
rpc_err monit.alert_resolve '{"alert_id":"nope"}' -32601 "monit.alert_resolve(不存在, 错误路径)"
rpc_match monit.alert_resolve "{\"alert_id\":\"$AT\"}" '"resolved"' "monit.alert_resolve($AT, 成对清理)"

# ── sched_d ────────────────────────────────────────────────────────────────
log "[sched_d]"
rpc_err sched.get_task '{"task_id":"nope"}' -32603 "sched.get_task(不存在, 错误路径)"
rpc_err sched.query '{"task_id":"nope"}' -32603 "sched.query(别名, 错误路径)"
rpc_err sched.dag_status '{"dag_id":"nope"}' -32603 "sched.dag_status(不存在, 错误路径)"
rpc sched.get_stats '{}' "sched.get_stats"
rpc sched.health_check '{}' "sched.health_check"
rpc sched.checkpoint_save '{}' "sched.checkpoint_save"
RA="t_role_${TS}"
rpc_match sched.register_agent "{\"agent\":{\"agent_id\":\"$RA\",\"agent_name\":\"$RA\",\"is_available\":true}}" '"registered"' "sched.register_agent($RA)"
rpc_err sched.cancel '{"task_id":"nope"}' -32602 "sched.cancel(不存在, 错误路径)"
rpc_err sched.dag_cancel '{"dag_id":"nope"}' -32602 "sched.dag_cancel(不存在, 错误路径)"
[ "$SKIP_EXTERNAL" = 0 ] && rpc_err sched.schedule_task '{"task":{}}' -32602 "sched.schedule_task(缺字段, 错误路径)"

# ── channel_d ──────────────────────────────────────────────────────────────
log "[channel_d]"
rpc_match channel.ping '{}' '"status":"ok"' "channel.ping"
rpc_match channel.list '{}' '"channels"' "channel.list"
rpc channel.health '{}' "channel.health"
rpc channel.health_check '{}' "channel.health_check(别名)"
rpc channel.get_stats '{}' "channel.get_stats"
CH="ch_${TS}"
rpc_match channel.open "{\"id\":\"$CH\",\"name\":\"e2e\"}" '"opened"' "channel.open($CH)"
rpc_match channel.send "{\"id\":\"$CH\",\"data\":\"hello e2e\"}" '"sent"' "channel.send($CH)"
rpc_err channel.send '{"id":"$CH","data":123}' -32602 "channel.send(非字符串 data, fail-closed)"
rpc_match channel.close "{\"id\":\"$CH\"}" '"closed"' "channel.close($CH, 成对清理)"
rpc_err channel.send "{\"id\":\"$CH\",\"data\":\"x\"}" -32603 "channel.send(已关闭, 错误路径)"

# ── market_d ───────────────────────────────────────────────────────────────
log "[market_d]"
rpc market.search_agents '{}' "market.search_agents"
rpc market.search '{}' "market.search(别名)"
rpc market.search_skills '{}' "market.search_skills"
rpc market.health_check '{}' "market.health_check"
rpc market.get_stats '{}' "market.get_stats"
MA="reg_${TS}"
rpc_match market.register_agent "{\"agent\":{\"agent_id\":\"$MA\",\"name\":\"e2e\",\"version\":\"1.0.0\"}}" '"registered"' "market.register_agent($MA)"
MS="skill_${TS}"
rpc_match market.register_skill "{\"skill\":{\"skill_id\":\"$MS\",\"name\":\"e2e\",\"version\":\"1.0.0\"}}" '"registered"' "market.register_skill($MS)"
[ "$SKIP_EXTERNAL" = 0 ] && rpc_match market.install_agent "{\"agent_id\":\"$MA\"}" '"installed"' "market.install_agent($MA, 本地注册即安装)"

# ── llm_d ──────────────────────────────────────────────────────────────────
log "[llm_d]"
rpc_match llm.list_models '{}' '"models"' "llm.list_models(本地 registry, 无需 key)"
rpc_match llm.count_tokens '{"text":"hello world"}' '"tokens"' "llm.count_tokens"
rpc llm.health_check '{}' "llm.health_check"
rpc llm.get_stats '{}' "llm.get_stats"
rpc_err llm.count_tokens '{}' -32602 "llm.count_tokens(缺参, 错误路径)"
rpc_err llm.complete '{"messages":[]}' -32602 "llm.complete(空消息数组, fail-closed)"
rpc_err llm.complete '{"model":"default"}' -32602 "llm.complete(缺 messages, fail-closed)"

# ── cupolas_d ──────────────────────────────────────────────────────────────
log "[cupolas_d]"
rpc cupolas.check_permission '{"agent_id":"agent-1","action":"read","resource":"fs:///tmp/x"}' "cupolas.check_permission"
rpc cupolas.sanitize '{"input":"<script>alert(1)</script>"}' "cupolas.sanitize"
rpc_match cupolas.execute_command '{"command":"echo","argv":["hello"]}' '"exit_code":0' "cupolas.execute_command(echo, 安全只读)"
rpc_match cupolas.add_rule '{"resource":"fs:///tmp/e2e_*","allow":false,"priority":10}' '"added"' "cupolas.add_rule(deny 规则)"
rpc cupolas.audit_flush '{}' "cupolas.audit_flush"
rpc cupolas.health_check '{}' "cupolas.health_check"
rpc cupolas.get_stats '{}' "cupolas.get_stats"

# M2-S2/S3（0.1.9 §3.2 PDP）：policy.* 两段式生效——load 暂存不生效、
# activate 提交运行集（epoch+1 + 广播），deny-wins 裁决翻转可经
# cupolas.check_permission 观测；写操作需 cap:cupolas.admin 授权。
POLY="e2e_pol_${TS}"
rpc_match policy.status '{}' '"rule_count"' "policy.status(基线)"
rpc_match policy.load "{\"json\":\"{\\\"rules\\\":[{\\\"id\\\":\\\"${POLY}\\\",\\\"effect\\\":\\\"deny\\\",\\\"resource\\\":\\\"fs:///tmp/${POLY}\\\"}]}\"}" '"staged":true' "policy.load(${POLY} 暂存 deny 规则)"
rpc_match policy.status '{}' '"staged_rule_count":1' "policy.status(load 后已暂存未生效)"
rpc_match policy.activate '{}' '"rule_count":1' "policy.activate(${POLY} 提交运行集)"
rpc_match cupolas.check_permission "{\"agent_id\":\"pol-e2e\",\"action\":\"read\",\"resource\":\"fs:///tmp/${POLY}\"}" '"allowed":false' "check_permission(PDP deny 生效)"
rpc_match policy.load "{\"json\":\"{\\\"rules\\\":[]}\"}" '"staged":true' "policy.load(暂存空集)"
rpc_match policy.activate '{}' '"rule_count":0' "policy.activate(清空动态策略, 回退基础)"

# 接线断言：vault / net / entitlements 三个安全子模块（cupolas_d 17 方法）
CRED="e2e_cred_${TS}"
rpc_match cupolas.vault_store "{\"cred_id\":\"$CRED\",\"type\":1,\"data\":\"736b2d74657374\",\"agent_id\":\"agent-e2e\"}" '"stored"' "cupolas.vault_store($CRED)"
rpc_match cupolas.vault_retrieve "{\"cred_id\":\"$CRED\",\"agent_id\":\"agent-e2e\"}" '"data"' "cupolas.vault_retrieve(属主命中)"
rpc_err cupolas.vault_retrieve "{\"cred_id\":\"$CRED\",\"agent_id\":\"agent-other\"}" -32603 "cupolas.vault_retrieve(非属主, ACL 拒绝)"
rpc_match cupolas.vault_list '{"type":0}' '"cred_id"' "cupolas.vault_list"
rpc_match cupolas.vault_delete "{\"cred_id\":\"$CRED\",\"agent_id\":\"agent-e2e\"}" '"deleted"' "cupolas.vault_delete($CRED, 成对清理)"
# vault_rotate：凭证组轮换（组 = cred_id 前缀，ROUND_ROBIN 选 updated_at 最旧者）
R1="e2e_rot_${TS}:k1"
R2="e2e_rot_${TS}:k2"
rpc_match cupolas.vault_store "{\"cred_id\":\"$R1\",\"type\":1,\"data\":\"736b2d74657374\",\"agent_id\":\"agent-e2e\"}" '"stored"' "cupolas.vault_store($R1)"
rpc_match cupolas.vault_store "{\"cred_id\":\"$R2\",\"type\":1,\"data\":\"736b2d74657374\",\"agent_id\":\"agent-e2e\"}" '"stored"' "cupolas.vault_store($R2)"
rpc_match cupolas.vault_rotate "{\"cred_group\":\"e2e_rot_${TS}\",\"strategy\":1}" '"selected_id"' "cupolas.vault_rotate($R1/$R2 组内选中)"
rpc_match cupolas.vault_delete "{\"cred_id\":\"$R1\",\"agent_id\":\"agent-e2e\"}" '"deleted"' "cupolas.vault_delete($R1, 成对清理)"
rpc_match cupolas.vault_delete "{\"cred_id\":\"$R2\",\"agent_id\":\"agent-e2e\"}" '"deleted"' "cupolas.vault_delete($R2, 成对清理)"
NETRULE="e2e_net_${TS}"
rpc_match cupolas.net_add_rule "{\"rule_id\":\"$NETRULE\",\"dst_ip\":\"10.99.0.0/16\",\"dst_port\":\"8443\",\"protocol\":1,\"direction\":2,\"action\":0}" '"added"' "cupolas.net_add_rule($NETRULE)"
rpc_match cupolas.net_check_access '{"host":"10.99.1.1","port":8443,"protocol":1,"direction":"outbound"}' '"allowed"' "cupolas.net_check_access(命中规则)"
rpc cupolas.net_get_stats '{}' "cupolas.net_get_stats"
# entitlements 测试夹具：运行时生成（不依赖安装器预置），验证 load + 裁决链路。
# check_syscall 走 allowed_syscalls 白名单，不要求签名校验；read 允许、fork 拒绝。
ENT_YAML="$AIRY_HOME/config/security/test_entitlements.yaml"
mkdir -p "$(dirname "$ENT_YAML")"
cat > "$ENT_YAML" <<'YAML_EOF'
agent_id: e2e-test-agent
version: "1.0.0"
allowed_syscalls: [read, write, open, close, mmap, munmap, brk, fstat]
YAML_EOF
rpc_match cupolas.entitlements_load '{"yaml_path":"'"$ENT_YAML"'"}' '"loaded"' "cupolas.entitlements_load"
rpc_match cupolas.entitlements_check '{"kind":"syscall","param1":"read"}' '"allowed":true' "cupolas.entitlements_check(syscall read 允许)"
rpc_match cupolas.entitlements_check '{"kind":"syscall","param1":"fork"}' '"allowed":false' "cupolas.entitlements_check(syscall fork 拒绝)"

# ── mem_d ──────────────────────────────────────────────────────────────────
log "[mem_d]"
rpc_match mem.search '{"query":"hello"}' '"results"' "mem.search"
rpc_match mem.count '{}' '"count"' "mem.count"
rpc mem.health_check '{}' "mem.health_check"
rpc mem.get_stats '{}' "mem.get_stats"
MEM_RESP=$(curl -fsS -m 10 -X POST -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"mem.write\",\"params\":{\"data\":\"e2e record $TS\",\"metadata\":{\"src\":\"regression\"}},\"id\":1}" "$GW" 2>/dev/null)
MEM_ID=$(echo "$MEM_RESP" | sed -n 's/.*"record_id":"\([^"]*\)".*/\1/p')
if [ -n "$MEM_ID" ]; then
    ok "mem.write(record_id=$MEM_ID)"
    rpc_match mem.get "{\"record_id\":\"$MEM_ID\"}" '"data"' "mem.get(命中)"
    rpc_match mem.evolve "{\"query\":\"e2e\"}" '"status"' "mem.evolve"
    rpc_match mem.delete "{\"record_id\":\"$MEM_ID\"}" '"deleted"' "mem.delete($MEM_ID, 成对清理)"
else
    fail "mem.write => $MEM_RESP"
fi
rpc_err mem.get '{"record_id":"nonexistent"}' -32601 "mem.get(不存在, 错误路径)"

# ── a2a_d ──────────────────────────────────────────────────────────────────
log "[a2a_d]"
rpc_match a2a.discover_agents '{}' '"agents"' "a2a.discover_agents"
rpc a2a.count '{}' "a2a.count"
rpc a2a.health_check '{}' "a2a.health_check"
rpc a2a.get_stats '{}' "a2a.get_stats"
rpc_err a2a.get_task '{"task_id":"nope"}' -32601 "a2a.get_task(不存在, 错误路径)"
rpc_err a2a.receive '{"task_id":"nope"}' -32601 "a2a.receive(别名, 错误路径)"
AA="agent-${TS}"
rpc_match a2a.register_agent "{\"id\":\"$AA\",\"name\":\"e2e\"}" '"registered"' "a2a.register_agent($AA)"
TASK_RESP=$(curl -fsS -m 10 -X POST -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"a2a.create_task\",\"params\":{\"agent_id\":\"$AA\",\"description\":\"e2e\"},\"id\":1}" "$GW" 2>/dev/null)
TASK_ID=$(echo "$TASK_RESP" | sed -n 's/.*"task":{"id":"\([^"]*\)".*/\1/p' | head -1)
if [ -n "$TASK_ID" ]; then
    ok "a2a.create_task(task_id=$TASK_ID)"
    rpc_match a2a.get_task "{\"task_id\":\"$TASK_ID\"}" '"task"' "a2a.get_task(命中)"
    rpc_match a2a.update_task "{\"task_id\":\"$TASK_ID\",\"state\":2}" '"updated"' "a2a.update_task($TASK_ID)"
    rpc_match a2a.cancel_task "{\"task_id\":\"$TASK_ID\"}" '"canceled"' "a2a.cancel_task($TASK_ID)"
else
    fail "a2a.create_task => $TASK_RESP"
fi
rpc_match a2a.unregister_agent "{\"agent_id\":\"$AA\"}" '"unregistered"' "a2a.unregister_agent($AA, 成对清理)"
[ "$SKIP_EXTERNAL" = 0 ] && rpc_match a2a.send_message "{\"target_agent_id\":\"$AA\",\"role\":\"user\",\"content\":\"hi\"}" '"responses"' "a2a.send_message(离线目标, ack 语义)"

# ── monit_d:info（0.1.9 M4：原 info_d 并入 monit_d，外部 cap key 不变） ──
log "[monit_d:info]"
rpc_match info.system '{}' '"system"|"platform"' "info.system"
rpc info.history '{}' "info.history"
rpc info.health '{}' "info.health"
rpc info.hardware '{}' "info.hardware"
rpc info.health_check '{}' "info.health_check"
rpc info.get_stats '{}' "info.get_stats"

# ── notify_d ───────────────────────────────────────────────────────────────
log "[notify_d]"
rpc_match notify.list '{}' '"subscriptions"' "notify.list"
rpc notify.health '{}' "notify.health"
rpc notify.health_check '{}' "notify.health_check"
rpc notify.get_stats '{}' "notify.get_stats"
NT="ttopic_${TS}"
rpc_match notify.subscribe "{\"topic\":\"$NT\",\"client_id\":\"client_${TS}\"}" '"subscribed"' "notify.subscribe($NT)"
rpc_match notify.publish "{\"message\":\"e2e\",\"topic\":\"$NT\"}" '"queued"' "notify.publish($NT)"
rpc_match notify.unsubscribe "{\"topic\":\"$NT\",\"client_id\":\"client_${TS}\"}" '"unsubscribed"' "notify.unsubscribe($NT, 成对清理)"

# ── monit_d:observe（0.1.9 M4：原 observe_d 并入 monit_d，外部 cap key 不变） ──
log "[monit_d:observe]"
rpc observe.get_stats '{}' "observe.get_stats"
rpc observe.health_check '{}' "observe.health_check"
rpc_match observe.query_metrics '{}' '"metrics"' "observe.query_metrics"
rpc_match observe.get_metrics '{}' '"metrics"' "observe.get_metrics(别名)"
OM="reg_metric_${TS}"
rpc_match observe.record_metric "{\"name\":\"$OM\",\"value\":1.5,\"type\":\"gauge\",\"unit\":\"count\"}" '"recorded"' "observe.record_metric($OM)"
rpc_err observe.record_metric '{"name":"x","value":1,"type":"bogus"}' -32602 "observe.record_metric(非法 type, 错误路径)"

# ── 汇总 ──────────────────────────────────────────────────────────────────
log ""
log "=== 汇总 ==="
log "PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
if [ "$FAIL" -gt 0 ]; then
    log "失败明细："
    for f in "${FAILURES[@]}"; do log "  - $f"; done
    exit 1
fi
log "全部通过"
exit 0

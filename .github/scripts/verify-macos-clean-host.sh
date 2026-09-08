#!/usr/bin/env bash
# verify-macos-clean-host.sh — macOS 干净真机核验（0.1.13 G4b）
#
# 背景：G4 出口的最后真机核验项 = "macOS 干净真机 daemon 群可启"。
#   - 托管 macos runner 为一次性干净 VM，是"干净机"的最强 CI 代理；
#   - 本脚本在 macOS host 上复刻 e2e-clean-room 语义：install.sh
#     --from-file 离线安装打包产物 → 完整启动器拉起 daemon 群 →
#     gateway TCP 探测 → airy_cli /daemons 冒烟（online N/N）。
#   - 与 Linux e2e 不同点：macOS 系统 bash 为 3.2，无 GNU coreutils
#     （sha256sum/seq/readlink -f 均缺失），安装器/启动器/本脚本全部
#     走 shasum -a 256 与 bash 内建（G4b 2026-09-08 修正）。
#
# 判定语义（fail-closed，stdout 为断言面）：
#   阶段 1  离线安装：install.sh --from-file <tarball>，相邻 .sha256
#           先行 shasum -a 256 -c 校验（macOS 无 sha256sum）。
#   阶段 2  完整启动器就位：install.sh 部署 bin/airymaxrt（thin）；管理
#           命令首用会联网拉取 full（latest/airymaxrt）。干净机无网络时
#           由调用方预置 $AH/bin/airymaxrt-full（本脚本第 4 参）。
#   阶段 3  daemon 群拉起：非交互执行完整启动器默认流程（守护进程群
#           就绪 → 前端）。stdin 以命名管道保持打开，启动器前台会话
#           不因 EOF 退出；就绪后由本脚本另行发起 gateway/CLI 探测。
#   阶段 4  gateway TCP：按 run/gateway.port（缺省 8080）探测。
#   阶段 5  CLI 冒烟：$AH/bin/airy_cli -p /daemons，断言 gateway online、
#           无 offline、online N==M 且 M>0。
#   阶段 6  收尾：TERM 启动器 → EXIT trap 回收 daemon 群。
#
# 用法：verify-macos-clean-host.sh <install.sh> <tarball> [airymaxrt-full]
#   第三参存在时预置到 $AH/bin/airymaxrt-full（离线自举，同 U9 语义）。
# 退出码：0=全链通过；非 0=阶段失败。
set -euo pipefail

INSTALLER="${1:?usage: verify-macos-clean-host.sh <install.sh> <tarball> [airymaxrt-full]}"
TARBALL="${2:?usage: verify-macos-clean-host.sh <install.sh> <tarball> [airymaxrt-full]}"
FULL="${3:-}"
AH="$HOME/.airymaxrt"

fail() { echo "::error::$*" >&2; exit 1; }
info() { echo "  -- $*"; }

[ -f "$INSTALLER" ] || fail "install.sh 不存在: $INSTALLER"
[ -f "$TARBALL" ] || fail "tarball 不存在: $TARBALL"
[ "$(uname -s 2>/dev/null)" = "Darwin" ] || fail "本脚本须在 macOS 宿主执行（当前 $(uname -srm)）"

# ─── 阶段 0：宿主出证 ─────────────────────────────────────────────────────
info "宿主: $(uname -srm) | bash $BASH_VERSION | sw_vers: $(sw_vers -productVersion 2>/dev/null || echo '?')"

# ─── 阶段 1：离线安装 ─────────────────────────────────────────────────────
if [ -f "${TARBALL}.sha256" ]; then
    info "sha256 校验（shasum -a 256 -c）"
    ( cd "$(dirname "$TARBALL")" && shasum -a 256 -c "$(basename "${TARBALL}.sha256")" >/dev/null ) \
        || fail "tarball sha256 校验失败"
fi
info "离线安装: $(basename "$TARBALL")"
# 隔离测试环境：确保无历史残留（托管 runner 每次全新，幂等兜底）
rm -rf "$AH"
bash "$INSTALLER" --from-file "$TARBALL" || fail "install.sh --from-file 失败"
for f in "$AH/bin/airy_cli" "$AH/bin/airymaxrt"; do
    [ -e "$f" ] || fail "安装产物缺失: $f"
done
info "安装产物齐备: $AH"

# ─── 阶段 2：完整启动器就位 ───────────────────────────────────────────────
if [ -n "$FULL" ] && [ -f "$FULL" ]; then
    # 离线自举（同 U9）：thin 管理命令联网拉取 full 的对象即此物，跳过网络
    cp -f "$FULL" "$AH/bin/airymaxrt-full" 2>/dev/null || true
    chmod 755 "$AH/bin/airymaxrt-full" 2>/dev/null || true
fi
if [ ! -x "$AH/bin/airymaxrt-full" ]; then
    info "airymaxrt-full 缺失，尝试经 thin 联网自举（doctor）…"
    bash "$AH/bin/airymaxrt" doctor >/dev/null 2>&1 || true
fi
[ -x "$AH/bin/airymaxrt-full" ] || fail "完整启动器不可用（airymaxrt-full）"

# ─── 阶段 3：daemon 群拉起（完整启动器默认流程）─────────────────────────
info "拉起 daemon 群（完整启动器默认流程，健康等待含 gateway）"
CTRL="$AH/tmp/g4b-ctrl.$$"
mkdir -p "$AH/tmp" 2>/dev/null || true
rm -f "$CTRL"; mkfifo "$CTRL" 2>/dev/null || true
# 保持 stdin 写端打开：非 TTY 前端（airy_cli -p）读 stdin，EOF 会让会话退出。
# 注意必须以读写方式（<>）打开 FIFO：只写（>）会在无读者时阻塞 exec，而
# 读者（启动器）要等本行返回后才启动——互相等待死锁（G4b 实测修正）。
exec 9<>"$CTRL"
LOGF="$AH/logs/g4b-clean-host.out"
mkdir -p "$AH/logs" 2>/dev/null || true
# AIRYRT_TERM_LOG=verbose：launcher 文档化排障开关（默认 quiet 时 INFO 只写
# airymaxrt.log 不进 stderr）。核验场景要求启动时序全量可见——stdout+stderr
# 合流 LOGF 后，死点（set -e 静默退出等）可精确到条目级。
AIRYRT_TERM_LOG=verbose bash "$AH/bin/airymaxrt-full" <"$CTRL" >"$LOGF" 2>&1 &
L_PID=$!
# 关闭子进程读端之外的引用；写端 fd9 保持打开
sleep 2

# ─── 阶段 4：gateway TCP 探测 ─────────────────────────────────────────────
GWP=""
if [ -s "$AH/run/gateway.port" ]; then
    GWP="$(sed -n '1s/[^0-9]//gp' "$AH/run/gateway.port" 2>/dev/null | head -1)"
fi
GWP="${GWP:-8080}"
_GW_OK=0
_i=0
while [ "$_i" -lt 120 ]; do
    if (exec 3<>"/dev/tcp/127.0.0.1/$GWP") 2>/dev/null; then
        exec 3>&- 3<&- 2>/dev/null || true
        _GW_OK=1; break
    fi
    _i=$((_i + 1))
    sleep 1
done
if [ "$_GW_OK" != "1" ]; then
    # 日志/状态转 annotation（GitHub job 日志需 admin，annotation 匿名 API
    # 可读，是 CI 台账的证据通道）。逐行 ::error 保证多行都可见。
    echo "::error::gateway TCP 不可达: 127.0.0.1:${GWP}"
    echo "::error::-- launcher 进程状态 --"
    if kill -0 "$L_PID" 2>/dev/null; then
        echo "::error::launcher 仍存活（PID $L_PID）——非 set -e 退出"
    else
        echo "::error::launcher 已退出（PID $L_PID）——疑似 set -e 静默终止"
    fi
    echo "::error::-- launcher 日志尾部（verbose，stdout+stderr 合流）--"
    tail -n 80 "$LOGF" 2>/dev/null | sed 's/^/::error::/; s/%/%25/g; s/\r//g' | head -80 || true
    echo "::error::-- airymaxrt.log 尾部（boot 进度真身，含 debug）--"
    tail -n 120 "$AH/logs/airymaxrt.log" 2>/dev/null | sed 's/^/::error::/; s/%/%25/g; s/\r//g' | head -120 || true
    echo "::error::-- logs/ 目录 --"
    ls -1 "$AH/logs" 2>/dev/null | sed 's/^/::error::/' | head -30 || true
    echo "::error::-- run/ 目录 --"
    ls -1 "$AH/run" 2>/dev/null | sed 's/^/::error::/' | head -20 || true
    echo "::error::-- gateway_d.out --"
    tail -n 20 "$AH/logs/gateway_d.out" 2>/dev/null | sed 's/^/::error::/; s/%/%25/g; s/\r//g' | head -20 || true
    echo "::error::-- 进程表（daemon 群/launcher 残留）--"
    ps aux 2>/dev/null | grep -E '[_]d( |$)|airymax|airy' | head -20 | sed 's/^/::error::/; s/%/%25/g; s/\r//g' || true
    exit 1
fi
info "gateway online（127.0.0.1:$GWP）"

# ─── 阶段 5：CLI 冒烟 ─────────────────────────────────────────────────────
info "CLI 冒烟: airy_cli -p /daemons"
# airy_cli -p 输出到 stdout；启动器自身亦写该日志，直接调用独立进程断言。
# macOS 无 timeout(1)：以后台 + 轮询实现 30s 超时（bash3.2 兼容）。
OUT=""
_i=0
while [ "$_i" -lt 60 ]; do
    _o=""
    "$AH/bin/airy_cli" -p /daemons >"$AH/tmp/g4b-cli.$$" 2>/dev/null &
    _cpid=$!
    _t=0
    while [ "$_t" -lt 30 ] && kill -0 "$_cpid" 2>/dev/null; do
        sleep 1; _t=$((_t + 1))
    done
    if kill -0 "$_cpid" 2>/dev/null; then
        kill -KILL "$_cpid" 2>/dev/null || true
    else
        wait "$_cpid" 2>/dev/null || true
        _o="$(cat "$AH/tmp/g4b-cli.$$" 2>/dev/null || true)"
    fi
    rm -f "$AH/tmp/g4b-cli.$$" 2>/dev/null || true
    if [ -n "$_o" ] && printf '%s' "$_o" | grep -q '^online '; then
        OUT="$_o"; break
    fi
    _i=$((_i + 1))
    sleep 2
done
printf '%s\n' "$OUT" | sed 's/^/    /' | head -30
printf '%s\n' "$OUT" | grep -q "gateway online" || fail "冒烟断言失败: gateway 非 online"
if printf '%s\n' "$OUT" | grep -q " offline"; then
    fail "冒烟断言失败: 存在 offline daemon"
fi
SUMMARY="$(printf '%s\n' "$OUT" | grep -E '^online [0-9]+/[0-9]+$' | tail -1)"
[ -n "$SUMMARY" ] || fail "冒烟断言失败: 缺汇总行 online N/M"
N="${SUMMARY#online }"; N="${N%%/*}"
M="${SUMMARY#*/}"
if [ "$N" != "$M" ] || [ "$M" -le 0 ]; then
    fail "冒烟断言失败: 汇总 $SUMMARY（要求 N==M 且 M>0）"
fi
info "CLI 冒烟通过: $SUMMARY"

# ─── 阶段 6：收尾 ─────────────────────────────────────────────────────────
kill -TERM "$L_PID" 2>/dev/null || true
sleep 3
kill -KILL "$L_PID" 2>/dev/null || true
exec 9>&- 2>/dev/null || true
rm -f "$CTRL"
echo "[OK] macOS 干净真机核验通过: $SUMMARY | gateway 127.0.0.1:$GWP"

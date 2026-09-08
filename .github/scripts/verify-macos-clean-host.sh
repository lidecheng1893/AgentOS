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

# GitHub 匿名证据通道：job log 需 admin，check-run annotation 匿名 API
# 可读；但每 step 上限 10 条，逐行 ::error:: 在长日志下被静默截断
# （rc4-3 实证仅见 3 条）。dump_file 把文件内容按 ≤3800 字符分段、
# 换行编码为 %0A，以多行 message 单条 annotation 输出——10 条内可
# 携带 ~36KB 取证（rc4-4 取证通道改造）。
_ann_seq=0
dump_file() { # dump_file <title> <file>
    _title="$1"; _file="$2"
    [ "$_ann_seq" -lt 9 ] || { info "（annotation 配额已尽，未 dump: $_title）"; return 0; }
    if [ ! -s "$_file" ]; then
        _ann_seq=$((_ann_seq + 1))
        printf '::error::%d) %s: <空>\n' "$_ann_seq" "$_title"
        return 0
    fi
    _sz="$(wc -c <"$_file" 2>/dev/null | tr -d ' ')"
    _off=0; _part=0
    while [ "$_off" -lt "$_sz" ] && [ "$_ann_seq" -lt 9 ]; do
        _ann_seq=$((_ann_seq + 1)); _part=$((_part + 1))
        printf '::error::%d) %s [段%d] bytes %d-%d / 共%s:\n' \
            "$_ann_seq" "$_title" "$_part" "$_off" "$((_off + 3800))" "$_sz"
        tail -c +"$((_off + 1))" "$_file" 2>/dev/null | head -c 3800 \
            | LC_ALL=C tr -d '\r' \
            | LC_ALL=C sed 's/%/%25/g' \
            | LC_ALL=C awk '{ ORS=""; print $0 "%0A" }'
        printf '\n'
        _off=$((_off + 3800))
    done
}

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
mkdir -p "$AH/logs" 2>/dev/null || true
# 安装输出全程捕获：失败时经 annotation 通道出证（job log 需 admin）。
IOUT="$AH/logs/install.out"
if bash "$INSTALLER" --from-file "$TARBALL" >"$IOUT" 2>&1; then
    tail -n 3 "$IOUT" | sed 's/^/    /' || true
else
    _irc=$?
    dump_file "install.sh --from-file 失败（rc=${_irc}）stdout+stderr" "$IOUT"
    { echo "宿主: $(uname -srm) | bash $BASH_VERSION"
      echo "tarball: $TARBALL（$(wc -c <"$TARBALL" 2>/dev/null | tr -d ' ') bytes）"
      echo "-- tar 清单（前 120 项）--"
      tar -tzf "$TARBALL" 2>&1 | head -120
    } >"$AH/logs/install.toc" 2>&1 || true
    dump_file "tarball 清单" "$AH/logs/install.toc"
    fail "install.sh --from-file 失败（rc=${_irc}，证据见 annotation）"
fi
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
    # 取证：launcher 存活/退出态（含 wait rc）→ 单一证据文件 → annotation
    # 分段通道（job log 需 admin，annotation 匿名可读；逐行 ::error:: 受
    # 10 条上限截断，rc4-3 实证——故走 dump_file 多行 message）。
    if kill -0 "$L_PID" 2>/dev/null; then
        L_STATE="仍存活（PID $L_PID）——非 set -e 退出"
    else
        wait "$L_PID" 2>/dev/null
        L_STATE="已退出（PID $L_PID, rc=$?）——set -e 静默终止嫌疑"
    fi
    EV="$AH/logs/g4b-evidence.txt"
    {
        echo "gateway TCP 不可达: 127.0.0.1:${GWP}（探测 ${_i}s）"
        echo "launcher $L_STATE"
        echo "== launcher 日志尾部（AIRYRT_TERM_LOG=verbose，stdout+stderr 合流 LOGF）=="
        tail -n 120 "$LOGF" 2>/dev/null
        echo "== airymaxrt.log 尾部（boot 进度真身，含 debug）=="
        tail -n 150 "$AH/logs/airymaxrt.log" 2>/dev/null
        echo "== logs/ 目录 =="
        ls -la "$AH/logs" 2>/dev/null
        echo "== run/ 目录 =="
        ls -la "$AH/run" 2>/dev/null
        echo "== gateway_d.out 尾部 =="
        tail -n 40 "$AH/logs/gateway_d.out" 2>/dev/null
        echo "== 进程表（daemon 群/launcher 残留）=="
        ps aux 2>/dev/null | grep -E '[_]d( |$)|airymax|airy' | head -20
    } >"$EV" 2>&1 || true
    dump_file "G4b phase4 取证" "$EV"
    exit 1
fi
info "gateway online（127.0.0.1:$GWP）"

# ─── 阶段 5：CLI 冒烟 ─────────────────────────────────────────────────────
info "CLI 冒烟: airy_cli -p /daemons"
# airy_cli -p 输出到 stdout；启动器自身亦写该日志，直接调用独立进程断言。
# macOS 无 timeout(1)：以后台 + 轮询实现 30s 超时（bash3.2 兼容）。
OUT=""
_i=0
CLI_OUT="$AH/logs/g4b-cli.out"
# 冒烟失败时输出经 annotation 通道出证（job log 需 admin）
smoke_fail() { dump_file "CLI 冒烟输出" "$CLI_OUT"; fail "$*"; }
while [ "$_i" -lt 60 ]; do
    _o=""
    "$AH/bin/airy_cli" -p /daemons >"$CLI_OUT" 2>/dev/null &
    _cpid=$!
    _t=0
    while [ "$_t" -lt 30 ] && kill -0 "$_cpid" 2>/dev/null; do
        sleep 1; _t=$((_t + 1))
    done
    if kill -0 "$_cpid" 2>/dev/null; then
        kill -KILL "$_cpid" 2>/dev/null || true
    else
        wait "$_cpid" 2>/dev/null || true
        _o="$(cat "$CLI_OUT" 2>/dev/null || true)"
    fi
    if [ -n "$_o" ] && printf '%s' "$_o" | grep -q '^online '; then
        OUT="$_o"; break
    fi
    _i=$((_i + 1))
    sleep 2
done
printf '%s\n' "$OUT" >"$CLI_OUT" 2>/dev/null || true
printf '%s\n' "$OUT" | sed 's/^/    /' | head -30
printf '%s\n' "$OUT" | grep -q "gateway online" || smoke_fail "冒烟断言失败: gateway 非 online"
if printf '%s\n' "$OUT" | grep -q " offline"; then
    smoke_fail "冒烟断言失败: 存在 offline daemon"
fi
SUMMARY="$(printf '%s\n' "$OUT" | grep -E '^online [0-9]+/[0-9]+$' | tail -1)"
[ -n "$SUMMARY" ] || smoke_fail "冒烟断言失败: 缺汇总行 online N/M"
N="${SUMMARY#online }"; N="${N%%/*}"
M="${SUMMARY#*/}"
if [ "$N" != "$M" ] || [ "$M" -le 0 ]; then
    smoke_fail "冒烟断言失败: 汇总 $SUMMARY（要求 N==M 且 M>0）"
fi
info "CLI 冒烟通过: $SUMMARY"

# ─── 阶段 6：收尾 ─────────────────────────────────────────────────────────
kill -TERM "$L_PID" 2>/dev/null || true
sleep 3
kill -KILL "$L_PID" 2>/dev/null || true
exec 9>&- 2>/dev/null || true
rm -f "$CTRL"
echo "[OK] macOS 干净真机核验通过: $SUMMARY | gateway 127.0.0.1:$GWP"

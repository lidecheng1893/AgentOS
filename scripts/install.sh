#!/bin/sh
# ============================================================================
# Airymax AgentRT 一键安装脚本（唯一官方安装入口）
#
# 位置：agentrt 管理仓 scripts/install.sh（v0.1.2 起自伞仓 scripts/ 迁移，
#       构建系统与安装器属 IRON-9 [IND] 完全独立层，随 agentrt 仓独立演进；
#       伞仓 scripts/ 保留兼容重定向入口）。
# 用法（一键安装。安装器权威源 = agentrt 仓 main 分支 scripts/install.sh：
# release 附件无法覆盖更新（AtomGit API 不支持替换附件），git push 即时
# 生效，经 v5 contents API 匿名拉取最可靠。必须用 bash 而非 sh 管道：
# dash 的 `sh -s` 不接收位置参数，--prefix/--channel 等将静默回落默认值）：
#   curl -fsSL "https://api.atomgit.com/api/v5/repos/openairymax/agentrt/contents/scripts/install.sh?ref=main" \
#     | python3 -c 'import json,sys,base64;sys.stdout.buffer.write(base64.b64decode(json.load(sys.stdin)["content"]))' \
#     | bash
#     # ↑ 最简形式：通道默认 stable（--channel 仅 beta 等非常规通道时需指定）
#     # 自定义路径：同上管道，末尾改为 `bash -s -- --prefix "$HOME/.airymaxrt"`
#   bash install.sh --reinstall                       # 强制重装（清缓存+停旧 daemon）
#   bash install.sh --uninstall                       # 一键卸载
# 三命令快速参考（安装完成后日常运维）。
# 安装命令首选下方"一键安装（最新版）"：安装器权威源是 agentrt 仓 main 分支
# scripts/install.sh（git push 即生效）。release 附件（releases/download/
# latest/install.sh）只在发版时更新，同版本重发会滞后——且经 curl 管道执行
# 时无法自举（$0 非文件），故不作为推荐入口，见"兼容入口"。
#   一键安装（最新版，推荐）:
#     curl -fsSL "https://api.atomgit.com/api/v5/repos/openairymax/agentrt/contents/scripts/install.sh?ref=main" \
#       | python3 -c 'import json,sys,base64;sys.stdout.buffer.write(base64.b64decode(json.load(sys.stdin)["content"]))' \
#       | bash
#   更新   airymaxrt update           （--check 仅检查 / --channel stable|beta / --rollback 回滚）
#   重装   bash install.sh --reinstall
# 兼容入口（release 附件，latest 指向最新 release；仅在最近发版后短暂可用，
# 同版本修复重发不更新该附件）：
#   curl -fsSL "https://atomgit.com/openairymax/agentrt/releases/download/latest/install.sh" | bash
#     # 磁盘副本（下载为文件后 bash install.sh）运行时会自动自举到 git main
#     # 最新版（见 installer_self_bootstrap）；curl 直接管道则不会。
#
# 安装策略（三模式，按可达性自动降级）：
#   模式 A 二进制：AIRY_RELEASE_URL 指向完全体 tarball（含闭源模块预编译产物），
#      下载解压到 $AIRY_HOME，秒级安装、无需工具链（完全体二进制为主）。
#   模式 B 混合构建：管理仓 + 公开子仓源码编译；闭源模块（atoms / memoryrovol）
#      下载预编译包到 $AIRY_HOME/modules/ 后链接（AIRY_ATOMS_PREBUILT_DIR /
#      MEMORYROVOL_PRO_LIB）。本地无闭源源码时自动走此模式。
#   模式 C 全源码构建：本地已持有闭源模块源码（如 airymaxrt-local），直接
#      全量源码编译（AIRY_MODE=source 或检测到本地源码树时）。
#
# 路径体系（与 platform.h AIRY_HOME 完全一致，全产物收敛）：
#   $AIRY_HOME            = $HOME/.airymaxrt（强制统一；--prefix 显式覆盖，
#                            环境变量 AIRY_HOME 不再继承——防终端残留劫持）
#   $AIRY_HOME/bin  lib  include  config  run  logs  data  tmp  cache
#   $AIRY_HOME/modules    — 闭源预编译模块包（atoms/memory/memoryrovol）
#   $AIRY_HOME/src        — 源码树（构建模式）
#   $AIRY_HOME/build      — out-of-source 构建目录（构建模式）
#   $AIRY_HOME/scripts    — 安装器自托管（install/uninstall 副本）
#
# 环境变量：
#   AIRY_HOME / AIRY_VERSION / AIRY_REPO_URL / AIRY_BUILD_JOBS
#   AIRY_RELEASE_URL / AIRY_NO_BUILD / AIRY_MODE(auto|binary|hybrid|source)
#   AIRY_ATOMS_PREBUILT_URL / AIRY_MEMORYROVOL_PREBUILT_URL（闭源预编译包直链）
# 硬件自适应（2.3.5/2.3.6）：安装即按架构/内存/CPU/加速器裁剪运行画像
#   （full/minimal，固化到 config/profile.env）；AIRY_RELEASE_URL 支持
#   {arch} 占位符按当前架构选择预编译包；airymaxrt monitor 常驻检测
#   外设增强（内存扩容/插卡）后自动恢复被裁剪的功能 daemon。
#
# 参数：
#   --prefix <path>  --mode <auto|binary|hybrid|source>  --bin-dir <path>
#   --profile <full|minimal|auto>  --channel <stable|beta>  --from-file <tarball>
#   --reinstall     强制重装：清本地包缓存强制下载最新版 + 先停旧 daemon
#   --uninstall [--keep-data] [--yes]  --help
#
# 发布通道（2.3.7）：--channel stable|beta 选择官方滚动通道；未指定
# AIRY_RELEASE_URL 时默认拉取官方通道 manifest（GPG 验签 + 本平台制品解析），
# 不再强制源码构建。--from-file <tarball> 支持离线包安装（跳过网络，
# 仅 sha256 + 架构自检）。AIRY_RELEASE_URL 亦支持直接指向 tarball URL
# （{arch} 占位符）或 manifest JSON。官方制品仓库：atomgit.com/openairymax/agentrt。
#
# 安装完成后：固化 install.env（含 AIRY_BIN_LINK）、生成 agentrt-env.sh、
# 软链 airymaxrt 启动器到 PATH（任意路径输入 airymaxrt 即启动），
# 校验 bin/*_d 全部就位（daemon 清单动态推导）。
#
# 卸载：sh install.sh --uninstall 或 airymaxrt uninstall（停止 daemon +
#       删除 $AIRY_HOME + 移除 PATH 软链；--keep-data 保留记忆数据）。
# ============================================================================

set -u

# ─── 颜色（无 TTY 时禁用） ──────────────────────────────────────────────
if [ -t 1 ]; then
    C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_CYAN='\033[0;36m'; C_NC='\033[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''; C_NC=''
fi
log_info()  { printf "${C_CYAN}[INFO]${C_NC} %s\n" "$1"; }
log_ok()    { printf "${C_GREEN}[ OK ]${C_NC} %s\n" "$1"; }
log_warn()  { printf "${C_YELLOW}[WARN]${C_NC} %s\n" "$1"; }
log_err()   { printf "${C_RED}[FAIL]${C_NC} %s\n" "$1"; }

# ─── 进度反馈（进度条 + 转圈动效；非 TTY 自动静默） ─────────────────────
# 与颜色检测同判据：stderr 为 TTY（交互终端）时启用，管道/重定向时静默，
# 防止转义序列污染日志。curl 进度条（--progress-bar）与 -s 互斥，
# 非 TTY 回落 -s 保持原静默行为。
if [ -t 2 ]; then
    CURL_FLAG="--progress-bar -S"
    HAS_TTY=1
else
    CURL_FLAG="-s"
    HAS_TTY=0
fi

# 转圈动效：命令后台运行时在 stderr 画旋转字符，结束清行（POSIX 兼容）
spinner() { # <pid> <label>
    local _sp_pid="$1" _sp_label="$2" _sp_i=0 _sp_c='|'
    while kill -0 "$_sp_pid" 2>/dev/null; do
        case "$_sp_i" in
            0) _sp_c='|' ;; 1) _sp_c='/' ;; 2) _sp_c='-' ;; 3) _sp_c='\' ;;
        esac
        printf '\r\033[K[%s] %s' "$_sp_c" "$_sp_label" >&2
        _sp_i=$(( (_sp_i + 1) % 4 ))
        sleep 0.1
    done
    printf '\r\033[K' >&2
}

# 带转圈执行命令：<label> <cmd...>——命令输出静音（进度经转圈呈现），
# 退出码原样返回；非 TTY 时直接静默执行，行为与调用方一致。
run_spin() { # <label> <cmd...>
    local _rs_label="$1"
    shift
    if [ "$HAS_TTY" = "1" ]; then
        "$@" >/dev/null 2>&1 &
        local _rs_pid=$!
        spinner "$_rs_pid" "$_rs_label"
        wait "$_rs_pid"
        return $?
    fi
    "$@" >/dev/null 2>&1
}

# ─── 默认值 ──────────────────────────────────────────────────────────────
# 安装路径强制统一 $HOME/.airymaxrt（社区用户与本地开发同一逻辑，2026-08-28）。
# 环境变量 AIRY_HOME 不再继承——历史故障：Trae 持久终端残留 export
# AIRY_HOME=<已删除目录>，静默劫持安装位置与启动器目标。需要非默认位置时
# 用显式 --prefix 参数（安装完成后打印实际位置，无隐藏状态）。
if [ -n "${AIRY_HOME:-}" ] && [ "${AIRY_HOME}" != "${HOME}/.airymaxrt" ]; then
    log_warn "已忽略环境变量 AIRY_HOME=${AIRY_HOME}（防残留劫持）；安装位置统一为 \${HOME}/.airymaxrt，非默认位置请用 --prefix"
fi
AIRY_HOME="${HOME}/.airymaxrt"
AIRY_REPO_URL="${AIRY_REPO_URL:-https://atomgit.com/openairymax/airymaxhub.git}"
# 版本 SSoT：优先读取同仓 agentrt/VERSION（源码树内运行），否则回退默认值。
# 注意：curl 管道 / 裸脚本场景无 VERSION 文件可读，默认值只作占位——
# 源码构建路径会以 clone 到的 agentrt/VERSION 为准（见 prepare_source），
# 二进制路径以 manifest/实际包版本为准（install_binary 固化）。
AIRY_VERSION_SPECIFIED=0
if [ -n "${AIRY_VERSION:-}" ]; then
    AIRY_VERSION_SPECIFIED=1
elif [ -f "$(dirname "$0")/../VERSION" ]; then
    AIRY_VERSION="v$(cat "$(dirname "$0")/../VERSION" | tr -d '[:space:]')"
fi
# 版本默认占位（仅 curl 管道/裸脚本且最终解析全部失败时兜底；banner 已不再
# 展示该值——真实版本一律以 manifest/包内 VERSION/制品名为准，杜绝漂移误导。
# 保持与当前最新发布一致，随发布节奏更新）。
AIRY_VERSION="${AIRY_VERSION:-v0.1.11}"
AIRY_BUILD_JOBS="${AIRY_BUILD_JOBS:-$(nproc 2>/dev/null || echo 4)}"
AIRY_MODE="${AIRY_MODE:-auto}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
UNINSTALL=0; REINSTALL=0; KEEP_DATA=0; YES=0
# 出厂预装 maths-toolkit（数学计算后端：MCP-Mathematics + sympy-mcp，
# 共享 $AIRY_HOME/venv）。默认开启，安装失败降级警告，不阻断主流程。
WITH_MATHS=1
AIRY_PROFILE="${AIRY_PROFILE:-auto}"
# 发布通道（自更新器/二进制安装共用）：stable | beta。AIRY_RELEASE_URL
# 指向 manifest JSON 时按通道解析本平台制品；指向 tarball 时直用。
AIRY_CHANNEL="${AIRY_CHANNEL:-stable}"
AIRY_FROM_FILE="${AIRY_FROM_FILE:-}"
case "$AIRY_CHANNEL" in stable|beta) ;; *) log_err "非法 --channel: ${AIRY_CHANNEL}（支持 stable|beta）"; exit 1 ;; esac

# 0.1.6f 系统性修复：curl 符号崩溃隔离（32 位 ARM 实测 2026-08-31）。
# 宿主曾安装 AgentRT 时，agentrt-env.sh 会把 $AIRY_HOME/lib 注入
# LD_LIBRARY_PATH；其中自编译 libcurl 与宿主 libssl 不匹配时直接调 curl
# 报 "curl: symbol lookup error: undefined symbol: curl_easy_ssls_import,
# version CURL_OPENSSL_4" 崩溃。本安装器全部网络请求统一走 syscurl：
# 剔除 $AIRY_HOME/lib 后调系统 curl，与完整启动器（latest/airymaxrt）
# 隔离策略同源。轻量启动器模板内嵌一份无 local 的 POSIX 同构实现。
syscurl() {
    local _ldp="" _seg _rest="${LD_LIBRARY_PATH:-}"
    while [ -n "$_rest" ]; do
        _seg="${_rest%%:*}"
        [ "$_seg" = "${AIRY_HOME}/lib" ] || _ldp="${_ldp:+$_ldp:}$_seg"
        [ "$_seg" = "$_rest" ] && _rest="" || _rest="${_rest#*:}"
    done
    if [ -n "$_ldp" ]; then
        env LD_LIBRARY_PATH="$_ldp" curl "$@"
    else
        env -u LD_LIBRARY_PATH curl "$@"
    fi
}

# 便携 sha256（G4b/macOS 干净机 2026-09-08）：核心工具链不含 coreutils，
# 无 sha256sum 命令；统一走 shasum -a 256 回退。两分支输出格式均为
# "<hex>  <path>"（GNU 与 BSD shasum 一致），awk 取首列即得 hex。
sha256_file() { # <file> → hex；无可用实现输出空
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
    else
        printf ''
    fi
}
sha256_stdin() { # stdin → hex；无可用实现输出空
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum 2>/dev/null | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 2>/dev/null | awk '{print $1}'
    else
        printf ''
    fi
}

# 幂等写 install.env（0.1.6g）：先删除同名键再追加——多次安装/引导不会
# 让键重复膨胀（此前 `>>` 直接追加，重装后 AIRY_PATH_RC 等出现多行）。
# 跨平台：grep -v + mv，不依赖 sed -i 的 GNU/BSD 语法差异（macOS 兼容）。
env_set() { # <key=value>
    local _k="${1%%=*}" _f="${AIRY_HOME}/config/install.env"
    mkdir -p "$(dirname "$_f")" 2>/dev/null || true
    [ -f "$_f" ] || : > "$_f"
    if grep -v "^${_k}=" "$_f" > "$_f.tmp" 2>/dev/null; then
        mv "$_f.tmp" "$_f"
    else
        rm -f "$_f.tmp"
    fi
    echo "$1" >> "$_f"
}

AIRY_SRC_DIR="${AIRY_HOME}/src/airymaxhub"
MODULES_DIR="${AIRY_HOME}/modules"

# 源码子模块根：兼容两种仓库布局——
#   A) 平铺：$AIRY_SRC_DIR/agentrt、$AIRY_SRC_DIR/ecosystem、…
#   B) 管理仓 submodule：$AIRY_SRC_DIR/agent-workload/agentrt、…/ecosystem、…
# 统一以 $AIRY_SRC_APP 作为 app 源码根，后续引用全部基于该变量。
AIRY_SRC_APP="${AIRY_SRC_DIR}/agent-workload"
if [ ! -d "${AIRY_SRC_APP}/agentrt" ]; then
    AIRY_SRC_APP="${AIRY_SRC_DIR}"
fi

# daemon 清单单一真相源：以制品 bin/*_d 推导（二进制包与源码构建共用
# 同一口径；daemon 增删不再改脚本硬编码，0.1.9 M4-S4 收敛）。
daemon_list() {
    local bin="${1:-${AIRY_HOME}/bin}" d
    [ -d "$bin" ] || return 0
    for d in "${bin}"/*_d; do
        [ -f "$d" ] && basename "$d"
    done
}

# ─── 安装器自举（系统性解决安装器无法更新，2026-08-30） ────────────────
# AtomGit API 不支持删除/替换 release 附件，同版本重发后一键命令仍拿旧
# 安装器。权威源定为 agentrt 仓 main 分支 scripts/install.sh（git push
# 即生效），本机磁盘副本（含 $AIRY_HOME/scripts/install.sh 自托管副本）
# 每次运行比对远程 hash，不同则用远程最新版重执行。curl 管道/stdin 场景
# （$0 非文件）跳过；AIRY_INSTALLER_BOOTSTRAPPED 守卫防递归。
#
# 必须位于顶层参数解析（shift 消费 $@）之前调用并转发 "$@"：否则自举
# re-exec 后 --prefix/--from-file/--reinstall/--uninstall 等全部丢失
# （2026-08-31 实测：--prefix 落到默认目录、--from-file 被忽略改走网络）。
installer_self_bootstrap() {
    [ "${AIRY_INSTALLER_BOOTSTRAPPED:-0}" = "1" ] && return 0
    [ -f "$0" ] || return 0
    command -v python3 >/dev/null 2>&1 || return 0
    command -v curl >/dev/null 2>&1 || return 0
    local api="https://api.atomgit.com/api/v5/repos/openairymax/agentrt/contents/scripts/install.sh?ref=main"
    local tmp remote_content tmp_inst
    tmp="$(syscurl -fsSL --max-time 30 "$api" 2>/dev/null)" || return 0
    remote_content="$(printf '%s' "$tmp" | python3 -c 'import sys,json,base64;d=json.load(sys.stdin);sys.stdout.write(base64.b64decode(d.get("content","")).decode())' 2>/dev/null)" || return 0
    [ -n "$remote_content" ] || return 0
    # 字符串相等比较（两侧都经命令替换、剥尾换行对称）。禁止改用
    # "解码串算 sha vs 磁盘文件算 sha"：命令替换剥掉尾部换行使两侧
    # 永不相等 → 每次磁盘执行都误切远程重执行（rc4-5 实证：核验对象
    # 漂移到 main 版安装器），且 printf '%s' 落盘会丢文件尾换行。
    [ "$remote_content" = "$(cat "$0")" ] && return 0
    log_info "检测到安装器新版本，切换到远程最新版执行…"
    export AIRY_INSTALLER_BOOTSTRAPPED=1
    tmp_inst="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/airymaxrt-installer.$$")"
    printf '%s\n' "$remote_content" > "$tmp_inst" || { rm -f "$tmp_inst"; return 0; }
    chmod 755 "$tmp_inst"
    exec "$tmp_inst" "$@"
}

# 自举必须最先执行（顶层、参数解析之前）：让 --reinstall/--uninstall/
# 全新安装都基于最新安装器，且保留完整命令行参数。
installer_self_bootstrap "$@"

# ─── 参数解析 ────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)    AIRY_HOME="$2"; shift 2 ;;
        --mode)      AIRY_MODE="$2"; shift 2 ;;
        --bin-dir)   BIN_DIR="$2"; shift 2 ;;
        --profile)   AIRY_PROFILE="$2"; shift 2 ;;
        --channel)   AIRY_CHANNEL="$2"; shift 2 ;;
        --from-file) AIRY_FROM_FILE="$2"; shift 2 ;;
        --uninstall) UNINSTALL=1; shift ;;
        --reinstall) REINSTALL=1; shift ;;
        --keep-data) KEEP_DATA=1; shift ;;
        --yes)       YES=1; shift ;;
        --with-maths)    WITH_MATHS=1; shift ;;
        --without-maths) WITH_MATHS=0; shift ;;
        --help|-h)   sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) log_err "未知参数: $1（--help 查看用法）"; exit 1 ;;
    esac
done

case "$AIRY_MODE" in auto|binary|hybrid|source) ;; *) log_err "非法 --mode: ${AIRY_MODE}"; exit 1 ;; esac
case "$AIRY_PROFILE" in auto|full|minimal) ;; *) log_err "非法 --profile: ${AIRY_PROFILE}（支持 full|minimal|auto）"; exit 1 ;; esac

# ─── 工具链检测 ──────────────────────────────────────────────────────────
require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log_err "缺少必要工具: $1"
        case "$1" in
            git)   log_warn "请安装 git（如 Debian/Ubuntu: sudo apt install git）" ;;
            cmake) log_warn "请安装 cmake ≥3.20（如: sudo apt install cmake）" ;;
            gcc|cc|clang) log_warn "请安装 C 编译器（如: sudo apt install build-essential）" ;;
            curl)  log_warn "请安装 curl" ;;
        esac
        exit 1
    fi
}

check_toolchain() {
    require_cmd curl
    if [ "${AIRY_NO_BUILD:-}" != "1" ]; then
        require_cmd git
        require_cmd cmake
        require_cmd make
        if ! command -v gcc >/dev/null 2>&1 && ! command -v clang >/dev/null 2>&1 && ! command -v cc >/dev/null 2>&1; then
            log_err "未找到 C 编译器（gcc/clang/cc）"; exit 1
        fi
        for lib in libcurl sqlite3; do
            pkg-config --exists "$lib" 2>/dev/null || \
                log_warn "未检测到 ${lib} 开发库，部分功能受限（建议安装 lib${lib}-dev）"
        done
    fi
}

# ─── 创建 AIRY_HOME 目录骨架 ───────────────────────────────────────────
init_home() {
    mkdir -p "${AIRY_HOME}"/bin "${AIRY_HOME}"/lib "${AIRY_HOME}"/include \
             "${AIRY_HOME}"/share "${AIRY_HOME}"/run \
             "${AIRY_HOME}"/config "${AIRY_HOME}"/data \
             "${AIRY_HOME}"/tmp \
             "${AIRY_HOME}"/data/agentrt/logs "${AIRY_HOME}"/data/agentrt/tmp \
             "${AIRY_HOME}"/data/agentrt/cache "${AIRY_HOME}"/data/agentrt/workspaces \
             "${AIRY_HOME}"/modules "${AIRY_HOME}"/scripts
    chmod 700 "${AIRY_HOME}/config" 2>/dev/null || true
    log_ok "AIRY_HOME 就绪: ${AIRY_HOME}"
}

# ─── 停止运行中的 daemon ────────────────────────────────────────────────
# 返回 0 = 有 daemon 被停止；返回 1 = 无运行进程（新装/已停）。调用方
# 据此决定是否提示"已停止旧 daemon"。与 bootstrap stop 同一判据（按
# 二进制绝对路径 pkill，避免误杀同名进程）。
stop_daemons() {
    local bin="$1" found=0 d
    [ -d "$bin" ] || return 1
    for d in $(daemon_list "$bin"); do
        if [ -x "${bin}/${d}" ]; then
            if pkill -f "${bin}/${d}" >/dev/null 2>&1; then
                found=1
            fi
            # /proc exe 精确兜底：以相对路径/旧 cwd 启动的旧实例，pkill -f
            # 按命令行参数串匹配可能漏杀（2026-08-31 实测）；对仍存活进程
            # 按 /proc/<pid>/exe 目标逐一精确核对后再 kill，避免误杀。
            if [ -d /proc ] && command -v readlink >/dev/null 2>&1; then
                for _pid in /proc/[0-9]*; do
                    _exe="$(readlink "${_pid}/exe" 2>/dev/null || true)"
                    case "$_exe" in
                        "${bin}/${d}"|*"/${d}")
                            kill "${_pid#/proc/}" 2>/dev/null && found=1 || true ;;
                    esac
                done
            fi
        fi
    done
    [ "$found" = "1" ] && sleep 1
    return $(( found == 0 ))
}

# ─── 一键卸载 ────────────────────────────────────────────────────────────
# 从 shell rc 移除 AgentRT PATH 引导标记块。path_bootstrap 只把单条 rc
# 路径记入 install.env（AIRY_PATH_RC），但用户换 shell / 启动器自愈可能
# 把引导块写到别的 rc（bash→zsh/fish/.profile），卸载只信单条记录会漏删。
# 统一按标记区间（# >>> AgentRT PATH bootstrap <<< … # <<< 同 <<<）对
# 已知 rc 候选全量扫描删除，幂等（无标记即跳过）。
remove_path_bootstrap() {
    local rc rc_path="${1:-}" _tmp
    for rc in "$rc_path" "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile" "$HOME/.config/fish/config.fish"; do
        [ -n "$rc" ] && [ -f "$rc" ] || continue
        grep -q '# >>> AgentRT PATH bootstrap <<<' "$rc" 2>/dev/null || continue
        _tmp="$rc.airy_uninstall_tmp"
        if sed '\|# >>> AgentRT PATH bootstrap <<<|,\|# <<< AgentRT PATH bootstrap <<<|d' "$rc" > "$_tmp" 2>/dev/null \
            && mv "$_tmp" "$rc"; then
            log_ok "已从 ${rc} 移除 AgentRT PATH 引导行"
        else
            rm -f "$_tmp" 2>/dev/null
            log_warn "无法自动清理 ${rc} 的 AgentRT PATH 引导行，请手动删除标记区间"
        fi
    done
}

do_uninstall() {
    local home="$1" keep_data="$2" yes="$3" env_file link size ans rc_path
    env_file="${home}/config/install.env"
    if [ -f "$env_file" ]; then
        home="$(sed -n 's/^AIRY_HOME=//p' "$env_file" | head -1)"
        [ -n "$home" ] || home="$1"
    fi
    if [ ! -d "$home" ]; then
        log_warn "未检测到安装（$home 不存在），无需卸载"
        return 0
    fi
    # link / rc_path 必须在 rm -rf 之前读取（install.env 随后被删除，
    # 读晚了恒为空 → PATH 引导行永不清理——0.1.13 C2a 社区反馈实证）。
    link="$(sed -n 's/^AIRY_BIN_LINK=//p' "$env_file" 2>/dev/null | head -1)"
    [ -n "$link" ] || link="${BIN_DIR}/airymaxrt"
    rc_path="$(sed -n 's/^AIRY_PATH_RC=//p' "$env_file" 2>/dev/null | head -1)"
    size="$(du -sh "$home" 2>/dev/null | cut -f1)"
    log_warn "将卸载 AirymaxRT：${home}（${size}）"
    if [ "$yes" != "1" ]; then
        printf "${C_YELLOW}确认卸载？[y/N] ${C_NC}"
        read -r ans || true
        case "$ans" in y|Y|yes|YES) ;; *) log_info "已取消卸载"; return 0 ;; esac
    fi
    stop_daemons "$home/bin"
    # 回收 airymaxrt monitor --daemon 常驻进程（stop_daemons 只按 bin/*_d
    # 匹配，monitor 是常驻 bash 循环，卸载不清则残留周期性探测已删
    # PID/写 profile——0.1.13 C2a 复核实证）。仅杀 environ 含本 AIRY_HOME
    # 的实例（pgrep -f 全串匹配会误伤其他安装，故按环境变量精确过滤）。
    if command -v pgrep >/dev/null 2>&1; then
        for _mp in $(pgrep -f "airymaxrt monitor" 2>/dev/null || true); do
            if tr '\0' '\n' < "/proc/${_mp}/environ" 2>/dev/null | grep -q "^AIRY_HOME=${home}$"; then
                kill "$_mp" 2>/dev/null || true
            fi
        done
    fi
    if [ "$keep_data" = "1" ] && [ -d "$home/data" ]; then
        rm -rf "$home"
        mkdir -p "$home/data"
        log_ok "已删除 ${home}（保留 data/ 记忆数据）"
    else
        rm -rf "$home"
        log_ok "已删除 ${home}"
    fi
    # 启动器可能是软链或普通副本（用户手动 cp 替代 ln 场景），一律删除
    if [ -L "$link" ] || [ -e "$link" ]; then
        rm -f "$link"
        log_ok "已移除启动器 ${link}"
    fi
    remove_path_bootstrap "$rc_path"
    log_ok "卸载完成"
}

# ─── 方式 A：完全体二进制 tarball（优先） ───────────────────────────────
# 硬件自适应（2.3.5）：预编译包按架构分发——AIRY_RELEASE_URL 支持 {arch}
# 占位符（自动替换为当前架构，如 .../agentrt-v0.1.3-linux-{arch}.tar.gz）；
# 架构不在预编译支持清单时告警并回退源码构建，避免跨架构运行错乱。
# 2.3.7 发布通道：AIRY_RELEASE_URL 亦支持 manifest JSON（.../manifest.stable.json）
# ——下载后 GPG 验签（内置公钥）+ 按当前平台解析制品 url/sha256；本地离线包
# 可直接传 tarball 路径（--from-file / AIRY_FROM_FILE），仅做 sha256 + 架构自检。

# 官方发布 GPG 公钥（manifest 权威签名；与 tools/scripts/ci/release/keys/agentrt.asc
# 及 sdk/tui/scripts/airymaxrt AIRY_GPG_PUBKEY 同源，指纹见 keys/agentrt.fingerprint）
AIRY_GPG_PUBKEY='-----BEGIN PGP PUBLIC KEY BLOCK-----

mDMEao7uahYJKwYBBAHaRw8BAQdAk8Ou1tA2EfX5xZT4ET79YJESeqINPyFF86MK
cpPAQDO0NEFnZW50UlQgUmVsZWFzZSBTaWduaW5nIDxyZWxlYXNlQGFnZW50cnQu
YWlyeW1heC5pbz6IkwQTFgoAOxYhBIbDf3xc3cxA57s+YuQ19/HMJP+EBQJqju5q
AhsDBQsJCAcCAiICBhUKCQgLAgQWAgMBAh4HAheAAAoJEOQ19/HMJP+EepEBANYY
xAN1mQL4gulwMvH3xjiL6aEVm1PFjus33MXJrDmKAQDEck2sowTfLa1WneqUY93D
QpegwKdM5Y9YiANOL8FODQ==
=EPz8
-----END PGP PUBLIC KEY BLOCK-----'

# AtomGit raw 域（raw.atomgit.com/.../raw/...）对非 Markdown 文件返回
# HTML 预览页（"暂不支持预览"，403），不可作原始文件直链。改用 v5
# contents API：匿名 GET /repos/{owner}/{repo}/contents/<path>?ref=main
# 返回 JSON（content 为 base64），python3 解码优先，无 python3 时回退
# sed 提取 + base64 -d（content 为单行 base64，不含引号，提取安全）。
fetch_repo_file() { # <repo_path> <dest>
    local api="https://api.atomgit.com/api/v5/repos/${AIRY_RELEASE_OWNER:-openairymax/agentrt}/contents/$1?ref=main"
    local tmp="${AIRY_HOME}/tmp/contents.$$"
    mkdir -p "$(dirname "$tmp")" 2>/dev/null
    syscurl -fsSL --max-time 60 -o "$tmp" "$api" || { rm -f "$tmp"; return 1; }
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json,sys,base64; sys.stdout.buffer.write(base64.b64decode(json.load(sys.stdin).get("content","").replace("\n","")))' < "$tmp" > "$2" || { rm -f "$tmp"; return 1; }
    else
        sed -n 's/.*"content"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$tmp" | tr -d '\n' | base64 -d > "$2" 2>/dev/null || { rm -f "$tmp"; return 1; }
    fi
    rm -f "$tmp"
    [ -s "$2" ]
}

# GPG 验签（独立 homedir 隔离用户 keyring；签名缺失拒绝——防供应链攻击
# 的 fail-closed 约束。公钥优先级：发布源 latest/keys/ 在线拉取（支持轮换）
# → 本地 $AIRY_HOME/keys/ → 内嵌公钥（首次引导兜底））。
verify_gpg_sig() { # <file> <sig.asc>
    [ -s "$2" ] || { log_warn "缺少签名文件（fail-closed），拒绝安装"; return 1; }
    local gnupg="${AIRY_HOME}/tmp/gnupg-install" keyf
    mkdir -p "$gnupg" && chmod 700 "$gnupg"
    keyf="$gnupg/agentrt.asc"
    if [ -z "${AIRY_NO_NETWORK:-}" ]; then
        fetch_repo_file "latest/keys/agentrt.asc" "$keyf" >/dev/null 2>&1 || true
    fi
    if [ ! -s "$keyf" ] && [ -f "${AIRY_HOME}/keys/agentrt.asc" ]; then
        cp -f "${AIRY_HOME}/keys/agentrt.asc" "$keyf" 2>/dev/null || true
    fi
    [ -s "$keyf" ] || printf '%s\n' "$AIRY_GPG_PUBKEY" > "$keyf"
    gpg --batch --quiet --no-tty --homedir "$gnupg" --import "$keyf" >/dev/null 2>&1 || return 1
    gpg --batch --no-tty --homedir "$gnupg" --verify "$2" "$1" >/dev/null 2>&1
}

# manifest 字段提取（python3 优先，回退 sed 单行提取）
parse_manifest() { # <manifest> <platform> <field:url|sha256>
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$1" "$2" "$3" <<'PYEOF'
import json, sys
try:
    m = json.load(open(sys.argv[1]))
    rel = m.get("releases", {}).get(m.get("latest", ""), {})
    print(rel.get("artifacts", {}).get(sys.argv[2], {}).get(sys.argv[3], ""))
except Exception:
    pass
PYEOF
        return 0
    fi
    sed -n "s/.*\"$3\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -1
}

install_binary() {
    # 返回码语义（系统性收敛，2026-09-05）：
    #   0  = 成功
    #   1  = 官方确无本平台制品 / 架构不受支持 → 调用方按"无官方制品"提示，
    #        显式要求源码构建时才降级（auto 不再静默源码）
    #   2  = 确定性故障（下载 / sha256 / 解压 / 制品不完整 / 结构异常）→
    #        调用方必须失败退出并给出可诊断指引，绝不静默降级源码构建
    # 历史教训：auto 静默源码构建把网络/校验故障误当"需源码"，社区用户被
    # 拖入克隆伞仓 + 全量 cmake，体验崩溃（0.1.10 安装事故）。fail-closed。
    local url="$1" arch plat expect_sha="" legacy="" tarball="" local_src=0
    arch="$(detect_arch)"
    # 运行平台显示（OS-架构族-位宽，与发布命名一致，0.1.11 消息结构优化）：
    # 平台名 + 架构名并排呈现，不再堆叠预编译支持清单——社区用户反馈
    # "看到 x86_64 和一串架构仍不知即将安装哪个平台制品"。
    if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
        plat="macos-$(plat_name "$(uname -m 2>/dev/null)")"
    else
        plat="linux-$(plat_name "${arch}")"
    fi
    log_info "运行平台: ${plat}（架构 ${arch}）"
    # 离线包（--from-file）放行任意架构（本地构建包不受官方发布清单限制）；
    # 在线安装严格按官方发布清单校验。
    if [ -z "${AIRY_FROM_FILE:-}" ]; then
        case " ${SUPPORTED_ARCHS} " in
            *" ${arch} "*) ;;
            *)
                # 兼容性指引（2026-08-30 32 位 ARM 用户空间教训）：不支持
                # 的架构不静默回退，给出明确可操作的路径；返回 1 后主流程
                # 仍会尝试源码构建兜底。
                log_err "检测到架构 ${arch}，不在官方预编译发布清单（${SUPPORTED_ARCHS}）内"
                log_err "请源码构建：AIRY_MODE=source bash install.sh（需 C 工具链 + 依赖库）"
                return 1
                ;;
        esac
        # riscv32 已入六架构清单，但 glibc riscv32 用户态生态未就绪
        # （Ubuntu 等发行版无 riscv32 libc），预编译制品暂不发布；明确
        # 指引回退源码构建，杜绝拉取缺制品后的隐性回退。
        if [ "$arch" = "riscv32" ]; then
            log_err "检测到 32 位 RISC-V（riscv32/ilp32d）。glibc riscv32 用户态生态"
            log_err "尚未成熟（主流发行版无 riscv32 libc），官方预编译包暂不可用。"
            log_err "请源码构建：AIRY_MODE=source bash install.sh（需 RISC-V 工具链）"
            return 1
        fi
    fi

    # 来源解析：a) manifest JSON（通道）→ GPG 验签 + 解析本平台制品；
    #          b) 本地 tarball（--from-file / AIRY_FROM_FILE）→ 直用；
    #          c) 远程 tarball URL（{arch} 占位符）→ 下载，相邻 .sha256 自动校验
    if [ "${url##*.}" = "json" ]; then
        local man="${AIRY_HOME}/tmp/manifest.json" man_asc="${AIRY_HOME}/tmp/manifest.json.asc"
        # 官方仓 manifest 经 contents API 拉取（raw 域对 JSON 返回 HTML，
        # 见 fetch_repo_file）；外部自定义 URL 保持直连。
        case "$url" in
            *openairymax/agentrt*)
                local man_path="latest/${url##*/}"
                fetch_repo_file "$man_path" "$man" || { log_err "官方 manifest 下载失败（网络/服务异常），请稍候重试"; return 2; }
                fetch_repo_file "$man_path.asc" "$man_asc" >/dev/null 2>&1 || true
                ;;
            *)
                syscurl -fsSL --max-time 60 -o "$man" "$url" || { log_err "manifest 下载失败（网络/服务异常），请稍候重试"; return 2; }
                syscurl -fsSL --max-time 60 -o "$man_asc" "${url}.asc" >/dev/null 2>&1 || true
                ;;
        esac
        verify_gpg_sig "$man" "$man_asc" || { log_err "manifest 验签失败（GPG），拒绝安装——请确认网络环境未被劫持后重试"; return 2; }
        [ -s "$man_asc" ] && log_ok "manifest 验签通过（GPG）"
        # plat 已在函数入口统一计算（macOS 走 uname -m，其余走 detect_arch）
        url="$(parse_manifest "$man" "$plat" url)"
        expect_sha="$(parse_manifest "$man" "$plat" sha256)"
        # 平台键兼容（三代 manifest）：本版主键 = OS-架构族-位宽（如
        # linux-x86-64）；旧两代（gen2：linux-x64 等 / gen1：linux-x86_64
        # 等）未命中时按 plat_legacy_name 候选依序反查，杜绝"无可用制品"
        # 假阴性（0.1.6f 社区反馈同源）。
        if [ -z "$url" ]; then
            for legacy in $(plat_legacy_name "$plat"); do
                [ -n "$legacy" ] || continue
                url="$(parse_manifest "$man" "$legacy" url)"
                expect_sha="$(parse_manifest "$man" "$legacy" sha256)"
                [ -n "$url" ] && { log_info "平台键 ${plat} 未命中，已用兼容命名 ${legacy}"; break; }
            done
        fi
        [ -n "$url" ] || { log_warn "manifest 无 ${plat} 制品，回退源码构建"; return 1; }
        # 目标版本从制品文件名提取（agentrt-v<ver>-<os>-<arch>.tar.gz），
        # 明确展示"即将安装的版本"；URL/文件名由随后的下载行呈现，避免
        # 平台名在相邻两行重复堆叠造成迷惑（0.1.11 社区反馈消息结构优化）。
        # OS 前缀逐个匹配（BSD sed 不支持 \| 交替，须循环兼容 macOS）。
        local _fname _fver _os
        _fname="$(basename "${url%%\?*}")"
        _fver=""
        for _os in linux macos win; do
            _fver="$(printf '%s' "$_fname" | sed -n "s/^agentrt-v\\(.*\\)-${_os}-.*/\\1/p")"
            [ -n "$_fver" ] && break
        done
        if [ -n "$_fver" ]; then
            log_info "目标版本: v${_fver}（通道 ${AIRY_CHANNEL}）"
        else
            log_info "目标制品: ${_fname}（通道 ${AIRY_CHANNEL}）"
        fi
    elif [ -f "$url" ]; then
        log_info "使用本地离线包: $url"
        tarball="$url"
        local_src=1
    else
        # URL {arch} 占位符替换（POSIX sed，兼容 sh）
        url="$(printf '%s' "$url" | sed "s/{arch}/${arch}/g")"
    fi

    # 0.1.6g 结构性修复：远程 tarball 的本地文件名 = 远端 basename
    #（如 agentrt-v0.1.6g-linux-x64.tar.gz），而非"脚本默认版本拼接名"。
    # 历史故障（2026-08-31 复现实测）：脚本默认 AIRY_VERSION 与 manifest
    # 实际版本漂移时，拼接名命中 tmp 残留的旧 tarball → 跳过下载 →
    # sha256 门禁被跳过（无期望值）→ 静默安装旧版二进制。basename 命名
    # 使"同名 = 同制品"，残留只能是同版本同平台，sha256 门禁正常兜底。
    if [ -z "$tarball" ] && [ -n "$url" ]; then
        tarball="${AIRY_HOME}/tmp/$(basename "${url%%\?*}")"
    fi

    # ── 解压前清理（结构性修复 0.1.6g）──────────────────────────────────
    # 铁律：清理必须在"下载"之前执行。历史根因：清理曾放在下载之后、
    # 解压之前，glob 一次误匹配（无尾斜杠）即删除刚下载的 tarball 自身
    #（32 位 ARM 安装实测 "tar: Cannot open: No such file or directory"）。
    # 顺序前移后，任何清理都只能触及上一轮残留，永远无法影响本轮下载
    # 的 tarball；尾斜杠（agentrt-*/）保留，只匹配旧解压目录（杜绝 find
    # 命中旧目录 → 拷贝旧 bin / 版本误显示 0.1.6c 的历史故障）。
    rm -rf "${AIRY_HOME}"/tmp/agentrt-*/ 2>/dev/null || true

    # sha256 期望值：manifest 已解析（expect_sha）；离线/直链场景回退相邻
    # .sha256 文件（install.sh --from-file 手动下载核对）。
    if [ -z "$expect_sha" ] && [ -f "${tarball}.sha256" ]; then
        expect_sha="$(cut -d' ' -f1 "${tarball}.sha256" 2>/dev/null)"
    fi
    # 下载（仅远程来源）。0.1.10 事故修复（2026-09-05）：同 tag 修复重传后，
    # tmp 残留的旧版同名 tar.gz 会被"已存在即复用"逻辑直接采用，与新 manifest
    # 期望 sha256 不符 → 校验失败。系统性收敛：任何缓存文件在期望 sha256
    # 已知时必须先校验自身，不匹配立即删除重下——缓存永远不得越过校验门禁。
    _retry_download=0
    while :; do
        if [ ! -f "$tarball" ]; then
            # 本地离线包不存在即失败（不尝试把文件路径当 URL 下载）
            if [ "$local_src" = "1" ]; then
                log_err "离线包不存在或已被移除: ${tarball}，请重新指定 --from-file 路径"
                return 2
            fi
            log_info "下载完全体二进制包: ${url}"
            if ! syscurl -fsSL --max-time 600 -o "${tarball}" "${url}"; then
                rm -f "${tarball}"
                if [ "$_retry_download" -lt 1 ]; then
                    log_warn "release 下载失败，重试一次（网络抖动兜底）…"
                    _retry_download=$((_retry_download+1)); continue
                fi
                log_err "release 下载失败（已重试）。请检查网络后重新运行一键安装："
                log_err "  curl -fsSL \"https://api.atomgit.com/api/v5/repos/openairymax/agentrt/contents/scripts/install.sh?ref=main\" | python3 -c 'import json,sys,base64;sys.stdout.buffer.write(base64.b64decode(json.load(sys.stdin)[\"content\"]))' | bash"
                return 2
            fi
        fi
        # 缓存自检（期望 sha256 已知）：本地缓存不符期望 → 删后重下。
        # 这覆盖同 tag 修复重传 / 上次下载残留 / CDN 缓存陈旧三类场景。
        if [ -n "$expect_sha" ]; then
            _actual_sha="$(sha256_file "$tarball")"
            if [ "$_actual_sha" != "$expect_sha" ]; then
                # 本地离线包：无网络缓存可重下，不删除用户文件，直接 fail-closed
                if [ "$local_src" = "1" ]; then
                    log_err "sha256 校验失败：离线包与校验值不一致，拒绝安装"
                    log_err "  - 请重新下载安装包，或核对离线包与其 .sha256 是否匹配。"
                    return 2
                fi
                rm -f "$tarball"
                if [ "$_retry_download" -lt 2 ]; then
                    log_warn "本地缓存与官方校验值不符（可能是修复重传或残留旧包），重新下载…"
                    _retry_download=$((_retry_download+1)); continue
                fi
                log_err "sha256 校验失败：下载内容与官方 manifest 不一致，拒绝安装"
                log_err "  - 已自动重试仍失败，多为 CDN 缓存陈旧或网络中间层篡改。"
                log_err "  - 请稍候重试；或 --from-file 使用手动下载并核对 sha256 的离线包。"
                return 2
            fi
        fi
        break
    done
    # 校验通过的正向确认（仅当存在期望值时；离线/直链无期望 sha 时不虚报）。
    # 与 [FAIL] sha256 校验失败 对称，用户可明确看到门禁已过。
    if [ -n "$expect_sha" ]; then
        log_ok "sha256 校验通过"
    fi
    # 记录已安装制品 sha256（固化到 install.env）。update 侧"同版本修复重发
    # 检测"的依据（0.1.11）：官方同 tag 修复重发时版本号不变而 sha 变化，
    # 仅比版本会误报"已是最新"，导致修复补丁收不到。以实际校验通过的文件为准。
    AIRY_ARTIFACT_SHA256="$(sha256_file "$tarball")"
    # 包内架构自校验：tarball 根含 platform-* 标识文件时交叉校验，防止
    # 下载到异架构包后静默安装（跨架构 daemon 启动即崩溃）。三代标记
    # 兼容：本版生成 platform-<架构族-位宽>（如 platform-x86-64），旧
    # gen2/gen1 标记（platform-x64 / platform-x86_64 等）同放行；异架构
    # 标记（如 x86-64 主机遇 platform-arm-64）明确拒绝。
    _marker="$(tar -tzf "${tarball}" 2>/dev/null | grep -oE 'platform-[A-Za-z0-9_-]+' | head -1 || true)"
    if [ -n "$_marker" ]; then
        _arch_ok=""
        for _p in $(plat_markers "${arch}"); do
            [ "$_marker" = "$_p" ] && { _arch_ok=1; break; }
        done
        if [ -z "$_arch_ok" ]; then
            log_err "二进制包架构与当前主机（${arch}）不匹配（标记 ${_marker}），拒绝安装"
            [ "$local_src" = "1" ] || rm -f "${tarball}"
            return 2
        fi
        log_ok "二进制包架构校验通过（${arch}）"
    fi
    tar -xzf "${tarball}" -C "${AIRY_HOME}/tmp" || { log_err "release 包解压失败（tar），制品可能损坏"; [ "$local_src" = "1" ] || rm -f "$tarball"; return 2; }
    local extracted
    extracted="$(find "${AIRY_HOME}/tmp" -maxdepth 1 -type d -name 'agentrt-*' | head -1)"
    [ -n "$extracted" ] || { log_err "release 包结构异常（缺 agentrt-* 顶层目录），制品不完整"; return 2; }
    # 0.1.7 自动计算：daemon 清单以制品 bin/*_d 为准（后续 daemon 增删不再
    # 改脚本硬编码；gateway_d 为 HTTP 服务亦属 *_d 自动纳入）。0.1.9 M4-S4
    # 与源码构建收敛为同一 daemon_list 推导。
    EXPECTED_DAEMONS="$(daemon_list "${extracted}/bin")"
    # bin/ 拷贝必须 fail-closed：静默失败（磁盘/权限/残留干扰）会导致 daemon
    # 未就位却显示"全部就位"（0.1.6e 实测：18 个就位但启动时
    # llm_d No such file）。lib/ 已有同类校验，bin/ 补齐。
    # 覆盖洁净（0.1.13 C2b）：bin/lib/include/share 是纯产品目录（无用户
    # 数据），覆盖安装/升级前整清重灌（镜像语义，与 airymaxrt update
    # apply_package 一致）——否则旧版本独有的 *_d/.so/python 运行时残留，
    # 会被 daemon_list 推导与自愈拉起，形成半新半旧污染面。config/（用户
    # secrets 等）绝不整清，只按模板覆盖。
    mkdir -p "${AIRY_HOME}/bin"
    if [ -n "$EXPECTED_DAEMONS" ]; then
        rm -rf "${AIRY_HOME}"/bin/* 2>/dev/null || true
        cp -f "${extracted}"/bin/* "${AIRY_HOME}/bin/" 2>/dev/null || true
        local _binok=1 _d2
        for _d2 in ${EXPECTED_DAEMONS}; do
            [ -x "${AIRY_HOME}/bin/${_d2}" ] || { _binok=0; log_err "bin/ 部署失败，缺失: ${_d2}（检查磁盘/权限）"; break; }
        done
        [ "$_binok" = "1" ] || return 2
    else
        log_err "release 包缺失 daemon 二进制（bin/*_d 为空，制品不完整）"
        return 2
    fi
    # lib/（.so/.dylib 自包含）部署 + 校验：0.1.5a 旧包曾缺 libcjson.so.1 导致
    # daemon/airy_cli 启动即失败（社区反馈）。包内 lib/ 含库文件时必须
    # 确认部署成功，缺失即 fail-closed（不再静默吞错）。
    # macOS 教训（0.1.13 G4b rc4-7）：bundle-macos-dylibs.sh 将引用重写为
    # @executable_path/../lib/*.dylib，而本块条件曾只匹配 .so* —— darwin 上
    # 整块跳过，~/.airymaxrt/lib/ 为空，dyld 报 libsqlite3/libssl.3/
    # libmicrohttpd.12 "no such file"，daemon 群 14/15 全崩。库面 glob 必须
    # 同时覆盖 .so* 与 .dylib*。
    lib_has() {
        # lib_has <dir> —— 目录内含 .so/.dylib 自包含库（任一形态）即为真
        ls "$1"/*.so* >/dev/null 2>&1 || ls "$1"/*.dylib* >/dev/null 2>&1
    }
    if [ -d "${extracted}/lib" ] && lib_has "${extracted}/lib"; then
        mkdir -p "${AIRY_HOME}/lib"
        rm -rf "${AIRY_HOME}"/lib/* 2>/dev/null || true
        cp -rf "${extracted}"/lib/* "${AIRY_HOME}/lib/" 2>/dev/null
        if ! lib_has "${AIRY_HOME}/lib"; then
            log_err "lib/ 部署失败（.so/.dylib 未就位），二进制将无法启动"
            return 2
        fi
    fi
    if [ -d "${extracted}/include" ]; then
        mkdir -p "${AIRY_HOME}/include"
        rm -rf "${AIRY_HOME}"/include/* 2>/dev/null || true
        cp -rf "${extracted}"/include/* "${AIRY_HOME}/include/" 2>/dev/null || true
    fi
    # LICENSE/README（share/licenses|share/doc）随包分发，满足许可证随二进制分发要求
    if [ -d "${extracted}/share" ]; then
        mkdir -p "${AIRY_HOME}/share"
        rm -rf "${AIRY_HOME}"/share/* 2>/dev/null || true
        cp -rf "${extracted}"/share/* "${AIRY_HOME}/share/" 2>/dev/null || true
    fi
    # 二进制包内置配置（secrets.env.example / agentrt.yaml / model.yaml）拷入 config/
    if [ -d "${extracted}/config" ]; then
        cp -f "${extracted}"/config/* "${AIRY_HOME}/config/" 2>/dev/null || true
    fi
    # 签名公钥随包同步（自更新器/下次安装复用）
    if [ -f "${extracted}/keys/agentrt.asc" ]; then
        mkdir -p "${AIRY_HOME}/keys"
        cp -f "${extracted}/keys/agentrt.asc" "${AIRY_HOME}/keys/" 2>/dev/null || true
    fi
    # 数学计算后端（maths-toolkit）随包分发：纯 Python + 安装器，无架构
    # 依赖，解包至 modules/ 供 install_maths_toolkit 调用（二进制模式必备）。
    if [ -d "${extracted}/modules/maths-toolkit" ]; then
        mkdir -p "${AIRY_HOME}/modules"
        cp -rf "${extracted}/modules/maths-toolkit" "${AIRY_HOME}/modules/" 2>/dev/null || true
    fi
    # 以实际安装包版本固化（manifest 通道可能高于默认 AIRY_VERSION）
    local ver_num
    ver_num="$(basename "$extracted" | sed 's/^agentrt-//')"
    [ -n "$ver_num" ] && AIRY_VERSION="v${ver_num}"
    log_ok "完全体二进制包安装完成（v${ver_num:-${AIRY_VERSION}}）"
    return 0
}

# ─── 闭源预编译模块下载（模式 B） ───────────────────────────────────────
fetch_prebuilt_module() {
    # fetch_prebuilt_module <name> <url> <解压后目录名>
    # 命名注意：解压目录变量用 mod_dir，勿用 dirname —— 遮蔽系统 dirname
    # 命令且在 set -u 下 local 同语句跨赋值引用易触发 "unbound variable"
    #（dash/bash 行为差异，2026-09-05 安装事故）。赋值拆行，避免同语句依赖。
    local name="$1" url="$2" mod_dir="$3" dest tarball
    dest="${MODULES_DIR}/${mod_dir}"
    tarball="${AIRY_HOME}/tmp/${mod_dir}.tar.gz"
    [ -n "$url" ] || { log_warn "未配置 ${name} 预编译包 URL，跳过"; return 1; }
    if [ -d "$dest" ]; then log_ok "${name} 预编译模块已就位"; return 0; fi
    log_info "下载闭源预编译模块 ${name}…"
    syscurl -fL ${CURL_FLAG} --max-time 600 -o "$tarball" "$url" || { log_warn "${name} 下载失败"; return 1; }
    mkdir -p "$dest"
    tar -xzf "$tarball" -C "$dest" || { log_warn "${name} 解压失败"; return 1; }
    log_ok "${name} 预编译模块就位: ${dest}"
    return 0
}

# ─── 源码获取（模式 B/C） ───────────────────────────────────────────────
prepare_source() {
    if [ ! -d "${AIRY_SRC_DIR}/.git" ]; then
        log_info "git 拉取 airymaxhub（${AIRY_REPO_URL}）…"
        mkdir -p "$(dirname "${AIRY_SRC_DIR}")"
        # 版本来源二选一：
        #   - 用户显式指定 AIRY_VERSION → 固定 tag 精确安装（可复现/回滚）；
        #   - 未指定（curl 管道等无 VERSION 场景）→ clone 默认分支，随后从
        #     agentrt/VERSION 读取真实版本（SSoT 单一来源），杜绝 install.sh
        #     内置默认版本与当前发布漂移导致 clone 到不存在/过期 tag。
        if [ "$AIRY_VERSION_SPECIFIED" = "1" ]; then
            git clone --depth 1 -b "${AIRY_VERSION}" "${AIRY_REPO_URL}" "${AIRY_SRC_DIR}" \
                || { log_err "git 拉取失败（若子仓私有，请配置 AIRY_RELEASE_URL 走二进制模式）"; exit 1; }
        else
            git clone --depth 1 "${AIRY_REPO_URL}" "${AIRY_SRC_DIR}" \
                || { log_err "git 拉取失败（若子仓私有，请配置 AIRY_RELEASE_URL 走二进制模式）"; exit 1; }
        fi
        # --recursive：agentrt 的 7 个核心子仓（atoms/commons/daemons/gateway/
        # cupolas/protocols/heapstore）与 sdk/ecosystem 子仓均为公开仓，必须
        # 一并拉取，否则模式 C 源码构建缺核心源码必然失败。闭源子仓
        # （closed-docs / closed-dev-build / memoryrovol 标 update=none）自动跳过。
        git -C "${AIRY_SRC_DIR}" submodule update --init --recursive --depth 1 2>/dev/null || \
            log_warn "部分子仓拉取受限（闭源模块将由预编译包补齐）"
    else
        log_info "airymaxhub 源码已存在，复用本地源码树"
        git -C "${AIRY_SRC_DIR}" fetch --all --tags --depth 1 >/dev/null 2>&1 || true
    fi

    # 源码版本 SSoT：以 agentrt/VERSION 为权威（重探测布局：管理仓 submodule
    # 或平铺两种布局）。
    if [ -d "${AIRY_SRC_APP}/agentrt" ]; then :; else AIRY_SRC_APP="${AIRY_SRC_DIR}"; fi
    local real_ver
    real_ver="$(cat "${AIRY_SRC_APP}/agentrt/VERSION" 2>/dev/null | tr -d '[:space:]')"
    if [ -n "$real_ver" ]; then
        AIRY_VERSION="v${real_ver}"
        log_ok "源码版本（SSoT）: ${AIRY_VERSION}"
    fi
    log_ok "源码就绪: ${AIRY_SRC_DIR}"
}

# ─── 构建（模式 B/C 共用） ──────────────────────────────────────────────
build_and_install() {
    local build_dir="${AIRY_HOME}/build"
    local cmake_args="-DCMAKE_BUILD_TYPE=Release -DBUILD_TESTS=OFF -DENABLE_SANITIZERS=OFF -DCMAKE_INSTALL_PREFIX=${AIRY_HOME}"

    # 闭源模块预编译路径注入（模式 B）
    if [ -d "${MODULES_DIR}/atoms" ]; then
        cmake_args="${cmake_args} -DAIRY_ATOMS_PREBUILT_DIR=${MODULES_DIR}/atoms"
    fi
    # 预编译库文件名对齐真实归档名（target agentrt_memoryrovol →
    # libagentrt_memoryrovol.a），与 install.ps1 及 products/memoryrovol 一致
    if [ -f "${MODULES_DIR}/memoryrovol/libagentrt_memoryrovol.a" ]; then
        cmake_args="${cmake_args} -DMEMORYROVOL_PRO_LIB=${MODULES_DIR}/memoryrovol/libagentrt_memoryrovol.a"
    fi

    log_info "cmake 配置（${cmake_args}）…"
    cmake -S "${AIRY_SRC_APP}/agentrt" -B "${build_dir}" ${cmake_args} \
        || { log_err "cmake 配置失败"; exit 1; }
    log_info "构建（-j${AIRY_BUILD_JOBS}）…"
    cmake --build "${build_dir}" -j"${AIRY_BUILD_JOBS}" || { log_err "构建失败"; exit 1; }
    # 0.1.6g：cmake --install 与 bin/ 拷贝 fail-closed（此前 `|| true` 静默
    # 吞错——磁盘满/权限不足时"安装完成"实为残缺安装，daemon 缺失只有
    # 到 verify_daemons 才暴露，且源码构建模式无 bin/*_d 清单校验）。
    log_info "安装到 ${AIRY_HOME}…"
    cmake --install "${build_dir}" || { log_err "安装失败（cmake --install）"; exit 1; }
    if [ -d "${build_dir}/bin" ]; then
        cp -f "${build_dir}"/bin/* "${AIRY_HOME}/bin/" 2>/dev/null || true
    fi
    # 与 install_binary 同口径校验：daemon 二进制必须就位（否则后续
    # verify_daemons 必然失败，提前报错给用户明确根因）。
    local _d2 _binok=1
    for _d2 in $(daemon_list); do
        [ -x "${AIRY_HOME}/bin/${_d2}" ] || { _binok=0; log_err "构建产物缺失 daemon: ${_d2}"; break; }
    done
    [ "$_binok" = "1" ] || { log_err "源码构建安装不完整，请检查磁盘空间与权限后重试"; exit 1; }
    log_ok "源码构建安装完成"
}

# ─── Python 依赖安装 → lib/ ────────────────────────────────────────────
install_python_deps() {
    log_info "安装 Python 依赖到 ${AIRY_HOME}/lib …"
    local pkg
    for pkg in airymax_agents airymax_agents_rs orchestration; do
        [ -d "${AIRY_SRC_APP}/ecosystem/agents/${pkg}" ] || { log_warn "跳过: ecosystem/agents/${pkg}"; continue; }
        rsync -a --exclude tests --exclude __pycache__ --exclude .git --exclude examples \
            "${AIRY_SRC_APP}/ecosystem/agents/${pkg}" "${AIRY_HOME}/lib/" 2>/dev/null \
            || cp -r "${AIRY_SRC_APP}/ecosystem/agents/${pkg}" "${AIRY_HOME}/lib/"
    done
    if [ -d "${AIRY_SRC_APP}/sdk/sdk-python/agentrt" ]; then
        rsync -a --exclude tests --exclude __pycache__ --exclude .git \
            "${AIRY_SRC_APP}/sdk/sdk-python/agentrt" "${AIRY_HOME}/lib/" 2>/dev/null \
            || cp -r "${AIRY_SRC_APP}/sdk/sdk-python/agentrt" "${AIRY_HOME}/lib/"
    fi
    if command -v python3 >/dev/null 2>&1; then
        if PYTHONPATH="${AIRY_HOME}/lib" python3 -c "import agentrt, airymax_agents, orchestration" 2>/dev/null; then
            log_ok "Python 依赖可导入 (agentrt/airymax_agents/orchestration)"
        else
            log_warn "lib/ 导入校验失败（检查源码包结构）"
        fi
    fi
}

# ─── 出厂预装 maths-toolkit（数学计算后端） ─────────────────────────────
# MCP-Mathematics + sympy-mcp 组合，共享 $AIRY_HOME/venv，默认不装
# einsteinpy。python3 缺失或安装失败时降级警告（maths_d 纯 C 快速路径
# 仍可用），不阻断 agentrt 主流程。--without-maths 可跳过。
install_maths_toolkit() {
    if [ "$WITH_MATHS" != "1" ]; then
        log_info "已跳过 maths-toolkit（--without-maths）"
        return 0
    fi
    local toolkit=""
    # 源码模式：airymaxhub 源码树内；二进制模式：随完全体包分发的 modules/
    if [ -f "${AIRY_SRC_APP}/ecosystem/markets/tools/maths-toolkit/install.sh" ]; then
        toolkit="${AIRY_SRC_APP}/ecosystem/markets/tools/maths-toolkit/install.sh"
    elif [ -f "${AIRY_HOME}/modules/maths-toolkit/install.sh" ]; then
        toolkit="${AIRY_HOME}/modules/maths-toolkit/install.sh"
    fi
    if [ -z "$toolkit" ]; then
        log_warn "maths-toolkit 安装器不存在（源码与二进制模式均未携带），跳过数学后端预装"
        return 0
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        log_warn "未找到 python3，跳过 maths-toolkit（maths_d 纯 C 快速路径可用）"
        return 0
    fi
    log_info "出厂预装数学计算后端（包内离线 wheel 优先 + 在线自动更新，失败降级纯 C 快速路径）…"
    # 子安装器优先 bash（兼容 sh 异常/被替换的环境，如部分容器 dash 静默
    # 不执行）；无 bash 时回退 sh。子安装器失败不阻断 agentrt 主流程。
    local run_sh="sh"
    command -v bash >/dev/null 2>&1 && run_sh="bash"
    if run_spin "预装数学计算后端（maths-toolkit：离线 wheel 优先，失败降级纯 C 快速路径）…" \
        "$run_sh" "$toolkit" --airy-home "${AIRY_HOME}"; then
        # 安装器返回 0 不代表依赖就绪（2026-08-29 教训：maths-toolkit 曾
        # 在 pip 失败时静默返回 0）；此处校验 venv+sympy 真实可用才报 OK。
        if [ -x "${AIRY_HOME}/venv/bin/python3" ] && \
           "${AIRY_HOME}/venv/bin/python3" -c "import sympy" >/dev/null 2>&1; then
            log_ok "maths-toolkit 安装完成（maths_d 符号计算后端已就绪）"
        else
            log_warn "maths-toolkit 安装器返回成功但后端不可用（venv/sympy 缺失），已降级：maths_d 纯 C 快速路径可用；"
            log_warn "包内已内置离线 wheel，可重试: sh ${toolkit} --airy-home ${AIRY_HOME}"
        fi
    else
        log_warn "maths-toolkit 安装失败（离线 wheel 与在线源均不可用），已降级：maths_d 纯 C 快速路径可用；"
        log_warn "包内已内置离线 wheel，可重试: sh ${toolkit} --airy-home ${AIRY_HOME}"
    fi
}

# ─── MemoryRovol OSS 库构建（TUI 独立链接用，源码模式） ───────────────
# TUI 是独立 Rust 二进制，无法链接 PRO 库（依赖 agentrt 运行时符号）；
# 本地持有 memoryrovol 源码（模式 C）时以 OSS 模式（L1+L2）编译并部署为
# $AIRY_HOME/lib/libagentrt_memoryrovol_oss.a，TUI build.rs 才会选中它
#（2.6：本地源码构建 memoryrovol 全功能开启）。无源码则跳过，
# TUI 降级 JsonlMemory（真实可用后备）。
build_mr_oss() {
    local mr_src="${AIRY_SRC_APP}/products/memoryrovol"
    [ -d "$mr_src" ] || { log_warn "products/memoryrovol 源码缺失，跳过 OSS 库构建（TUI 降级 JsonlMemory）"; return 0; }
    local mr_build="${AIRY_HOME}/build-mr-oss"
    log_info "构建 MemoryRovol OSS 库（L1+L2，TUI 独立链接）…"
    cmake -S "$mr_src" -B "$mr_build" \
        -DCMAKE_BUILD_TYPE=Release -DMEMORYROVOL_OSS=ON -DBUILD_TESTS=OFF \
        || { log_warn "memoryrovol OSS cmake 配置失败，TUI 降级 JsonlMemory"; return 0; }
    cmake --build "$mr_build" -j"${AIRY_BUILD_JOBS}" 2>&1 | tail -5 \
        || { log_warn "memoryrovol OSS 构建失败，TUI 降级 JsonlMemory"; return 0; }
    local oss_lib="$mr_build/src/libagentrt_memoryrovol.a"
    if [ -f "$oss_lib" ]; then
        cp -f "$oss_lib" "${AIRY_HOME}/lib/libagentrt_memoryrovol_oss.a"
        log_ok "MemoryRovol OSS 库就位: ${AIRY_HOME}/lib/libagentrt_memoryrovol_oss.a"
    else
        log_warn "OSS 库产物缺失（${oss_lib}），TUI 降级 JsonlMemory"
    fi
}

# ─── Rust TUI 构建（源码模式附带） ─────────────────────────────────────
build_tui() {
    [ -d "${AIRY_SRC_APP}/sdk/tui" ] || return 0
    # AIRY_HOME 需 export 给 cargo 子进程：TUI build.rs 据此定位
    # $AIRY_HOME/lib/libagentrt_memoryrovol.a（TUI memoryrovol 全功能链接）。
    export AIRY_HOME
    if ! command -v cargo >/dev/null 2>&1 && [ -x "$HOME/.cargo/bin/cargo" ]; then
        export PATH="$HOME/.cargo/bin:$PATH"
    fi
    command -v cargo >/dev/null 2>&1 || { log_warn "cargo 不可用，跳过 agentrt-tui"; return 0; }
    # 构建产物收敛（铁律 4.7）：CARGO_TARGET_DIR 重定向到 $AIRY_HOME/target，
    # 禁止 cargo 在源码树 sdk/tui/target 落盘（曾有 1.7G 泄漏）。
    export CARGO_TARGET_DIR="${AIRY_HOME}/target"
    log_info "构建 agentrt-tui（Rust TUI，产物 → ${CARGO_TARGET_DIR}）…"
    ( cd "${AIRY_SRC_APP}/sdk/tui" && cargo build --release ) 2>/dev/null || { log_warn "TUI 构建失败，跳过"; return 0; }
    [ -f "${CARGO_TARGET_DIR}/release/agentrt-tui" ] && \
        cp -f "${CARGO_TARGET_DIR}/release/agentrt-tui" "${AIRY_HOME}/bin/agentrt-tui"
    log_ok "agentrt-tui 部署完成"
}

# ─── CLI 兼容入口：Rust TUI 缺失时用 C airy_cli 提供 agentrt-tui ──────
# airymaxrt 启动器通过 TUI 可执行文件进入交互界面；当 Rust TUI 未构建
# （cargo 缺失 / 构建失败 / 二进制包未含）时，以 C 实现的 airy_cli 作为
# agentrt-tui 兼容入口，保证 `airymaxrt` 始终可用。包装脚本 source
# install-pinned 的 agentrt-env.sh，导出 AIRY_HOME 等，使 CLI 能连接已
# 安装的 daemon（不受调用 shell 的环境变量影响）。
ensure_cli_entry() {
    [ -x "${AIRY_HOME}/bin/agentrt-tui" ] && return 0
    if [ -x "${AIRY_HOME}/bin/airy_cli" ]; then
        cat > "${AIRY_HOME}/bin/agentrt-tui" <<'TUIEOF'
#!/bin/sh
# SPDX-FileCopyrightText: 2025-2026 SPHARX Ltd.
# SPDX-License-Identifier: AGPL-3.0-or-later OR Apache-2.0
# agentrt-tui compat entry for the C airy_cli (used when the Rust TUI is
# not built). Sources the install-pinned environment so the CLI reaches
# the installed daemons regardless of the calling shell.
_DIR="$(cd -P "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$_DIR/agentrt-env.sh"
exec "$_DIR/airy_cli" "$@"
TUIEOF
        chmod 755 "${AIRY_HOME}/bin/agentrt-tui"
        log_ok "agentrt-tui 使用 C airy_cli 兼容入口（Rust TUI 未构建）"
    else
        log_warn "agentrt-tui 与 airy_cli 均缺失"
    fi
}

# ─── secrets.env 模板 ──────────────────────────────────────────────────
init_secrets() {
    local secrets="${AIRY_HOME}/config/secrets.env"
    if [ ! -f "${secrets}" ]; then
        local template="${AIRY_SRC_DIR}/tools/scripts/ops/templates/secrets.env.example"
        # 二进制模式无源码树：回退到随包分发的 config/secrets.env.example
        [ -f "${template}" ] || template="${AIRY_HOME}/config/secrets.env.example"
        if [ -f "${template}" ]; then
            cp "${template}" "${secrets}"
            chmod 600 "${secrets}"
            log_warn "已生成 ${secrets}，请填写 LLM API key"
        else
            log_warn "未找到 secrets.env 模板，跳过"
        fi
    else
        log_ok "secrets.env 已存在，跳过"
    fi
    [ -f "${AIRY_SRC_APP}/ecosystem/manager/configs/agentrt.yaml" ] && \
        cp -f "${AIRY_SRC_APP}/ecosystem/manager/configs/agentrt.yaml" "${AIRY_HOME}/config/" 2>/dev/null || true
    [ -f "${AIRY_SRC_APP}/ecosystem/manager/model/model.yaml" ] && \
        cp -f "${AIRY_SRC_APP}/ecosystem/manager/model/model.yaml" "${AIRY_HOME}/config/" 2>/dev/null || true
    # 工具级权限规则（fail-closed：缺文件时 tool_d/agent_d 拒绝全部工具调用）。
    # 模板授予 coding_v1 标准编码工具集；生产部署应按最小权限裁剪。
    # 权威路径 $AIRY_HOME/config/cupolas/permission_rules.yaml
    # （daemon_cupolas_bootstrap.c 启动时读取，缺 cupolas 才回退
    #  $AIRY_HOME/config/permission_rules.yaml 兼容旧部署）。
    # 注意：模板是 SSoT，必须每次覆盖（不跳过已存在文件），否则模板演进
    # （如新增工具授权 fs_delete）无法随重装生效，造成运行时 ACL 陈旧。
    local rules_tpl="${AIRY_SRC_DIR}/tools/scripts/ops/templates/permission_rules.yaml"
    [ -f "${rules_tpl}" ] || rules_tpl="${AIRY_HOME}/config/permission_rules.yaml"
    if [ -f "${rules_tpl}" ]; then
        mkdir -p "${AIRY_HOME}/config/cupolas"
        cp -f "${rules_tpl}" "${AIRY_HOME}/config/cupolas/permission_rules.yaml"
        chmod 600 "${AIRY_HOME}/config/cupolas/permission_rules.yaml"
        log_ok "已部署工具权限规则 ${AIRY_HOME}/config/cupolas/permission_rules.yaml"
    else
        log_warn "未找到 permission_rules.yaml 模板，工具调用将 fail-closed 拒绝"
    fi
}

# ─── PATH 自动引导（2.3.2.6 增强，2026-08-24） ────────────────────────
# 根因：默认 BIN_DIR=~/.local/bin 在多数新系统不在 PATH——安装器此前只
# 提示"请手动 export"，用户不执行就永远 command not found（只能完整路径
# 启动）。彻底解决：安装时自动幂等追加 BIN_DIR 到当前 shell 的 rc 文件
# （带标记行，可卸载移除），并固化 rc 路径到 install.env 供卸载与
# airymaxrt 启动器自愈使用；rc 不可写时回退提示。
path_rc_file() {
    case "$(basename "${SHELL:-/bin/sh}")" in
        zsh) echo "$HOME/.zshrc" ;;
        fish) echo "$HOME/.config/fish/config.fish" ;;
        sh|dash|ash) echo "$HOME/.profile" ;;
        *) echo "$HOME/.bashrc" ;;
    esac
}

# 返回 0 已引导（rc 含标记行或成功追加）；1 追加失败（已提示手动命令）。
path_bootstrap() {
    local rc
    rc="$(path_rc_file)"
    if [ -f "$rc" ] && grep -q '# >>> AgentRT PATH bootstrap <<<' "$rc" 2>/dev/null; then
        log_info "PATH 引导: $rc 已包含 AgentRT PATH 行（幂等跳过）"
        env_set "AIRY_PATH_RC=$rc"
        env_set "AIRY_PATH_APPENDED=yes"
        return 0
    fi
    local line
    if [ "$(basename "$rc")" = "config.fish" ]; then
        line="set -gx PATH \"${BIN_DIR}\" \$PATH"
    else
        line="export PATH=\"${BIN_DIR}:\$PATH\""
    fi
    if { printf '\n# >>> AgentRT PATH bootstrap <<<\n%s\n# <<< AgentRT PATH bootstrap <<<\n' "$line" ; } >> "$rc" 2>/dev/null; then
        log_ok "PATH 引导: 已自动追加 ${BIN_DIR} 到 ${rc}（新开终端生效，或执行 source \"$rc\"）"
        env_set "AIRY_PATH_RC=$rc"
        env_set "AIRY_PATH_APPENDED=yes"
        return 0
    fi
    log_warn "PATH 引导: 无法写入 ${rc}（自动追加失败），请手动执行:"
    log_warn "  echo '${line}' >> \"$rc\" && source \"$rc\""
    env_set "AIRY_PATH_APPENDED=no"
    return 1
}

# ─── 硬件评估与画像固化（2.3.5/2.3.6 硬件自适应裁剪） ──────────────
# 与 airymaxrt 启动器 assess_hardware/detect_accel/detect_arch 同口径
# （SSoT 单一判据，见 sdk/tui/scripts/airymaxrt）：
#   minimal：MemTotal < 2.5GiB 或 MemAvailable < 1.5GiB 或 CPU 核数 < 3
#     （端侧/低配设备：2GB 内存级别 ARM 设备等，启动器仅拉起 llm/think/agent/tool
#     核心 daemon，其余能力 daemon 裁剪，gateway 自动降级，避免 OOM）
#   full：资源充足（大型服务器/个人电脑）
# 加速器探测（nvidia-smi / rocm-smi / /dev/dri）记录到画像——为本地推理
# 能力判定预留依据；airymaxrt monitor 在检测到外设增强（插卡/扩容）时
# 自动恢复被裁剪 daemon（见 sdk/tui/scripts/airymaxrt）。
# 架构检测（uname -m 归一化）：二进制模式按架构选择预编译包
# （AIRY_RELEASE_URL 支持 {arch} 占位符），并固化到画像供后续校验。
detect_arch() {
    local _m _bits
    _m="$(uname -m 2>/dev/null)"
    # 用户空间位数复判（0.1.6c 教训）：uname -m 报告内核架构，64 位内核 +
    # 32 位用户空间（armhf / 老 x86 系统）会误报 64 位。以
    # getconf LONG_BIT（用户空间 C long 位数）为主判据，缺失时用加载器
    # 存在性兜底。三架构（x86/ARM/RISC-V）的 32/64 位全覆盖。
    _bits="$(getconf LONG_BIT 2>/dev/null)"
    case "$_m" in
        x86_64|amd64)
            if [ "$_bits" = "64" ] || [ -f /lib64/ld-linux-x86-64.so.2 ]; then
                echo "x86_64"
            else
                echo "i686"
            fi
            ;;
        i386|i486|i586|i686|x86) echo "i686" ;;
        aarch64|arm64)
            if [ "$_bits" = "64" ] || [ -f /lib/ld-linux-aarch64.so.1 ]; then
                echo "aarch64"
            else
                echo "armv7l"
            fi
            ;;
        armv7l|armv6l|armhf) echo "armv7l" ;;
        riscv64)
            if [ "$_bits" = "64" ] || [ -f /lib/ld-linux-riscv64-lp64d.so.1 ]; then
                echo "riscv64"
            else
                echo "riscv32"
            fi
            ;;
        riscv32|riscv) echo "riscv32" ;;
        *)                echo "unknown" ;;
    esac
}
# 预编译包支持的架构清单（binary 模式校验；其余架构回退源码构建）
# 与 CI release.yml build-linux-riscv-64 job（agentrt-<v>-linux-riscv-64.tar.gz）
# 及 sdk/tui/scripts/airymaxrt detect_arch 同口径。
# 六架构全覆盖（2026-08-30 决策：硬件使用最大化）：x86（x86-64/x86-32）、
# ARM（arm-64/arm-32）、RISC-V（riscv-64/riscv-32）的 32 与 64 位全兼容；
# detect_arch 以用户空间位数复判，杜绝 64 位内核 + 32 位用户空间误装。
SUPPORTED_ARCHS="x86_64 aarch64 riscv64 i686 armv7l riscv32"

# 制品平台命名规范（0.1.10 起，用户定案）：OS-架构族-位宽，弃用
# i686/armv7l/x64/arm64 等架构行话。技术架构名（detect_arch 输出，
# uname -m 事实）→ 制品平台后缀（架构族-位宽）：
#   x86_64→x86-64  i686→x86-32  aarch64→arm-64  armv7l→arm-32
#   riscv64→riscv-64  riscv32→riscv-32
# 全键 = OS 前缀 + 后缀（linux-x86-64 / macos-arm-64 / win-x86-64…）。
# 与 build.sh PLATFORM 映射、latest/airymaxrt runtime_platform 同口径。
plat_name() {
    case "$1" in
        x86_64)  echo "x86-64" ;;
        i686)    echo "x86-32" ;;
        aarch64) echo "arm-64" ;;
        armv7l)  echo "arm-32" ;;
        riscv64) echo "riscv-64" ;;
        riscv32) echo "riscv-32" ;;
        *)       echo "$1" ;;
    esac
}
# 平台键兼容反查（三代 manifest）：本版主键 = OS-架构族-位宽（gen3）；
# 旧两代依次回退：gen2（0.1.6e~0.1.10：linux-x64/x86/arm64/arm32…）→
# gen1（≤0.1.6d：uname 原始名 linux-x86_64/i686/aarch64/armv7l…）。
# 逐行输出候选，调用方依序尝试 parse_manifest。与 publish-release.sh
# ALIAS 表、latest/airymaxrt plat_legacy_name 同口径（SSoT）。
plat_legacy_name() {
    case "$1" in
        linux-x86-64|macos-x86-64|win-x86-64) printf '%s\n' "${1%-x86-64}-x64" "${1%-x86-64}-x86_64" ;;
        linux-x86-32|macos-x86-32|win-x86-32) printf '%s\n' "${1%-x86-32}-x86" "${1%-x86-32}-i686" ;;
        linux-arm-64|macos-arm-64|win-arm-64) printf '%s\n' "${1%-arm-64}-arm64" "${1%-arm-64}-aarch64" ;;
        linux-arm-32|macos-arm-32|win-arm-32) printf '%s\n' "${1%-arm-32}-arm32" "${1%-arm-32}-armv7l" ;;
        linux-riscv-64|win-riscv-64)          echo "${1%-riscv-64}-riscv64" ;;
        linux-riscv-32|win-riscv-32)          echo "${1%-riscv-32}-riscv32" ;;
        *)                                    echo "" ;;
    esac
}
# 某技术架构允许的包内 platform-* 标记（三代全兼容：新安装器安装存量
# gen2/gen1 离线包不误拒；异架构标记仍明确拒绝）。与 CI 打包标记同口径。
plat_markers() {
    case "$1" in
        x86_64)  printf 'platform-x86-64 platform-x64 platform-x86_64 platform-amd64' ;;
        i686)    printf 'platform-x86-32 platform-x86 platform-i686 platform-i386' ;;
        aarch64) printf 'platform-arm-64 platform-arm64 platform-aarch64' ;;
        armv7l)  printf 'platform-arm-32 platform-arm32 platform-armv7l' ;;
        riscv64) printf 'platform-riscv-64 platform-riscv64' ;;
        riscv32) printf 'platform-riscv-32 platform-riscv32' ;;
        *)       echo "" ;;
    esac
}

detect_accel() {
    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
        echo "nvidia:$(nvidia-smi -L 2>/dev/null | wc -l)"
    elif command -v rocm-smi >/dev/null 2>&1; then
        echo "rocm"
    elif [ -d /dev/dri ] && ls /dev/dri/renderD* >/dev/null 2>&1; then
        echo "dri"
    else
        echo "none"
    fi
}

assess_hardware() {
    local mem_kib mem_avail_kib nproc_val accel profile
    # 跨平台内存探测：Linux 读 /proc/meminfo；macOS/BSD 无 /proc，回退
    # sysctl（hw.memsize 单位字节 → KiB）。此前仅 /proc 导致 macOS 恒判
    # minimal（非致命但画像错误，2026-08-25 修复）。
    if [ -r /proc/meminfo ]; then
        mem_kib="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
        mem_avail_kib="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null || echo "${mem_kib:-0}")"
    elif command -v sysctl >/dev/null 2>&1; then
        mem_kib="$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 ))"
        mem_avail_kib="$mem_kib"
    else
        mem_kib=0
        mem_avail_kib=0
    fi
    # 跨平台 CPU 核数：nproc（GNU）→ sysctl hw.ncpu（macOS/BSD）→ 1
    if command -v nproc >/dev/null 2>&1; then
        nproc_val="$(nproc 2>/dev/null || echo 1)"
    elif command -v sysctl >/dev/null 2>&1; then
        nproc_val="$(sysctl -n hw.ncpu 2>/dev/null || echo 1)"
    else
        nproc_val=1
    fi
    accel="$(detect_accel)"
    if [ -n "$mem_kib" ] && [ "$mem_kib" -gt 0 ] && \
       [ "$mem_kib" -ge $((2560 * 1024)) ] && \
       [ "$mem_avail_kib" -ge $((1536 * 1024)) ] && \
       [ "$nproc_val" -ge 3 ]; then
        profile="full"
    else
        profile="minimal"
    fi
    printf '%s|%s|%s|%s|%s' "$profile" "${mem_kib:-0}" "${mem_avail_kib:-0}" "$nproc_val" "$accel"
}

# 固化运行画像到 $AIRY_HOME/config/profile.env（airymaxrt 启动器启动时
# 优先读取，见 sdk/tui/scripts/airymaxrt PROFILE_ENV）。install.env 保持
# 只读（安装信息），画像允许被 `airymaxrt profile` / monitor 跨会话调整。
persist_profile() {
    local hw hw_profile mem total avail cores accel
    hw="$(assess_hardware)"
    hw_profile="${hw%%|*}"
    mem="${hw#*|}"
    total="${mem%%|*}"; mem="${mem#*|}"
    avail="${mem%%|*}"; mem="${mem#*|}"
    cores="${mem%%|*}"
    accel="${mem#*|}"
    # auto 画像以硬件评估为准；显式 --profile 尊重用户选择
    if [ "$AIRY_PROFILE" != "auto" ]; then
        hw_profile="$AIRY_PROFILE"
    fi
    mkdir -p "${AIRY_HOME}/config"
    {
        echo "# AgentRT 运行画像（由 install.sh 生成，airymaxrt 启动器读取）"
        echo "AIRY_PROFILE=${hw_profile}"
        echo "AIRY_HW_ARCH=$(detect_arch)"
        echo "AIRY_HW_MEM_TOTAL_KIB=${total}"
        echo "AIRY_HW_MEM_AVAIL_KIB=${avail}"
        echo "AIRY_HW_CPU_CORES=${cores}"
        echo "AIRY_HW_ACCEL=${accel}"
    } > "${AIRY_HOME}/config/profile.env"
    chmod 600 "${AIRY_HOME}/config/profile.env" 2>/dev/null || true
    log_ok "运行画像已固化: ${hw_profile}（${AIRY_HW_ARCH:-$(detect_arch)} · 内存 ${total}KiB/可用 ${avail}KiB · CPU ${cores} 核 · 加速器 ${accel}）"
    log_info "  硬件变化后（内存扩容/插入显卡）执行 'airymaxrt profile' 重评估，"
    log_info "  或 'airymaxrt monitor --daemon' 后台常驻自动恢复被裁剪功能"
}

# ─── 固化安装位置 + 生成运行环境 + 启动器软链 ──────────────────────────
finalize_install() {
    # 生成 vault 主密钥口令（AES-256-GCM 凭据加密）。随机强口令，缺失回退链：
    # openssl rand → od /dev/urandom（POSIX：BSD od 亦支持 -N，替代 GNU
    # head -c）→ 时间戳+urandom 哈希 cksum（POSIX，替代 Linux 特有 sha256sum）。
    local vault_password
    vault_password=$(openssl rand -hex 32 2>/dev/null \
        || { od -An -tx1 -N32 /dev/urandom 2>/dev/null | tr -d ' \n'; })
    if [ -z "${vault_password}" ]; then
        vault_password="$( { date '+%s%N'; od -An -tx1 -N64 /dev/urandom 2>/dev/null; } | cksum | cut -c1-64 )"
    fi
    {
        echo "# AgentRT 安装信息（由 install.sh 生成，勿手改）"
        echo "AIRY_HOME=${AIRY_HOME}"
        echo "AIRY_VERSION=${AIRY_VERSION}"
        # 已安装制品 sha256（update 同版本修复重发检测依据；源码构建/旧安装留空）
        echo "AIRY_ARTIFACT_SHA256=${AIRY_ARTIFACT_SHA256:-}"
        echo "AIRY_CHANNEL=${AIRY_CHANNEL}"
        echo "AIRY_BIN_LINK=${BIN_DIR}/airymaxrt"
        echo "INSTALLED_AT=$(date -Is 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')"
        echo "AIRY_VAULT_PASSWORD=${vault_password}"
    } > "${AIRY_HOME}/config/install.env"
    chmod 600 "${AIRY_HOME}/config/install.env"

    # 引号 heredoc（<<'EOF'）：dash + set -u 下 \${...} 在无引号 heredoc 中会被
    # 错误展开（"AIRY_CONFIG_DIR: parameter not set" 中止写入，agentrt-env.sh
    # 变空文件——2026-08-25 实测复现）。引号 heredoc 杜绝一切展开，AIRY_HOME
    # 实际值用占位符 __AIRY_HOME__ + sed 注入。
    cat > "${AIRY_HOME}/bin/agentrt-env.sh" <<'AIRY_ENV_EOF'
#!/bin/sh
# AgentRT 运行环境（由 install.sh 生成，source 使用）
# AIRY_HOME 以调用方显式设置优先（隔离测试/多实例/--prefix 自定义安装），
# 缺省回退安装时固化值；无条件 export 会覆盖显式设置，导致 daemon 群与
# 调用方等待探测的 socket 目录分叉（历史故障：socket 未就绪 + 第二实例
# 抢占生产 socket）。
AIRY_HOME="${AIRY_HOME:-__AIRY_HOME__}"
export AIRY_HOME
# 0.1.6c 系统性修复：AIRY_HOME 为权威运行根，子目录一律强制从最终
# AIRY_HOME 派生。父环境残留的旧 AIRY_* 值（历史安装 export/终端残留）
# 会使 daemon 从旧目录启动、socket 探测分叉（实测复现）。多实例/--prefix
# 经 AIRY_HOME 显式覆盖即可，子目录自动跟随。
export AIRY_RUNTIME_DIR="$AIRY_HOME/run"
# 运行时数据全量统一于 $AIRY_HOME/data/agentrt（2026-08-25）：日志/缓存/
# 临时/持久化工作区均收敛其下，顶层仅保留分发物、用户配置与易失 run/。
export AIRY_LOG_DIR="$AIRY_HOME/data/agentrt/logs"
export AIRY_CONFIG_DIR="$AIRY_HOME/config"
export AIRY_BIN_DIR="$AIRY_HOME/bin"
export AIRY_LIB_DIR="$AIRY_HOME/lib"
export AIRY_DATA_DIR="$AIRY_HOME/data"
export AIRY_CACHE_DIR="$AIRY_HOME/data/agentrt/cache"
export AIRY_TMP_DIR="$AIRY_HOME/data/agentrt/tmp"
export AIRY_WORKSPACE_DIR="$AIRY_HOME/data/agentrt/workspaces"
# Python 字节码缓存收敛：editable 安装的包源码位于源码区，PYTHONPYCACHEPREFIX
# 将所有 __pycache__ 重定向到 $AIRY_HOME/data/agentrt/cache/pycache，禁止落盘源码区。
export PYTHONPYCACHEPREFIX="${PYTHONPYCACHEPREFIX:-$AIRY_HOME/data/agentrt/cache/pycache}"
# Agent 工具 ACL：默认不设（fail-closed，以 $AIRY_CONFIG_DIR/permission_rules.yaml
# 为唯一权威源，按角色最小权限授权）。高级部署可显式覆盖收紧，如
# AIRY_AGENT_ACL="coding_v1=fs_read,fs_glob"。
export AIRY_AGENT_ACL="${AIRY_AGENT_ACL:-}"
export PATH="${AIRY_HOME}/bin:$PATH"
# 运行时 .so 兜底（0.1.6 社区 bug 根治：0.1.5a 旧包未做 .so 自包含，二进制
# 依赖 libcjson.so.1 等非系统库且无 $ORIGIN/../lib RUNPATH，系统无 libcjson1
# 时 daemon/airy_cli/agentrt-tui 启动即失败）。二进制内置 $ORIGIN/../lib
# RUNPATH 为主路径，此处 LD_LIBRARY_PATH 为兜底——即便包部署路径异常，
# 只要 $AIRY_HOME/lib 存在即可正常加载。
export LD_LIBRARY_PATH="${AIRY_HOME}/lib:${LD_LIBRARY_PATH:-}"
AIRY_ENV_EOF
    sed "s|__AIRY_HOME__|${AIRY_HOME}|g" "${AIRY_HOME}/bin/agentrt-env.sh" > "${AIRY_HOME}/bin/agentrt-env.sh.tmp" && \
        mv "${AIRY_HOME}/bin/agentrt-env.sh.tmp" "${AIRY_HOME}/bin/agentrt-env.sh"
    chmod 700 "${AIRY_HOME}/bin/agentrt-env.sh"

    # 启动器软链：任意路径输入 airymaxrt 即启动（读 install.env 定位运行时根）
    if [ -f "${AIRY_SRC_APP}/sdk/tui/scripts/airymaxrt" ]; then
        cp -f "${AIRY_SRC_APP}/sdk/tui/scripts/airymaxrt" "${AIRY_HOME}/bin/airymaxrt"
        chmod 755 "${AIRY_HOME}/bin/airymaxrt"
    else
        # 二进制模式无源码：无论 TUI 是否存在都生成轻量启动器（前端选择
        # 逻辑：有 TTY+TUI → TUI；否则 → airy_cli；管理命令自举 airymaxrt-full）。
        # 历史 bug：elif 依赖 agentrt-tui 存在，arm32 等无 TUI 架构整段跳过，
        # bin/airymaxrt 不生成 → 用户继续运行旧版残留启动器（清单/格式错乱）。
        cat > "${AIRY_HOME}/bin/airymaxrt" <<EOF
#!/bin/sh
_SELF="\$0"
while [ -L "\$_SELF" ]; do
    _LINK="\$(readlink "\$_SELF")"
    case "\$_LINK" in
        /*) _SELF="\$_LINK" ;;
        *)  _SELF="\$(dirname "\$_SELF")/\$_LINK" ;;
    esac
done
_DIR="\$(cd -P "\$(dirname "\$_SELF")" && pwd)"
# 解析顺序：环境变量（须通过 airy_cli 存在性校验——终端残留 export
# 指向已删除目录时自动失效）→ install.env 固化值（同样校验）→
# 默认统一安装根。
_AH="\${AIRY_HOME:-}"
[ -n "\$_AH" ] && [ -x "\$_AH/bin/airy_cli" ] || _AH=""
if [ -z "\$_AH" ]; then
    _AH="\$(sed -n 's/^AIRY_HOME=//p' "\${_DIR}/../config/install.env" 2>/dev/null | head -1)"
    [ -x "\$_AH/bin/airy_cli" ] || _AH=""
fi
[ -n "\$_AH" ] || _AH="\$HOME/.airymaxrt"
AIRY_HOME="\$_AH"
export AIRY_HOME
# 0.1.6f 系统性修复：curl 符号崩溃隔离（与安装器 syscurl 同构，无 local，
# POSIX 兼容）。本启动器已注入 LD_LIBRARY_PATH=\$AIRY_HOME/lib，其中自编译
# libcurl 与宿主 libssl 不匹配时 curl 报 "symbol lookup error: undefined
# symbol: curl_easy_ssls_import, version CURL_OPENSSL_4" 崩溃（32 位 ARM
# airymaxrt update 实测）。管理命令自举与 gateway ping 等网络请求统一走
# syscurl：剔除 \$AIRY_HOME/lib 后调系统 curl。
syscurl() {
    _sc_ldp=""
    _sc_rest="\${LD_LIBRARY_PATH:-}"
    _sc_seg=""
    while [ -n "\$_sc_rest" ]; do
        _sc_seg="\${_sc_rest%%:*}"
        [ "\$_sc_seg" = "\${AIRY_HOME}/lib" ] || _sc_ldp="\${_sc_ldp:+\$_sc_ldp:}\$_sc_seg"
        [ "\$_sc_seg" = "\$_sc_rest" ] && _sc_rest="" || _sc_rest="\${_sc_rest#*:}"
    done
    if [ -n "\$_sc_ldp" ]; then
        env LD_LIBRARY_PATH="\$_sc_ldp" curl "\$@"
    else
        env -u LD_LIBRARY_PATH curl "\$@"
    fi
}
# 运行环境注入（0.1.6b 缺陷修复：社区"很多库找不到 / daemon 群起不来"）。
# 包内 lib/ 自带全部第三方 .so，但 DT_RUNPATH 非传递性——daemon 的直接
# 依赖可经 \$ORIGIN/../lib 找到，而 libcurl 等的传递依赖只能走系统路径；
# 宿主缺 gnutls/ssh/rtmp 等库时 daemon 启动即失败。source 安装期生成的
# agentrt-env.sh（含 LD_LIBRARY_PATH=\$AIRY_HOME/lib），使无参数入口后续
# 的 bootstrap 与前端全部继承（bootstrap 侧亦有同源兜底）。
if [ -f "\${AIRY_HOME}/bin/agentrt-env.sh" ]; then
    . "\${AIRY_HOME}/bin/agentrt-env.sh"
    AIRY_HOME="\$_AH"
fi
# 0.1.6c 系统性修复：幂等运行库路径兜底。老用户（0.1.5a 及更早安装）的
# agentrt-env.sh 无 LD_LIBRARY_PATH 注入行（airymaxrt update 热替换不重新
# 生成 env.sh），仅 source 不会注入；此处确保 \$AIRY_HOME/lib 始终在
# LD_LIBRARY_PATH 首位（已含则跳过），与完整启动器 airymaxrt 兜底同源。
case ":\${LD_LIBRARY_PATH:-}:" in
    *":\${AIRY_HOME}/lib:"*) ;;
    *) export LD_LIBRARY_PATH="\${AIRY_HOME}/lib:\${LD_LIBRARY_PATH:-}" ;;
esac
# PATH 自愈（与完整启动器对齐）：BIN_DIR 软链目录不在 PATH 时自动追加
# 当前 shell 的 rc 文件（带 AgentRT 标记行，幂等，卸载可移除）。根治
# 社区用户"一键安装后 command not found"——安装器已引导过 rc，此处再兜底
# 覆盖 rc 丢失/换 shell/多用户等场景。
_BINLINK="\$(sed -n 's/^AIRY_BIN_LINK=//p' "\${AIRY_HOME}/config/install.env" 2>/dev/null | head -1)"
_BINLINK="\${_BINLINK:-\$HOME/.local/bin/airymaxrt}"
_BINDIR="\${_BINLINK%/airymaxrt}"
_INPATH=0
_P="\$PATH"
while [ -n "\$_P" ]; do
    _SEG="\${_P%%:*}"
    [ "\$_SEG" = "\$_BINDIR" ] && _INPATH=1
    [ "\$_SEG" = "\$_P" ] && _P="" || _P="\${_P#*:}"
    [ "\$_INPATH" = "1" ] && break
done
if [ "\$_INPATH" != "1" ] && [ -n "\$_BINDIR" ]; then
    case "\$(basename "\${SHELL:-/bin/sh}")" in
        zsh) _RC="\$HOME/.zshrc" ;;
        fish) _RC="\$HOME/.config/fish/config.fish" ;;
        sh|dash|ash) _RC="\$HOME/.profile" ;;
        *) _RC="\$HOME/.bashrc" ;;
    esac
    if ! grep -q '# >>> AgentRT PATH bootstrap <<<' "\$_RC" 2>/dev/null; then
        if [ "\$(basename "\$_RC")" = "config.fish" ]; then
            _LINE=\$(printf 'set -gx PATH "%s" \$PATH' "\$_BINDIR")
        else
            _LINE=\$(printf 'export PATH="%s:\$PATH"' "\$_BINDIR")
        fi
        printf '\n# >>> AgentRT PATH bootstrap <<<\n%s\n# <<< AgentRT PATH bootstrap <<<\n' "\$_LINE" >> "\$_RC" 2>/dev/null \
            && echo "airymaxrt: 已自动将 \${_BINDIR} 追加到 \${_RC}（新开终端生效，或 source \"\$_RC\"）" >&2
    fi
fi
# 管理命令自举：二进制模式轻量启动器仅提供 TUI/CLI 前端入口，完整启动器
# （含 start/status/doctor/cli/profile/monitor/uninstall/update 等管理命令）
# 随发布以 latest/airymaxrt 分发（sdk 仓私有，匿名不可达，须经公开 agentrt
# 仓 contents API 匿名拉取，raw 域对非 md 文件返回 HTML 预览页不可直连）。
# 信任模型与安装器自举一致，更新器内部再对 manifest 做 GPG fail-closed
# 验签 + sha256 强制校验。
# update 每次强制重新拉取（完整启动器自身负责后续自更新）；其余管理命令
# 复用已缓存的完整启动器，避免频繁网络往返。start 亦自举（完整启动器负责
# 拉起守护进程群 + 前端；缓存存在时零网络）。
case "\$1" in
    start|cli|profile|monitor|status|doctor|logs|uninstall|update|reinstall)
        _FULL="\$AIRY_HOME/bin/airymaxrt-full"
        if [ "\$1" != "update" ] && [ -s "\$_FULL" ]; then
            exec bash "\$_FULL" "\$@"
        fi
        _TMP="\$AIRY_HOME/tmp/airymaxrt-full.\$\$"
        mkdir -p "\$AIRY_HOME/tmp" || exit 1
        syscurl -fsSL --max-time 60 -o "\$_TMP" \
            "https://api.atomgit.com/api/v5/repos/openairymax/agentrt/contents/latest/airymaxrt?ref=main" || {
            echo "airymaxrt \$1: 完整启动器下载失败（api.atomgit.com 不可达）" >&2
            rm -f "\$_TMP"; exit 1
        }
        if command -v python3 >/dev/null 2>&1; then
            python3 -c 'import json,sys,base64; sys.stdout.buffer.write(base64.b64decode(json.load(sys.stdin).get("content","").replace("\n","")))' < "\$_TMP" > "\$_FULL" || {
                echo "airymaxrt \$1: 完整启动器解码失败" >&2
                rm -f "\$_TMP"; exit 1
            }
        else
            sed -n 's/.*"content"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "\$_TMP" | tr -d '\n' | base64 -d > "\$_FULL" 2>/dev/null || {
                echo "airymaxrt \$1: 完整启动器解码失败（无 python3，base64 回退失败）" >&2
                rm -f "\$_TMP"; exit 1
            }
        fi
        rm -f "\$_TMP"
        chmod 755 "\$_FULL"
        [ -s "\$_FULL" ] || { echo "airymaxrt \$1: 完整启动器为空" >&2; exit 1; }
        exec bash "\$_FULL" "\$@"
        ;;
    "")
        # 默认前端入口（无参数）：先确保守护进程群就绪再进入前端。
        # 0.1.6 社区缺陷修复：此前无参数直接 exec 前端，daemon 群未拉起，
        # CLI/TUI 全部离线（"online 0/17"）。优先复用已缓存的完整启动器
        #（含 daemon 群拉起 + 前端选择）；无缓存则本地 bootstrap start
        #（幂等：已运行实例复用，离线可用，无需网络）。
        _FULL="\$AIRY_HOME/bin/airymaxrt-full"
        # 0.1.6h 修复：gateway 实际端口从运行时文件读取（完整启动器在
        # 端口漂移后固化 run/gateway.port；缺省 8080），根治"端口漂移后
        # 硬编码 8080 探测永远判离线、TUI 连不上"
        _GWP="\$(sed -n '1s/[^0-9]//gp' "\$AIRY_HOME/run/gateway.port" 2>/dev/null | head -1)"
        _GWP="\${_GWP:-8080}"
        if [ -s "\$_FULL" ]; then
            exec bash "\$_FULL"
        fi
        if [ -x "\$AIRY_HOME/bin/agentrt-bootstrap.sh" ]; then
            _GW_READY=0
            if command -v curl >/dev/null 2>&1; then
                syscurl -fsS --max-time 1 -X POST "http://127.0.0.1:\$_GWP/" \
                    -H 'Content-Type: application/json' \
                    -d '{"jsonrpc":"2.0","id":1,"method":"ping","params":{}}' \
                    >/dev/null 2>&1 && _GW_READY=1
            fi
            if [ "\$_GW_READY" != "1" ]; then
                echo "airymaxrt: gateway 离线，拉起守护进程群…" >&2
                "\$AIRY_HOME/bin/agentrt-bootstrap.sh" start >/dev/null 2>&1 || true
            fi
        fi
        ;;
esac
# 前端选择（与完整启动器一致）：有 TTY 且 TUI 可用 → TUI；否则 → airy_cli
# 流式（非 TTY 环境，stdin 读指令）。修复旧版无 TTY 时透传参数给
# agentrt-tui 报 "unexpected argument" 的问题。
# 0.1.6h：TUI 显式传实际 gateway 端口（run/gateway.port），防端口漂移断连。
if [ -t 0 ] && [ -t 1 ] && [ -x "\$AIRY_HOME/bin/agentrt-tui" ]; then
    exec "\$AIRY_HOME/bin/agentrt-tui" --gateway-url "http://127.0.0.1:\${_GWP:-8080}"
fi
if [ -x "\$AIRY_HOME/bin/airy_cli" ]; then
    exec "\$AIRY_HOME/bin/airy_cli" -p
fi
if [ -x "\$AIRY_HOME/bin/agentrt-tui" ]; then
    exec "\$AIRY_HOME/bin/agentrt-tui" --gateway-url "http://127.0.0.1:\${_GWP:-8080}"
fi
echo "airymaxrt: 未找到可执行前端（agentrt-tui / airy_cli 均缺失）" >&2
exit 1
EOF
        chmod 755 "${AIRY_HOME}/bin/airymaxrt"
    fi
    if [ -x "${AIRY_HOME}/bin/airymaxrt" ]; then
        mkdir -p "${BIN_DIR}"
        ln -sf "${AIRY_HOME}/bin/airymaxrt" "${BIN_DIR}/airymaxrt"
        log_ok "启动器软链: ${BIN_DIR}/airymaxrt → ${AIRY_HOME}/bin/airymaxrt"
    fi

    # daemon 启动编排脚本（bootstrap）：部署到 bin/（systemd 与手动启动引用）
    if [ -f "${AIRY_SRC_DIR}/tools/scripts/ops/bin/agentrt-bootstrap.sh" ]; then
        cp -f "${AIRY_SRC_DIR}/tools/scripts/ops/bin/agentrt-bootstrap.sh" "${AIRY_HOME}/bin/agentrt-bootstrap.sh"
        chmod 755 "${AIRY_HOME}/bin/agentrt-bootstrap.sh"
        log_ok "agentrt-bootstrap.sh 已部署到 bin/"
    elif [ -f "${AIRY_HOME}/bin/agentrt-bootstrap.sh" ]; then
        log_ok "agentrt-bootstrap.sh 已存在（二进制模式自带）"
    else
        log_warn "agentrt-bootstrap.sh 未部署（源码缺失且二进制未含）"
    fi

    # 安装器自托管（供离线卸载/airymaxrt uninstall·reinstall 委托）。
    # curl|bash 管道场景 $0 非文件（=bash），cp "$0" 落空使卸载无安装器
    # 可用 → 改为从官方仓拉取自托管副本落盘（与 installer_self_bootstrap
    # 同源），仍失败则告警（airymaxrt 侧已备在线拉取兜底）。
    mkdir -p "${AIRY_HOME}/scripts"
    if [ -f "$0" ] && [ -r "$0" ]; then
        cp -f "$0" "${AIRY_HOME}/scripts/install.sh"
    else
        if command -v python3 >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
            _it_remote="$(syscurl -fsSL --max-time 30 \
                "https://api.atomgit.com/api/v5/repos/openairymax/agentrt/contents/scripts/install.sh?ref=main" 2>/dev/null || true)"
            if [ -n "$_it_remote" ]; then
                printf '%s' "$_it_remote" | python3 -c 'import sys,json,base64;d=json.load(sys.stdin);sys.stdout.write(base64.b64decode(d.get("content","")).decode())' > "${AIRY_HOME}/scripts/install.sh" 2>/dev/null || true
            fi
        fi
        if [ ! -s "${AIRY_HOME}/scripts/install.sh" ]; then
            log_warn "安装器自托管失败（管道执行且联网拉取失败）；airymaxrt uninstall 将提示在线兜底"
        fi
    fi
    chmod 755 "${AIRY_HOME}/scripts/install.sh" 2>/dev/null || true
    log_ok "安装位置已固化: install.env + agentrt-env.sh + 启动器"

    # ── PATH 引导检查（2.3.2.6，与 build.sh 同构）────────────────────────
    # 二进制安装最常见的失败模式：`airymaxrt: command not found`——BIN_DIR
    # 不在用户 PATH 中且安装器未提示。安装即引导：BIN_DIR 不在 PATH 时给出
    # 可复制的修复命令，并把结果写入 install.env（airymaxrt status/doctor
    # 可据此提示，避免"装上了却找不到命令"的困惑）。
    # 2026-08-24 强化：
    #   - 写入 AIRY_BIN_LINK（doctor/status 据此给出准确的修复路径，此前
    #     该键从未写入，--prefix 自定义安装时诊断提示回退到错误的默认路径）；
    #   - PATH 检测按段遍历（对含空格/glob 字符的 BIN_DIR 健壮，此前
    #     case glob 匹配在这些路径下会误判）；
    #   - 永久生效提示按当前 shell 选择 rc 文件（bash/zsh/fish/posix）。
    env_set "AIRY_BIN_LINK=${BIN_DIR}/airymaxrt"
    _PATH_OK=0
    _P_SEG="$PATH"
    while [ -n "$_P_SEG" ]; do
        _seg="${_P_SEG%%:*}"
        if [ "$_seg" = "$BIN_DIR" ]; then
            _PATH_OK=1
            break
        fi
        if [ "$_seg" = "$_P_SEG" ]; then
            _P_SEG=""
        else
            _P_SEG="${_P_SEG#*:}"
        fi
    done
    if [ "$_PATH_OK" = "1" ]; then
        log_ok "PATH 引导: ${BIN_DIR} 已在 PATH 中，可直接输入 airymaxrt"
        env_set "AIRY_BIN_DIR_IN_PATH=yes"
    else
        log_warn "PATH 引导: ${BIN_DIR} 不在 PATH 中——当前 shell 输入 airymaxrt 会报 command not found"
        path_bootstrap
        env_set "AIRY_BIN_DIR_IN_PATH=no"
    fi
}

# ─── daemon 完整性校验 ─────────────────────────────────────────────────
# 参数 strict：二进制模式下缺 daemon 视为安装失败（exit 1），
# 避免「残缺安装却显示成功」；源码模式保留 warn。
verify_daemons() {
    local missing="" strict="$1" dl d n=0
    dl="$(daemon_list)"
    if [ -z "$dl" ]; then
        if [ "$strict" = "strict" ]; then
            log_err "daemon 校验失败：${AIRY_HOME}/bin 下无 *_d 二进制（制品不完整）"
            exit 1
        fi
        log_warn "daemon 校验未全通过：${AIRY_HOME}/bin 下无 *_d 二进制"
        return 1
    fi
    for d in ${dl}; do
        n=$((n + 1))
        [ -x "${AIRY_HOME}/bin/${d}" ] || missing="${missing} ${d}"
    done
    if [ -n "$missing" ]; then
        if [ "$strict" = "strict" ]; then
            log_err "daemon 校验失败，缺失:${missing}（二进制包不完整，请检查 release 制品）"
            exit 1
        fi
        log_warn "daemon 校验未全通过，缺失:${missing}（可能为二进制包未含全部组件）"
    else
        log_ok "${n} 个 daemon 全部就位"
    fi
}

# ─── 安装后自检：版本一致性 + 更新通道提示 ──────────────────────────────
post_install_selfcheck() {
    local ver_installed=""
    if [ -f "${AIRY_HOME}/config/install.env" ]; then
        ver_installed="$(sed -n 's/^AIRY_VERSION=//p' "${AIRY_HOME}/config/install.env" 2>/dev/null | head -1)"
    fi
    log_ok "已安装版本: ${ver_installed:-v?}（通道: ${AIRY_CHANNEL}）"
    if [ "${AIRY_CHANNEL}" = "beta" ]; then
        log_warn "beta 通道发布更频繁；正式环境建议 'airymaxrt update --channel stable' 切回"
    fi
    log_info "更新检查: airymaxrt update --check    升级: airymaxrt update"

    # 运行时依赖自包含校验（2026-08-29 社区 bug 根治）：agentrt-tui/daemons
    # 依赖 libcjson.so.1 等非系统 .so，随包 lib/ + $ORIGIN/../lib RUNPATH
    # 交付。安装后立刻验证所有 ELF 二进制无未解析依赖，尽早暴露缺失。
    local _missing=0 _b
    for _b in "${AIRY_HOME}"/bin/*; do
        [ -f "$_b" ] || continue
        # 仅检查 ELF 可执行（跳过 .sh 包装器）
        if head -c4 "$_b" 2>/dev/null | od -An -tx1 | grep -q "7f 45 4c 46"; then
            if command -v ldd >/dev/null 2>&1 && ldd "$_b" 2>/dev/null | grep -q "not found"; then
                log_warn "$(basename "$_b") 存在未解析动态库依赖:"
                ldd "$_b" 2>/dev/null | grep "not found" | sed 's/^/    /'
                _missing=$((_missing+1))
            fi
        fi
    done
    if [ "$_missing" -gt 0 ]; then
        log_warn "检测到 ${_missing} 个二进制缺少运行时库。"
        log_warn "若 libcjson.so.1 等随包 .so 未生效，请确认 AIRY_LIB_PATH 已含 ${AIRY_HOME}/lib，或重装本版本。"
    else
        log_ok "运行时依赖校验通过（全部二进制动态库解析正常）"
    fi
}

# ─── 版本信息 ──────────────────────────────────────────────────────────
# 0.1.6f 视觉强化：banner 回归简约——单线框 + 品牌 + 版本 + 一句理念，
# 去除冗余装饰行（此前信息堆砌且含拼写错误）。留白即秩序。
print_banner() {
    # 0.1.11 视觉修复（2026-09-05）：横幅不再内嵌 AIRY_VERSION——curl 管道
    # 无 VERSION 文件时回退默认值（v0.1.9），与真实安装版本漂移造成"安装
    # 了 0.1.10 却显示 0.1.9"的误导；版本改由 [2/5] 阶段解析 manifest 后
    # 明确展示（目标版本以官方 manifest 为准，杜绝写死漂移）。同时固定等宽
    # 框线（此前版本号长度变化导致右边界错位）。
    cat <<EOF
${C_CYAN}
  ┌─────────────────────────────────────────────┐
  │  Airymax AgentRT · Agent Runtime Platform   │
  └─────────────────────────────────────────────┘
${C_NC}
EOF
}

# 阶段导航（0.1.6f 视觉强化）：统一「序号/总数 + 名称」分隔标题，让
# 长安装流程呈现清晰秩序感（简约、克制；POSIX 兼容）。
stage() { # <n> <total> <title>
    printf "${C_CYAN}\n  ── [%s/%s] %s ───────────────────────────${C_NC}\n" "$1" "$2" "$3"
}

print_summary() {
    cat <<EOF

安装位置:   ${AIRY_HOME}
可执行文件: ${AIRY_HOME}/bin/
配置文件:   ${AIRY_HOME}/config/
安装固化:   ${AIRY_HOME}/config/install.env
运行环境:   . ${AIRY_HOME}/bin/agentrt-env.sh
启动器:     ${BIN_DIR}/airymaxrt（任意路径输入 airymaxrt 即启动）

快速开始:
  1. 配置 LLM 提供方（API key）:
     ${AIRY_HOME}/config/secrets.env
  2. 启动交互界面（自动拉起 gateway/llm daemon）:
     airymaxrt
  3. 查看运行时状态:
     airymaxrt status
  4. 一键卸载（--keep-data 保留记忆数据）:
     airymaxrt uninstall   或   ${AIRY_HOME}/scripts/install.sh --uninstall
EOF
}

# ─── PATH 引导（2026-08-22 初版；2026-08-23 2.1.2.6 优化）──────────────
# 历史教训：其他设备安装后用户直接输入 airymaxrt 报 command not found——
# ${BIN_DIR}（默认 $HOME/.local/bin）未加入 PATH，而摘要宣称"任意路径输入
# airymaxrt 即启动"造成误导。安装收尾时必须实测 PATH 并在缺失时给出
# 精确、可复制的引导（临时/持久/完整路径三选一）。
# 2.1.2.6 优化：
#   - 持久生效给出"一键命令"（写 rc + 立即 export 合并，无需重启会话）
#   - 检测全部存在的 shell rc（.bashrc/.zshrc/.profile），逐项给出
#   - PATH 已就绪时输出确认，避免静默
print_path_guidance() {
    _found=0
    _ifs="$IFS"
    IFS=:
    for _p in $PATH; do
        [ -n "$_p" ] || _p="."
        if [ "$_p" = "$BIN_DIR" ]; then _found=1; break; fi
    done
    IFS="$_ifs"

    # 安装完整性兜底：BIN_DIR 下无启动器时提前告警（避免引导后仍 404）
    if [ ! -x "$BIN_DIR/airymaxrt" ]; then
        log_warn "${BIN_DIR}/airymaxrt 不存在——启动器安装可能未完成。"
        echo "  请先检查上方安装日志，或使用完整路径排查："
        echo "    ls -l \"${BIN_DIR}/airymaxrt\""
    fi

    if [ "$_found" -eq 1 ]; then
        log_ok "PATH 已包含 ${BIN_DIR}，可直接输入 airymaxrt 启动。"
        return 0
    fi

    log_warn "${BIN_DIR} 不在当前 PATH 中，无法直接输入 airymaxrt 启动。"
    echo "  请按需选择以下任一种方式："
    echo ""
    echo "    1) 临时生效（仅当前终端，立即可用）:"
    echo "       export PATH=\"${BIN_DIR}:\$PATH\""
    echo ""
    echo "    2) 持久生效（推荐，一键命令——写入配置并立即生效）:"
    _shown_rc=0
    for _rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
        if [ -f "$_rc" ]; then
            _rc_basename="${_rc##*/}"
            echo "       # ${_rc_basename}"
            echo "       echo 'export PATH=\"${BIN_DIR}:\$PATH\"' >> \"$_rc\" && export PATH=\"${BIN_DIR}:\$PATH\""
            _shown_rc=1
        fi
    done
    if [ "$_shown_rc" -eq 0 ]; then
        echo "       # 未检测到 .bashrc/.zshrc/.profile，请手动执行后任选其一追加:"
        echo "       echo 'export PATH=\"${BIN_DIR}:\$PATH\"' >> \"\$HOME/.bashrc\""
    fi
    echo ""
    echo "    3) 不改 PATH，改用完整路径启动:"
    echo "       ${BIN_DIR}/airymaxrt"
    echo ""
    echo "  提示：方式 2 对新开的终端永久生效；本终端立即执行方式 1 或方式 2 中的 export 即可先用。"
}

# ─── 主流程 ────────────────────────────────────────────────────────────
main() {
    print_banner
    log_info "Airymax AgentRT 安装程序"
    log_info "AIRY_HOME = ${AIRY_HOME} | 模式 = ${AIRY_MODE}"

    if [ "$UNINSTALL" = "1" ]; then
        do_uninstall "$AIRY_HOME" "$KEEP_DATA" "$YES"
        exit $?
    fi

    init_home

    # 重装模式：清本地缓存强制下载最新版 + 先停旧 daemon（防旧进程占用二进制）
    if [ "$REINSTALL" = "1" ]; then
        log_warn "重装模式：清除本地包缓存并停止旧 daemon，强制下载最新版本…"
        rm -f "${AIRY_HOME}"/tmp/agentrt-*.tar.gz 2>/dev/null || true
        stop_daemons "$AIRY_HOME/bin"
    fi

    local installed=1 _bin_rc=0
    stage 2 5 "获取运行时"
    # 发布来源解析：--from-file 离线包 > AIRY_RELEASE_URL 显式 URL >
    # 官方通道 manifest（默认，stable/beta 由 --channel 决定；--mode source 除外）。
    # manifest 实际经 contents API 拉取（install_binary 内 fetch_repo_file，
    # raw 域对 JSON 返回 HTML 不可用）；此 URL 仅作 .json 路由判定与
    # 文件名提取。源码降级仅限"官方确无本平台制品"（install_binary rc=1），
    # 且 mode 为 auto/hybrid；确定性故障（rc=2）一律失败退出并给指引，
    # 杜绝把网络/校验故障静默拖入源码构建（0.1.10 安装事故教训，2026-09-05）。
    local release_url="${AIRY_RELEASE_URL:-}"
    if [ -z "$release_url" ] && [ "${AIRY_MODE:-auto}" != "source" ]; then
        release_url="https://atomgit.com/openairymax/agentrt/latest/manifest.${AIRY_CHANNEL}.json"
    fi
    if [ -n "$AIRY_FROM_FILE" ]; then
        install_binary "$AIRY_FROM_FILE"; _bin_rc=$?
        [ "$_bin_rc" = "0" ] && installed=0
    elif [ "$AIRY_MODE" = "binary" ] || { [ "$AIRY_MODE" = "auto" ] && [ -n "$release_url" ]; }; then
        install_binary "$release_url"; _bin_rc=$?
        [ "$_bin_rc" = "0" ] && installed=0
    fi

    # rc=2（确定性故障）→ 直接失败，绝不静默源码构建
    if [ "$_bin_rc" = "2" ]; then
        log_err "二进制安装失败（详见上方错误）。已停止，未进入源码构建。"
        exit 1
    fi
    # rc=1（官方确无本平台制品）→ 仅 auto/hybrid 允许源码兜底；binary 直接失败
    if [ "$_bin_rc" = "1" ] && [ "$AIRY_MODE" = "binary" ]; then
        log_err "官方未发布当前平台的预编译制品，且你指定 --mode binary（禁止源码构建）。"
        log_err "可改 --mode auto 或 hybrid 自动源码构建，或 AIRY_MODE=source 显式源码构建。"
        exit 1
    fi

    if [ "$installed" -ne 0 ]; then
        # 走到这里 = 无官方制品（rc=1）的 auto/hybrid 源码兜底，或显式 source/hybrid
        if [ "$AIRY_MODE" = "auto" ]; then
            log_warn "当前平台暂无官方预编译制品（${AIRY_MODE}），转为源码构建…"
        else
            log_info "进入源码构建模式（${AIRY_MODE}）"
        fi
        # 工具链仅在源码构建路径要求（二进制模式无需 git/cmake/gcc）
        check_toolchain
        prepare_source

        # 模式 B：无闭源源码 → 下载预编译模块包。atoms 默认指向官方
        # Release 附件直链（publish-release.sh 上传口径：releases/download/
        # <tag>/<file>，文件名含 detect_arch 架构），环境变量可覆盖；
        # 下载失败仅降级警告（闭源功能受限），不阻断安装。memoryrovol
        # 为授权分发、无公开发布，保持显式 URL 配置制（未配置即跳过）。
        if [ ! -d "${AIRY_SRC_APP}/agentrt/atoms" ] && [ "$AIRY_MODE" != "source" ]; then
            fetch_prebuilt_module "atoms" \
                "${AIRY_ATOMS_PREBUILT_URL:-https://atomgit.com/openairymax/agentrt/releases/download/${AIRY_VERSION}/airy-atoms-prebuilt-${AIRY_VERSION}-linux-$(detect_arch).tar.gz}" \
                "atoms" || \
                log_warn "atoms 预编译包不可用；如需完整功能请配置 AIRY_ATOMS_PREBUILT_URL 或使用本地源码"
            fetch_prebuilt_module "memoryrovol" "${AIRY_MEMORYROVOL_PREBUILT_URL:-}" "memoryrovol" || \
                log_warn "memoryrovol 预编译包不可用（无授权将自动降级 OSS/builtin）"
        elif [ "$AIRY_MODE" = "source" ] && [ -d "${AIRY_SRC_APP}/agentrt/atoms" ]; then
            log_ok "模式 C：本地闭源源码（atoms/memory/memoryrovol）全量构建"
        fi

        if [ "${AIRY_NO_BUILD:-}" != "1" ]; then
            build_and_install
            install_python_deps
            build_mr_oss
            build_tui
        fi
    fi

    # 启动器兼容入口与 secrets 在两种模式（二进制/源码）下均需生成：
    # 二进制模式依赖 airy_cli 生成 agentrt-tui 兼容入口，否则无任何启动命令
    ensure_cli_entry
    init_secrets

    # 硬件评估与运行画像固化（2.3.5/2.3.6）：安装即按硬件裁剪——
    # 二进制包同样适用（无论安装模式，自动识别硬件、固化画像；
    # airymaxrt 启动器按画像拉起 daemon 集，monitor 监控外设增强自动恢复）。
    persist_profile

    # 重装/版本更新后自动停止旧 daemon：旧进程仍持有旧 .so/二进制，
    # 不杀则下次 airymaxrt 仍复用旧代码（2026-08-30 用户反馈）。新装
    # 无运行进程则静默跳过（stop_daemons 返回 1）。
    if stop_daemons "$AIRY_HOME/bin"; then
        log_ok "已自动停止旧版本 daemon（新版本已就位，运行 airymaxrt 启动）"
    fi

    # 出厂预装 maths-toolkit（数学计算后端，默认开启，可 --without-maths 跳过）
    install_maths_toolkit

    stage 5 5 "校验与完成"
    finalize_install
    if [ "$installed" -eq 0 ]; then
        verify_daemons strict
    else
        verify_daemons
    fi
    post_install_selfcheck
    print_summary
    print_path_guidance
    log_ok "安装完成"
}

main "$@"

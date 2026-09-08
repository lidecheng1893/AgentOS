#!/usr/bin/env bash
#
# sync-mirror.sh — agentrt + 全部子模块 → GitHub / Gitee 双镜像
#
# agentrt 现为 workflow 宿主仓（发布平面）。本脚本取代原伞仓同名脚本：
# 同步对象从伞仓（agent-workload/tools/docs/...）收窄为 agentrt + 其
# 7 个叶子子模块（atoms/commons/cupolas/daemons/gateway/heapstore/
# protocols）+ 发布链消费的 sibling 数据仓（tools/sdk/ecosystem，
# 0.1.13 收口项：rc2 实证镜像落后阻塞 e2e，纳入自动通道）。伞仓
# airymaxhub 恢复纯容器，不再承载任何流水线。
#
# 根因修复（旧版三大缺陷，沿用）：
#   1. 循环依赖死锁：旧 workflow 用 checkout submodules:true，需要从
#      GitHub 拉子模块，而子模块镜像仓正是本工作流要创建的 → run #82
#      9 秒即败，tag 从未到达 GitHub，release.yml 无法触发。
#   2. gh repo create --confirm 已在 gh 2.x 移除 → 缺失仓自动创建静默
#      失败（"warn: skipping"），镜像永久停留在旧提交。
#   3. set -e 下单仓推送失败中断整条同步链，无汇总、无隔离。
#
# 新模型：
#   - 源 = atomgit（SSoT）：clone --mirror 抓全量 refs 后，push 只同步
#     heads + tags（force 保证与 SSoT 一致）——不用 push --mirror，
#     atomgit 平台内部 ref（refs/merge-requests/*、refs/keep-around/*）
#     不应外泄到 GitHub/Gitee。公开子仓匿名可读；私有子仓（atoms）需
#     ATOMGIT_TOKEN。
#   - 子模块树以 agentrt HEAD:.gitmodules 动态 BFS 解析，新增子模块零维护。
#   - GitHub 缺仓用 gh CLI 创建；Gitee 缺仓用 API v5 创建；私有名单
#     （atoms）建私有，防内容泄露。
#   - 每仓错误隔离，末尾汇总，任一失败 exit 1。
#   - agentrt 最后同步：tag 推上 GitHub 触发 release.yml 时，子模块
#     镜像已全部就绪（release.yml 从 GitHub 拉子模块）。

set -uo pipefail

# 凭据缺失时快速失败而非挂在交互式提示上（Actions 无 tty，git 会
# 反复重试 "could not read Username" 拖满超时）
export GIT_TERMINAL_PROMPT=0

GH_ORG="openairymax"
GT_ORG="openairymax"
ROOT_REPO="agentrt"

# 闭源子模块：无公网镜像，跳过（含历史名兜底）
SKIP_LIST=" closed-docs closed-dev-build build-closed devbuild-closed developbuild docs-closed memoryrovol "
# 私有仓（atomgit/GitHub 均为 private）：缺仓创建时必须 private
PRIVATE_LIST=" atoms "

FAILED=()
OK=()
SEEN=" "
QUEUE=()

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log() { echo "$@"; }

# 脱敏 URL 内嵌凭据（git/curl 错误可能回显带 token 的 URL）
redact() { sed 's#://[^@/]*@#://***@#g'; }

# 源 clone URL：atomgit 为 SSoT。认证形式为 token 回退候选（匿名优先，
# 避免无效 token 拖垮全部公开仓同步）。
src_url() {
  printf 'https://atomgit.com/%s/%s.git' "$GH_ORG" "$1"
}

src_url_authed() {
  printf 'https://oauth2:%s@atomgit.com/%s/%s.git' "$ATOMGIT_TOKEN" "$GH_ORG" "$1"
}

# clone 失败原因必须可见：Actions 日志需 admin 才能下载，故用 ::error::
# workflow command 写入 annotations（匿名 API 可读）。
mirror_clone() {
  local name="$1" dir="$2" err
  err="$(timeout 900 git clone --mirror -q "$(src_url "$name")" "$dir" 2>&1)" && return 0
  rm -rf "$dir"
  if [ -n "${ATOMGIT_TOKEN:-}" ]; then
    err="$(timeout 900 git clone --mirror -q "$(src_url_authed "$name")" "$dir" 2>&1)" && return 0
    rm -rf "$dir"
  fi
  echo "::error::repo $name: atomgit clone failed: $(printf '%s' "$err" | redact | tr '\n' ' ' | tail -c 300)"
  return 1
}

# 远端"默认分支"落在待删陈旧清单里时，先经平台 API 把默认切到 SSoT 分支：
# GitHub/Gitee 都无条件拒绝删除当前默认分支（receive.denyDeleteCurrent），
# run #90 本地复现实证：Gitee 23 仓默认分支仍是历史名 develop，删除被拒
# 且 stderr 曾被 2>/dev/null 吞掉、零告警，随后强推 develop/hubs-01 撞
# refname 层级冲突 → 整仓失败。API 只 warn 不致命：失败时回退旧行为。
reset_stale_default() {
  local dir="$1" url="$2" label="$3" name="$4" stale="$5"
  local tok api resp cur new err
  case "$label" in
    github) tok="${GH_TOKEN:-}"; api="https://api.github.com/repos/${GH_ORG}/${name}" ;;
    gitee)  tok="${GT_TOKEN:-}"; api="https://gitee.com/api/v5/repos/${GT_ORG}/${name}" ;;
    *) return 0 ;;
  esac
  [ -n "$tok" ] || return 0
  if [ "$label" = github ]; then
    resp="$(curl -fsS -H "Authorization: Bearer ${tok}" "$api" 2>/dev/null)"
  else
    resp="$(curl -fsS "${api}?access_token=${tok}" 2>/dev/null)"
  fi
  cur="$(printf '%s' "$resp" | grep -o '"default_branch":[ ]*"[^"]*"' \
        | head -1 | sed -E 's/.*"([^"]*)"$/\1/')"
  [ -n "$cur" ] || return 0
  printf '%s\n' "$stale" | grep -qxF "$cur" || return 0
  new="$(git -C "$dir" for-each-ref --format='%(refname:strip=2)' refs/heads/ \
        | grep -Fx main || true)"
  [ -n "$new" ] || new="$(git -C "$dir" for-each-ref --format='%(refname:strip=2)' \
        refs/heads/ | head -1)"
  [ -n "$new" ] || return 0
  if [ "$label" = github ]; then
    err="$(curl -fsS -X PATCH "$api" -H "Authorization: Bearer ${tok}" \
        -H "Accept: application/vnd.github+json" \
        -d "{\"default_branch\":\"${new}\"}" 2>&1)"
  else
    err="$(curl -fsS -X PATCH "$api" -H "Content-Type: application/json" \
        -d "{\"access_token\":\"${tok}\",\"name\":\"${name}\",\"default_branch\":\"${new}\"}" 2>&1)"
  fi
  if [ $? -ne 0 ]; then
    log "  warn: repo $name: $label set default branch to '$new' failed: $(printf '%s' "$err" | redact | tr '\n' ' ' | tail -c 160)"
    return 0
  fi
  log "  $label: repo $name default branch '$cur' is stale -> switched to '$new'"
}

# push 到单个 remote：只同步 heads + tags（force 保证与 SSoT 一致）。
# 不用 push --mirror —— atomgit 仓含平台内部 ref（refs/merge-requests/*、
# refs/keep-around/*），--mirror 会把这些垃圾 ref 灌进 GitHub/Gitee。
push_mirror() {
  local name="$1" dir="$2" url="$3" label="$4" err stale r
  # 预删目标端陈旧分支：SSoT 已不存在的分支（如 Gitee 镜像遗留的
  # develop）会与 SSoT 的 develop/hubs-01 构成 refname 层级冲突，
  # 令整笔 push 以 "remote rejected (refname conflict)" 被拒
  # （run #89 实证 23 仓）。镜像语义 = 与 SSoT 完全一致，删。
  stale="$(comm -13 \
      <(git -C "$dir" for-each-ref --format='%(refname:strip=2)' refs/heads/ | sort) \
      <(git ls-remote --heads "$url" 2>/dev/null \
        | awk '{print $2}' | sed 's|^refs/heads/||' | sort))"
  if [ -n "$stale" ]; then
    reset_stale_default "$dir" "$url" "$label" "$name" "$stale"
    for r in $stale; do
      # 删除失败原因必须可见（#90 教训：2>/dev/null 吞掉了
      # "refusing to delete the current branch" 的定性证据）
      err="$(timeout 300 git -C "$dir" push -q "$url" ":refs/heads/$r" 2>&1)" \
        || log "  warn: repo $name: $label delete stale branch '$r' failed: $(printf '%s' "$err" | redact | tr '\n' ' ' | tail -c 160)"
    done
  fi
  err="$(timeout 900 git -C "$dir" push -q -f "$url" \
      'refs/heads/*:refs/heads/*' 'refs/tags/*:refs/tags/*' 2>&1)" && return 0
  echo "::error::repo $name: push $label failed: $(printf '%s' "$err" | redact | tr '\n' ' ' | tail -c 300)"
  return 1
}

is_private() { case "$PRIVATE_LIST" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
is_skip()    { case "$SKIP_LIST"    in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# .gitmodules 文件 → 子模块仓名列表（path 的 basename，本树约定仓名=basename）
# 注意：--get-regexp 只匹配 key 名（形如 submodule.<name>.path，以 .path
# 结尾），故锚点必须是 \.path$；值（路径）从第二列取。
parse_submodules() {
  [ -s "$1" ] || return 0
  git config -f "$1" --get-regexp '\.path$' 2>/dev/null \
    | awk '{print $2}' | while read -r p; do basename "$p"; done
}

# 入队（去重交给主循环 SEEN）
enqueue() {
  local s
  while read -r s; do
    [ -n "$s" ] && QUEUE+=("$s")
  done < <(parse_submodules "$1")
}

ensure_github_repo() {
  gh repo view "${GH_ORG}/$1" >/dev/null 2>&1 && return 0
  local vis="--public" err
  is_private "$1" && vis="--private"
  # gh 2.x 无 --confirm；非交互环境下 create 直接生效
  if err="$(gh repo create "${GH_ORG}/$1" "$vis" 2>&1 >/dev/null)"; then
    log "  created github.com/${GH_ORG}/$1"
    return 0
  fi
  echo "::error::repo $1: gh create failed: $(printf '%s' "$err" | tr '\n' ' ' | tail -c 200)"
  return 1
}

ensure_gitee_repo() {
  curl -fsS -o /dev/null \
    "https://gitee.com/api/v5/repos/${GT_ORG}/$1?access_token=${GT_TOKEN}" && return 0
  local vis="false" err
  is_private "$1" && vis="true"
  if err="$(curl -fsS -X POST \
      "https://gitee.com/api/v5/orgs/${GT_ORG}/repos" \
      --data-urlencode "access_token=${GT_TOKEN}" \
      --data-urlencode "name=$1" \
      --data-urlencode "private=${vis}" \
      --data-urlencode "auto_init=false" 2>&1)"; then
    log "  created gitee.com/${GT_ORG}/$1"
    return 0
  fi
  echo "::error::repo $1: gitee create failed: $(printf '%s' "$err" | sed 's/access_token[^&"]*/access_token***/g' | tr '\n' ' ' | tail -c 200)"
  return 1
}

# 单仓同步：atomgit mirror clone → push heads+tags 到 GitHub + Gitee。
# 克隆后读 HEAD:.gitmodules 将嵌套子模块入队（BFS）；目录用完即删（控磁盘，
# kernel 仓 mirror 约 2.5GB）。
sync_repo() {
  local name="$1"
  local dir="$WORK/${name}.git"
  log "=== $name ==="

  if ! mirror_clone "$name" "$dir"; then
    FAILED+=("$name")
    return 1
  fi

  local gm="$WORK/${name}.gitmodules"
  : > "$gm"
  git -C "$dir" show HEAD:.gitmodules > "$gm" 2>/dev/null || true
  enqueue "$gm"
  rm -f "$gm"

  local rc=0
  if ensure_github_repo "$name"; then
    push_mirror "$name" "$dir" \
      "https://x-access-token:${GH_TOKEN}@github.com/${GH_ORG}/${name}.git" github || rc=1
  else
    rc=1
  fi
  if ensure_gitee_repo "$name"; then
    push_mirror "$name" "$dir" \
      "https://oauth2:${GT_TOKEN}@gitee.com/${GT_ORG}/${name}.git" gitee || rc=1
  else
    rc=1
  fi

  rm -rf "$dir"
  if [ "$rc" -eq 0 ]; then
    OK+=("$name")
    log "  done"
  else
    FAILED+=("$name")
  fi
  return "$rc"
}

# agentrt 自身：checkout 自 GitHub（触发 ref），从 atomgit 补全 tags
# （v0.1.8 等发布 tag 只存在于 atomgit），再推 GitHub + Gitee。
# main 用非 force push（分叉时大声失败而非静默覆盖）；tag 用 --force
# （tag 必须与 SSoT 一致，镜像语义）。
sync_root() {
  log "=== $ROOT_REPO (root) ==="
  local rc=0 err
  # 探针：此步成功即证明 runner 可访问 atomgit（发布 tag 只存在于 SSoT）
  if ! err="$(timeout 300 git -C "$GITHUB_WORKSPACE" fetch -q "$(src_url "$ROOT_REPO")" \
      '+refs/tags/*:refs/tags/*' 2>&1)"; then
    echo "::error::agentrt: atomgit tags fetch failed: $(printf '%s' "$err" | redact | tr '\n' ' ' | tail -c 300)"
  fi
  # main 本地引用也须自 SSoT 补全（sync-mirror #112 实证）：tag push 触发
  # 的运行 checkout 处于 detached 状态，本地无 refs/heads/main，下方
  # 'refs/heads/main:refs/heads/main' 推送直接 "src refspec does not
  # match any" 失败。自 atomgit 取 main 后 push 语义不变：GitHub 侧
  # main 与 SSoT 分叉时仍被非 force push 大声拒绝（镜像 = SSoT 一致）。
  #
  # refspec 必须按 checkout 形态分流（rc4-8 前一轮实证）：branch push
  # 触发的 checkout 正检着 main，向已检出分支 fetch 被 git 无条件拒绝
  # （"refusing to fetch into branch 'refs/heads/main' checked out at
  # ..."），annotation 报警后 main 推送仍照常执行——镜像静默停留在
  # checkout SHA，SSoT 独有提交永不落地。detached（tag 触发）形态无此
  # 冲突，维持直写 refs/heads/main。
  if [ -n "$(git -C "$GITHUB_WORKSPACE" symbolic-ref -q HEAD 2>/dev/null)" ]; then
    # branch checkout 形态：SSoT main 落到镜像专用 ref，绕开已检出分支；
    # push 源用该 ref，非 force 的分叉拒绝语义保持不变
    main_ref='refs/mirror/main'
    if ! err="$(timeout 300 git -C "$GITHUB_WORKSPACE" fetch -q "$(src_url "$ROOT_REPO")" \
        '+refs/heads/main:refs/mirror/main' 2>&1)"; then
      echo "::error::agentrt: atomgit main fetch failed: $(printf '%s' "$err" | redact | tr '\n' ' ' | tail -c 300)"
      FAILED+=("$ROOT_REPO")
      return 1
    fi
  else
    main_ref='refs/heads/main'
    if ! err="$(timeout 300 git -C "$GITHUB_WORKSPACE" fetch -q "$(src_url "$ROOT_REPO")" \
        '+refs/heads/main:refs/heads/main' 2>&1)"; then
      echo "::error::agentrt: atomgit main fetch failed: $(printf '%s' "$err" | redact | tr '\n' ' ' | tail -c 300)"
      FAILED+=("$ROOT_REPO")
      return 1
    fi
  fi
  local pair label url
  for pair in \
    "github|https://x-access-token:${GH_TOKEN}@github.com/${GH_ORG}/${ROOT_REPO}.git" \
    "gitee|https://oauth2:${GT_TOKEN}@gitee.com/${GT_ORG}/${ROOT_REPO}.git"; do
    label="${pair%%|*}"
    url="${pair#*|}"
    git -C "$GITHUB_WORKSPACE" push -q "$url" \
      "${main_ref}:refs/heads/main" \
      || { echo "::error::agentrt: push $label (main) failed"; rc=1; }
    git -C "$GITHUB_WORKSPACE" push -q --force --tags "$url" \
      || { echo "::error::agentrt: push $label (tags) failed"; rc=1; }
  done
  if [ "$rc" -eq 0 ]; then
    OK+=("$ROOT_REPO")
    log "  done"
  else
    FAILED+=("$ROOT_REPO")
  fi
}

# ─── 主流程 ────────────────────────────────────────────────────────────

# 1) 种子：agentrt 工作树（GITHUB_WORKSPACE 根）的直接子模块（7 叶子）
gm="$WORK/root.gitmodules"
git -C "$GITHUB_WORKSPACE" show HEAD:.gitmodules > "$gm" 2>/dev/null || : > "$gm"
enqueue "$gm"
rm -f "$gm"

# 1b) sibling 发布数据仓（tools/sdk/ecosystem）：release 链从 GitHub 镜像
# 克隆这三仓取发布脚本 / TUI 源 / Python 运行时。rc2 实证：tools 镜像落后
# 5 提交、缺 e2e-clean-room.sh → e2e exit 127。0.1.13 收口项：纳入自动
# 镜像通道，消除人工快进依赖。sdk 的嵌套子模块（tui/sdk-python，相对 URL
# ../tui.git）由 sync_repo 的 HEAD:.gitmodules BFS 自动入队，无需列名。
QUEUE+=(tools sdk ecosystem)

# 2) BFS 全子模块树（agentrt 叶子 → 若有嵌套则继续，深度 ≤3）
while [ "${#QUEUE[@]}" -gt 0 ]; do
  name="${QUEUE[0]}"
  QUEUE=("${QUEUE[@]:1}")
  case "$SEEN" in *" ${name} "*) continue ;; esac
  SEEN="${SEEN}${name} "
  if is_skip "$name"; then
    log "=== $name === skip (closed source)"
    continue
  fi
  sync_repo "$name" || true
done

# 3) agentrt 最后同步（见文件头注释：保证 tag 触发 release.yml 时镜像就绪）
sync_root || true

# 4) 汇总
log ""
log "================ summary ================"
log "OK     (${#OK[@]}): ${OK[*]:-}"
log "FAILED (${#FAILED[@]}): ${FAILED[*]:-}"
if [ "${#FAILED[@]}" -gt 0 ]; then
  exit 1
fi
log "all mirrors in sync"

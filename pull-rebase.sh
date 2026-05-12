#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${CYAN}[${repo}]${RESET} $*"; }
ok()      { echo -e "${GREEN}[${repo}]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[${repo}]${RESET} $*"; }
error()   { echo -e "${RED}[${repo}]${RESET} $*"; }

# ── Discover repos (sorted) ────────────────────────────────────────────────────
declare -a all_dirs=()
for dir in "$SCRIPT_DIR"/*/; do
    [[ -d "$dir/.git" ]] && all_dirs+=("$dir")
done
IFS=$'\n' all_dirs=($(sort <<< "${all_dirs[*]}")); unset IFS

# Column width shared by both the welcome list and the summary table
max_len=4
for dir in "${all_dirs[@]}"; do
    r="$(basename "$dir")"
    (( ${#r} > max_len )) && max_len=${#r}
done

# ── Check whether gh CLI is usable (once) ─────────────────────────────────────
gh_available=false
if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
    gh_available=true
fi

# ── Helper: fetch GitHub metadata for a repo dir ──────────────────────────────
# Sets gh_badge (icon string) and gh_desc (description) in caller's scope.
fetch_gh_meta() {
    local d="$1"
    gh_badge=""
    gh_desc=""

    local remote_url
    remote_url="$(git -C "$d" remote get-url origin 2>/dev/null || true)"
    [[ -z "$remote_url" ]] && return

    # Accept both SSH (git@github.com:owner/repo.git) and HTTPS
    if [[ "$remote_url" =~ github\.com[:/]([^/]+/[^/]+)(\.git)?$ ]]; then
        # Strip .git suffix — POSIX ERE has no lazy quantifiers so the capture
        # group may include it even when the second group is present.
        local nwo="${BASH_REMATCH[1]%.git}"

        $gh_available || return 0

        local json
        json="$(gh repo view "$nwo" \
            --json nameWithOwner,description,isArchived,isPrivate 2>/dev/null)" || return 0

        local is_private is_archived description
        is_private="$(  echo "$json" | grep -o '"isPrivate":[^,}]*'  | cut -d: -f2 | tr -d ' "' || true)"
        is_archived="$( echo "$json" | grep -o '"isArchived":[^,}]*' | cut -d: -f2 | tr -d ' "' || true)"
        description="$( echo "$json" | sed 's/.*"description":"\([^"]*\)".*/\1/')"
        [[ "$description" == "null" || "$description" == "$json" ]] && description=""

        local vis_icon arc_icon
        [[ "$is_private"  == "true" ]] && vis_icon="🔒" || vis_icon="🌐"
        [[ "$is_archived" == "true" ]] && arc_icon="📦" || arc_icon="✅"

        gh_badge="${vis_icon} ${arc_icon}"
        gh_desc="$description"
    fi
    return 0
}

# ── Welcome banner ─────────────────────────────────────────────────────────────
echo -e "${BOLD}pull-rebase — syncing git repositories in ${SCRIPT_DIR}${RESET}"
echo -e "${BOLD}─────────────────────────────────────────────────────────────────${RESET}"
echo -e "Found ${#all_dirs[@]} repositor$([ ${#all_dirs[@]} -eq 1 ] && echo y || echo ies):"
for dir in "${all_dirs[@]}"; do
    fetch_gh_meta "$dir"
    name="$(basename "$dir")"
    badge_part=""
    [[ -n "$gh_badge" ]] && badge_part="  ${gh_badge}"
    desc_part=""
    [[ -n "$gh_desc"  ]] && desc_part="  ${gh_desc}"
    printf "  ${CYAN}%-*s${RESET}${badge_part}${desc_part}\n" "$max_len" "$name"
done
echo

# ── summary_icon[repo] and summary_msg[repo] collected during the loop ─────────
declare -a summary_repos=()
declare -A summary_icon=()
declare -A summary_msg=()

record() {
    local icon="$1" msg="$2"
    summary_repos+=("$repo")
    summary_icon[$repo]="$icon"
    summary_msg[$repo]="$msg"
}

for dir in "${all_dirs[@]}"; do
    repo="$(basename "$dir")"

    branch="$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null || true)"
    if [[ -z "$branch" ]]; then
        warn "detached HEAD — skipping"
        record "?" "detached HEAD — skipped"
        continue
    fi

    if [[ "$branch" != "main" ]]; then
        info "on branch '$branch'"

        unstaged="$(git -C "$dir" diff --name-only 2>/dev/null)"
        staged="$(git -C "$dir" diff --cached --name-only 2>/dev/null)"
        untracked="$(git -C "$dir" ls-files --others --exclude-standard 2>/dev/null)"

        has_local_work=false
        work_detail=""

        if [[ -n "$unstaged" ]]; then
            warn "  unstaged changes:"
            while IFS= read -r f; do warn "    M  $f"; done <<< "$unstaged"
            has_local_work=true
            work_detail+="unstaged "
        fi

        if [[ -n "$staged" ]]; then
            warn "  staged (uncommitted) changes:"
            while IFS= read -r f; do warn "    A  $f"; done <<< "$staged"
            has_local_work=true
            work_detail+="staged "
        fi

        if [[ -n "$untracked" ]]; then
            warn "  untracked files:"
            while IFS= read -r f; do warn "    ?  $f"; done <<< "$untracked"
            has_local_work=true
            work_detail+="untracked "
        fi

        # Check for commits not yet pushed to remote
        unpushed=""
        remote_branch="$(git -C "$dir" for-each-ref --format='%(upstream:short)' \
            "refs/heads/$branch" 2>/dev/null)"
        if [[ -n "$remote_branch" ]]; then
            unpushed="$(git -C "$dir" log --oneline "${remote_branch}..HEAD" 2>/dev/null)"
        else
            unpushed="$(git -C "$dir" log --oneline HEAD 2>/dev/null | head -1)"
        fi

        if [[ -n "$unpushed" ]]; then
            warn "  unpushed commits:"
            while IFS= read -r line; do warn "    $line"; done <<< "$unpushed"
            has_local_work=true
            work_detail+="unpushed "
        fi

        if $has_local_work; then
            warn "  -> branch has unfinished work; leaving as-is"
            detail="$(echo "$work_detail" | xargs | tr ' ' '/')"
            record "!" "branch '$branch' — unfinished work (${detail})"
            continue
        fi

        info "  branch is clean and fully pushed — switching to main"
        git -C "$dir" checkout main
    fi

    # Now on main; attempt fast-forward only pull
    remote_main="$(git -C "$dir" for-each-ref --format='%(upstream:short)' \
        refs/heads/main 2>/dev/null)"
    if [[ -z "$remote_main" ]]; then
        warn "main has no upstream configured — skipping pull"
        record "-" "main — no upstream configured"
        continue
    fi

    git -C "$dir" fetch --quiet origin main 2>/dev/null || {
        warn "fetch failed — skipping pull"
        record "!" "main — fetch failed"
        continue
    }

    behind="$(git -C "$dir" rev-list --count HEAD..FETCH_HEAD 2>/dev/null)"
    ahead="$(git -C "$dir" rev-list --count FETCH_HEAD..HEAD 2>/dev/null)"

    if [[ "$behind" -eq 0 ]]; then
        ok "main is up to date"
        record "✓" "main — already up to date"
    elif [[ "$ahead" -gt 0 ]]; then
        warn "main has diverged (${ahead} ahead, ${behind} behind) — fast-forward not possible; skipping pull"
        record "!" "main — diverged (${ahead} ahead / ${behind} behind), pull skipped"
    else
        git -C "$dir" merge --ff-only FETCH_HEAD
        ok "main fast-forwarded ${behind} commit(s)"
        record "↑" "main — fast-forwarded ${behind} commit(s)"
    fi
done

# ── Summary ────────────────────────────────────────────────────────────────────
(( ${#summary_repos[@]} == 0 )) && { echo; exit 0; }

echo
echo -e "${BOLD}Summary${RESET}"
echo -e "${BOLD}───────────────────────────────────────────────────────────────${RESET}"

IFS=$'\n' sorted_repos=($(sort <<< "${summary_repos[*]}")); unset IFS

for r in "${sorted_repos[@]}"; do
    icon="${summary_icon[$r]}"
    msg="${summary_msg[$r]}"
    case "$icon" in
        "✓"|"↑") color="$GREEN" ;;
        "!")      color="$YELLOW" ;;
        *)        color="$RESET" ;;
    esac
    printf "${color}%-*s  %s %s${RESET}\n" "$max_len" "$r" "$icon" "$msg"
done
echo

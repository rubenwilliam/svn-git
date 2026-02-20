#!/usr/bin/env bash
set -Eeuo pipefail

SVN_ROOT="/var/svn"
GIT_ROOT="/var/git"
LOG_DIR="$(pwd)/log"
MAX_PARALLEL=2

mkdir -p "$LOG_DIR" "$GIT_ROOT"

# ===================== COUNTER FILES =====================
SUCCESS_FILE="$LOG_DIR/success.list"
SKIP_FILE="$LOG_DIR/skip.list"
FAIL_FILE="$LOG_DIR/fail.list"

> "$SUCCESS_FILE"
> "$SKIP_FILE"
> "$FAIL_FILE"

migrate_repo() {
    svn_repo="$1"
    repo_name="$(basename "$svn_repo")"
    git_dest="$GIT_ROOT/$repo_name.git"
    tmp_dir="$GIT_ROOT/$repo_name.tmp"
    log_file="$LOG_DIR/$repo_name.log"

    echo "[$(date '+%F %T')] START $repo_name"

    if [[ -d "$git_dest" ]]; then
        echo "[$(date '+%F %T')] SKIP $repo_name (already exists)"
        printf "%s\n" "$repo_name" >> "$SKIP_FILE"
        return 0
    fi

    rm -rf "$tmp_dir"
    SVN_URL="file://$svn_repo"

    # =========================
    # VALIDASI REPO
    # =========================
    if ! svn ls "$SVN_URL/" &>/dev/null; then
        echo "[$(date '+%F %T')] ERROR $repo_name (invalid svn repo)"
        printf "%s\n" "$repo_name" >> "$FAIL_FILE"
        return 1
    fi

    # =========================
    # AUTO DETECT LAYOUT
    # =========================
    HAS_TRUNK=0
    HAS_BRANCHES=0
    HAS_TAGS=0

    svn ls "$SVN_URL/trunk" &>/dev/null && HAS_TRUNK=1
    svn ls "$SVN_URL/branches" &>/dev/null && HAS_BRANCHES=1
    svn ls "$SVN_URL/tags" &>/dev/null && HAS_TAGS=1

    SVN_OPTS=""

    [[ $HAS_TRUNK -eq 1 ]] && SVN_OPTS+=" -T trunk"
    [[ $HAS_BRANCHES -eq 1 ]] && SVN_OPTS+=" -b branches"
    [[ $HAS_TAGS -eq 1 ]] && SVN_OPTS+=" -t tags"

    # If no have trunk -> flat repo
    [[ $HAS_TRUNK -eq 0 ]] && SVN_OPTS=""

    # =========================
    # CLONE SVN
    # =========================
    if ! git svn clone \
        --quiet \
        $SVN_OPTS \
        "$SVN_URL" \
        "$tmp_dir" \
        >>"$log_file" 2>&1; then
        echo "[$(date '+%F %T')] ERROR $repo_name (clone failed)"
        printf "%s\n" "$repo_name" >> "$FAIL_FILE"
        rm -rf "$tmp_dir"
        return 1
    fi

    cd "$tmp_dir"

    # =========================
    # NORMALIZE DEFAULT BRANCH
    # =========================
    if git show-ref --verify --quiet refs/remotes/trunk; then
        git branch -m trunk main 2>/dev/null || true
    fi

    cd - >/dev/null

    # =========================
    # CREATE BARE REPO
    # =========================
    if ! git clone --bare "$tmp_dir" "$git_dest" >>"$log_file" 2>&1; then
        echo "[$(date '+%F %T')] ERROR $repo_name (bare clone failed)"
        printf "%s\n" "$repo_name" >> "$FAIL_FILE"
        rm -rf "$tmp_dir"
        return 1
    fi

    rm -rf "$tmp_dir"

    echo "[$(date '+%F %T')] DONE $repo_name"
    printf "%s\n" "$repo_name" >> "$SUCCESS_FILE"
}

export -f migrate_repo
export SVN_ROOT GIT_ROOT LOG_DIR SUCCESS_FILE SKIP_FILE FAIL_FILE

find "$SVN_ROOT" -mindepth 1 -maxdepth 1 -type d | \
    xargs -P "$MAX_PARALLEL" -I{} bash -c 'migrate_repo "$1"' _ {}

echo ""
echo "=== MIGRATION COMPLETE ==="

TOTAL=$(find "$SVN_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l)
SUCCESS=$(wc -l < "$SUCCESS_FILE")
SKIPPED=$(wc -l < "$SKIP_FILE")
FAILED=$(wc -l < "$FAIL_FILE")

echo "Total SVN Repo     : $TOTAL"
echo "Already Existing   : $SKIPPED"
echo "Migrated Success   : $SUCCESS"
echo "Failed             : $FAILED"

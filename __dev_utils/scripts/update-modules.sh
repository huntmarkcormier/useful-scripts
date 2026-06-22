#!/usr/bin/env bash
#
# update-modules.sh — обходит подмодули в dbo-modules/ и обновляет их рабочие
# ветки согласно __dev_utils/config/modules.tsv.
#
# Алгоритм для каждого модуля:
#   1. stash локальных изменений (включая untracked), если они есть;
#   2. git fetch --prune;
#   3. переключение на рабочую ветку (с созданием из origin/<branch>, если нужно);
#   4. git pull --ff-only;
#   5. возврат на исходную ветку;
#   6. восстановление stash через apply + drop; при конфликте stash остаётся
#      в стеке, рабочее дерево откатывается до чистого состояния.
#
# Флаги:
#   --dry-run           печатать мутирующие команды вместо выполнения
#   --config <path>     переопределить путь к конфигу
#   -h | --help         справка

set -uo pipefail

# ----- paths -----------------------------------------------------------------

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "${SCRIPT_DIR}/../.." && pwd)
MODULES_DIR="${ROOT_DIR}/dbo-modules"
CONFIG="${ROOT_DIR}/__dev_utils/config/modules.tsv"
DRY_RUN=0

# ----- args ------------------------------------------------------------------

usage() {
    cat <<EOF
Usage: $(basename "$0") [--dry-run] [--config <path>]

Обновляет рабочие ветки подмодулей dbo-modules/ согласно конфигу.

  --dry-run         показать команды, ничего не выполнять
  --config <path>   путь к конфигу (по умолчанию: ${CONFIG})
  -h, --help        эта справка
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --config)  CONFIG="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# ----- colors ----------------------------------------------------------------

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'
    C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_DIM=$'\e[2m'
else
    C_RESET=''; C_BOLD=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_DIM=''
fi

log()  { printf '%s\n' "$*"; }
warn() { printf '%s%s%s\n' "$C_YELLOW" "$*" "$C_RESET" >&2; }
err()  { printf '%s%s%s\n' "$C_RED"    "$*" "$C_RESET" >&2; }

# ----- dry-run helper --------------------------------------------------------

run() {
    if (( DRY_RUN )); then
        printf '%sDRY:%s %s\n' "$C_DIM" "$C_RESET" "$*"
    else
        "$@"
    fi
}

# ----- preflight -------------------------------------------------------------

[[ -f "$CONFIG" ]]      || { err "config not found: $CONFIG"; exit 2; }
[[ -d "$MODULES_DIR" ]] || { err "modules dir not found: $MODULES_DIR"; exit 2; }

# ----- state -----------------------------------------------------------------

declare -a SUMMARY_LINES=()
declare -a CONFIGURED=()
EXIT_CODE=0

add_summary() {
    local module="$1" color="$2" status="$3"
    SUMMARY_LINES+=("$(printf '%-16s %s%s%s' "$module" "$color" "$status" "$C_RESET")")
}

# ----- per-module processing -------------------------------------------------

process_module() {
    local module="$1" target="$2"
    local dir="${MODULES_DIR}/${module}"

    printf '\n%s=== %s%s%s ===%s\n' "$C_BOLD" "$C_RESET" "$C_BOLD" "$module" "$C_RESET"

    if [[ ! -d "$dir/.git" ]]; then
        warn "[$module] не клонирован — пропускаю"
        add_summary "$module" "$C_YELLOW" "SKIPPED (not cloned)"
        return
    fi

    pushd "$dir" >/dev/null || {
        err "[$module] cd failed"
        add_summary "$module" "$C_RED" "FAILED (cd)"
        EXIT_CODE=1
        return
    }

    local original_branch did_stash=0 did_switch=0 stash_msg
    stash_msg="auto-stash by update-modules.sh @ $(date -Iseconds)"

    # текущая ветка / detached HEAD
    if ! original_branch=$(git symbolic-ref --short HEAD 2>/dev/null); then
        warn "[$module] detached HEAD — пропускаю"
        add_summary "$module" "$C_YELLOW" "SKIPPED (detached HEAD)"
        popd >/dev/null
        return
    fi
    log "[$module] на ветке '${original_branch}', рабочая — '${target}'"

    # dirty?
    if [[ -n "$(git status --porcelain)" ]]; then
        log "[$module] обнаружены локальные изменения — stash"
        if run git stash push -u -m "$stash_msg"; then
            did_stash=1
        else
            err "[$module] stash push failed"
            add_summary "$module" "$C_RED" "FAILED (stash push)"
            EXIT_CODE=1
            popd >/dev/null
            return
        fi
    fi

    # fetch
    if ! run git fetch --prune; then
        err "[$module] fetch failed"
        restore_stash "$module" "$did_stash"
        add_summary "$module" "$C_RED" "FAILED (fetch)"
        EXIT_CODE=1
        popd >/dev/null
        return
    fi

    # переключение на target, если нужно
    if [[ "$original_branch" != "$target" ]]; then
        if git show-ref --verify --quiet "refs/heads/${target}"; then
            if ! run git checkout "$target"; then
                err "[$module] checkout '${target}' failed"
                restore_stash "$module" "$did_stash"
                add_summary "$module" "$C_RED" "FAILED (checkout)"
                EXIT_CODE=1
                popd >/dev/null
                return
            fi
            did_switch=1
        elif git show-ref --verify --quiet "refs/remotes/origin/${target}"; then
            if ! run git checkout -b "$target" "origin/${target}"; then
                err "[$module] checkout -b '${target}' from origin failed"
                restore_stash "$module" "$did_stash"
                add_summary "$module" "$C_RED" "FAILED (checkout -b)"
                EXIT_CODE=1
                popd >/dev/null
                return
            fi
            did_switch=1
        else
            err "[$module] рабочая ветка '${target}' не найдена ни локально, ни в origin"
            restore_stash "$module" "$did_stash"
            add_summary "$module" "$C_RED" "FAILED (target branch missing)"
            EXIT_CODE=1
            popd >/dev/null
            return
        fi
    fi

    # pull --ff-only с подсчётом дельты
    local sha_before sha_after pulled_count
    sha_before=$(git rev-parse HEAD 2>/dev/null || echo '')
    if ! run git pull --ff-only; then
        err "[$module] pull --ff-only failed"
        return_to_original "$module" "$did_switch" "$original_branch"
        restore_stash "$module" "$did_stash"
        add_summary "$module" "$C_RED" "FAILED (pull)"
        EXIT_CODE=1
        popd >/dev/null
        return
    fi
    sha_after=$(git rev-parse HEAD 2>/dev/null || echo '')

    local pull_note
    if (( DRY_RUN )); then
        pull_note="DRY"
    elif [[ "$sha_before" == "$sha_after" ]]; then
        pull_note="up-to-date"
    else
        pulled_count=$(git rev-list --count "${sha_before}..${sha_after}" 2>/dev/null || echo '?')
        pull_note="pulled ${pulled_count} commits"
    fi

    # возврат на исходную
    if (( did_switch )); then
        if ! run git checkout "$original_branch"; then
            err "[$module] не удалось вернуться на '${original_branch}' — stash оставлен в стеке"
            add_summary "$module" "$C_RED" "FAILED (return to '${original_branch}')"
            EXIT_CODE=1
            popd >/dev/null
            return
        fi
    fi

    # восстановление stash
    local stash_note=""
    if (( did_stash )); then
        if try_apply_stash "$module"; then
            stash_note=", unstashed"
        else
            add_summary "$module" "$C_YELLOW" "PARTIAL (${pull_note}, stash conflict — stash@{0} preserved)"
            EXIT_CODE=1
            popd >/dev/null
            return
        fi
    fi

    add_summary "$module" "$C_GREEN" "OK (${pull_note}${stash_note})"
    popd >/dev/null
}

# ----- helpers: stash / return ----------------------------------------------

return_to_original() {
    local module="$1" did_switch="$2" original_branch="$3"
    (( did_switch )) || return 0
    if ! run git checkout "$original_branch"; then
        err "[$module] не удалось вернуться на '${original_branch}'"
        return 1
    fi
}

restore_stash() {
    local module="$1" did_stash="$2"
    (( did_stash )) || return 0
    try_apply_stash "$module" || \
        warn "[$module] stash@{0} оставлен в стеке для ручного разбора"
}

# применяет stash@{0}; при конфликте чистит рабочее дерево и оставляет stash.
# возвращает 0 при чистом apply, 1 при конфликте/ошибке.
try_apply_stash() {
    local module="$1"
    if (( DRY_RUN )); then
        printf '%sDRY:%s git stash apply && git stash drop\n' "$C_DIM" "$C_RESET"
        return 0
    fi
    if git stash apply --quiet stash@{0}; then
        # detect conflict markers in status
        if git status --porcelain | grep -qE '^(UU|AA|DD|AU|UA|DU|UD) '; then
            err "[$module] конфликт при stash apply — откатываю рабочее дерево"
            git reset --hard HEAD >/dev/null 2>&1 || true
            git clean -fd >/dev/null 2>&1 || true
            return 1
        fi
        if ! git stash drop --quiet stash@{0}; then
            warn "[$module] не удалось дропнуть stash@{0}"
        fi
        return 0
    else
        err "[$module] git stash apply вернул ошибку"
        git reset --hard HEAD >/dev/null 2>&1 || true
        git clean -fd >/dev/null 2>&1 || true
        return 1
    fi
}

# ----- main loop -------------------------------------------------------------

log "${C_BOLD}update-modules${C_RESET}: конфиг=${CONFIG}$( ((DRY_RUN)) && echo ' (DRY-RUN)' )"

while IFS=$'\t' read -r module branch || [[ -n "${module:-}" ]]; do
    # skip comments / blank lines
    [[ -z "${module// }" ]] && continue
    [[ "${module#\#}" != "$module" ]] && continue
    # tolerate spaces instead of tabs
    if [[ -z "${branch:-}" ]]; then
        # попытка распарсить через whitespace
        read -r module branch <<<"$module"
    fi
    [[ -z "${branch:-}" ]] && { warn "пропускаю строку без ветки: '$module'"; continue; }
    CONFIGURED+=("$module")
    process_module "$module" "$branch"
done < "$CONFIG"

# unconfigured directories
declare -a UNCONFIGURED=()
shopt -s nullglob
for d in "$MODULES_DIR"/*/; do
    name=$(basename "$d")
    [[ "$name" == "target" ]] && continue
    found=0
    for c in "${CONFIGURED[@]}"; do
        [[ "$c" == "$name" ]] && { found=1; break; }
    done
    (( found )) || UNCONFIGURED+=("$name")
done
shopt -u nullglob

# ----- summary ---------------------------------------------------------------

printf '\n%s=== Summary ===%s\n' "$C_BOLD" "$C_RESET"
for line in "${SUMMARY_LINES[@]}"; do
    printf '%s\n' "$line"
done

if (( ${#UNCONFIGURED[@]} > 0 )); then
    printf '\n%sUnconfigured directories in dbo-modules/:%s %s\n' \
        "$C_YELLOW" "$C_RESET" "${UNCONFIGURED[*]}"
fi

exit "$EXIT_CODE"

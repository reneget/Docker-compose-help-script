#!/usr/bin/env bash
#
# compose-runner.sh — запуск/остановка docker compose сервисов во всех подпапках каталога.
#
# Ищет в подпапках compose-файл (docker-compose.yml / docker-compose.yaml /
# compose.yml / compose.yaml) и выполняет в каждой найденной папке выбранное
# действие. Скрытые папки (.* ) и node_modules пропускаются.
#
# Требования: bash >= 4.3, docker compose (v2) или docker-compose (v1).
# Справка: ./compose-runner.sh --help

set -uo pipefail

# ----------------------------- параметры по умолчанию -----------------------------
ACTION="up"          # up | down
DO_BUILD=0
DO_PULL=0
DO_VOLUMES=0
PARALLEL=0
JOBS=4
DEPTH=1
DRY_RUN=0
VERBOSE=0
GOT_DASH=0
BASE_DIR="$PWD"
EXTRA_ARGS=()

usage() {
  cat <<'EOF'
compose-runner.sh — запуск/остановка docker compose сервисов во всех подпапках.

Использование:
  ./compose-runner.sh [ОПЦИИ]

Опции:
  --down          остановить сервисы (docker compose down) вместо запуска
  --build         пересобрать образы (docker compose up -d --build)
  --pull          тянуть свежие образы перед запуском (up -d --pull always)
  --volumes       вместе с --down: удалять и тома (down -v)
  --parallel      обрабатывать папки параллельно (по умолчанию последовательно)
  --jobs N        лимит параллельных задач (по умолчанию 4; работает с --parallel)
  --depth N       глубина вложенности подпапок (по умолчанию 1 — только прямые подпапки)
  --dir PATH      базовый каталог (по умолчанию — текущий)
  --dry-run       только показать, что будет выполнено, ничего не запуская
  --verbose       подробный вывод (в параллельном режиме — логи и успешных папок)
  --no-color      отключить цветной вывод
  -- ФЛАГИ        всё после «--» передаётся напрямую в docker compose
  -h, --help      эта справка

Примеры:
  ./compose-runner.sh                          # docker compose up -d во всех подпапках
  ./compose-runner.sh --build                  # up -d --build
  ./compose-runner.sh --down                   # остановить всё (docker compose down)
  ./compose-runner.sh --parallel --jobs 8      # параллельно, до 8 задач
  ./compose-runner.sh --dry-run --down         # показать, что будет остановлено
  ./compose-runner.sh --dir /opt/services --depth 2 --build
  ./compose-runner.sh -- --force-recreate      # доп. флаги compose после «--»
EOF
}

die()  { printf 'Ошибка: %s\n' "$*" >&2; exit 2; }
warn() { printf 'Внимание: %s\n' "$*" >&2; }

# bash >= 4.3: нужны mapfile, wait -n, declare -A
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
  die "требуется bash >= 4.3 (сейчас: $BASH_VERSION)"
fi

# ----------------------------- разбор аргументов -----------------------------
while (( $# )); do
  case "$1" in
    --down)       ACTION="down" ;;
    --build)      DO_BUILD=1 ;;
    --pull)       DO_PULL=1 ;;
    --volumes)    DO_VOLUMES=1 ;;
    --parallel)   PARALLEL=1 ;;
    --dry-run)    DRY_RUN=1 ;;
    --verbose)    VERBOSE=1 ;;
    --no-color)   NO_COLOR=1 ;;
    -h|--help)    usage; exit 0 ;;
    --jobs)
      [[ ${2:-} =~ ^[1-9][0-9]*$ ]] || die "--jobs требует целое число > 0"
      JOBS="$2"; shift ;;
    --depth)
      [[ ${2:-} =~ ^[1-9][0-9]*$ ]] || die "--depth требует целое число > 0"
      DEPTH="$2"; shift ;;
    --dir)
      [[ -n ${2:-} ]] || die "--dir требует путь к каталогу"
      BASE_DIR="$2"; shift ;;
    --)
      shift; EXTRA_ARGS+=("$@"); GOT_DASH=1; break ;;
    *)
      die "неизвестный аргумент: $1 (см. --help; доп. флаги compose — после «--»)" ;;
  esac
  shift
done

# ----------------------------- цвета -----------------------------
if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  C_GREEN=$'\e[32m'
  C_RED=$'\e[31m'
  C_YELLOW=$'\e[33m'
  C_CYAN=$'\e[36m'
  C_BOLD=$'\e[1m'
  C_RESET=$'\e[0m'
else
  C_GREEN=''
  C_RED=''
  C_YELLOW=''
  C_CYAN=''
  C_BOLD=''
  C_RESET=''
fi

# ----------------------------- проверки -----------------------------
[[ -d $BASE_DIR ]] || die "каталог не найден: $BASE_DIR"
resolved="$(cd -- "$BASE_DIR" 2>/dev/null && pwd -P)" || die "не удалось войти в каталог: $BASE_DIR"
BASE_DIR="$resolved"

if [[ $ACTION == down ]]; then
  if (( DO_BUILD || DO_PULL )); then
    warn "--build/--pull не имеют смысла с --down — игнорируются"
    DO_BUILD=0; DO_PULL=0
  fi
elif (( DO_VOLUMES )); then
  warn "--volumes работает только вместе с --down — игнорируется"
  DO_VOLUMES=0
fi

# ----------------------------- определение docker compose -----------------------------
COMPOSE_CMD=()
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD=(docker-compose)
elif (( DRY_RUN )); then
  COMPOSE_CMD=(docker compose)   # просто для отображения в плане
else
  die "docker compose не найден (проверьте: docker compose version)"
fi

COMPOSE_ARGS=()
if [[ $ACTION == up ]]; then
  COMPOSE_ARGS+=(up -d)
  (( DO_BUILD ))  && COMPOSE_ARGS+=(--build)
  (( DO_PULL ))   && COMPOSE_ARGS+=(--pull always)
else
  COMPOSE_ARGS+=(down --remove-orphans)
  (( DO_VOLUMES )) && COMPOSE_ARGS+=(-v)
fi
(( ${#EXTRA_ARGS[@]} )) && COMPOSE_ARGS+=("${EXTRA_ARGS[@]}")
CMD_DISPLAY="${COMPOSE_CMD[*]} ${COMPOSE_ARGS[*]}"

# ----------------------------- поиск папок с compose-файлом -----------------------------
mapfile -t DIRS < <(
  find "$BASE_DIR" -mindepth 1 -maxdepth $((DEPTH + 1)) \
    \( -type d \( -name '.*' -o -name node_modules \) -prune \) -o \
    \( -type f \( -name docker-compose.yml  -o -name docker-compose.yaml \
                 -o -name compose.yml      -o -name compose.yaml \) \
       -printf '%h\n' \) \
  | awk -v b="$BASE_DIR" '$0 != b' | sort -u
)

rel() { local r="${1#"$BASE_DIR"/}"; printf '%s' "$r"; }

MODE_DESC="последовательно"
(( PARALLEL )) && MODE_DESC="параллельно (jobs=$JOBS)"

printf '%s%s compose-runner%s  каталог: %s\n' "$C_BOLD" "$C_CYAN" "$C_RESET" "$BASE_DIR"
printf 'действие: %s%s%s | режим: %s\n' "$C_BOLD" "$CMD_DISPLAY" "$C_RESET" "$MODE_DESC"
printf 'найдено папок с compose-файлом: %d\n' "${#DIRS[@]}"

if (( ${#DIRS[@]} == 0 )); then
  printf 'Нечего делать.\n'
  exit 0
fi

# ----------------------------- dry-run -----------------------------
if (( DRY_RUN )); then
  printf '\n%s[dry-run] план действий, ничего не выполняется:%s\n' "$C_YELLOW" "$C_RESET"
  for dir in "${DIRS[@]}"; do
    printf '  %-40s -> %s\n' "$(rel "$dir")" "$CMD_DISPLAY"
  done
  exit 0
fi

# ----------------------------- выполнение -----------------------------
OK_DIRS=()
FAIL_DIRS=()

run_compose() {  # $1 — каталог
  ( cd -- "$1" && "${COMPOSE_CMD[@]}" "${COMPOSE_ARGS[@]}" )
}

run_sequential() {
  local dir rc
  for dir in "${DIRS[@]}"; do
    printf '\n%s==> %s%s\n' "$C_CYAN" "$(rel "$dir")" "$C_RESET"
    if run_compose "$dir"; then
      OK_DIRS+=("$dir")
      printf '%s[ OK ]%s\n' "$C_GREEN" "$C_RESET"
    else
      rc=$?
      FAIL_DIRS+=("$dir")
      printf '%s[FAIL] код %d%s — вывод выше\n' "$C_RED" "$rc" "$C_RESET"
    fi
  done
}

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

declare -A PRINTED=()

# Печатает результаты завершившихся параллельных задач (ровно один раз каждую)
print_finished() {
  local i dir st log
  for i in "${!DIRS[@]}"; do
    [[ -n ${PRINTED[$i]:-} ]] && continue
    log="$TMPROOT/$i.log"
    [[ -s "$log.status" ]] || continue
    st="$(<"$log.status")"
    st="${st:-1}"
    PRINTED[$i]=1
    dir="$(rel "${DIRS[$i]}")"
    if [[ $st == 0 ]]; then
      OK_DIRS+=("${DIRS[$i]}")
      printf '%s[ OK ]%s  %s\n' "$C_GREEN" "$C_RESET" "$dir"
      if (( VERBOSE )); then sed 's/^/    /' "$log"; fi
    else
      FAIL_DIRS+=("${DIRS[$i]}")
      printf '%s[FAIL] код %s%s  %s\n' "$C_RED" "$st" "$C_RESET" "$dir"
      sed 's/^/    /' "$log"
    fi
  done
  return 0
}

run_job() {  # $1 — индекс, $2 — каталог; вывод — в лог, статус — в .status
  local log="$TMPROOT/$1.log"
  ( cd -- "$2" && "${COMPOSE_CMD[@]}" "${COMPOSE_ARGS[@]}" ) >"$log" 2>&1
  printf '%s\n' "$?" >"$log.status"
}

run_parallel() {
  local i
  trap 'printf "\nПрервано — останавливаю фоновые задачи...\n" >&2; kill $(jobs -p) 2>/dev/null; exit 130' INT
  for i in "${!DIRS[@]}"; do
    while (( $(jobs -rp | wc -l) >= JOBS )); do
      wait -n || true
      print_finished
    done
    printf '%s[start]%s  %s\n' "$C_CYAN" "$C_RESET" "$(rel "${DIRS[$i]}")"
    run_job "$i" "${DIRS[$i]}" &
  done
  while (( $(jobs -rp | wc -l) > 0 )); do
    wait -n || true
    print_finished
  done
  print_finished
}

if (( PARALLEL )); then
  run_parallel
else
  run_sequential
fi

# ----------------------------- итог -----------------------------
printf '\n%sИтог:%s успешно %s%d%s, ошибок %s%d%s, всего %d\n' \
  "$C_BOLD" "$C_RESET" \
  "$C_GREEN" "${#OK_DIRS[@]}" "$C_RESET" \
  "$C_RED" "${#FAIL_DIRS[@]}" "$C_RESET" "${#DIRS[@]}"

(( ${#FAIL_DIRS[@]} )) && exit 1
exit 0

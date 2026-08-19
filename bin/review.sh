#!/usr/bin/env bash
# Первичное LLM-ревью ADR.
#
#   ./bin/review.sh <confluence-url>              # полный прогон (готовые этапы пропускаются)
#   ./bin/review.sh <confluence-url> --stage 2    # перегнать только этап 2 (и всё после — руками)
#   ./bin/review.sh <confluence-url> --force      # перегнать всё с нуля
#
# Артефакты: workspace/<slug>/{adr.md, verdicts.json, substance.json, slop.json, task-prompt.md, report.md}
# + prompt-stage*.md — реально отправленные промпты, для дебага.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Корп-CLI ──────────────────────────────────────────────────────────────────
# FIXME(корп-CLI): подставь реальный вызов headless-режима своего CLI.
# Контракт, на который рассчитан скрипт:
#   - $1 — файл с промптом; скрипт уже подставил в него рубрику/текст ADR;
#   - агент подключается файлом-инструкцией agents/reviewer.md;
#   - MCP Confluence доступен в headless-режиме;
#   - в stdout уходит ТОЛЬКО ответ модели (логи/прогресс — в stderr или отключить).
CLI_BIN="${ADR_REVIEW_CLI:-corp-cli}"     # FIXME: имя бинаря или полный путь
run_llm() {
  local prompt_file="$1"
  # FIXME: реальные флаги. Типичные варианты:
  #   "$CLI_BIN" --agent "$ROOT/agents/reviewer.md" -p "$(cat "$prompt_file")"
  #   "$CLI_BIN" chat --system-file "$ROOT/agents/reviewer.md" --prompt-file "$prompt_file" --no-interactive
  "$CLI_BIN" --agent "$ROOT/agents/reviewer.md" -p "$(cat "$prompt_file")"
}
# ──────────────────────────────────────────────────────────────────────────────

usage() { sed -n '2,8p' "${BASH_SOURCE[0]}"; exit 1; }

URL="" ; ONLY_STAGE="" ; FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --stage) ONLY_STAGE="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage ;;
    *) URL="$1"; shift ;;
  esac
done
[ -n "$URL" ] || usage
command -v jq >/dev/null || { echo "нужен jq" >&2; exit 1; }

SLUG="$(printf '%s' "$URL" | sed -e 's|[?#].*||' -e 's|/*$||' -e 's|.*/||' \
        | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-' '-' | sed -e 's/-\{2,\}/-/g' -e 's/^-//' -e 's/-$//')"
[ -n "$SLUG" ] || SLUG="adr-$(printf '%s' "$URL" | cksum | cut -d' ' -f1)"
WS="$ROOT/workspace/$SLUG"
mkdir -p "$WS"
echo "ADR: $URL"
echo "workspace: $WS"

# LLM любит заворачивать JSON в ```-заборы — снимаем и берём с первой { до конца.
extract_json() { sed -e 's/^```json$//' -e 's/^```$//' | sed -n '/^[[:space:]]*{/,$p'; }

need() {  # need <номер-этапа> <файл-артефакт> → 0, если этап надо гнать
  local n="$1" f="$2"
  if [ -n "$ONLY_STAGE" ]; then [ "$ONLY_STAGE" = "$n" ]; return; fi
  [ "$FORCE" = 1 ] || [ ! -s "$f" ]
}

# ── Этап 1: нормализация ADR ─────────────────────────────────────────────────
if need 1 "$WS/adr.md"; then
  echo "── этап 1: тянем и нормализуем ADR"
  sed "s|{{ADR_URL}}|$URL|g" "$ROOT/prompts/stage1-fetch.md" > "$WS/prompt-stage1.md"
  run_llm "$WS/prompt-stage1.md" > "$WS/adr.md"
  if grep -q '^FETCH-ERROR:' "$WS/adr.md"; then
    echo "не смогли достать ADR: $(grep '^FETCH-ERROR:' "$WS/adr.md")" >&2
    rm -f "$WS/adr.md"; exit 1
  fi
  [ -s "$WS/adr.md" ] || { echo "этап 1 вернул пустоту" >&2; exit 1; }
else
  echo "── этап 1: уже есть, пропускаем"
fi

# ── Этап 2: проход по рубрике ────────────────────────────────────────────────
if need 2 "$WS/verdicts.json"; then
  echo "── этап 2: проход по рубрике"
  awk -v rub="$ROOT/rubric/rubric.yaml" -v adr="$WS/adr.md" '
    /^\{\{RUBRIC\}\}$/ { while ((getline l < rub) > 0) print l; close(rub); next }
    /^\{\{ADR\}\}$/    { while ((getline l < adr) > 0) print l; close(adr); next }
    { print }
  ' "$ROOT/prompts/stage2-rubric.md" > "$WS/prompt-stage2.md"
  run_llm "$WS/prompt-stage2.md" | extract_json > "$WS/verdicts.json"
  jq -e '.items | type == "array" and length > 0
         and all(.[]; .id and (.status | IN("pass","fail","unclear","n-a")))' \
     "$WS/verdicts.json" >/dev/null \
    || { echo "этап 2 вернул невалидный JSON — смотри $WS/verdicts.json" >&2; exit 1; }
else
  echo "── этап 2: уже есть, пропускаем"
fi

# ── Этап 3: содержательный проход ────────────────────────────────────────────
if need 3 "$WS/substance.json"; then
  echo "── этап 3: сверка с нормами (norms/ + MCP-поиск)"
  awk -v ver="$WS/verdicts.json" -v adr="$WS/adr.md" '
    /^\{\{VERDICTS\}\}$/ { while ((getline l < ver) > 0) print l; close(ver); next }
    /^\{\{ADR\}\}$/      { while ((getline l < adr) > 0) print l; close(adr); next }
    { print }
  ' "$ROOT/prompts/stage3-substance.md" > "$WS/prompt-stage3.md"
  run_llm "$WS/prompt-stage3.md" | extract_json > "$WS/substance.json"
  jq -e '.findings | type == "array"' "$WS/substance.json" >/dev/null \
    || { echo "этап 3 вернул невалидный JSON — смотри $WS/substance.json" >&2; exit 1; }
else
  echo "── этап 3: уже есть, пропускаем"
fi

# ── Этап 4: проверка на неосмысленную генерацию ──────────────────────────────
if need 4 "$WS/slop.json"; then
  echo "── этап 4: маркеры AI-дичи и вопросы на понимание"
  awk -v adr="$WS/adr.md" '
    /^\{\{ADR\}\}$/ { while ((getline l < adr) > 0) print l; close(adr); next }
    { print }
  ' "$ROOT/prompts/stage4-understanding.md" > "$WS/prompt-stage4.md"
  run_llm "$WS/prompt-stage4.md" | extract_json > "$WS/slop.json"
  jq -e '(.markers | type == "array") and (.comprehension_questions | type == "array")' \
     "$WS/slop.json" >/dev/null \
    || { echo "этап 4 вернул невалидный JSON — смотри $WS/slop.json" >&2; exit 1; }
else
  echo "── этап 4: уже есть, пропускаем"
fi

# ── Этап 5: абстрактный промпт задачи ────────────────────────────────────────
if need 5 "$WS/task-prompt.md"; then
  echo "── этап 5: промпт задачи для web-LLM"
  awk -v adr="$WS/adr.md" '
    /^\{\{ADR\}\}$/ { while ((getline l < adr) > 0) print l; close(adr); next }
    { print }
  ' "$ROOT/prompts/stage5-taskprompt.md" > "$WS/prompt-stage5.md"
  run_llm "$WS/prompt-stage5.md" > "$WS/task-prompt.md"
  [ -s "$WS/task-prompt.md" ] || { echo "этап 5 вернул пустоту" >&2; exit 1; }
else
  echo "── этап 5: уже есть, пропускаем"
fi

# ── Этап 6: отчёт (без LLM, чистый jq) ───────────────────────────────────────
echo "── этап 6: собираем отчёт"
{
  echo "# Первичное ревью ADR"
  echo
  echo "- Источник: $URL"
  echo "- Дата прогона: $(date +%F)"
  echo
  echo "## Блокеры"
  echo
  jq -r '[.items[] | select(.severity == "blocker" and (.status == "fail" or .status == "unclear"))]
         | if length == 0 then "_Блокеров по рубрике нет._"
           else .[] | "- **\(.title)** (`\(.status)`) — \(.comment)" end' "$WS/verdicts.json"
  echo
  echo "## Рубрика"
  echo
  echo "| Пункт | Вердикт | Комментарий |"
  echo "|---|---|---|"
  jq -r '.items[] | "| \(.title) | \({"pass":"✅","fail":"❌","unclear":"⚠️","n-a":"➖"}[.status] // .status) \(.status) | \(.comment | gsub("\\|"; "/") | gsub("\n"; " ")) |"' \
     "$WS/verdicts.json"
  echo
  echo "## Цитаты-основания"
  echo
  jq -r '[.items[] | select(.quote != "" and .quote != null)]
         | if length == 0 then "_Нет._"
           else .[] | "- **\(.title)**: «\(.quote | gsub("\n"; " "))»" end' "$WS/verdicts.json"
  echo
  echo "## Содержательные замечания"
  echo
  jq -r 'if (.findings | length) == 0 then "_Находок нет._"
         else .findings[] | "- **[\(.rubric_id)]** \(.finding)\n  - источник: \(if .evidence_source == "" then "—" else .evidence_source end); уверенность: \(.confidence)"
         end' "$WS/substance.json"
  echo
  echo "## Признаки генерации без понимания"
  echo
  jq -r 'if (.markers | length) == 0 then "_Не найдено._"
         else .markers[] | "- **\(.marker)** (уверенность: \(.confidence))\n  - цитата: «\(.quote | gsub("\n"; " "))»\n  - \(.explanation)"
         end' "$WS/slop.json"
  echo
  echo "## Вопросы на понимание (задать устно)"
  echo
  jq -r 'if (.comprehension_questions | length) == 0 then "_Нет._"
         else .comprehension_questions[] | "- \(.question)\n  - к строке: «\(.quote | gsub("\n"; " "))»"
         end' "$WS/slop.json"
  echo
  echo "## Вопросы автору (копипаст в Confluence)"
  echo
  { jq -r '.items[] | select(.question_for_author != "" and .question_for_author != null) | "- \(.question_for_author)"' "$WS/verdicts.json"
    jq -r '.findings[] | select(.question_for_author != "" and .question_for_author != null) | "- \(.question_for_author)"' "$WS/substance.json"
  } | awk 'NF' | { grep . || echo "_Вопросов нет._"; }
  echo
  echo "---"
  echo "_Промпт задачи для web-LLM (сравнить best practice с решением команды): \`task-prompt.md\` рядом с отчётом._"
  echo
  echo "_Сгенерировано LLM — проверь каждый пункт перед отправкой автору._"
} > "$WS/report.md"

echo
echo "готово: $WS/report.md"

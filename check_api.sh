#!/usr/bin/env bash
#
# check_api.sh — проверка доступности HTTP API.
#
# Использование: ./check_api.sh <URL>
# Пример:        ./check_api.sh https://httpbin.org/status/200
#
# Код возврата: 0 — API ответил 200, 1 — любой другой код, ошибка сети или неверные аргументы.

set -uo pipefail

readonly EXPECTED_CODE=200
readonly TIMEOUT=10

usage() {
    echo "Использование: $(basename "$0") <URL>" >&2
    echo "Пример: $(basename "$0") https://httpbin.org/status/200" >&2
}

if [[ $# -ne 1 ]]; then
    echo "Ошибка: ожидается ровно один аргумент — URL API." >&2
    usage
    exit 1
fi

url="$1"

# URL должен начинаться с http:// или https:// и не содержать пробелов
if [[ ! "$url" =~ ^https?://[^[:space:]]+$ ]]; then
    echo "Ошибка: некорректный URL '$url' (ожидается http:// или https://)." >&2
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "Ошибка: curl не установлен." >&2
    exit 1
fi

# -s: без прогресс-бара, -o /dev/null: тело не нужно, -w: печатаем только код ответа.
# --retry повторяет запрос при временных сбоях (таймауты, 5xx), чтобы не ловить ложные падения.
# При ошибке соединения curl печатает код 000.
http_code=$(curl -s -o /dev/null -w '%{http_code}' \
    --max-time "$TIMEOUT" --retry 2 --retry-delay 1 \
    "$url")

if [[ "$http_code" == "$EXPECTED_CODE" ]]; then
    echo "API доступен"
    exit 0
else
    echo "API недоступен, код ответа: $http_code"
    exit 1
fi

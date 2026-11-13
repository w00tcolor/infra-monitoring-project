#!/usr/bin/env bash
#
# analyze_logs.sh — генерация тестового access.log и его анализ.
#
# Использование: ./analyze_logs.sh [-f файл] [-n строк] [-s]
#   -f FILE  путь к лог-файлу (по умолчанию access.log)
#   -n N     сколько строк сгенерировать (по умолчанию 300, минимум 300)
#   -s       не генерировать лог, только проанализировать существующий файл
#   -h       справка
#
# Формат строки:
#   192.168.1.10 - - [15/Aug/2026:10:15:32] "GET /api/users HTTP/1.1" 200

set -euo pipefail

log_file="access.log"
lines=300
skip_generate=false

usage() {
    sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//'
}

while getopts ":f:n:sh" opt; do
    case "$opt" in
        f) log_file="$OPTARG" ;;
        n) lines="$OPTARG" ;;
        s) skip_generate=true ;;
        h) usage; exit 0 ;;
        :) echo "Ошибка: опции -$OPTARG нужен аргумент." >&2; usage >&2; exit 1 ;;
        \?) echo "Ошибка: неизвестная опция -$OPTARG." >&2; usage >&2; exit 1 ;;
    esac
done

if [[ ! "$lines" =~ ^[0-9]+$ ]] || (( lines < 300 )); then
    echo "Ошибка: -n должно быть целым числом не меньше 300." >&2
    exit 1
fi

# Регулярное выражение для IPv4: каждый октет 0–255
readonly OCTET='(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
readonly IP_RE="${OCTET}\.${OCTET}\.${OCTET}\.${OCTET}"
# Полная строка лога: IP, дата, запрос в кавычках, трёхзначный код
readonly LINE_RE="^${IP_RE} - - \[[0-9]{2}/[A-Za-z]{3}/[0-9]{4}:[0-9]{2}:[0-9]{2}:[0-9]{2}\] \"[A-Z]+ [^ ]+ HTTP/[0-9.]+\" [0-9]{3}$"

generate_log() {
    local file="$1" count="$2"
    # Несколько "шумных" IP, чтобы топ был заметен, и разные коды ответа
    local ips=(192.168.1.10 192.168.1.10 192.168.1.10 10.0.0.5 10.0.0.5
               172.16.0.23 192.168.1.42 10.0.0.77 203.0.113.9 198.51.100.14)
    local methods=(GET GET GET POST POST PUT DELETE)
    local paths=(/api/users /api/login /api/orders /api/products /api/health /api/metrics)
    local codes=(200 200 200 200 200 201 204 301 400 401 403 404 500 502 503)

    local start=$(( 10 * 3600 + 15 * 60 ))   # 10:15:00
    local i t
    for (( i = 0; i < count; i++ )); do
        t=$(( start + i ))
        printf '%s - - [15/Aug/2026:%02d:%02d:%02d] "%s %s HTTP/1.1" %s\n' \
            "${ips[RANDOM % ${#ips[@]}]}" \
            $(( t / 3600 % 24 )) $(( t / 60 % 60 )) $(( t % 60 )) \
            "${methods[RANDOM % ${#methods[@]}]}" \
            "${paths[RANDOM % ${#paths[@]}]}" \
            "${codes[RANDOM % ${#codes[@]}]}"
    done > "$file"
}

if [[ "$skip_generate" == false ]]; then
    generate_log "$log_file" "$lines"
    echo "Сгенерирован файл $log_file ($lines строк)"
fi

if [[ ! -r "$log_file" ]]; then
    echo "Ошибка: файл $log_file не найден или недоступен для чтения." >&2
    exit 1
fi

echo "=============================================="
echo " Анализ лога: $log_file"
echo "=============================================="

# Общее количество запросов: считаем только строки, подходящие под формат
total=$(grep -cE "$LINE_RE" "$log_file" || true)
invalid=$(grep -cvE "$LINE_RE" "$log_file" || true)
echo "Всего запросов: $total"
if (( invalid > 0 )); then
    echo "Пропущено строк неверного формата: $invalid"
fi

echo
echo "Топ-3 IP-адреса по числу запросов:"
grep -oE "^${IP_RE}" "$log_file" \
    | sort \
    | uniq -c \
    | sort -rn \
    | head -n 3 \
    | awk '{ printf "  %d. %-16s %d запросов\n", NR, $2, $1 }'

echo
echo "Ошибки по классам кодов ответа:"
grep -E "$LINE_RE" "$log_file" \
    | awk '
        $NF ~ /^4[0-9][0-9]$/ { c4++ }
        $NF ~ /^5[0-9][0-9]$/ { c5++ }
        END {
            printf "  4xx (ошибки клиента): %d\n", c4
            printf "  5xx (ошибки сервера): %d\n", c5
            printf "  Всего 4xx+5xx:        %d\n", c4 + c5
        }'

echo
echo "Распределение по HTTP-методам:"
# sed вырезает метод из запроса в кавычках: "GET /path HTTP/1.1" -> GET
grep -E "$LINE_RE" "$log_file" \
    | sed -E 's/^.*"([A-Z]+) [^ ]+ HTTP\/[0-9.]+".*$/\1/' \
    | sort \
    | uniq -c \
    | sort -rn \
    | awk '{ printf "  %-7s %d\n", $2, $1 }'

# infra-monitoring-project

Учебный проект по инфраструктурному мониторингу: Bash-скрипты для проверки API и анализа логов, стек на Docker Compose (http-echo + nginx), CI на GitHub Actions и анализ сетевого трафика в Wireshark.

## Структура

```
.
├── .github/workflows/ci.yml   # CI: проверка синтаксиса и тесты скриптов, проверка compose-стека
├── check_api.sh               # мониторинг доступности API
├── analyze_logs.sh            # генерация и анализ access.log
├── docker-compose.yml         # стек: api (http-echo) + proxy (nginx)
├── nginx/default.conf         # конфиг reverse proxy: 80 -> api:8080
├── docs/
│   ├── traffic-report.md      # отчёт по анализу трафика в Wireshark
│   └── capture.pcapng         # дамп трафика
├── .gitignore
└── README.md
```

## Git workflow

- `main` — защищённая ветка, изменения попадают в неё только через Pull Request.
- `feature/monitoring` — рабочая ветка, в ней ведётся вся разработка.
- CI запускается на каждый Pull Request в `main`.

## Bash-скрипты

### check_api.sh

Проверяет, что API отвечает кодом `200`.

```bash
./check_api.sh https://httpbin.org/status/200
# API доступен                         (код возврата 0)

./check_api.sh https://httpbin.org/status/503
# API недоступен, код ответа: 503      (код возврата 1)
```

- URL передаётся единственным аргументом и проверяется регулярным выражением `^https?://`.
- Если соединение не установлено, curl возвращает код `000`, и скрипт выводит «API недоступен, код ответа: 000».
- При неверных аргументах скрипт выводит справку и возвращает `1`.

### analyze_logs.sh

Генерирует `access.log` (по умолчанию 300 строк) и анализирует его.

```bash
./analyze_logs.sh               # сгенерировать access.log и проанализировать
./analyze_logs.sh -n 1000       # сгенерировать 1000 строк
./analyze_logs.sh -s -f my.log  # только анализ существующего файла
./analyze_logs.sh -h            # справка
```

Что выводит скрипт:

| Метрика | Как считается |
|---|---|
| Общее число запросов | `grep -cE` по регулярному выражению всей строки лога |
| Топ-3 IP | `grep -oE` с regexp IPv4 → `sort` → `uniq -c` → `sort -rn` → `head -3` → `awk` |
| Число 4xx и 5xx | `awk` с проверкой последнего поля по шаблонам `/^4[0-9][0-9]$/` и `/^5[0-9][0-9]$/` |
| Распределение по методам | `sed -E` вырезает метод из запроса, затем `sort` → `uniq -c` |

Регулярное выражение для IP проверяет, что каждый октет лежит в диапазоне 0–255:
`(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])` × 4 через `\.`.

## Docker Compose

| Сервис | Образ | Порт | Назначение |
|---|---|---|---|
| `api` | `hashicorp/http-echo` | 8080 (только внутри сети) | отвечает текстом «Monitoring Service Active» |
| `proxy` | `nginx:alpine` | 80 → хост | reverse proxy на `api:8080` |

Оба контейнера подключены к bridge-сети `monitoring-net`. Nginx находит API по имени сервиса `api` через встроенный DNS Docker.

```bash
docker compose up -d
curl http://localhost:80
# Monitoring Service Active

docker compose ps
docker compose logs proxy
docker compose down
```

## CI/CD

Пайплайн [.github/workflows/ci.yml](.github/workflows/ci.yml) запускается на Pull Request в `main`:

1. `bash -n check_api.sh` и `bash -n analyze_logs.sh`: проверка синтаксиса.
2. `./check_api.sh https://httpbin.org/status/200`: ожидается код возврата 0.
3. `./check_api.sh https://httpbin.org/status/404`: ожидается код возврата 1 (проверка ветки ошибки).
4. Запуск `analyze_logs.sh` и проверка, что в логе не меньше 300 строк.
5. Подъём compose-стека и проверка `curl http://localhost:80`.

## Анализ трафика

Подробности в отчёте [docs/traffic-report.md](docs/traffic-report.md), дамп лежит в [docs/capture.pcapng](docs/capture.pcapng).

## Деплой на удалённый сервер по SSH/SCP

Ниже используется пример: сервер `203.0.113.10`, пользователь `deploy`, каталог `/opt/infra-monitoring-project`.

### 1. Генерация SSH-ключа

```bash
ssh-keygen -t ed25519 -C "deploy@infra-monitoring" -f ~/.ssh/id_ed25519_deploy
```

- `-t ed25519` — современный быстрый алгоритм (RSA, если нужен, — не меньше `-b 4096`).
- Приватный ключ стоит защитить парольной фразой. Он остаётся только на локальной машине, права на файл: `chmod 600`.

### 2. Копирование публичного ключа на сервер

```bash
ssh-copy-id -i ~/.ssh/id_ed25519_deploy.pub deploy@203.0.113.10

# если ssh-copy-id нет (например, Windows):
cat ~/.ssh/id_ed25519_deploy.pub | ssh deploy@203.0.113.10 \
  "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"

# проверка входа по ключу
ssh -i ~/.ssh/id_ed25519_deploy deploy@203.0.113.10 "hostname && whoami"
```

После проверки на сервере рекомендуется отключить вход по паролю в `/etc/ssh/sshd_config`:
`PasswordAuthentication no`, `PermitRootLogin no`, затем `sudo systemctl reload sshd`.

Чтобы не указывать ключ каждый раз, добавьте запись в `~/.ssh/config`:

```
Host monitoring-server
    HostName 203.0.113.10
    User deploy
    IdentityFile ~/.ssh/id_ed25519_deploy
```

### 3. Передача проекта

**Вариант A: архив + scp**

```bash
# упаковать проект без .git и мусора
tar --exclude='.git' --exclude='*.log' -czf infra-monitoring.tar.gz .

# скопировать на сервер
scp infra-monitoring.tar.gz monitoring-server:/tmp/

# распаковать и запустить
ssh monitoring-server "mkdir -p /opt/infra-monitoring-project \
  && tar -xzf /tmp/infra-monitoring.tar.gz -C /opt/infra-monitoring-project \
  && rm /tmp/infra-monitoring.tar.gz \
  && cd /opt/infra-monitoring-project \
  && docker compose up -d"
```

**Вариант B: tar через ssh без промежуточного файла**

```bash
tar --exclude='.git' --exclude='*.log' -czf - . \
  | ssh monitoring-server "mkdir -p /opt/infra-monitoring-project && tar -xzf - -C /opt/infra-monitoring-project"
```

**Вариант C: rsync (только изменённые файлы)**

```bash
rsync -avz --delete --exclude='.git' --exclude='*.log' \
  ./ monitoring-server:/opt/infra-monitoring-project/
```

### 4. Проверка после деплоя

```bash
ssh monitoring-server "cd /opt/infra-monitoring-project && docker compose ps && curl -s http://localhost"
./check_api.sh http://203.0.113.10/
```

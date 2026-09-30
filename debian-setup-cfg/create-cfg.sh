#!/usr/bin/env bash
#
# generate-preseed.sh — генератор preseed.cfg для автоматической установки Debian
# и раздача его через простой HTTP-сервер на Python.
#

set -euo pipefail

# ---------- Настройки ----------
TEMPLATE_FILE="preseed.template.cfg"
OUTPUT_FILE="preseed.cfg"
HTTP_PORT="8000"
PYTHON_BIN=""

# ---------- Цветной вывод ----------
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'
NC=$'\033[0m' # No Color

info()  { echo "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo "${GREEN}[OK]${NC}    $*"; }
warn()  { echo "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo "${RED}[ERROR]${NC} $*" >&2; }

# ---------- Проверка зависимостей ----------
check_dependencies() {
    if command -v python3 >/dev/null 2>&1; then
        PYTHON_BIN="python3"
    elif command -v python >/dev/null 2>&1; then
        PYTHON_BIN="python"
    else
        err "Python не найден. Установите python3 (например: sudo apt install python3)."
        exit 1
    fi
    info "Используется интерпретатор: ${PYTHON_BIN}"

    if command -v openssl >/dev/null 2>&1; then
        HAS_OPENSSL=1
    else
        HAS_OPENSSL=0
        warn "openssl не найден — пароли будут сохранены в открытом виде в preseed.cfg."
    fi
}

# ---------- Функция запроса пароля с подтверждением ----------
# $1 - приглашение
# Возвращает пароль в глобальную переменную REPLY_PASSWORD
ask_password() {
    local prompt="$1"
    local pass1 pass2

    while true; do
        read -r -s -p "${prompt}: " pass1
        echo
        if [[ -z "$pass1" ]]; then
            warn "Пароль не может быть пустым. Попробуйте снова."
            continue
        fi

        read -r -s -p "Повторите пароль: " pass2
        echo
        if [[ "$pass1" != "$pass2" ]]; then
            warn "Пароли не совпадают. Попробуйте снова."
            continue
        fi

        REPLY_PASSWORD="$pass1"
        return 0
    done
}

# ---------- Функция генерации хэша пароля (SHA-512 crypt) ----------
# $1 - пароль
# Выводит строку вида $6$... если есть openssl, иначе пустую строку
hash_password() {
    local pass="$1"
    if [[ "$HAS_OPENSSL" -eq 1 ]]; then
        openssl passwd -6 "$pass"
    else
        echo ""
    fi
}

# ---------- Функция запроса имени пользователя ----------
ask_username() {
    local username
    while true; do
        read -r -p "Введите имя пользователя (например, debian): " username
        if [[ -z "$username" ]]; then
            warn "Имя пользователя не может быть пустым."
            continue
        fi
        # Проверка на корректность (буквы, цифры, дефис, подчёркивание; начинается с буквы)
        if [[ ! "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
            warn "Некорректное имя. Разрешены строчные буквы, цифры, '_' и '-', начинается с буквы или '_'."
            continue
        fi
        REPLY_USERNAME="$username"
        return 0
    done
}

# ---------- Основной сценарий ----------
main() {
    echo "=========================================="
    echo "  Генератор preseed.cfg для Debian"
    echo "=========================================="
    echo

    check_dependencies

    # Проверяем наличие шаблона
    if [[ ! -f "$TEMPLATE_FILE" ]]; then
        err "Файл шаблона '${TEMPLATE_FILE}' не найден в текущем каталоге."
        err "Создайте его из вашего исходного файла перед запуском скрипта."
        exit 1
    fi

    # --- Ввод данных ---
    info "Шаг 1/2: учётные данные root"
    ask_password "Введите пароль для root"
    ROOT_PASSWORD="$REPLY_PASSWORD"
    echo

    info "Шаг 2/2: учётные данные пользователя"
    ask_username
    USERNAME="$REPLY_USERNAME"
    ask_password "Введите пароль для пользователя '${USERNAME}'"
    USER_PASSWORD="$REPLY_PASSWORD"
    echo

    # --- Генерация хэшей (или использование plaintext) ---
    ROOT_HASH="$(hash_password "$ROOT_PASSWORD")"
    USER_HASH="$(hash_password "$USER_PASSWORD")"

    if [[ -n "$ROOT_HASH" ]]; then
        ROOT_LINE="d-i passwd/root-password-crypted password ${ROOT_HASH}"
        USER_LINE="d-i passwd/user-password-crypted password ${USER_HASH}"
        info "Пароли захэшированы (SHA-512 crypt)."
    else
        ROOT_LINE="d-i passwd/root-password password ${ROOT_PASSWORD}
d-i passwd/root-password-again password ${ROOT_PASSWORD}"
        USER_LINE="d-i passwd/user-password password ${USER_PASSWORD}
d-i passwd/user-password-again password ${USER_PASSWORD}"
        warn "Пароли записаны в открытом виде."
    fi

    # --- Генерация preseed.cfg из шаблона ---
    info "Генерация ${OUTPUT_FILE}..."

    # Читаем шаблон и делаем подстановки через awk (безопаснее, чем sed с паролями)
    awk -v username="$USERNAME" \
        -v root_line="$ROOT_LINE" \
        -v user_line="$USER_LINE" \
        '
        # Подставляем имя пользователя
        /^d-i passwd\/username string/ {
            print "d-i passwd/username string " username
            next
        }
        # Удаляем старые строки с паролями root и вставляем новые
        /^d-i passwd\/root-password / {
            if (!root_inserted) {
                print root_line
                root_inserted = 1
            }
            next
        }
        /^d-i passwd\/root-password-again / { next }
        # Удаляем старые строки с паролями пользователя и вставляем новые
        /^d-i passwd\/user-password / {
            if (!user_inserted) {
                print user_line
                user_inserted = 1
            }
            next
        }
        /^d-i passwd\/user-password-again / { next }
        # Всё остальное печатаем как есть
        { print }
        ' "$TEMPLATE_FILE" > "$OUTPUT_FILE"

    chmod 600 "$OUTPUT_FILE"
    ok "Файл ${OUTPUT_FILE} успешно создан."
    echo

    # --- Определяем IP для подсказки ---
    LOCAL_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [[ -z "$LOCAL_IP" ]] && LOCAL_IP="<IP_ЭТОЙ_МАШИНЫ>"

    echo "=========================================="
    echo "  Готово! Учётные данные:"
    echo "=========================================="
    echo "  root пароль      : ********"
    echo "  пользователь     : ${USERNAME}"
    echo "  пароль пользователя: ********"
    echo "=========================================="
    echo
    echo "Для установки Debian VM в строке загрузки ядра укажите:"
    echo
    echo "  auto=true priority=critical url=http://${LOCAL_IP}:${HTTP_PORT}/preseed.cfg"
    echo
    echo "Нажмите Ctrl+C для остановки HTTP-сервера."
    echo "=========================================="
    echo

    # --- Запуск HTTP-сервера ---
    info "Запуск HTTP-сервера на 0.0.0.0:${HTTP_PORT}..."
    info "Файл доступен по адресу: http://${LOCAL_IP}:${HTTP_PORT}/${OUTPUT_FILE}"
    echo

    # python3 -m http.server <port> --bind 0.0.0.0
    exec "$PYTHON_BIN" -m http.server "$HTTP_PORT" --bind 0.0.0.0
}

main "$@"
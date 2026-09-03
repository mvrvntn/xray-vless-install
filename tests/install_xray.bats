#!/usr/bin/env bats

# Базовый тестовый набор для install_xray.sh
# Поскольку скрипт в основном интерактивный, мы тестируем
# базовое выполнение, синтаксис и флаги.

setup() {
    if [ -n "$BATS_TEST_DIRNAME" ]; then
        export SCRIPT_PATH="${BATS_TEST_DIRNAME}/../install_xray.sh"
    else
        export SCRIPT_PATH="./install_xray.sh"
    fi
}

@test "Скрипт существует" {
    [ -f "$SCRIPT_PATH" ]
}

@test "Запуск с флагом --help должен вернуть usage" {
    run bash "$SCRIPT_PATH" --help
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Использование:" ]]
}

@test "Запуск с флагом -h должен вернуть usage" {
    run bash "$SCRIPT_PATH" -h
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Использование:" ]]
}

@test "Запуск с флагом --version должен вернуть версию" {
    run bash "$SCRIPT_PATH" --version
    [ "$status" -eq 0 ]
    [[ "$output" =~ "version" ]]
}

@test "Скрипт проходит shellcheck без синтаксических ошибок" {
    if ! command -v shellcheck &> /dev/null; then
        skip "shellcheck не установлен"
    fi
    run shellcheck -s bash "$SCRIPT_PATH"
    [ "$status" -eq 0 ]
}

@test "Синтаксическая проверка bash -n проходит без ошибок" {
    run bash -n "$SCRIPT_PATH"
    [ "$status" -eq 0 ]
}

@test "Скрипт содержит строго LF окончания строк (без CRLF)" {
    run grep -U $'\r' "$SCRIPT_PATH"
    [ "$status" -ne 0 ]
}

@test "Скрипт содержит конфигурацию VLESS gRPC на порту 8443" {
    run grep "8443" "$SCRIPT_PATH"
    [ "$status" -eq 0 ]
}

@test "Запуск с неизвестным флагом возвращает ненулевой статус и ошибку" {
    run bash "$SCRIPT_PATH" --unknown-flag-test
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Неизвестная опция" ]]
}

@test "Запуск --headless без параметров возвращает код 1" {
    run bash "$SCRIPT_PATH" --headless
    [ "$status" -eq 1 ]
}

@test "Справка --help содержит опцию --optimize" {
    run bash "$SCRIPT_PATH" --help
    [ "$status" -eq 0 ]
    [[ "$output" =~ "--optimize" ]]
}

@test "Справка --help содержит опцию --renew-cert" {
    run bash "$SCRIPT_PATH" --help
    [ "$status" -eq 0 ]
    [[ "$output" =~ "--renew-cert" ]]
}

@test "VLESS ссылки содержат encryption=none и service_name для ZeroBlock" {
    run grep "service_name=vless-grpc" "$SCRIPT_PATH"
    [ "$status" -eq 0 ]
    run grep "encryption=none" "$SCRIPT_PATH"
    [ "$status" -eq 0 ]
}

@test "Скрипт содержит проверку версии Bash 4+ и функцию log_warn" {
    run grep "BASH_VERSINFO" "$SCRIPT_PATH"
    [ "$status" -eq 0 ]
    run grep "log_warn()" "$SCRIPT_PATH"
    [ "$status" -eq 0 ]
}

@test "Маршрутизация Xray содержит domainStrategy IPIfNonMatch и блокировку SMB/NetBIOS/SMTP" {
    run grep "IPIfNonMatch" "$SCRIPT_PATH"
    [ "$status" -eq 0 ]
    run grep "25,135,137,138,139,445,465,587" "$SCRIPT_PATH"
    [ "$status" -eq 0 ]
}

@test "Подписка содержит домены Lava и автоопределение User-Agent" {
    run grep "domain:lava.ru" "$SCRIPT_PATH"
    [ "$status" -eq 0 ]
    run grep "sing-box.*in user_agent" "$SCRIPT_PATH"
    [ "$status" -eq 0 ]
}

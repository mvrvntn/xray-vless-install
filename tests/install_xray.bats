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

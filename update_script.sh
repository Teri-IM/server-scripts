#!/bin/sh

# Устанавливаем зависимости (если их нет)
# Используем apk, так как базовый образ Alpine
apk add --no-cache curl jq docker-cli

# Значения по умолчанию (если не переданы через environment)
CONFIG_PATH=${CONFIG_PATH:-"/etc/glueless/proxy-config.json"}
UPDATE_INTERVAL=${UPDATE_INTERVAL:-86400}
CONVERTER_HOST=${CONVERTER_HOST:-"subconverter:25500"}

echo "=== Запуск VPN Updater ==="
echo "Цель: $TARGET_CONTAINER"
echo "Интервал: $UPDATE_INTERVAL сек"

while true; do
    echo "$(date): Начинаем обновление..."

    if [ -z "$SUB_URL" ]; then
        echo "ОШИБКА: Не задана переменная SUB_URL!"
        sleep 60
        continue
    fi

    # 1. Кодируем ссылку для передачи в URL
    ENCODED_URL=$(echo "$SUB_URL" | jq -sRr @uri)

    # 2. Запрашиваем конфиг у локального конвертера
    # target=sing-box - формат для glueless
    # config=... - можно добавить ссылку на внешний конфиг конвертации, если нужно, но здесь используем дефолт
    HTTP_CODE=$(curl -s -o /tmp/temp.json -w "%{http_code}" "http://$CONVERTER_HOST/sub?target=sing-box&url=$ENCODED_URL&insert=false")

    if [ "$HTTP_CODE" -eq 200 ] && [ -s /tmp/temp.json ]; then
        echo "Конфиг получен от subconverter. Применяем патч для TUN..."

        # 3. Превращаем конфиг прокси в конфиг VPN (добавляем Tun Inbound)
        # ВАЖНО: Эти настройки нужны Glueless для захвата трафика
        jq '.inbounds = [{
            "type": "tun",
            "tag": "tun-in",
            "interface_name": "tun0",
            "inet4_address": "172.19.0.1/30",
            "auto_route": true,
            "strict_route": true,
            "stack": "system",
            "sniff": true
        }] | 
        .route.rules[0] |= . + {"inbound": "tun-in", "action": "route", "outbound": "o0"} |
        .route.auto_detect_interface = true' /tmp/temp.json > "$CONFIG_PATH"

        if [ $? -eq 0 ]; then
            echo "Конфиг успешно записан в $CONFIG_PATH"
            
            # 4. Перезапускаем контейнер VPN
            echo "Перезагружаем контейнер $TARGET_CONTAINER..."
            docker restart "$TARGET_CONTAINER"
            echo "Успешно обновлено!"
        else
            echo "ОШИБКА: Сбой при обработке JSON через jq"
        fi
    else
        echo "ОШИБКА: Subconverter вернул код $HTTP_CODE или пустой файл"
    fi

    # Очистка
    rm -f /tmp/temp.json

    echo "Следующее обновление через $UPDATE_INTERVAL секунд..."
    sleep "$UPDATE_INTERVAL"
done

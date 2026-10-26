#!/bin/bash
# Compile et flash le firmware ESPHome sur la Muse Luxe via CP210x UART
# Usage: ./flash.sh [fichier.yaml]

set -e

YAML="${1:-luxe_music_min.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Trouver le device série
DEVICE=$(readlink -f /dev/serial/by-id/*CP210* 2>/dev/null || true)
if [ -z "$DEVICE" ]; then
    for d in /dev/ttyUSB0 /dev/ttyUSB1; do
        [ -e "$d" ] && DEVICE="$d" && break
    done
fi

if [ -z "$DEVICE" ] || [ ! -e "$DEVICE" ]; then
    echo "❌ Aucun CP210x trouvé. Vérifiez la connexion USB."
    exit 1
fi

echo "🎯 Périphérique: $DEVICE"
echo "📄 YAML: $YAML"
echo ""

# ── Méthode 1 : esphome CLI local/natif (idéal) ──
if [ -x "$SCRIPT_DIR/.venv-2026.10/bin/esphome" ]; then
    ESPHOME="$SCRIPT_DIR/.venv-2026.10/bin/esphome"
elif [ -x "$SCRIPT_DIR/.venv/bin/esphome" ]; then
    ESPHOME="$SCRIPT_DIR/.venv/bin/esphome"
elif command -v esphome &> /dev/null; then
    ESPHOME="$(command -v esphome)"
else
    ESPHOME=""
fi

if [ -n "$ESPHOME" ]; then
    echo "✅ esphome CLI trouvé: $ESPHOME"
    echo "🔨 Compilation..."
    "$ESPHOME" compile "$YAML"

    FACTORY_BIN=$(find "$SCRIPT_DIR/.esphome/build" -name "firmware.factory.bin" 2>/dev/null | head -1)
    if [ -z "$FACTORY_BIN" ]; then
        echo "❌ firmware.factory.bin non trouvé après compilation."
        exit 1
    fi

    echo "📦 Firmware factory: $FACTORY_BIN"
    echo "🔥 Flash série à l'offset 0x0..."
    if [ -x "$(dirname "$ESPHOME")/esptool" ]; then
        ESPTOOL="$(dirname "$ESPHOME")/esptool"
    elif command -v esptool.py &> /dev/null; then
        ESPTOOL="$(command -v esptool.py)"
    elif command -v esptool &> /dev/null; then
        ESPTOOL="$(command -v esptool)"
    else
        echo "❌ esptool non trouvé."
        exit 1
    fi

    "$ESPTOOL" --chip esp32 --port "$DEVICE" --baud 460800 \
        write_flash -z 0x0 "$FACTORY_BIN"
    exit 0
fi

# ── Méthode 2 : Docker Desktop (compile) + esptool (flash) ──
if command -v docker &> /dev/null; then
    echo "🐳 Docker détecté — compilation en conteneur..."
    docker run --rm \
        -v "$SCRIPT_DIR":/config \
        esphome/esphome compile "/config/$YAML"

    # Trouver l'image complète factory, flashable à 0x0.
    BIN=$(find "$SCRIPT_DIR/.esphome/build" -name "firmware.factory.bin" 2>/dev/null | head -1)

    if [ -z "$BIN" ]; then
        echo "❌ Firmware .bin non trouvé après compilation."
        echo "   Cherchez dans $SCRIPT_DIR/.esphome/build/"
        exit 1
    fi

    echo "📦 Firmware: $BIN"
    echo ""

    # Flash avec esptool
    if command -v esptool.py &> /dev/null; then
        echo "🔥 Flash via esptool.py..."
        esptool.py --chip esp32 --port "$DEVICE" --baud 460800 \
            write_flash -z 0x0 "$BIN"
    elif command -v esptool &> /dev/null; then
        echo "🔥 Flash via esptool..."
        esptool --chip esp32 --port "$DEVICE" --baud 460800 \
            write_flash -z 0x0 "$BIN"
    else
        echo "⚠️  esptool.py non trouvé. Installez-le :"
        echo "   pip install esptool"
        echo ""
        echo "Puis flash manuellement :"
        echo "   esptool.py --chip esp32 --port $DEVICE --baud 460800 write_flash -z 0x0 $BIN"
        exit 1
    fi

    echo ""
    echo "✅ Flash terminé !"
    exit 0
fi

echo "❌ Ni esphome ni docker trouvé. Installez esphome:"
echo "   pip install esphome"
exit 1

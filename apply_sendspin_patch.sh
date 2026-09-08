#!/bin/bash
# Réapplique le correctif local après un nettoyage du dossier .esphome/build.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPONENT_DIR="$SCRIPT_DIR/.esphome/build/muse-luxe-music/managed_components/sendspin__sendspin-cpp"
SOURCE="$COMPONENT_DIR/src/esp/ws_server.cpp"
PATCH_FILE="$SCRIPT_DIR/patches/sendspin-httpd-stack.patch"

if [ ! -f "$SOURCE" ]; then
    echo "Source Sendspin absente. Lancez d'abord une compilation ESPHome."
    exit 1
fi

if grep -q 'config.stack_size = 16384;' "$SOURCE"; then
    echo "Correctif pile HTTPD Sendspin déjà appliqué."
    exit 0
fi

patch -d "$COMPONENT_DIR" -p1 < "$PATCH_FILE"
echo "Correctif pile HTTPD Sendspin appliqué (16 Kio)."

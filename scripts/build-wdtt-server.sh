#!/usr/bin/env bash
# Получает vk-turn-proxy server-бинарь (cacggghp/vk-turn-proxy):
# по умолчанию — скачивает готовый release, или собирает локально с --build.
# Кладёт в .local/vk-turn-proxy, печатает sha256 и размер.
#
# Использование:
#   bash scripts/build-wdtt-server.sh                  # release v1.8.3
#   bash scripts/build-wdtt-server.sh v1.8.3
#   bash scripts/build-wdtt-server.sh --build          # собрать main из исходников
#   bash scripts/build-wdtt-server.sh --build v1.8.3   # собрать конкретный tag

set -euo pipefail

REPO="cacggghp/vk-turn-proxy"
BUILD_FROM_SOURCE=0
VERSION="v1.8.3"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build) BUILD_FROM_SOURCE=1; shift ;;
    v*)      VERSION="$1"; shift ;;
    *)       echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

OUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/.local"
BIN_PATH="${OUT_DIR}/vk-turn-proxy"
mkdir -p "${OUT_DIR}"

if [[ "${BUILD_FROM_SOURCE}" == "1" ]]; then
  if ! command -v go >/dev/null 2>&1; then
    echo "ERROR: Go не установлен. brew install go (macOS) / apt-get install golang (Linux)" >&2
    exit 1
  fi
  WORK_DIR="$(mktemp -d -t vkturn-build.XXXXXX)"
  trap 'rm -rf "${WORK_DIR}"' EXIT

  echo "[*] Клонирую github.com/${REPO} @ ${VERSION}..."
  if ! git clone --depth 1 --branch "${VERSION}" "https://github.com/${REPO}" "${WORK_DIR}/src" 2>/dev/null; then
    echo "[!] Tag ${VERSION} не найден, клонирую main"
    git clone --depth 1 "https://github.com/${REPO}" "${WORK_DIR}/src"
  fi

  echo "[*] go build -o ${BIN_PATH}..."
  (
    cd "${WORK_DIR}/src"
    GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -ldflags='-s -w' -o "${BIN_PATH}" ./server
  )
else
  URL="https://github.com/${REPO}/releases/download/${VERSION}/server-linux-amd64"
  echo "[*] Скачиваю ${URL}"
  curl -fL --progress-bar -o "${BIN_PATH}" "${URL}"
  chmod +x "${BIN_PATH}"
fi

if [[ ! -x "${BIN_PATH}" ]]; then
  echo "ERROR: бинарь не появился: ${BIN_PATH}" >&2
  exit 1
fi

SIZE="$(wc -c < "${BIN_PATH}" | tr -d ' ')"
SHA256="$(shasum -a 256 "${BIN_PATH}" | awk '{print $1}')"

cat <<EOF

[OK] Готово.
  Path:    ${BIN_PATH}
  Size:    ${SIZE} bytes
  SHA256:  ${SHA256}
  Version: ${VERSION}$([ "${BUILD_FROM_SOURCE}" = "1" ] && echo " (built from source)" || echo " (release)")

Сверь флаги (должны быть -listen и -connect):
  ${BIN_PATH} -h

Дальше:
  make plan && make apply
EOF

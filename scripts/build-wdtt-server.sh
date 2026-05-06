#!/usr/bin/env bash
# Сборка wdtt-server из исходников amurcanov/proxy-turn-vk-android.
# Кладёт бинарь в .local/wdtt-server, печатает sha256 и размер.
# Запуск: bash scripts/build-wdtt-server.sh [version]   # default: v1.1.0

set -euo pipefail

VERSION="${1:-v1.1.0}"
REPO_URL="https://github.com/amurcanov/proxy-turn-vk-android"
OUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/.local"
BIN_PATH="${OUT_DIR}/wdtt-server"
WORK_DIR="$(mktemp -d -t wdtt-build.XXXXXX)"
trap 'rm -rf "${WORK_DIR}"' EXIT

if ! command -v go >/dev/null 2>&1; then
  echo "ERROR: Go не установлен. brew install go (macOS) или apt-get install golang (Linux)" >&2
  exit 1
fi

echo "[*] Клонирую ${REPO_URL} @ ${VERSION}..."
git clone --depth 1 --branch "${VERSION}" "${REPO_URL}" "${WORK_DIR}/src" || {
  echo "[!] Tag ${VERSION} не найден, клонирую main"
  git clone --depth 1 "${REPO_URL}" "${WORK_DIR}/src"
}

# Сервер живёт в подкаталоге server/ (по структуре wdtt-analysis.md).
# Если структура изменилась — найдём server.go.
SERVER_DIR="$(find "${WORK_DIR}/src" -type d -name server -print -quit)"
if [[ -z "${SERVER_DIR}" || ! -f "${SERVER_DIR}/server.go" ]]; then
  SERVER_DIR="$(dirname "$(find "${WORK_DIR}/src" -type f -name 'server.go' -print -quit || true)")"
fi
if [[ -z "${SERVER_DIR}" ]]; then
  echo "ERROR: server.go не найден в репо. Проверь структуру upstream'а:" >&2
  find "${WORK_DIR}/src" -maxdepth 2 -type d | sed 's/^/  /' >&2
  exit 1
fi

echo "[*] Собираю в ${SERVER_DIR}..."
mkdir -p "${OUT_DIR}"
(
  cd "${SERVER_DIR}"
  GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build \
    -ldflags='-s -w' \
    -o "${BIN_PATH}" \
    ./...
)

if [[ ! -x "${BIN_PATH}" ]]; then
  echo "ERROR: бинарь не создался: ${BIN_PATH}" >&2
  exit 1
fi

SIZE="$(wc -c < "${BIN_PATH}" | tr -d ' ')"
SHA256="$(shasum -a 256 "${BIN_PATH}" | awk '{print $1}')"

cat <<EOF

[OK] Готово.
  Path:    ${BIN_PATH}
  Size:    ${SIZE} bytes
  SHA256:  ${SHA256}
  Version: ${VERSION}

Можно прогнать:
  ${BIN_PATH} --help    # сверить флаги с wdtt_server_args в роли

Дальше:
  make plan   # увидишь diff включая раскатку wdtt-server на vpn1
  make apply  # применить
EOF

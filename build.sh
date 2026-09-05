#!/usr/bin/env bash
# Construit Notekeeper.app dans ./build/ (SwiftPM + toolchain Xcode), signe ad hoc et vérifie.
#
#   ./build.sh              construit et vérifie
#   ./build.sh --install    construit puis installe dans /Applications (remplace l'ancienne version)
#   ./build.sh --debug      build debug (plus rapide) pour les tests
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Notekeeper"
PRODUCT="Notekeeper"
BUNDLE_ID="fr.charlesneveu.notekeeper"
BUILD_DIR="./build"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"
MACOS_DIR="${APP_DIR}/Contents/MacOS"
RES_DIR="${APP_DIR}/Contents/Resources"
CONFIG="release"
DO_INSTALL=0
for a in "$@"; do
  case "$a" in
    --install) DO_INSTALL=1 ;;
    --debug) CONFIG="debug" ;;
  esac
done

fail() { echo ""; echo "❌ $1" >&2; exit 1; }

if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  SWIFT_BIN="${DEVELOPER_DIR}/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
else
  fail "Xcode introuvable dans /Applications."
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
echo "==> ${APP_NAME} ${VERSION} (${CONFIG})"

echo "==> Compilation Swift…"
"${SWIFT_BIN}" build -c "${CONFIG}" --arch arm64 --product "${PRODUCT}"
"${SWIFT_BIN}" build -c "${CONFIG}" --arch arm64 --product notekeeper-mcp
BIN_DIR="$("${SWIFT_BIN}" build -c "${CONFIG}" --arch arm64 --product "${PRODUCT}" --show-bin-path)"
BIN_PATH="${BIN_DIR}/${PRODUCT}"
[[ -x "${BIN_PATH}" ]] || fail "Binaire introuvable : ${BIN_PATH}"

echo "==> Assemblage de ${APP_NAME}.app…"
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RES_DIR}"
cp "${BIN_PATH}" "${MACOS_DIR}/${PRODUCT}"
cp "Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"
# Serveur MCP embarqué dans le bundle : l'app affiche son chemin dans les Réglages.
cp "${BIN_DIR}/notekeeper-mcp" "${MACOS_DIR}/notekeeper-mcp"
# Bundles de ressources des dépendances (FluidAudio embarque des ressources).
for b in "${BIN_DIR}"/*.bundle; do [[ -d "$b" ]] && cp -R "$b" "${RES_DIR}/"; done
# Bundle de ressources SwiftPM (Assets) s'il existe.
if compgen -G "${BIN_DIR}/${PRODUCT}_${PRODUCT}.bundle" > /dev/null; then
  cp -R "${BIN_DIR}/${PRODUCT}_${PRODUCT}.bundle" "${RES_DIR}/"
fi
if [[ ! -f "Resources/AppIcon.icns" ]]; then
  echo "==> Génération de l'icône…"
  "${SWIFT_BIN}" make-icon.swift Resources/AppIcon.icns
fi
cp "Resources/AppIcon.icns" "${RES_DIR}/AppIcon.icns"
echo "fr" > "${RES_DIR}/.lproj_marker" && rm -f "${RES_DIR}/.lproj_marker"
mkdir -p "${RES_DIR}/fr.lproj"
echo 'APPL????' > "${APP_DIR}/Contents/PkgInfo"

# Identité auto-signée stable si elle existe (./setup-signing.sh) : macOS garde alors les autorisations
# (localisation) d'une version à l'autre. Sinon signature ad hoc.
SIGNING_IDENTITY="Notekeeper Developer"
if security find-identity -v -p codesigning | grep -q "${SIGNING_IDENTITY}"; then
  echo "==> Signature avec '${SIGNING_IDENTITY}'…"
  codesign --force --sign "${SIGNING_IDENTITY}" --identifier "${BUNDLE_ID}" --timestamp=none --entitlements Notekeeper.entitlements "${APP_DIR}"
else
  echo "==> Signature ad hoc (lance ./setup-signing.sh pour une identité stable)…"
  codesign --force --sign - --identifier "${BUNDLE_ID}" --entitlements Notekeeper.entitlements "${APP_DIR}"
fi
codesign --verify --strict --verbose=1 "${APP_DIR}" 2>&1 | sed 's/^/    /' || fail "Signature invalide."

echo "==> OK : ${APP_DIR}"

if [[ "${DO_INSTALL}" == "1" ]]; then
  echo "==> Installation dans /Applications…"
  osascript -e "tell application id \"${BUNDLE_ID}\" to quit" 2>/dev/null || true
  sleep 1
  rm -rf "/Applications/${APP_NAME}.app"
  cp -R "${APP_DIR}" "/Applications/${APP_NAME}.app"
  echo "==> Installé : /Applications/${APP_NAME}.app"
fi

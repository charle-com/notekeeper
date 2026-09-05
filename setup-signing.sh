#!/usr/bin/env bash
# Crée une identité de code signing auto-signée persistante pour Notekeeper.
# À lancer une seule fois. Rend la signature stable → TCC (Localisation)
# garde l'autorisation entre les rebuilds.
set -euo pipefail

cd "$(dirname "$0")"

IDENTITY="Notekeeper Developer"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  echo "✅ Identité '$IDENTITY' déjà présente dans le keychain."
  exit 0
fi

echo "==> Génération d'une identité auto-signée '$IDENTITY'…"

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

cat > "$TMP/openssl.cnf" <<'EOF'
[req]
distinguished_name = dn
req_extensions = v3_req
prompt = no

[dn]
CN = Notekeeper Developer
O  = Notekeeper
C  = FR

[v3_req]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -config "$TMP/openssl.cnf" -extensions v3_req 2>/dev/null

openssl pkcs12 -export -legacy \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/cert.p12" -passout pass:notekeeper \
  -name "$IDENTITY" 2>/dev/null

echo "==> Import dans le trousseau (login.keychain)…"
security import "$TMP/cert.p12" \
  -k "$KEYCHAIN" -P notekeeper \
  -T /usr/bin/codesign -T /usr/bin/security 2>&1 | grep -v "^security:" || true

echo ""
echo "==> Trust du certificat pour codeSigning…"
security find-certificate -c "$IDENTITY" -p > "$TMP/vp.pem"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/vp.pem" 2>/dev/null || true

echo ""
echo "==> Autoriser codesign à utiliser la clé sans popup…"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" 2>/dev/null || \
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s "$KEYCHAIN" 2>/dev/null || true

echo ""
echo "✅ Identité '$IDENTITY' prête."
echo "   Les builds suivants utiliseront cette identité."
echo "   L'autorisation de localisation persistera entre les rebuilds."

#!/usr/bin/env bash
# Test de fumée du serveur MCP : base temporaire seedée, puis initialize, tools/list,
# tools/call search_meetings et tools/call get_transcript via stdin, avec vérifications.
#
#   docs/mcp-smoke.sh                 utilise .build-llm/debug/notekeeper-mcp (ou .build/debug)
#   NOTEKEEPER_MCP=/chemin/binaire docs/mcp-smoke.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${NOTEKEEPER_MCP:-}"
if [ -z "$BIN" ]; then
  for candidate in "$ROOT/.build-llm/debug/notekeeper-mcp" "$ROOT/.build/debug/notekeeper-mcp"; do
    [ -x "$candidate" ] && BIN="$candidate" && break
  done
fi
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
  echo "Binaire notekeeper-mcp introuvable : swift build --scratch-path .build-llm --product notekeeper-mcp" >&2
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/notekeeper-smoke.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
DB="$WORK/notekeeper.sqlite"

fail() { echo "ÉCHEC : $*" >&2; exit 1; }
pass() { echo "ok   : $*"; }

# 1. Seed
SEED="$("$BIN" --seed-demo "$DB")"
echo "$SEED"
MEETING_ID="$(echo "$SEED" | head -n 1 | awk '{print $1}')"
[ -n "$MEETING_ID" ] || fail "seed : aucun identifiant de réunion"
[ "$(echo "$SEED" | wc -l | tr -d ' ')" -eq 2 ] || fail "seed : 2 réunions attendues"
pass "seed : 2 réunions, première = $MEETING_ID"

# 2. Session MCP complète sur stdin (une ligne JSON par message), stderr ignoré.
OUT="$WORK/out.jsonl"
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"ping"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"search_meetings","arguments":{"query":"petit porteur","limit":5}}}' \
  "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"get_transcript\",\"arguments\":{\"id\":\"$MEETING_ID\",\"from_seconds\":0,\"to_seconds\":60}}}" \
  '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"list_meetings","arguments":{"limit":10}}}' \
  "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"rename_speaker\",\"arguments\":{\"meeting_id\":\"$MEETING_ID\",\"speaker_id\":\"Locuteur 2\",\"name\":\"Priya\"}}}" \
  "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tools/call\",\"params\":{\"name\":\"add_note\",\"arguments\":{\"id\":\"$MEETING_ID\",\"text\":\"Relancer le nom de domaine.\"}}}" \
  "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"name\":\"get_meeting\",\"arguments\":{\"id\":\"$MEETING_ID\"}}}" \
  '{"jsonrpc":"2.0","id":10,"method":"nope/unknown"}' \
  '{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"get_meeting","arguments":{"id":"pas-un-uuid"}}}' \
  '{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"get_meeting","arguments":{"id":"00000000-0000-0000-0000-000000000000"}}}' \
  'ceci n est pas du json' \
  | "$BIN" --db "$DB" 2>"$WORK/stderr.log" > "$OUT"

line() { grep -E "\"id\":$1[,}]" "$OUT" | head -n 1; }

# Une réponse par requête, aucune pour la notification, une seule ligne chacune.
[ "$(wc -l < "$OUT" | tr -d ' ')" -eq 13 ] || fail "13 lignes de réponse attendues, $(wc -l < "$OUT" | tr -d ' ') reçues"
pass "13 réponses, une ligne chacune, rien pour la notification"

# initialize
R="$(line 1)"
echo "$R" | grep -q '"protocolVersion":"2025-06-18"' || fail "initialize : protocolVersion non renvoyé"
echo "$R" | grep -q '"name":"notekeeper"' || fail "initialize : serverInfo.name"
echo "$R" | grep -q '"tools":{}' || fail "initialize : capabilities.tools"
pass "initialize"

# ping
line 2 | grep -q '"result":{}' || fail "ping"
pass "ping"

# tools/list
R="$(line 3)"
for t in list_meetings get_meeting get_transcript search_meetings add_note rename_speaker; do
  echo "$R" | grep -q "\"name\":\"$t\"" || fail "tools/list : $t absent"
done
echo "$R" | grep -q '"inputSchema"' || fail "tools/list : inputSchema absent"
pass "tools/list : 6 outils"

# search_meetings
R="$(line 4)"
echo "$R" | grep -q '"type":"text"' || fail "search_meetings : content.text absent"
echo "$R" | grep -qi 'porteur' || fail "search_meetings : extrait attendu"
echo "$R" | grep -q 'Point transfert entrepôt' || fail "search_meetings : titre de la réunion attendu"
echo "$R" | grep -q 'meeting_id: ' || fail "search_meetings : meeting_id attendu"
echo "$R" | grep -q '"isError":false' || fail "search_meetings : isError"
pass "search_meetings « petit porteur »"

# get_transcript
R="$(line 5)"
echo "$R" | grep -q 'Kick-off refonte site Atelier Morin' || fail "get_transcript : titre"
echo "$R" | grep -q '\[0:02\] Moi : Bonjour à tous' || fail "get_transcript : premier tour horodaté"
echo "$R" | grep -q 'Locuteur 2 : Oui, je t' || fail "get_transcript : locuteur 2"
echo "$R" | grep -q 'Merci Priya, merci Paul' && fail "get_transcript : la fenêtre 0-60 s ne doit pas contenir la fin"
pass "get_transcript 0-60 s"

# list_meetings
R="$(line 6)"
echo "$R" | grep -q '2 réunion(s)' || fail "list_meetings : 2 attendues"
echo "$R" | grep -q "id: $MEETING_ID" || fail "list_meetings : id"
pass "list_meetings"

# rename_speaker par étiquette, puis vérification dans get_meeting
line 7 | grep -q 'Priya' || fail "rename_speaker"
line 8 | grep -q 'Note ajoutée' || fail "add_note"
R="$(line 9)"
echo "$R" | grep -q 'Priya (label : Locuteur 2' || fail "get_meeting : renommage non répercuté"
echo "$R" | grep -q 'Relancer le nom de domaine' || fail "get_meeting : note absente"
echo "$R" | grep -q 'Invités (calendrier) : Priya Sharma, Paul Lemaire' || fail "get_meeting : invités"
pass "rename_speaker + add_note + get_meeting"

# Erreurs propres
line 10 | grep -q '"code":-32601' || fail "méthode inconnue : -32601 attendu"
line 11 | grep -q '"code":-32602' || fail "id invalide : -32602 attendu"
line 12 | grep -q '"isError":true' || fail "réunion inconnue : isError attendu"
grep -q '"code":-32700' "$OUT" || fail "JSON illisible : -32700 attendu"
pass "erreurs JSON-RPC : -32601, -32602, -32700, isError"

# stdout ne contient que du JSON (les journaux vont sur stderr)
while IFS= read -r l; do
  case "$l" in '{'*) ;; *) fail "stdout contient autre chose que du JSON : $l" ;; esac
done < "$OUT"
grep -q 'prêt' "$WORK/stderr.log" || fail "journal attendu sur stderr"
pass "stdout = JSON seul, journal sur stderr"

echo
echo "Test de fumée MCP : tout passe."

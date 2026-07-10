#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# gen-apple-secret.sh — erzeugt das "Client Secret" JWT für Sign in with Apple.
#
# GoTrue (Supabase Auth) erwartet als GOTRUE_EXTERNAL_APPLE_SECRET NICHT die
# .p8-Datei, sondern ein damit signiertes, kurzlebiges JWT (ES256). Apple lässt
# eine Laufzeit von max. 6 Monaten zu → danach neu erzeugen und in der
# Provider-Config aktualisieren.
#
# Eingaben (Apple Developer Portal):
#   --team-id     Dein 10-stelliger Team-Identifier (oben rechts im Account)
#   --key-id      Die Key-ID des "Sign in with Apple"-Keys (10 Zeichen)
#   --services-id Die Services-ID = client_id (z.B. app.munter.web)
#   --p8          Pfad zur AuthKey_XXXXXXXXXX.p8 Datei
#   [--days N]    Laufzeit in Tagen (Default 180, Apple-Max 180)
#
# Beispiel:
#   ./deploy/gen-apple-secret.sh \
#       --team-id ABCDE12345 --key-id KEY1234567 \
#       --services-id app.munter.web --p8 ~/AuthKey_KEY1234567.p8
#
# Gibt das JWT auf STDOUT aus. Direkt in die Provider-Config übernehmen.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

TEAM_ID="" KEY_ID="" SERVICES_ID="" P8="" DAYS=180
while [ $# -gt 0 ]; do
  case "$1" in
    --team-id)     TEAM_ID="$2"; shift 2 ;;
    --key-id)      KEY_ID="$2"; shift 2 ;;
    --services-id) SERVICES_ID="$2"; shift 2 ;;
    --p8)          P8="$2"; shift 2 ;;
    --days)        DAYS="$2"; shift 2 ;;
    *) echo "Unbekannt: $1" >&2; exit 1 ;;
  esac
done

for v in TEAM_ID KEY_ID SERVICES_ID P8; do
  [ -n "${!v}" ] || { echo "Fehlt: --${v//_/-} (siehe --help im Skriptkopf)" >&2; exit 1; }
done
[ -f "$P8" ] || { echo ".p8 nicht gefunden: $P8" >&2; exit 1; }
command -v openssl >/dev/null || { echo "openssl fehlt" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 fehlt (für iat/exp-Berechnung)" >&2; exit 1; }

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# iat = jetzt, exp = jetzt + DAYS (Apple erlaubt max. 180 Tage = 15777000s)
read -r IAT EXP < <(python3 - "$DAYS" <<'PY'
import sys, time
now = int(time.time()); days = int(sys.argv[1])
print(now, now + days*86400)
PY
)

HEADER="$(printf '{"alg":"ES256","kid":"%s","typ":"JWT"}' "$KEY_ID" | b64url)"
PAYLOAD="$(printf '{"iss":"%s","iat":%s,"exp":%s,"aud":"https://appleid.apple.com","sub":"%s"}' \
           "$TEAM_ID" "$IAT" "$EXP" "$SERVICES_ID" | b64url)"
SIGNING_INPUT="${HEADER}.${PAYLOAD}"

# ES256 über den EC-Key; openssl liefert DER-ecdsa → in raw R||S (64 byte) wandeln
SIG_DER="$(printf '%s' "$SIGNING_INPUT" | openssl dgst -sha256 -sign "$P8" | openssl base64 -A)"
SIG="$(python3 - "$SIG_DER" <<'PY'
import sys, base64
der = base64.b64decode(sys.argv[1])
# minimal DER-ECDSA parser: SEQ 0x30 len, INT 0x02 len R, INT 0x02 len S
i = 0
assert der[i] == 0x30; i += 1
seqlen = der[i]; i += 1
def read_int(buf, i):
    assert buf[i] == 0x02; i += 1
    ln = buf[i]; i += 1
    v = buf[i:i+ln]; i += ln
    # strip leading zero padding, left-pad to 32
    v = v.lstrip(b'\x00')
    v = v.rjust(32, b'\x00')
    return v, i
r, i = read_int(der, i)
s, i = read_int(der, i)
raw = r + s
print(base64.urlsafe_b64encode(raw).rstrip(b'=').decode())
PY
)"

printf '%s.%s\n' "$SIGNING_INPUT" "$SIG"

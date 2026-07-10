#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# multi-supabase — install / init additional self-hosted Supabase stacks
# alongside an EXISTING Koro deployment, WITHOUT restarting Koro.
#
# For every line in projects/projects.conf this script:
#   1. copies the upstream supabase/docker into /opt/multi-supabase-stacks/<stack>
#   2. generates POSTGRES_PASSWORD, JWT_SECRET and signs ANON_KEY /
#      SERVICE_ROLE_KEY from it, writes the stack .env
#   3. renders the per-stack override (unique container names + edge net +
#      Traefik labels for db.<domain> / studio.<domain>)
#   4. brings the stack up with an isolated compose project name (sb-<stack>)
#   5. attaches Kong + Studio to the shared `edge` network so the RUNNING Koro
#      Traefik routes them live (label auto-discovery — no Traefik restart)
#
# Idempotent: existing stacks (detected via their .env) are skipped, secrets
# reused. Safe to re-run after adding a project. It NEVER runs `up`/`restart`
# against Koro's stack, its containers, or Traefik.
#
#   sudo ./deploy/install.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Paths ────────────────────────────────────────────────────────────────────
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACKS_ROOT="/opt/multi-supabase-stacks"        # where each stack's compose dir lives
SUPABASE_SRC="/opt/supabase-src"                # shallow clone of supabase/supabase (shared)
PROJECTS_CONF="$REPO_DIR/projects/projects.conf"
OVERRIDE_TMPL="$REPO_DIR/deploy/supabase.override.tmpl.yml"
CRED_FILE="$REPO_DIR/deploy/.install-credentials"
TS="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo manual)"
LOGFILE="/var/log/multi-supabase-install-${TS}.log"
touch "$LOGFILE" 2>/dev/null || LOGFILE="/tmp/multi-supabase-install-${TS}.log"

# ── Pretty logging ───────────────────────────────────────────────────────────
c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_err=$'\033[31m'; c_info=$'\033[36m'; c_step=$'\033[1;35m'; c_0=$'\033[0m'
step() { printf '\n%s▸ %s%s\n' "$c_step" "$*" "$c_0"; }
ok()   { printf '  %s✓%s %s\n' "$c_ok"   "$c_0" "$*"; }
warn() { printf '  %s!%s %s\n' "$c_warn" "$c_0" "$*"; }
err()  { printf '  %s✗%s %s\n' "$c_err"  "$c_0" "$*" >&2; }
info() { printf '  %s·%s %s\n' "$c_info" "$c_0" "$*"; }
die()  { err "$*"; err "Log: $LOGFILE"; exit 1; }
run()  { local d="$1"; shift; if "$@" >>"$LOGFILE" 2>&1; then ok "$d"; else err "$d — siehe $LOGFILE"; return 1; fi; }

# ── Pre-flight ───────────────────────────────────────────────────────────────
[ "$(id -u)" = "0" ] || die "Bitte mit sudo/root ausführen."
command -v docker >/dev/null 2>&1 || die "docker fehlt. Erst Docker installieren (siehe Koro-DEPLOYMENT.md §0)."
docker compose version >/dev/null 2>&1 || die "docker compose v2 fehlt."
command -v openssl >/dev/null 2>&1 || die "openssl fehlt (apt-get install -y openssl)."
[ -f "$PROJECTS_CONF" ] || die "projects.conf fehlt: $PROJECTS_CONF"
[ -f "$OVERRIDE_TMPL" ] || die "Override-Template fehlt: $OVERRIDE_TMPL"

step "multi-supabase — Init neben Koro (Koro wird NICHT neugestartet)"
info "Repo:        $REPO_DIR"
info "Stacks-Root: $STACKS_ROOT"
info "Log:         $LOGFILE"

# ── Shared edge network (created by Koro; create only if missing) ────────────
step "Shared 'edge'-Netz prüfen"
if docker network inspect edge >/dev/null 2>&1; then
  ok "edge-Netz vorhanden (von Koro) — wird mitbenutzt, nicht neu angelegt"
else
  warn "edge-Netz fehlt — lege es an (normalerweise existiert es via Koro)"
  run "Docker-Netz 'edge' anlegen" docker network create edge
fi

# ── Ensure Traefik is running (do NOT restart it if it is) ───────────────────
step "Traefik (Reverse Proxy) prüfen"
if docker ps --format '{{.Names}}' | grep -qx traefik; then
  ok "Traefik läuft bereits — nutze Label-Auto-Discovery (kein Neustart)"
else
  warn "Kein laufender 'traefik'-Container gefunden."
  warn "Die neuen Domains brauchen die Koro-Traefik. Starte zuerst Koros Proxy:"
  warn "  cd /opt/koro-api && sudo koroctl start   (oder docker compose -f deploy/docker-compose.proxy.yml up -d)"
  warn "Fahre fort — sobald Traefik läuft, werden die Routen automatisch erkannt."
fi

# ── Supabase source (shared shallow clone) ───────────────────────────────────
step "Supabase-Quelle vorbereiten"
if [ -d "$SUPABASE_SRC/docker" ]; then
  ok "Supabase-Quelle vorhanden ($SUPABASE_SRC)"
else
  run "supabase/supabase klonen (--depth 1)" \
      git clone --depth 1 https://github.com/supabase/supabase "$SUPABASE_SRC"
fi

mkdir -p "$STACKS_ROOT"
touch "$CRED_FILE" && chmod 600 "$CRED_FILE"

# ── Helpers: base64url + HS256 JWT signer (anon / service_role) ──────────────
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
gen_jwt() {   # gen_jwt <role> <secret>
  local role="$1" secret="$2" iat exp header payload sig
  iat=1700000000; exp=2000000000   # fixed, long-lived (matches Koro's approach)
  header="$(printf '%s' '{"alg":"HS256","typ":"JWT"}' | b64url)"
  payload="$(printf '%s' "{\"role\":\"${role}\",\"iss\":\"supabase\",\"iat\":${iat},\"exp\":${exp}}" | b64url)"
  sig="$(printf '%s' "${header}.${payload}" | openssl dgst -binary -sha256 -hmac "$secret" | b64url)"
  printf '%s.%s.%s' "$header" "$payload" "$sig"
}
set_env() {   # set_env <file> <KEY> <VALUE>   (idempotent replace/append)
  local f="$1" k="$2" v="$3"
  if grep -qE "^${k}=" "$f"; then
    local tmp; tmp="$(mktemp)"; grep -vE "^${k}=" "$f" > "$tmp"; mv "$tmp" "$f"
  fi
  printf '%s=%s\n' "$k" "$v" >> "$f"
}
htpasswd_hash() {  # htpasswd_hash <user> <pass> → user:$2y$... (bcrypt via httpd:alpine)
  docker run --rm httpd:alpine htpasswd -nbB "$1" "$2" 2>/dev/null | head -1
}

# ── Process each project ─────────────────────────────────────────────────────
NEW_COUNT=0; SKIP_COUNT=0
while read -r STACK DB_HOST STUDIO_HOST _rest || [ -n "$STACK" ]; do
  # skip blanks / comments
  case "$STACK" in ''|\#*) continue ;; esac
  [ -n "${DB_HOST:-}" ] && [ -n "${STUDIO_HOST:-}" ] || { warn "Zeile unvollständig (stack=$STACK) — übersprungen"; continue; }
  [ "$STACK" = "supabase" ] && die "Stack-Name 'supabase' ist für Koro reserviert. Wähle einen anderen."

  PROJECT="sb-${STACK}"                 # compose project name → container/volume prefix
  STACK_DIR="$STACKS_ROOT/$STACK"
  SB_COMPOSE=(docker compose -p "$PROJECT" -f docker-compose.yml -f docker-compose.override.yml)

  step "Projekt: $STACK  ($DB_HOST · $STUDIO_HOST)"

  # ── Idempotency: existing stack? reuse, don't regenerate secrets ──────────
  if [ -f "$STACK_DIR/.env" ] && grep -q '^ANON_KEY=' "$STACK_DIR/.env"; then
    ok "Stack existiert bereits ($STACK_DIR) — Secrets bleiben, bringe nur hoch."
    ANON_KEY="$(grep -E '^ANON_KEY=' "$STACK_DIR/.env" | head -1 | cut -d= -f2-)"
    SERVICE_ROLE_KEY="$(grep -E '^SERVICE_ROLE_KEY=' "$STACK_DIR/.env" | head -1 | cut -d= -f2-)"
    SKIP_COUNT=$((SKIP_COUNT+1))
    FRESH=0
  else
    FRESH=1
    run "Supabase-Docker nach $STACK_DIR kopieren" \
        bash -c "rm -rf '$STACK_DIR' && cp -r '$SUPABASE_SRC/docker' '$STACK_DIR'"
    cp "$STACK_DIR/.env.example" "$STACK_DIR/.env"

    POSTGRES_PASSWORD="$(openssl rand -hex 32)"
    JWT_SECRET="$(openssl rand -base64 48 | tr -d '\n')"
    ANON_KEY="$(gen_jwt anon "$JWT_SECRET")"
    SERVICE_ROLE_KEY="$(gen_jwt service_role "$JWT_SECRET")"
    DASHBOARD_PASSWORD="$(openssl rand -hex 16)"
    SECRET_KEY_BASE="$(openssl rand -hex 32)"
    VAULT_ENC_KEY="$(openssl rand -hex 16)"     # must be 32 chars
    ok "Secrets erzeugt + ANON/SERVICE_ROLE aus JWT_SECRET signiert"

    SB="$STACK_DIR/.env"
    set_env "$SB" POSTGRES_PASSWORD "$POSTGRES_PASSWORD"
    set_env "$SB" JWT_SECRET        "$JWT_SECRET"
    set_env "$SB" ANON_KEY          "$ANON_KEY"
    set_env "$SB" SERVICE_ROLE_KEY  "$SERVICE_ROLE_KEY"
    set_env "$SB" DASHBOARD_USERNAME "admin"
    set_env "$SB" DASHBOARD_PASSWORD "$DASHBOARD_PASSWORD"
    set_env "$SB" SECRET_KEY_BASE   "$SECRET_KEY_BASE"
    set_env "$SB" VAULT_ENC_KEY     "$VAULT_ENC_KEY"
    # Public URLs / API host so Studio + links resolve correctly
    set_env "$SB" SUPABASE_PUBLIC_URL "https://$DB_HOST"
    set_env "$SB" API_EXTERNAL_URL     "https://$DB_HOST"
    set_env "$SB" SITE_URL             "https://$STUDIO_HOST"
    set_env "$SB" STUDIO_DEFAULT_PROJECT "$STACK"
    # Keep Postgres/pooler ports off the host — each stack is reached via Kong
    # through Traefik only; no host-port collisions between stacks.
    set_env "$SB" POSTGRES_PORT 5432
    ok "Stack-.env geschrieben ($SB)"

    # persist credentials for you
    {
      printf '\n# === %s  (%s)  generated %s ===\n' "$STACK" "$DB_HOST" "$TS"
      printf 'DB_HOST=%s\nSTUDIO_HOST=%s\n' "$DB_HOST" "$STUDIO_HOST"
      printf 'POSTGRES_PASSWORD=%s\nJWT_SECRET=%s\n' "$POSTGRES_PASSWORD" "$JWT_SECRET"
      printf 'ANON_KEY=%s\nSERVICE_ROLE_KEY=%s\n' "$ANON_KEY" "$SERVICE_ROLE_KEY"
      printf 'STUDIO_LOGIN=admin / %s\n' "$DASHBOARD_PASSWORD"
    } >> "$CRED_FILE"

    # ── Render override (unique names + edge + Traefik labels) ──────────────
    STUDIO_AUTH_RAW="$(htpasswd_hash admin "$DASHBOARD_PASSWORD" || true)"
    if [ -n "$STUDIO_AUTH_RAW" ]; then
      # escape $ → $$ for compose interpolation
      STUDIO_AUTH="${STUDIO_AUTH_RAW//\$/\$\$}"
      ok "Studio Basic-Auth erzeugt (admin / siehe .install-credentials)"
    else
      STUDIO_AUTH='admin:$$2y$$05$$INVALIDPLACEHOLDERHASHXXXXXXXXXXXXXXXXXXXXXXXXXXX'
      warn "htpasswd-Hash nicht erzeugbar — Studio-Auth ist Platzhalter (401). Später nachziehen."
    fi

    python3 - "$OVERRIDE_TMPL" "$STACK_DIR/docker-compose.override.yml" \
             "$STACK" "$DB_HOST" "$STUDIO_HOST" "$STUDIO_AUTH" <<'PY'
import sys
tmpl, out, stack, db, studio, auth = sys.argv[1:7]
s = open(tmpl).read()
s = (s.replace("__STACK__", stack)
       .replace("__DB_HOST__", db)
       .replace("__STUDIO_HOST__", studio)
       .replace("__STUDIO_AUTH__", auth))
open(out, "w").write(s)
PY
    ok "Override gerendert (Container-Namen ${STACK}-*, edge, Traefik-Labels)"
    NEW_COUNT=$((NEW_COUNT+1))
  fi

  # ── Bring the stack up (DB first, then the rest) ──────────────────────────
  info "Starte Postgres ($STACK-db) — Erst-Init kann dauern …"
  ( cd "$STACK_DIR" && "${SB_COMPOSE[@]}" up -d db ) >>"$LOGFILE" 2>&1 \
      && ok "$STACK-db gestartet" || warn "$STACK-db Start meldete Fehler (siehe Log)"

  # wait until Postgres answers
  for i in $(seq 1 60); do
    if docker exec "$STACK-db" pg_isready -U postgres >/dev/null 2>&1; then
      ok "$STACK-db bereit (nach $((i*3))s)"; break
    fi
    [ "$i" = 60 ] && warn "$STACK-db nach 180s nicht bereit — fahre trotzdem fort"
    sleep 3
  done

  info "Starte restlichen Stack ($STACK) …"
  ( cd "$STACK_DIR" && "${SB_COMPOSE[@]}" up -d ) >>"$LOGFILE" 2>&1 \
      && ok "$STACK-Stack hochgefahren" || warn "$STACK up -d meldete Fehler (siehe Log)"

  # ── Deterministically attach Kong + Studio to edge (override merge of the
  #    networks: block can be flaky depending on compose version) ────────────
  for c in "$STACK-kong" "$STACK-studio"; do
    if docker inspect "$c" >/dev/null 2>&1; then
      if docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$c" | grep -qw edge; then
        info "$c hängt am edge-Netz"
      else
        docker network connect edge "$c" >>"$LOGFILE" 2>&1 \
          && ok "$c ans edge-Netz gehängt" || warn "$c: edge-connect fehlgeschlagen"
      fi
    fi
  done

  ok "$STACK fertig →  API: https://$DB_HOST   Studio: https://$STUDIO_HOST"
done < "$PROJECTS_CONF"

# ── Summary ──────────────────────────────────────────────────────────────────
step "Fertig"
ok "Neu eingerichtet: $NEW_COUNT   ·   Bereits vorhanden (übersprungen): $SKIP_COUNT"
info "Zugangsdaten (Keys, Studio-Passwörter): $CRED_FILE  (chmod 600)"
info "Koro wurde NICHT angefasst. Traefik nahm die neuen Routen per Label auf."
cat <<EOF

  DNS-Check: Jede Domain muss als A-Record auf DIESEN Server zeigen
  (Port 80 offen für Let's Encrypt). Erwartet:
$(while read -r S D T _ ; do case "$S" in ''|\#*) continue;; esac; printf '    %-20s %-22s → dieser Server\n' "$D" "$T"; done < "$PROJECTS_CONF")

  Steuern:  ./deploy/msctl.sh status|start|stop|logs <stack>
EOF

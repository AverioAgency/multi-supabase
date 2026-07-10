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

  # ── Idempotency: a stack counts as "existing" only if a PREVIOUS run fully
  #    succeeded (marker file). A half-built dir from a failed run is rebuilt
  #    from scratch, so re-running after an error is self-healing.
  if [ -f "$STACK_DIR/.multi-supabase-ready" ] && grep -q '^ANON_KEY=' "$STACK_DIR/.env" 2>/dev/null; then
    ok "Stack existiert bereits ($STACK_DIR) — Secrets bleiben, bringe nur hoch."
    ANON_KEY="$(grep -E '^ANON_KEY=' "$STACK_DIR/.env" | head -1 | cut -d= -f2-)"
    SERVICE_ROLE_KEY="$(grep -E '^SERVICE_ROLE_KEY=' "$STACK_DIR/.env" | head -1 | cut -d= -f2-)"
    SKIP_COUNT=$((SKIP_COUNT+1))
    FRESH=0
  else
    FRESH=1
    # Clean up any leftovers from a previous FAILED attempt for this stack, so
    # the rebuild is truly fresh (containers, volumes, half-copied dir).
    if docker ps -aq --filter "name=^${STACK}-" | grep -q . 2>/dev/null; then
      info "Räume Reste eines früheren Fehlversuchs für '$STACK' auf …"
      ( cd "$STACK_DIR" 2>/dev/null && docker compose -p "$PROJECT" down -v ) >>"$LOGFILE" 2>&1 || true
      docker ps -aq --filter "name=^${STACK}-" | xargs -r docker rm -f >>"$LOGFILE" 2>&1 || true
      docker volume ls -q --filter "name=^${PROJECT}_" | xargs -r docker volume rm >>"$LOGFILE" 2>&1 || true
    fi
    run "Supabase-Docker nach $STACK_DIR kopieren" \
        bash -c "rm -rf '$STACK_DIR' && cp -r '$SUPABASE_SRC/docker' '$STACK_DIR'"
    cp "$STACK_DIR/.env.example" "$STACK_DIR/.env"

    # The upstream compose hard-codes container_name: supabase-* on every
    # service, which would collide between stacks AND ignore our project prefix.
    # Strip them so compose falls back to `sb-<stack>-<svc>` naming; the three
    # services we address by name (db/kong/studio) get a clean explicit name
    # back via the override.
    sed -i -E '/^[[:space:]]*container_name:[[:space:]]*(supabase-|realtime-dev\.supabase-)/d' \
        "$STACK_DIR/docker-compose.yml"
    ok "Upstream container_name-Zeilen entfernt (Projekt-Präfix sb-${STACK} greift)"

    # Remove the two HOST port bindings the upstream compose publishes:
    #   kong      → ${KONG_HTTP_PORT}:8000 , ${KONG_HTTPS_PORT}:8443
    #   supavisor → ${POSTGRES_PORT}:5432  , ${POOLER_PROXY_PORT_TRANSACTION}:6543
    # Koro already owns those host ports (8000/8443/5432/6543). These stacks are
    # reached ONLY via Traefik (by domain) + internally over `edge`, so they need
    # no host ports at all → no "port is already allocated" clash. We delete the
    # published-port list items and the resulting empty `ports:` keys.
    python3 - "$STACK_DIR/docker-compose.yml" <<'PY'
import sys, re
p = sys.argv[1]
lines = open(p).read().splitlines(keepends=True)
out = []
# drop list items that publish a host port for the known upstream ports
drop_item = re.compile(
    r'^\s*-\s*\$\{(KONG_HTTP_PORT|KONG_HTTPS_PORT|POSTGRES_PORT|POOLER_PROXY_PORT_TRANSACTION)\}\s*:\s*\d+',
)
kept = [l for l in lines if not drop_item.match(l)]
# now remove any `ports:` key that has no list items left under it
res = []
i = 0
while i < len(kept):
    l = kept[i]
    if re.match(r'^\s*ports:\s*$', l):
        indent = len(l) - len(l.lstrip())
        j = i + 1
        has_item = False
        while j < len(kept):
            nxt = kept[j]
            if nxt.strip() == '':
                j += 1; continue
            nindent = len(nxt) - len(nxt.lstrip())
            if nindent > indent and nxt.lstrip().startswith('-'):
                has_item = True
            break
        if not has_item:
            i += 1        # skip the orphan `ports:` line
            continue
    res.append(l)
    i += 1
open(p, 'w').write(''.join(res))
PY
    ok "Host-Port-Bindungen (kong 8000/8443, pooler 5432/6543) entfernt — keine Kollision mit Koro"

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
    # Public URLs / API host so Studio, Auth links + Functions resolve correctly.
    set_env "$SB" SUPABASE_PUBLIC_URL "https://$DB_HOST"
    # GoTrue/Auth: the upstream default is http://localhost:8000/auth/v1 — it
    # expects the /auth/v1 PATH, not just the host. Without it, auth callbacks,
    # magic links and the JWT issuer are wrong.
    set_env "$SB" API_EXTERNAL_URL     "https://$DB_HOST/auth/v1"
    # SITE_URL = default redirect target for YOUR end-user app (not Studio).
    # No app yet → point at the API host; override per project later.
    set_env "$SB" SITE_URL             "https://$DB_HOST"
    set_env "$SB" ADDITIONAL_REDIRECT_URLS ""
    # No real mail server in this stack (upstream default SMTP_HOST is the
    # non-existent 'supabase-mail'). Auto-confirm e-mail signups so users are
    # usable immediately; otherwise signup "works" but nobody can ever log in.
    # Set up real SMTP + flip this to false when you want confirmation mails.
    set_env "$SB" ENABLE_EMAIL_SIGNUP      true
    set_env "$SB" ENABLE_EMAIL_AUTOCONFIRM true
    set_env "$SB" DISABLE_SIGNUP           false
    # Edge Functions: don't force JWT on every function (matches upstream
    # default); functions opt into verification themselves.
    set_env "$SB" FUNCTIONS_VERIFY_JWT     false
    set_env "$SB" STUDIO_DEFAULT_PROJECT "$STACK"
    # Keep Postgres/pooler ports off the host — each stack is reached via Kong
    # through Traefik only; no host-port collisions between stacks.
    set_env "$SB" POSTGRES_PORT 5432
    ok "Stack-.env geschrieben ($SB)"

    # persist credentials for you — drop any stale block for this stack first
    if grep -q "^# === $STACK " "$CRED_FILE" 2>/dev/null; then
      awk -v s="# === $STACK " '
        $0 ~ ("^" s) {skip=1; next}
        /^# === / && skip {skip=0}
        !skip {print}
      ' "$CRED_FILE" > "$CRED_FILE.tmp" && mv "$CRED_FILE.tmp" "$CRED_FILE"
    fi
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

  # ── OAuth-Provider verdrahten (idempotent, läuft bei JEDEM Run) ───────────
  # Der upstream auth-Service hat keine Apple-Zeilen und kommentiert Google/
  # GitHub aus. Wir schreiben deshalb einen eigenen `auth: environment:`-Block
  # in den Override, der die GOTRUE_EXTERNAL_<PROVIDER>_*-Vars direkt setzt.
  # Quelle: projects/<stack>.providers.env (gitignored). Fehlt die Datei →
  # kein Provider-Block (alles bleibt beim upstream-Default = aus).
  PROV_FILE="$REPO_DIR/projects/${STACK}.providers.env"
  OVERRIDE="$STACK_DIR/docker-compose.override.yml"
  if [ -f "$PROV_FILE" ]; then
    python3 - "$OVERRIDE" "$PROV_FILE" "https://$DB_HOST/auth/v1/callback" <<'PY'
import sys, re
override, provfile, redirect = sys.argv[1:4]

# parse KEY=VALUE from the providers env (ignore comments/blanks)
env = {}
for line in open(provfile):
    line = line.strip()
    if not line or line.startswith('#') or '=' not in line:
        continue
    k, v = line.split('=', 1)
    env[k.strip()] = v.strip()

def on(key):
    return env.get(key, '').lower() in ('true', '1', 'yes')

# build GOTRUE_* env lines for each enabled provider
lines = []
def add(k, v):
    # escape $ for compose interpolation so a $ in a secret is not treated as a var
    v = v.replace('$', '$$')
    lines.append(f'      {k}: "{v}"')

for prov, gname in (('APPLE','APPLE'), ('GOOGLE','GOOGLE'), ('GITHUB','GITHUB')):
    if on(f'{prov}_ENABLED') and env.get(f'{prov}_CLIENT_ID') and env.get(f'{prov}_SECRET'):
        add(f'GOTRUE_EXTERNAL_{gname}_ENABLED', 'true')
        add(f'GOTRUE_EXTERNAL_{gname}_CLIENT_ID', env[f'{prov}_CLIENT_ID'])
        add(f'GOTRUE_EXTERNAL_{gname}_SECRET', env[f'{prov}_SECRET'])
        add(f'GOTRUE_EXTERNAL_{gname}_REDIRECT_URI', redirect)

text = open(override).read()
# strip any previously injected provider block (between the markers)
text = re.sub(r'\n# >>> multi-supabase providers >>>.*?# <<< multi-supabase providers <<<\n',
              '\n', text, flags=re.S)

if lines:
    block = ('\n# >>> multi-supabase providers >>>\n'
             '  auth:\n'
             '    environment:\n'
             + '\n'.join(lines) + '\n'
             '# <<< multi-supabase providers <<<\n')
    # insert the block right after the top-level `services:` line
    if re.search(r'^services:\s*$', text, flags=re.M):
        text = re.sub(r'(^services:\s*$)', r'\1' + block, text, count=1, flags=re.M)
    else:
        text = 'services:' + block + text
    print("PROVIDERS:" + ",".join(sorted(
        p for p in ('APPLE','GOOGLE','GITHUB')
        if on(f'{p}_ENABLED') and env.get(f'{p}_CLIENT_ID') and env.get(f'{p}_SECRET'))))
else:
    print("PROVIDERS:none")

open(override, 'w').write(text)
PY
    _prov="$(cd "$STACK_DIR" && grep -o 'GOTRUE_EXTERNAL_[A-Z]*_ENABLED' docker-compose.override.yml | sed 's/GOTRUE_EXTERNAL_//;s/_ENABLED//' | sort -u | tr '\n' ' ')"
    [ -n "$_prov" ] && ok "OAuth-Provider aktiv: $_prov" || warn "Provider-Datei da, aber kein Provider vollständig (CLIENT_ID/SECRET?) — keiner aktiviert"
  else
    info "Keine Provider-Datei ($PROV_FILE) — nur E-Mail-Auth. (Vorlage: projects/PROVIDERS.example.env)"
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
  UP_OK=0
  if ( cd "$STACK_DIR" && "${SB_COMPOSE[@]}" up -d ) >>"$LOGFILE" 2>&1; then
    UP_OK=1; ok "$STACK-Stack hochgefahren"
  else
    warn "$STACK up -d meldete Fehler (siehe Log) — Stack bleibt UNvollständig, Marker wird NICHT gesetzt"
  fi

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

  # Mark this stack as successfully set up (drives idempotency on re-runs).
  # ONLY when `up` fully succeeded AND every declared service is running — so a
  # partial start (e.g. some containers dead) is NOT treated as "done" and the
  # next run rebuilds it. Count expected vs. running services for this project.
  EXPECTED="$(cd "$STACK_DIR" && "${SB_COMPOSE[@]}" config --services 2>/dev/null | wc -l | tr -d ' ')"
  RUNNING="$(docker ps --filter "label=com.docker.compose.project=$PROJECT" --format '{{.Names}}' | wc -l | tr -d ' ')"
  if [ "$UP_OK" = 1 ] && [ "$EXPECTED" -gt 0 ] && [ "$RUNNING" -ge "$EXPECTED" ]; then
    printf 'ready %s  (%s/%s services)\n' "$TS" "$RUNNING" "$EXPECTED" > "$STACK_DIR/.multi-supabase-ready"
    ok "$STACK fertig →  API: https://$DB_HOST   Studio: https://$STUDIO_HOST  ($RUNNING/$EXPECTED laufen)"
  else
    rm -f "$STACK_DIR/.multi-supabase-ready"
    warn "$STACK UNvollständig ($RUNNING/$EXPECTED Services laufen) — kein Ready-Marker. Nächster Run baut neu auf."
    warn "Logs:  ./deploy/msctl.sh logs $STACK    (oder: docker compose -p $PROJECT logs)"
  fi
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

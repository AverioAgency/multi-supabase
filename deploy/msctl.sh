#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# msctl — steuere die multi-supabase Stacks (unabhängig von Koro/Traefik).
#
#   sudo msctl status                 # Übersicht aller Stacks aus projects.conf
#   sudo msctl start   <stack|all>    # DB-first hochfahren
#   sudo msctl stop    <stack|all>    # sanft stoppen (entfernt nichts)
#   sudo msctl restart <stack|all>
#   sudo msctl logs    <stack> [svc] [-f]   # z.B. msctl logs munter kong -f
#
# Betrifft NUR sb-<stack> Compose-Projekte. Koro (Projekt "supabase-stack",
# Container supabase-*) und Traefik werden nie angefasst.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
STACKS_ROOT="/opt/multi-supabase-stacks"
PROJECTS_CONF="$REPO_DIR/projects/projects.conf"

c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_info=$'\033[36m'; c_h=$'\033[1;35m'; c0=$'\033[0m'
ok(){ printf '  %s✓%s %s\n' "$c_ok" "$c0" "$*"; }
info(){ printf '  %s·%s %s\n' "$c_info" "$c0" "$*"; }
warn(){ printf '  %s!%s %s\n' "$c_warn" "$c0" "$*"; }
hdr(){ printf '\n%s▸ %s%s\n' "$c_h" "$*" "$c0"; }

compose_for(){ # echoes the compose invocation for a stack dir
  local stack="$1" dir="$STACKS_ROOT/$stack"
  [ -d "$dir" ] || { warn "Stack '$stack' nicht installiert ($dir fehlt)"; return 1; }
  if [ -f "$dir/docker-compose.override.yml" ]; then
    printf 'docker compose -p sb-%s -f %s/docker-compose.yml -f %s/docker-compose.override.yml' "$stack" "$dir" "$dir"
  else
    printf 'docker compose -p sb-%s -f %s/docker-compose.yml' "$stack" "$dir"
  fi
}

each_stack(){ # iterate stack names from projects.conf → $1 callback
  local cb="$1" S D T _
  while read -r S D T _ || [ -n "$S" ]; do
    case "$S" in ''|\#*) continue;; esac
    "$cb" "$S" "$D" "$T"
  done < "$PROJECTS_CONF"
}

resolve_targets(){ # $1 = stack|all → prints stack names
  local t="${1:-}"
  [ -z "$t" ] && { warn "Stack angeben (oder 'all')."; exit 1; }
  if [ "$t" = "all" ]; then each_stack _print_name; else printf '%s\n' "$t"; fi
}
_print_name(){ printf '%s\n' "$1"; }

do_start(){ local s="$1" c; c="$(compose_for "$s")" || return 0
  hdr "start $s"
  ( cd "$STACKS_ROOT/$s" && eval "$c up -d db" ) && ok "$s-db"
  for i in $(seq 1 40); do docker exec "$s-db" pg_isready -U postgres >/dev/null 2>&1 && break; sleep 3; done
  ( cd "$STACKS_ROOT/$s" && eval "$c up -d" ) && ok "$s hochgefahren"
  for x in "$s-kong" "$s-studio"; do
    docker inspect "$x" >/dev/null 2>&1 || continue
    docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$x" | grep -qw edge \
      || { docker network connect edge "$x" 2>/dev/null && ok "$x → edge"; }
  done
}
do_stop(){ local s="$1" c; c="$(compose_for "$s")" || return 0
  hdr "stop $s"; ( cd "$STACKS_ROOT/$s" && eval "$c stop" ) && ok "$s gestoppt (nichts entfernt)"; }

do_status(){
  hdr "multi-supabase — Status"
  each_stack _status_row
  printf '\n'; info "Koro (supabase-*) + Traefik werden hier bewusst NICHT gelistet."
}
_status_row(){
  local s="$1" db="$2" studio="$3" n up
  n="$(docker ps -a --filter "name=^${s}-" --format '{{.Names}}' | wc -l | tr -d ' ')"
  up="$(docker ps --filter "name=^${s}-" --format '{{.Names}}' | wc -l | tr -d ' ')"
  local edge="—"; docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "${s}-kong" 2>/dev/null | grep -qw edge && edge="edge✓"
  printf '  %s%-10s%s  container: %s/%s up  %s   API https://%s   Studio https://%s\n' \
    "$c_h" "$s" "$c0" "$up" "$n" "$edge" "$db" "$studio"
}

do_logs(){
  local s="$1"; shift || true
  local follow="" svc=""
  for a in "$@"; do case "$a" in -f) follow="-f";; *) svc="$a";; esac; done
  local c; c="$(compose_for "$s")" || return 0
  ( cd "$STACKS_ROOT/$s" && eval "$c logs --tail 200 $follow $svc" )
}

CMD="${1:-status}"; shift || true
case "$CMD" in
  status)  do_status ;;
  start)   for s in $(resolve_targets "${1:-}"); do do_start "$s"; done ;;
  stop)    for s in $(resolve_targets "${1:-}"); do do_stop  "$s"; done ;;
  restart) for s in $(resolve_targets "${1:-}"); do do_stop "$s"; do_start "$s"; done ;;
  logs)    do_logs "$@" ;;
  *) printf 'Usage: msctl status|start|stop|restart <stack|all> | logs <stack> [svc] [-f]\n'; exit 1 ;;
esac

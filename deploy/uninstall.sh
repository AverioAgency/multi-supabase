#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# uninstall — entfernt EINEN multi-supabase Stack vollständig (Container +
# Volumes + Stack-Dir). Koro/Traefik bleiben unberührt.
#
#   sudo ./deploy/uninstall.sh <stack>          # fragt nach, tippe DELETE
#   sudo ./deploy/uninstall.sh <stack> --yes    # ohne Rückfrage
#
# ⚠️  Unwiderruflich — löscht das Postgres-Volume dieses Projekts (alle Daten).
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
STACKS_ROOT="/opt/multi-supabase-stacks"
STACK="${1:-}"; YES="${2:-}"
[ "$(id -u)" = "0" ] || { echo "Bitte mit sudo ausführen."; exit 1; }
[ -n "$STACK" ] || { echo "Usage: uninstall.sh <stack> [--yes]"; exit 1; }
[ "$STACK" = "supabase" ] && { echo "Verweigert: 'supabase' ist Koro. Abbruch."; exit 1; }

DIR="$STACKS_ROOT/$STACK"
echo "Ziel: Stack '$STACK'  ($DIR)"
docker ps -a --filter "name=^${STACK}-" --format '  container: {{.Names}}'
docker volume ls --filter "name=^sb-${STACK}_" --format '  volume:    {{.Name}}'

if [ "$YES" != "--yes" ]; then
  printf 'Alles obige LÖSCHEN? Tippe DELETE: '; read -r ans
  [ "$ans" = "DELETE" ] || { echo "Abgebrochen."; exit 1; }
fi

if [ -f "$DIR/docker-compose.override.yml" ]; then
  ( cd "$DIR" && docker compose -p "sb-$STACK" -f docker-compose.yml -f docker-compose.override.yml down -v ) || true
elif [ -f "$DIR/docker-compose.yml" ]; then
  ( cd "$DIR" && docker compose -p "sb-$STACK" -f docker-compose.yml down -v ) || true
fi
# safety net: any leftover container / volume with the prefix
docker ps -aq --filter "name=^${STACK}-" | xargs -r docker rm -f
docker volume ls -q --filter "name=^sb-${STACK}_" | xargs -r docker volume rm
rm -rf "$DIR"
echo "✓ Stack '$STACK' entfernt. Koro/Traefik unberührt."
echo "  (Zeile in projects/projects.conf ggf. selbst löschen.)"

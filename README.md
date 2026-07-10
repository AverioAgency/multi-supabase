# multi-supabase

Betreibt **beliebig viele eigenständige, self-hosted Supabase-Instanzen** auf
demselben Server **neben Koro** — ohne Koro (oder Traefik) neu zu starten.

Aktuell vorkonfiguriert:

| Projekt | API (Kong)          | Studio                  |
|---------|---------------------|-------------------------|
| munter  | `db.munter.app`     | `studio.munter.app`     |
| axsuro  | `db.axsuro.com`     | `studio.axsuro.com`     |

## Wie es sich neben Koro einfügt

Koro bringt bereits mit:

- ein **Traefik** (Reverse Proxy + Let's Encrypt) mit Docker-**Label-Auto-
  Discovery** — neue Services registrieren sich **ohne Traefik-Neustart**,
- das gemeinsame externe Docker-Netz **`edge`**.

Dieses Repo hängt sich genau da ein: jede Instanz bekommt ein **eigenes
Compose-Projekt** (`sb-<stack>` → alle Container-Namen `<stack>-*`, keine
Kollision mit Koros `supabase-*`), **eigene Volumes** und ein **eigenes
internes Netz**. Nur **Kong** (API-Gateway) und **Studio** werden zusätzlich
ans `edge`-Netz gehängt, damit die **laufende** Koro-Traefik sie live routet.

```
                     (bereits da, läuft weiter)
   Internet 443 ─▶ Traefik ─┬─▶ Koro:  api/db/studio.koro.chat
                            ├─▶ munter: db.munter.app / studio.munter.app
                            └─▶ axsuro: db.axsuro.com / studio.axsuro.com
   Netz `edge` (shared) ── Kong+Studio jeder Instanz hängen hier mit dran.
   Jede Instanz sonst voll isoliert: eigene Postgres, eigene Volumes.
```

Isolation je Instanz: eigene Postgres-DB, eigenes `JWT_SECRET`/`ANON_KEY`/
`SERVICE_ROLE_KEY`, eigenes `edge`-Alias, eigene Traefik-Router. Kein
geteilter State mit Koro oder untereinander.

## Initialisieren (ohne Koro-Neustart)

Auf dem Server:

```bash
# einmalig klonen (du machst danach nur noch git pull)
sudo mkdir -p /opt/multi-supabase && sudo chown "$USER" /opt/multi-supabase
git clone <DIESES_REPO_URL> /opt/multi-supabase
cd /opt/multi-supabase

# initialisieren — richtet munter + axsuro ein, Koro läuft unberührt weiter
sudo ./deploy/install.sh
```

Bei jedem weiteren Mal (Repo aktualisiert sich, du hast z.B. eine Domain in
`projects/projects.conf` ergänzt):

```bash
cd /opt/multi-supabase && git pull && sudo ./deploy/install.sh
```

`install.sh` ist **idempotent**: bereits eingerichtete Stacks werden erkannt
(Secrets bleiben erhalten) und nur hochgefahren; nur neue Zeilen aus
`projects.conf` werden frisch aufgesetzt. **Koro wird nie `up`/`restart`et.**

### Voraussetzungen

- Docker + `docker compose` v2 laufen (via Koro-Setup schon vorhanden).
- Koros **Traefik läuft** (`docker ps | grep traefik`). Wenn nicht:
  `cd /opt/koro-api && sudo koroctl start`.
- **DNS**: jede Domain als A-Record auf **diesen** Server, Port **80** offen
  (Let's Encrypt HTTP-01). Vor dem Init setzen:
  `db.munter.app`, `studio.munter.app`, `db.axsuro.com`, `studio.axsuro.com`.

## Zugangsdaten

`install.sh` schreibt alle generierten Keys/Passwörter nach
`deploy/.install-credentials` (chmod 600, **gitignored**): pro Projekt
`ANON_KEY`, `SERVICE_ROLE_KEY`, `POSTGRES_PASSWORD`, `JWT_SECRET` und das
Studio-Login (`admin` / Passwort). Studio ist zusätzlich hinter Traefik Basic
Auth.

Client-Nutzung wie bei Supabase Cloud:

```
SUPABASE_URL = https://db.munter.app
SUPABASE_ANON_KEY = <ANON_KEY aus .install-credentials>
```

## Steuern

```bash
sudo ./deploy/msctl.sh status              # Übersicht (nur multi-supabase, nicht Koro)
sudo ./deploy/msctl.sh start   munter      # oder: all
sudo ./deploy/msctl.sh stop    axsuro      # sanft, entfernt nichts
sudo ./deploy/msctl.sh restart munter
sudo ./deploy/msctl.sh logs    munter kong -f
```

Optional als globalen Befehl:

```bash
sudo chmod +x deploy/msctl.sh
sudo ln -sf /opt/multi-supabase/deploy/msctl.sh /usr/local/bin/msctl
sudo msctl status
```

## Ein Projekt hinzufügen

1. Zeile in `projects/projects.conf` anhängen: `<stack>  db.<domain>  studio.<domain>`
2. DNS für beide Hosts auf den Server zeigen lassen.
3. `sudo ./deploy/install.sh` — nur das neue Projekt wird aufgesetzt.

## OAuth-Provider (Apple, Google, GitHub)

Self-hosted Supabase liefert alle Social-Provider **deaktiviert** aus — das
Studio kann sie nicht selbst anschalten (anders als Supabase Cloud). Aktivierung
läuft über eine Provider-Datei pro Stack, die `install.sh` in den auth-Service
(GoTrue) verdrahtet.

### Apple

1. **Client-Secret-JWT erzeugen** (Apple will kein statisches Secret, sondern
   ein signiertes JWT aus deinem `.p8`-Key; läuft nach max. 180 Tagen ab):

   ```bash
   ./deploy/gen-apple-secret.sh \
     --team-id ABCDE12345 \
     --key-id  KEY1234567 \
     --services-id app.munter.web \
     --p8 ~/AuthKey_KEY1234567.p8
   ```

   Gibt das JWT aus.

2. **Provider-Datei anlegen** (gitignored):

   ```bash
   cp projects/PROVIDERS.example.env projects/munter.providers.env
   # eintragen:
   #   APPLE_ENABLED=true
   #   APPLE_CLIENT_ID=app.munter.web        (deine Services-ID)
   #   APPLE_SECRET=<JWT aus Schritt 1>
   ```

3. **In Apple** die Return-URL der Services-ID auf exakt diese setzen:
   `https://db.munter.app/auth/v1/callback`

4. **Anwenden** (startet nur diesen Stack neu, Koro unberührt):

   ```bash
   sudo ./deploy/install.sh
   ```

   `install.sh` meldet dann `OAuth-Provider aktiv: APPLE`. Nach ~180 Tagen JWT
   neu erzeugen und `APPLE_SECRET` ersetzen → `install.sh` erneut.

Google/GitHub gehen analog über dieselbe Datei (Zeilen in der Vorlage).

## Ein Projekt entfernen

```bash
sudo ./deploy/uninstall.sh munter    # ⚠️ löscht dessen DB-Volume unwiderruflich
```

Koro und Traefik bleiben dabei immer unberührt.

ge#!/usr/bin/env bash
# Edge-Setup: WireGuard + Logstash + Git-Pipelines
# Achtung: Datei mit LF-Zeilenenden speichern (nicht CRLF)!
set -euo pipefail

# ---------- kleine Helfer ----------
info(){ echo -e "\e[36mℹ\e[0m $*"; }
ok(){   echo -e "\e[32m✔\e[0m $*"; }
warn(){ echo -e "\e[33m!\e[0m $*"; }
fail(){ echo -e "\e[31m✖\e[0m $*"; exit 1; }

# ---------- Parameter / Defaults (per ENV überschreibbar) ----------
GIT_URL="${GIT_URL:-https://github.com/alphanumerisch/monitoring.git}"                 # z.B. https://git.example.tld/org/repo.git
GIT_BRANCH="${GIT_BRANCH:-dev}"
GIT_USER="${GIT_USER:-alphanumerisch}"               # alphanumerisch, falls https-Auth nötig
GIT_TOKEN="${GIT_TOKEN:-}"             # optionales Token/Passwort für https

REPO_DIR="${REPO_DIR:-/opt/elk/repo}"
LS_PIPELINE_DIR="${LS_PIPELINE_DIR:-/etc/logstash/pipeline/forwarder}"
LS_ETC_DIR="/etc/logstash"

# Aus Repo zu holende Dateien/Ordner (Case-Sensitive wie im Repo!)
REPO_EDGE_PIPELINES_PATH="${REPO_EDGE_PIPELINES_PATH:-logstash/edge/Pipelines}"
REPO_LOGSTASH_YML_PATH="${REPO_LOGSTASH_YML_PATH:-logstash/edge/logstash.yml}"
REPO_PIPELINES_YML_PATH="${REPO_PIPELINES_YML_PATH:-logstash/edge/pipelines.yml}"

# WireGuard
EDGE_ENV="${EDGE_ENV:-/etc/wireguard/edge.env}"
WG_CONF="${WG_CONF:-/etc/wireguard/wg0.conf}"
WG_IFACE="${WG_IFACE:-wg0}"

# ---------- Root / sudo ----------
if [[ $EUID -ne 0 ]]; then
  SUDO="sudo"
else
  SUDO=""
fi

# ---------- Vorbereitungen ----------
$SUDO apt-get update -y
$SUDO apt-get install -y curl ca-certificates git jq qrencode

# ---------- Snaps entfernen ----------
info "Entferne Snaps (falls vorhanden)…"
set +e
$SUDO snap remove --purge lxd 2>/dev/null
$SUDO snap remove --purge core20 2>/dev/null
$SUDO snap remove --purge core22 2>/dev/null
$SUDO snap remove --purge snapd 2>/dev/null
set -e
$SUDO apt-get purge -y snapd || true
$SUDO apt-get autoremove --purge -y || true

# ---------- Basis-Hardening / System ----------
info "Setze Zeitsync & deaktiviere unnötige Dienste…"
$SUDO systemctl disable --now motd-news.service motd-news.timer 2>/dev/null || true
$SUDO systemctl disable --now cloud-init.service 2>/dev/null || true
$SUDO timedatectl set-timezone Europe/Berlin || true
$SUDO systemctl enable --now systemd-timesyncd || true

# ---------- WireGuard installieren & IP-Forwarding ----------
info "Installiere WireGuard…"
$SUDO apt-get install -y wireguard
info "Aktiviere IP-Forwarding…"
echo 'net.ipv4.ip_forward=1' | $SUDO tee /etc/sysctl.d/99-wg.conf >/dev/null
echo 'net.ipv6.conf.all.forwarding=1' | $SUDO tee -a /etc/sysctl.d/99-wg.conf >/dev/null
$SUDO sysctl --system >/dev/null

# ---------- Elastic GPG-Key + APT-Repo für Logstash ----------
info "Importiere Elastic/Logstash GPG-Key & APT-Repo…"
$SUDO rm -f /etc/apt/sources.list.d/elastic-8.x.list  # evtl. alte defekte Quelle
$SUDO install -d -m 0755 /etc/apt/keyrings

curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch \
  | $SUDO gpg --dearmor -o /etc/apt/keyrings/elastic.gpg

$SUDO chmod 0644 /etc/apt/keyrings/elastic.gpg

echo 'deb [signed-by=/etc/apt/keyrings/elastic.gpg] https://artifacts.elastic.co/packages/8.x/apt stable main' \
  | $SUDO tee /etc/apt/sources.list.d/elastic-8.x.list >/dev/null

# ---------- Logstash installieren ----------
$SUDO apt-get update -y
info "Installiere Logstash…"
$SUDO apt-get install -y logstash
$SUDO systemctl enable logstash

# ---------- Git-Repo klonen/aktualisieren ----------
if [[ -z "$GIT_URL" ]]; then
  fail "GIT_URL ist leer. Bitte GIT_URL (und ggf. GIT_USER/GIT_TOKEN) als ENV setzen."
fi

info "Hole Repo: $GIT_URL (Branch: $GIT_BRANCH)…"
$SUDO install -d -m 0755 "$(dirname "$REPO_DIR")"
if [[ -d "$REPO_DIR/.git" ]]; then
  (cd "$REPO_DIR" && $SUDO git fetch --all && $SUDO git checkout "$GIT_BRANCH" && $SUDO git pull --ff-only)
else
  if [[ -n "$GIT_USER" && -n "$GIT_TOKEN" && "$GIT_URL" =~ ^https?:// ]]; then
    # https mit Basic Auth
    AUTH_URL="$(echo "$GIT_URL" | sed -E "s#https://#https://${GIT_USER}:${GIT_TOKEN}@#")"
    $SUDO git clone --branch "$GIT_BRANCH" --depth 1 "$AUTH_URL" "$REPO_DIR"
  else
    $SUDO git clone --branch "$GIT_BRANCH" --depth 1 "$GIT_URL" "$REPO_DIR"
  fi
fi

# ---------- Logstash: Dateien deployen ----------
info "Deploye Logstash-Konfiguration…"
$SUDO install -d -m 0755 "$LS_PIPELINE_DIR"

# Pipelines (Edge)
if [[ -d "$REPO_DIR/$REPO_EDGE_PIPELINES_PATH" ]]; then
  $SUDO rsync -a --delete "$REPO_DIR/$REPO_EDGE_PIPELINES_PATH"/ "$LS_PIPELINE_DIR"/
else
  warn "Repo-Pfad nicht gefunden: $REPO_DIR/$REPO_EDGE_PIPELINES_PATH – überspringe Edge-Pipelines."
fi

# logstash.yml
if [[ -f "$REPO_DIR/$REPO_LOGSTASH_YML_PATH" ]]; then
  $SUDO install -m 0644 "$REPO_DIR/$REPO_LOGSTASH_YML_PATH" "$LS_ETC_DIR/logstash.yml"
else
  warn "Repo-Pfad nicht gefunden: $REPO_DIR/$REPO_LOGSTASH_YML_PATH – überspringe logstash.yml."
fi

# pipelines.yml (vom Repo – auch wenn Dateiname 'pipelines.yml' im rz-Pfad liegt)
if [[ -f "$REPO_DIR/$REPO_PIPELINES_YML_PATH" ]]; then
  $SUDO install -m 0644 "$REPO_DIR/$REPO_PIPELINES_YML_PATH" "/etc/logstash/pipelines.yml"
else
  warn "Repo-Pfad nicht gefunden: $REPO_DIR/$REPO_PIPELINES_YML_PATH – überspringe pipelines.yml."
fi

# Eigentümer setzen
$SUDO chown -R logstash:logstash /etc/logstash

# ---------- WireGuard: ENV & Config rendern ----------
info "Richte WireGuard ein…"
$SUDO install -d -m 0700 /etc/wireguard
if [[ -f "$EDGE_ENV" ]]; then
  # ENV laden
  # shellcheck disable=SC1090
  source "$EDGE_ENV"
else
  info "Erzeuge Schlüssel & ENV: $EDGE_ENV"
  umask 077
  WG_PRIV_GEN="$(wg genkey)"
  WG_PUB_GEN="$(awk 'BEGIN{print ARGV[1]}' <<<"$WG_PRIV_GEN" | wg pubkey)" 2>/dev/null || WG_PUB_GEN=""
  cat | $SUDO tee "$EDGE_ENV" >/dev/null <<ENV
# WireGuard Edge-ENV (pro Gerät anpassen)
WG_PRIVATE_KEY="$WG_PRIV_GEN"
# Unbedingt je Edge setzen:
WG_ADDRESS="${WG_ADDRESS:-10.0.100.XXX/32}"
WG_LISTEN_PORT="${WG_LISTEN_PORT:-51820}"

# RZ/Peer-Daten:
WG_PEER_PUBLIC_KEY="${WG_PEER_PUBLIC_KEY:-}"
WG_ENDPOINT="${WG_ENDPOINT:-vpn.labor-habermehl.de:51820}"
WG_ALLOWED_IPS="${WG_ALLOWED_IPS:-10.0.100.1/32,172.16.60.1/32}"
WG_KEEPALIVE="${WG_KEEPALIVE:-25}"
ENV
  $SUDO chmod 600 "$EDGE_ENV"
  # shellcheck disable=SC1090
  source "$EDGE_ENV"
  [[ -n "${WG_PUB_GEN:-}" ]] && echo "$WG_PUB_GEN" | $SUDO tee /etc/wireguard/publickey >/dev/null || true
fi

# Plausibilitäts-Check
[[ -z "${WG_PRIVATE_KEY:-}" ]] && warn "WG_PRIVATE_KEY fehlt in $EDGE_ENV"
[[ -z "${WG_ADDRESS:-}" ]]     && warn "WG_ADDRESS (z. B. 10.0.100.4/32) fehlt in $EDGE_ENV"
[[ -z "${WG_PEER_PUBLIC_KEY:-}" ]] && warn "WG_PEER_PUBLIC_KEY fehlt (RZ-PublicKey) – Verbindung wird nicht aufbauen."

# wg0.conf rendern
info "Schreibe $WG_CONF (aus ENV)…"
umask 077
$SUDO bash -c "cat > '$WG_CONF' <<WG
[Interface]
PrivateKey = ${WG_PRIVATE_KEY:-}
Address    = ${WG_ADDRESS:-}
ListenPort = ${WG_LISTEN_PORT:-51820}

[Peer]
PublicKey  = ${WG_PEER_PUBLIC_KEY:-}
Endpoint   = ${WG_ENDPOINT:-}
AllowedIPs = ${WG_ALLOWED_IPS:-}
PersistentKeepalive = ${WG_KEEPALIVE:-25}
WG"
$SUDO chmod 600 "$WG_CONF"

# ---------- Dienste starten ----------
info "Starte WireGuard & Logstash…"
set +e
$SUDO systemctl enable --now "wg-quick@${WG_IFACE}"
WG_RC=$?
set -e
if [[ $WG_RC -ne 0 ]]; then
  warn "WireGuard konnte nicht gestartet werden. Prüfe $EDGE_ENV & $WG_CONF."
else
  ok "WireGuard aktiv."
fi

$SUDO systemctl restart logstash
$SUDO systemctl enable logstash
ok "Logstash aktiv."

# ---------- Statushinweise ----------
echo
ok "Fertig. Nützliche Checks:"
echo "  sudo wg show"
echo "  sudo systemctl status wg-quick@${WG_IFACE}"
echo "  sudo systemctl status logstash"
echo
echo "Public Key dieses Edge (falls erzeugt):"
[[ -f /etc/wireguard/publickey ]] && cat /etc/wireguard/publickey || echo "(kein publickey erzeugt – siehe $EDGE_ENV)"



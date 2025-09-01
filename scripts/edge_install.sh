#!/usr/bin/env bash
# edge_install.sh – Edge-Appliance Bootstrapper (Ubuntu/Debian)
# - Legt /tmp/wg_env.env automatisch an, wenn nicht vorhanden (und beendet sich dann)
# - Installiert WireGuard, aktiviert Forwarding, generiert/übernimmt Keys
# - Entfernt Snaps
# - Installiert Logstash (Elastic APT) + zieht Pipelines/Configs aus Git (dev)
# - Setzt Timezone/Timesync
# - Schreibt wg0.conf (Peer-PublicKey als Platzhalter)
# - Am Ende: hebt den Public Key deutlich hervor

set -Eeuo pipefail

# ---------- Helpers ----------
log()  { printf "\033[32m[+] %s\033[0m\n" "$*"; }
warn() { printf "\033[33m[!] %s\033[0m\n" "$*"; }
err()  { printf "\033[31m[-] %s\033[0m\n" "$*"; }
box()  { local t="$1"; printf "\n\033[1;44m %s \033[0m\n" "$t"; }
trap 'err "Fehler in Zeile $LINENO. Abbruch."' ERR

# ---------- Root required ----------
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  err "Bitte als root ausführen."
  exit 1
fi

# ---------- Repo-Parameter ----------
GIT_HOST="https://github.com"
GIT_USER="alphanumerisch"
GIT_REPO="monitoring"
GIT_BRANCH="dev"

# ---------- Pfade ----------
ENV_PATH="/tmp/wg_env.env"
WG_DIR="/etc/wireguard"
WG_CONF="${WG_DIR}/wg0.conf"
WG_PRIV_FILE="${WG_DIR}/privatekey"
WG_PUB_FILE="${WG_DIR}/publickey"

LOGSTASH_ETC="/etc/logstash"
LS_PIPELINES_DIR="${LOGSTASH_ETC}/pipelines/forwarder"
WORKDIR="/tmp/edge-setup"
REPO_CLONE_DIR="${WORKDIR}/${GIT_REPO}"
TS="$(date +%F_%H%M%S)"

mkdir -p "$WORKDIR"

# ---------- ENV prüfen/erzeugen ----------
if [[ ! -f "$ENV_PATH" ]]; then
  warn "$ENV_PATH existiert nicht – lege neue Datei an."
  cat >"$ENV_PATH" <<'EOF'
# WireGuard Environment Variablen
# WG_PRIV_KEY kann automatisch generiert werden, wenn hier "GENERATE" steht.
WG_PRIV_KEY=GENERATE

# IP/Prefix dieses Edge-Geräts (z. B. 10.0.100.4/32)
WG_INTERFACE_IP=CHANGE_ME
EOF
  chmod 600 "$ENV_PATH"
  warn "Bitte $ENV_PATH bearbeiten (WG_INTERFACE_IP setzen; WG_PRIV_KEY auf GENERATE lassen oder Key eintragen)."
  warn "Script beendet sich jetzt. Danach erneut starten."
  exit 0
fi

# ---------- ENV robust laden (CRLF -> LF) ----------
TMP_ENV="$(mktemp)"
sed 's/\r$//' "$ENV_PATH" > "$TMP_ENV"
set -a
# shellcheck disable=SC1090
. "$TMP_ENV"
set +a
rm -f "$TMP_ENV"

WG_PRIV_KEY="${WG_PRIV_KEY:-}"
WG_INTERFACE_IP="${WG_INTERFACE_IP:-}"

if [[ -z "${WG_INTERFACE_IP}" || "${WG_INTERFACE_IP}" == "CHANGE_ME" ]]; then
  err "WG_INTERFACE_IP ist nicht gesetzt. Bitte $ENV_PATH anpassen (z. B. 10.0.100.4/32)."
  exit 2
fi
# /32 anhängen, falls kein Prefix
if [[ "$WG_INTERFACE_IP" != */* ]]; then
  WG_INTERFACE_IP="${WG_INTERFACE_IP}/32"
fi

# ---------- 1.1 WireGuard installieren & Forwarding ----------
log "Installiere WireGuard & Tools…"
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends wireguard qrencode ca-certificates curl gnupg git rsync

log "Aktiviere IPv4/IPv6 Forwarding…"
install -d -m 0755 /etc/sysctl.d
{
  echo 'net.ipv4.ip_forward=1'
  echo 'net.ipv6.conf.all.forwarding=1'
} | tee /etc/sysctl.d/99-wg.conf >/dev/null
sysctl --system >/dev/null

# ---------- Keys erzeugen/übernehmen ----------
install -d -m 0700 "$WG_DIR"
umask 077
if [[ -z "${WG_PRIV_KEY}" || "${WG_PRIV_KEY}" == "GENERATE" || "${WG_PRIV_KEY}" == "AUTO" ]]; then
  warn "WG_PRIV_KEY leer/GENERATE → generiere Schlüssel…"
  wg genkey | tee "$WG_PRIV_FILE" | wg pubkey > "$WG_PUB_FILE"
  WG_PRIV_KEY="$(cat "$WG_PRIV_FILE")"
  chmod 600 "$WG_PRIV_FILE" "$WG_PUB_FILE"
  # WG_PRIV_KEY in env-Datei zurückschreiben/ersetzen
  if grep -q '^WG_PRIV_KEY=' "$ENV_PATH"; then
    sed -i "s#^WG_PRIV_KEY=.*#WG_PRIV_KEY=${WG_PRIV_KEY}#g" "$ENV_PATH"
  else
    printf "\nWG_PRIV_KEY=%s\n" "$WG_PRIV_KEY" >> "$ENV_PATH"
  fi
else
  printf "%s\n" "$WG_PRIV_KEY" > "$WG_PRIV_FILE"
  chmod 600 "$WG_PRIV_FILE"
  printf "%s\n" "$WG_PRIV_KEY" | wg pubkey > "$WG_PUB_FILE"
  chmod 600 "$WG_PUB_FILE"
fi

# ---------- 1.2 Snaps entfernen ----------
warn "Entferne Snaps (falls vorhanden)…"
command -v snap >/dev/null 2>&1 && {
  snap remove --purge lxd 2>/dev/null || true
  snap remove --purge "core"* 2>/dev/null || true
}
apt-get purge -y snapd || true
apt-get autoremove --purge -y || true

# ---------- 1.3 Logstash (Elastic APT) ----------
log "Installiere Logstash (Elastic APT)…"
install -d -m 0755 /usr/share/keyrings
curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch | gpg --dearmor -o /usr/share/keyrings/elastic.gpg
cat >/etc/apt/sources.list.d/elastic-8.x.list <<'EOF'
deb [signed-by=/usr/share/keyrings/elastic.gpg] https://artifacts.elastic.co/packages/8.x/apt stable main
EOF
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y logstash
systemctl enable --now logstash

# ---------- Pipelines & Configs aus Git ziehen ----------
log "Hole Logstash-Konfigurationen aus Git…"
if [[ -d "$REPO_CLONE_DIR/.git" ]]; then
  git -C "$REPO_CLONE_DIR" fetch origin "$GIT_BRANCH" --depth 1
  git -C "$REPO_CLONE_DIR" reset --hard "origin/${GIT_BRANCH}"
else
  rm -rf "$REPO_CLONE_DIR" || true
  git clone --depth 1 --branch "$GIT_BRANCH" \
    "${GIT_HOST}/${GIT_USER}/${GIT_REPO}.git" "$REPO_CLONE_DIR"
fi

# Bevorzugt lowercase-Struktur; Fallback auf versehentliches 'Edge'
BASE_EDGE_DIR=""
if [[ -d "${REPO_CLONE_DIR}/logstash/edge" ]]; then
  BASE_EDGE_DIR="${REPO_CLONE_DIR}/logstash/edge"
elif [[ -d "${REPO_CLONE_DIR}/logstash/Edge" ]]; then
  BASE_EDGE_DIR="${REPO_CLONE_DIR}/logstash/Edge"
else
  warn "Weder logstash/edge noch logstash/Edge vorhanden – überspringe Git-Deploy."
  BASE_EDGE_DIR=""

#!/usr/bin/env bash
# edge_install.sh – Edge-Appliance Bootstrapper (Ubuntu/Debian)

set -Eeuo pipefail

# ---------- Helpers ----------
log()  { printf "\033[32m[+] %s\033[0m\n" "$*"; }
warn() { printf "\033[33m[!] %s\033[0m\n" "$*"; }
err()  { printf "\033[31m[-] %s\033[0m\n" "$*"; }
box()  { local t="$1"; printf "\n\033[1;44m %s \033[0m\n" "$t"; }
trap 'err "Fehler in Zeile $LINENO. Abbruch."' ERR

# ---------- Root required ----------
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  err "Bitte als root ausführen."; exit 1
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
  warn "$ENV_PATH existiert nicht – lege neue Datei an und beende mich."
  cat >"$ENV_PATH" <<'EOF'
# WireGuard Environment Variablen
# WG_PRIV_KEY kann automatisch generiert werden, wenn hier "GENERATE" steht.
WG_PRIV_KEY=GENERATE

# IP/Prefix dieses Edge-Geräts (z. B. 10.0.100.4/32)
WG_INTERFACE_IP=CHANGE_ME
EOF
  chmod 600 "$ENV_PATH"
  warn "Bitte $ENV_PATH bearbeiten (WG_INTERFACE_IP setzen; WG_PRIV_KEY auf GENERATE lassen oder Key eintragen)."
  exit 0
fi

# ---------- ENV robust laden (CRLF -> LF) ----------
TMP_ENV="$(mktemp)"
sed 's/\r$//' "$ENV_PATH" > "$TMP_ENV"
set -a; . "$TMP_ENV"; set +a
rm -f "$TMP_ENV"

WG_PRIV_KEY="${WG_PRIV_KEY:-}"
WG_INTERFACE_IP="${WG_INTERFACE_IP:-}"

# Falls IP fehlt → mit Warnung Default setzen, damit Script sauber bis zum Ende läuft
if [[ -z "${WG_INTERFACE_IP}" || "${WG_INTERFACE_IP}" == "CHANGE_ME" ]]; then
  warn "WG_INTERFACE_IP ist nicht gesetzt – setze vorläufig 10.0.100.4/32. Bitte später in $ENV_PATH korrigieren."
  WG_INTERFACE_IP="10.0.100.4/32"
fi
# /32 anhängen, falls kein Prefix
if [[ "$WG_INTERFACE_IP" != */* ]]; then
  WG_INTERFACE_IP="${WG_INTERFACE_IP}/32"
fi

# ---------- WireGuard & Tools installieren, Forwarding ----------
log "Installiere WireGuard & Tools…"
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  wireguard wireguard-tools qrencode ca-certificates curl gnupg git rsync

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
  # Privatkey in ENV zurückschreiben
  if grep -q '^WG_PRIV_KEY=' "$ENV_PATH"; then
    sed -i "s#^WG_PRIV_KEY=.*#WG_PRIV_KEY=${WG_PRIV_KEY}#g" "$ENV_PATH"
  else
    printf "\nWG_PRIV_KEY=%s\n" "$WG_PRIV_KEY" >> "$ENV_PATH"
  fi
else
  printf "%s\n" "$WG_PRIV_KEY" > "$WG_PRIV_FILE"
  chmod 600 "$WG_PRIV_FILE"
  wg pubkey < "$WG_PRIV_FILE" > "$WG_PUB_FILE"
  chmod 600 "$WG_PUB_FILE"
fi

# ---------- Snaps entfernen (idempotent) ----------
warn "Entferne Snaps (falls vorhanden)…"
if command -v snap >/dev/null 2>&1; then
  snap remove --purge lxd 2>/dev/null || true
  snap remove --purge core 2>/dev/null || true
  snap remove --purge core* 2>/dev/null || true
fi
apt-get purge -y snapd || true
apt-get autoremove --purge -y || true

# ---------- Logstash (Elastic APT) ----------
log "Installiere Logstash (Elastic APT)…"
install -d -m 0755 /usr/share/keyrings
curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch \
  | gpg --dearmor -o /usr/share/keyrings/elastic.gpg
cat >/etc/apt/sources.list.d/elastic-8.x.list <<'EOF'
deb [signed-by=/usr/share/keyrings/elastic.gpg] https://artifacts.elastic.co/packages/8.x/apt stable main
EOF
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y logstash
systemctl enable --now logstash

# ---------- Pipelines & Configs aus Git ziehen (lowercase edge) ----------
log "Hole Logstash-Konfigurationen aus Git…"
rm -rf "$REPO_CLONE_DIR" || true
git clone -q --depth 1 --branch "$GIT_BRANCH" \
  "${GIT_HOST}/${GIT_USER}/${GIT_REPO}.git" "$REPO_CLONE_DIR"

BASE_EDGE_DIR="${REPO_CLONE_DIR}/logstash/edge"
if [[ ! -d "$BASE_EDGE_DIR" ]]; then
  warn "Quellverzeichnis fehlt: $BASE_EDGE_DIR – überspringe Git-Deploy."
else
  install -d -m 0755 "$LS_PIPELINES_DIR"
  # nur .conf, inkl. Unterordner, robust gegen zusätzliche Dateien
  rsync -a --delete \
        --include='*/' --include='*.conf' --exclude='*' \
        "${BASE_EDGE_DIR}/pipelines/" "$LS_PIPELINES_DIR/"
  log "Pipelines nach ${LS_PIPELINES_DIR} synchronisiert."

  for f in jvm.options logstash.yml pipelines.yml; do
    SRC="${BASE_EDGE_DIR}/${f}"
    DST="${LOGSTASH_ETC}/${f}"
    if [[ -f "$SRC" ]]; then
      [[ -f "$DST" ]] && cp -a "$DST" "${DST}.${TS}.bak"
      install -m 0644 "$SRC" "$DST"
      log "Config aktualisiert: $DST"
    else
      warn "Quelle fehlt: $SRC"
    fi
  done
  systemctl restart logstash || warn "logstash Neustart fehlgeschlagen – prüfen!"
fi

# ---------- Basis-Hardening ----------
warn "Basis-Footprint anpassen…"
systemctl disable --now motd-news.service 2>/dev/null || true
systemctl disable --now motd-news.timer   2>/dev/null || true
systemctl disable --now cloud-init.service 2>/dev/null || true
timedatectl set-timezone Europe/Berlin
systemctl enable --now systemd-timesyncd 2>/dev/null || true

# ---------- WireGuard-Konfiguration schreiben ----------
log "Schreibe ${WG_CONF}…"
cat >"$WG_CONF" <<EOF
[Interface]
PrivateKey = ${WG_PRIV_KEY}
Address = ${WG_INTERFACE_IP}
ListenPort = 51820

[Peer]
# !!! Peer PublicKey bitte eintragen !!!
PublicKey = CHANGE_ME_PEER_PUBLIC_KEY
Endpoint = vpn.labor-habermehl.de:51820
AllowedIPs = 10.0.100.1/32, 172.16.60.1/32
PersistentKeepalive = 25
EOF
chmod 600 "$WG_CONF"

# ---------- Abschluss / Ausgabe ----------
PUBKEY="$(wg pubkey < "$WG_PRIV_FILE" 2>/dev/null || cat "$WG_PUB_FILE" 2>/dev/null || true)"
box "WG PUBLIC KEY (dieses Gerät) – diesen in der UTM eintragen"
printf "\n\033[1m%s\033[0m\n\n" "${PUBKEY:-<kein PublicKey ermittelt>}"

if grep -q 'CHANGE_ME_PEER_PUBLIC_KEY' "$WG_CONF"; then
  warn "Peer-PublicKey fehlt noch in ${WG_CONF}. WireGuard wird NICHT gestartet."
  warn "Nach Eintrag starten mit:  systemctl enable --now wg-quick@wg0"
else
  systemctl enable --now wg-quick@wg0
fi

log "Fertig. Prüfen:"
echo "  - ls -l $WG_CONF $WG_PRIV_FILE $WG_PUB_FILE"
echo "  - systemctl status logstash --no-pager"
echo "  - ls -1 $LS_PIPELINES_DIR"

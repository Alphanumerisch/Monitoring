#!/usr/bin/env bash
# edge_install.sh – Edge-Appliance Bootstrapper (Ubuntu/Debian)
# - /tmp/wg_env.env auto anlegen (falls fehlt) => dann beenden
# - WireGuard + wireguard-tools installieren, Forwarding aktivieren
# - Keys generieren/übernehmen; PubKey am Ende IMMER anzeigen
# - Snaps entfernen
# - Logstash via Elastic APT installieren
# - Pipelines:   logstash/edge/pipelines/*.conf -> /etc/logstash/pipelines/forwarder/
#   * Idempotent: existieren bereits .conf-Dateien in forwarder/, wird NICHT überschrieben
# - Configs:     logstash/edge/{jvm.options,logstash.yml,pipelines.yml} -> /etc/logstash/ (überschreiben)
# - Rechte auf Pipelines setzen (Gruppe logstash, d=750, *.conf=640)
# - wg0.conf immer schreiben (Peer-PubKey Platzhalter)

set -Eeuo pipefail

# ---------- helpers ----------
log()  { printf "\033[32m[+] %s\033[0m\n" "$*"; }
warn() { printf "\033[33m[!] %s\033[0m\n" "$*"; }
err()  { printf "\033[31m[-] %s\033[0m\n" "$*"; }
box()  { printf "\n\033[1;44m %s \033[0m\n" "$1"; }
trap 'err "Fehler in Zeile $LINENO."' ERR

# ---------- root ----------
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then err "Bitte als root ausführen."; exit 1; fi

# ---------- repo ----------
GIT_HOST="https://github.com"
GIT_USER="alphanumerisch"
GIT_REPO="monitoring"
GIT_BRANCH="dev"

# ---------- paths ----------
ENV_PATH="/tmp/wg_env.env"
WG_DIR="/etc/wireguard"
WG_CONF="${WG_DIR}/wg0.conf"
WG_PRIV_FILE="${WG_DIR}/privatekey"
WG_PUB_FILE="${WG_DIR}/publickey"

LOGSTASH_ETC="/etc/logstash"
LS_PIPELINES_ROOT="${LOGSTASH_ETC}/pipelines"
LS_PIPELINES_DIR="${LS_PIPELINES_ROOT}/forwarder"
WORKDIR="/tmp/edge-setup"
REPO_CLONE_DIR="${WORKDIR}/${GIT_REPO}"
TS="$(date +%F_%H%M%S)"

mkdir -p "$WORKDIR" "$LS_PIPELINES_DIR"

# ---------- env erzeugen falls fehlt ----------
if [[ ! -f "$ENV_PATH" ]]; then
  warn "$ENV_PATH fehlt – erstelle Vorlage und beende."
  cat >"$ENV_PATH" <<'EOF'
# WireGuard ENV
# WG_PRIV_KEY=GENERATE   -> Key wird automatisch erzeugt
WG_PRIV_KEY=GENERATE
# Beispiel: 10.0.100.4/32
WG_INTERFACE_IP=CHANGE_ME
EOF
  chmod 600 "$ENV_PATH"
  warn "Bitte $ENV_PATH editieren (WG_INTERFACE_IP setzen). Danach Script erneut starten."
  exit 0
fi

# ---------- env laden (CRLF->LF) ----------
TMP_ENV="$(mktemp)"
sed 's/\r$//' "$ENV_PATH" > "$TMP_ENV"
set -a; . "$TMP_ENV"; set +a
rm -f "$TMP_ENV"

WG_PRIV_KEY="${WG_PRIV_KEY:-GENERATE}"
WG_INTERFACE_IP="${WG_INTERFACE_IP:-}"

# Fallback IP, damit Script durchläuft
if [[ -z "$WG_INTERFACE_IP" || "$WG_INTERFACE_IP" == "CHANGE_ME" ]]; then
  warn "WG_INTERFACE_IP nicht gesetzt – setze vorläufig 10.0.100.4/32 (bitte in $ENV_PATH anpassen)."
  WG_INTERFACE_IP="10.0.100.4/32"
fi
[[ "$WG_INTERFACE_IP" != */* ]] && WG_INTERFACE_IP="${WG_INTERFACE_IP}/32"

# ---------- WireGuard + Forwarding ----------
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

# ---------- Keys ----------
install -d -m 0700 "$WG_DIR"
umask 077
if [[ "$WG_PRIV_KEY" == "GENERATE" || -z "$WG_PRIV_KEY" || "$WG_PRIV_KEY" == "AUTO" ]]; then
  warn "Generiere WireGuard-Schlüssel…"
  wg genkey | tee "$WG_PRIV_FILE" | wg pubkey > "$WG_PUB_FILE"
  WG_PRIV_KEY="$(cat "$WG_PRIV_FILE")"
  chmod 600 "$WG_PRIV_FILE" "$WG_PUB_FILE"
  # zurück in ENV
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

# ---------- Snaps entfernen ----------
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
curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch | gpg --dearmor -o /usr/share/keyrings/elastic.gpg
cat >/etc/apt/sources.list.d/elastic-8.x.list <<'EOF'
deb [signed-by=/usr/share/keyrings/elastic.gpg] https://artifacts.elastic.co/packages/8.x/apt stable main
EOF
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y logstash
systemctl enable --now logstash

# ---------- Git ziehen ----------
log "Hole Logstash-Konfigurationen aus Git…"
rm -rf "$REPO_CLONE_DIR" || true
git clone -q --depth 1 --branch "$GIT_BRANCH" \
  "${GIT_HOST}/${GIT_USER}/${GIT_REPO}.git" "$REPO_CLONE_DIR"
BASE_EDGE_DIR="${REPO_CLONE_DIR}/logstash/edge"

# ---------- Pipelines idempotent deployen ----------
install -d -m 0755 "$LS_PIPELINES_DIR"
if compgen -G "${LS_PIPELINES_DIR}/*.conf" >/dev/null; then
  log "Pipelines existieren bereits in ${LS_PIPELINES_DIR} – überspringe Deploy (idempotent)."
else
  if [[ -d "${BASE_EDGE_DIR}/pipelines" ]]; then
    rsync -a --delete --include='*/' --include='*.conf' --exclude='*' \
      "${BASE_EDGE_DIR}/pipelines/" "$LS_PIPELINES_DIR/"
    log "Pipelines -> ${LS_PIPELINES_DIR}"
  else
    warn "Quellverzeichnis fehlt: ${BASE_EDGE_DIR}/pipelines – keine Pipelines kopiert."
  fi
fi

# ---------- Configs (immer überschreiben, mit Backup) ----------
for f in jvm.options logstash.yml pipelines.yml; do
  SRC="${BASE_EDGE_DIR}/${f}"
  DST="${LOGSTASH_ETC}/${f}"
  if [[ -f "$SRC" ]]; then
    [[ -f "$DST" ]] && cp -a "$DST" "${DST}.${TS}.bak"
    install -m 0644 "$SRC" "$DST"
    log "$f -> ${DST}"
  else
    warn "Fehlt im Repo: ${SRC}"
  fi
done

# ---------- Rechte auf Pipelines setzen ----------
log "Setze Rechte für Pipelines…"
chgrp -R logstash "$LS_PIPELINES_ROOT" 2>/dev/null || true
find "$LS_PIPELINES_ROOT" -type d -exec chmod 750 {} \; 2>/dev/null || true
find "$LS_PIPELINES_ROOT" -type f -name '*.conf' -exec chmod 640 {} \; 2>/dev/null || true

# ---------- Logstash neu starten (nur falls was kopiert/konfiguriert) ----------
systemctl restart logstash || warn "logstash Neustart fehlgeschlagen – prüfen!"

# ---------- wg0.conf schreiben ----------
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

# ---------- Abschluss ----------
PUBKEY="$(wg pubkey < "$WG_PRIV_FILE" 2>/dev/null || cat "$WG_PUB_FILE" 2>/dev/null || true)"
box "WG PUBLIC KEY (dieses Gerät) – in der UTM eintragen"
printf "\n\033[1m%s\033[0m\n\n" "${PUBKEY:-<kein PublicKey ermittelt>}"

if grep -q 'CHANGE_ME_PEER_PUBLIC_KEY' "$WG_CONF"; then
  warn "Peer-PublicKey fehlt noch in ${WG_CONF}. WireGuard wird NICHT gestartet."
  warn "Nach Eintrag starten:  systemctl enable --now wg-quick@wg0"
else
  systemctl enable --now wg-quick@wg0
fi

log "Done. Quick-Checks:"
echo "  - cat $WG_CONF"
echo "  - systemctl status logstash --no-pager"
echo "  - ls -1 $LS_PIPELINES_DIR"

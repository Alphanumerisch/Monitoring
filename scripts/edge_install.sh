#!/usr/bin/env bash
# edge_setup.sh – Edge-Appliance Bootstrapper
# Anforderung: root-Rechte, Ubuntu/Debian
# Autor: Meisters Helfer :)

set -Eeuo pipefail

# ------------ Hilfsfunktionen ------------
log()  { printf "\033[32m[+] %s\033[0m\n" "$*"; }
warn() { printf "\033[33m[!] %s\033[0m\n" "$*"; }
err()  { printf "\033[31m[-] %s\033[0m\n" "$*"; }
trap 'err "Fehler in Zeile $LINENO. Abbruch."' ERR

# ------------ Root-Check ------------
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  err "Bitte als root ausführen."
  exit 1
fi

# ------------ Git/Repo-Parameter ------------
GIT_HOST="https://github.com"
GIT_USER="alphanumerisch"
GIT_REPO="monitoring"
GIT_BRANCH="dev"
RAW_BASE="https://raw.githubusercontent.com/${GIT_USER}/${GIT_REPO}/${GIT_BRANCH}"

# ------------ Pfade/Variablen ------------
ENV_PATH="/tmp/wg_env.env"              # gemäß Vorgabe
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

# ------------ Schritt 1 / 2 / 3: wg_env.env prüfen/holen ------------
if [[ -f "$ENV_PATH" ]]; then
  log "Gefunden: $ENV_PATH"
else
  warn "$ENV_PATH nicht gefunden. Versuche Download aus Git…"
  mkdir -p "$WORKDIR"
  cd "$WORKDIR"

  # 1) Versuche Raw-Pfade (häufige Varianten)
  GOT=""
  for P in \
    "edge/wg_env.env" \
    "wg_env.env" \
    "logstash/Edge/wg_env.env" \
    "Edge/wg_env.env"
  do
    if curl -fsSL "${RAW_BASE}/${P}" -o "$ENV_PATH"; then
      log "wg_env.env via raw: ${P}"
      GOT="yes"
      break
    fi
  done

  # 2) Fallback: Git-Clone und suchen
  if [[ -z "${GOT}" ]]; then
    warn "Raw-Download fehlgeschlagen, clone Repository…"
    rm -rf "$REPO_CLONE_DIR" || true
    git clone --depth 1 --branch "$GIT_BRANCH" \
      "${GIT_HOST}/${GIT_USER}/${GIT_REPO}.git" "$REPO_CLONE_DIR"
    FOUND="$(find "$REPO_CLONE_DIR" -maxdepth 4 -type f -name wg_env.env | head -n1 || true)"
    if [[ -n "${FOUND}" ]]; then
      cp -f "$FOUND" "$ENV_PATH"
      log "wg_env.env aus Repo: $FOUND -> $ENV_PATH"
    fi
  fi

  if [[ ! -s "$ENV_PATH" ]]; then
    err "Konnte wg_env.env nicht beziehen."
    exit 2
  fi

  warn "Bitte $ENV_PATH editieren (WG_PRIV_KEY, WG_INTERFACE_IP). Script beendet sich jetzt."
  exit 0
fi

# ------------ env laden ------------
set -a
# shellcheck disable=SC1090
. "$ENV_PATH"
set +a

WG_PRIV_KEY="${WG_PRIV_KEY:-}"
WG_INTERFACE_IP="${WG_INTERFACE_IP:-}"

# ------------ 1.1 WireGuard installieren & Forwarding aktivieren ------------
log "Installiere WireGuard & Tools…"
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends wireguard qrencode

log "Aktiviere IPv4/IPv6 Forwarding…"
install -d -m 0755 /etc/sysctl.d
{
  echo 'net.ipv4.ip_forward=1'
  echo 'net.ipv6.conf.all.forwarding=1'
} | tee /etc/sysctl.d/99-wg.conf >/dev/null
sysctl --system >/dev/null

# Schlüsselverzeichnis
install -d -m 0700 "$WG_DIR"

# Priv-/PubKey erzeugen, falls nicht vorhanden/in ENV leer
if [[ -z "${WG_PRIV_KEY}" || "${WG_PRIV_KEY}" == "AUTO" || "${WG_PRIV_KEY}" == "GENERATE" ]]; then
  warn "WG_PRIV_KEY leer/auto → generiere Schlüssel…"
  umask 077
  wg genkey | tee "$WG_PRIV_FILE" | wg pubkey > "$WG_PUB_FILE"
  WG_PRIV_KEY="$(cat "$WG_PRIV_FILE")"
  chmod 600 "$WG_PRIV_FILE" "$WG_PUB_FILE"

  # WG_PRIV_KEY in env-Datei schreiben/ersetzen
  if grep -q '^WG_PRIV_KEY=' "$ENV_PATH"; then
    sed -i "s#^WG_PRIV_KEY=.*#WG_PRIV_KEY=${WG_PRIV_KEY}#g" "$ENV_PATH"
  else
    printf "\nWG_PRIV_KEY=%s\n" "$WG_PRIV_KEY" >> "$ENV_PATH"
  fi
  log "PrivKey in $ENV_PATH aktualisiert. PublicKey: $WG_PUB_FILE"
else
  # wenn KEY in ENV vorhanden → Dateien aktualisieren
  umask 077
  printf "%s\n" "$WG_PRIV_KEY" > "$WG_PRIV_FILE"
  chmod 600 "$WG_PRIV_FILE"
  printf "%s\n" "$WG_PRIV_KEY" | wg pubkey > "$WG_PUB_FILE"
  chmod 600 "$WG_PUB_FILE"
  log "Schlüssel aus ENV übernommen. PublicKey: $WG_PUB_FILE"
fi

# IP absichern – /32 anhängen, falls vergessen
if [[ "$WG_INTERFACE_IP" != */* ]]; then
  WG_INTERFACE_IP="${WG_INTERFACE_IP}/32"
fi

# ------------ 1.2 Snaps entfernen (idempotent) ------------
warn "Entferne Snaps (falls vorhanden)…"
snap remove --purge lxd 2>/dev/null || true
snap remove --purge "core*" 2>/dev/null || true
apt-get purge -y snapd || true
apt-get autoremove --purge -y || true

# ------------ 1.3 Logstash (Elastic APT) installieren ------------
log "Installiere Logstash (Elastic APT)…"
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends curl ca-certificates gnupg

install -d -m 0755 /usr/share/keyrings
curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch \
  | gpg --dearmor -o /usr/share/keyrings/elastic.gpg

# Repo-Datei (immer neu schreiben – robust gegen Altlasten)
cat >/etc/apt/sources.list.d/elastic-8.x.list <<'EOF'
deb [signed-by=/usr/share/keyrings/elastic.gpg] https://artifacts.elastic.co/packages/8.x/apt stable main
EOF

apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y logstash
systemctl enable --now logstash

# ------------ Pipelines & Configs aus Git ziehen ------------
log "Hole Logstash-Konfigurationen aus Git…"
# Repo holen/aktualisieren
if [[ -d "$REPO_CLONE_DIR/.git" ]]; then
  git -C "$REPO_CLONE_DIR" fetch origin "$GIT_BRANCH" --depth 1
  git -C "$REPO_CLONE_DIR" checkout -f "origin/${GIT_BRANCH}"
else
  rm -rf "$REPO_CLONE_DIR" || true
  git clone --depth 1 --branch "$GIT_BRANCH" \
    "${GIT_HOST}/${GIT_USER}/${GIT_REPO}.git" "$REPO_CLONE_DIR"
fi

# Pipelines kopieren
SRC_PIPE_DIR="${REPO_CLONE_DIR}/logstash/Edge/Pipelines"
install -d -m 0755 "$LS_PIPELINES_DIR"
if [[ -d "$SRC_PIPE_DIR" ]]; then
  rsync -a --delete "$SRC_PIPE_DIR"/ "$LS_PIPELINES_DIR"/
  log "Pipelines nach ${LS_PIPELINES_DIR} synchronisiert."
else
  warn "Quellpfad für Pipelines nicht gefunden: $SRC_PIPE_DIR"
fi

# Hauptconfigs überschreiben (vorher Backup)
for f in jvm.options logstash.yml pipelines.yml; do
  SRC="${REPO_CLONE_DIR}/logstash/Edge/${f}"
  DST="${LOGSTASH_ETC}/${f}"
  if [[ -f "$SRC" ]]; then
    if [[ -f "$DST" ]]; then
      cp -a "$DST" "${DST}.${TS}.bak"
    fi
    install -m 0644 "$SRC" "$DST"
    log "Config aktualisiert: $DST"
  else
    warn "Quelle fehlt: $SRC"
  fi
done

systemctl restart logstash || warn "logstash Neustart fehlgeschlagen – prüfen!"

# ------------ Basis-Hardening / Footprint ------------
warn "Basis-Footprint anpassen…"
systemctl disable --now motd-news.service 2>/dev/null || true
systemctl disable --now motd-news.timer   2>/dev/null || true
systemctl disable --now cloud-init.service 2>/dev/null || true

timedatectl set-timezone Europe/Berlin
systemctl enable --now systemd-timesyncd 2>/dev/null || true

# ------------ WireGuard-Konfiguration schreiben ------------
log "Erzeuge ${WG_CONF}…"
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
log "wg0.conf geschrieben. Eigener PublicKey: $(cat "$WG_PUB_FILE")"
warn "Bitte den Peer-PublicKey in ${WG_CONF} ersetzen (CHANGE_ME_PEER_PUBLIC_KEY)."

# Sicherheitshalber NICHT starten, solange Peer-Key Platzhalter ist
if grep -q 'CHANGE_ME_PEER_PUBLIC_KEY' "$WG_CONF"; then
  warn "WG nicht gestartet, da Peer-Key fehlt. Start später mit: systemctl enable --now wg-quick@wg0"
else
  systemctl enable --now wg-quick@wg0
fi

log "Fertig."
log "ENV-Datei: $ENV_PATH"
log "WG Keys:   $WG_PRIV_FILE (priv), $WG_PUB_FILE (pub)"

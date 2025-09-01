#!/usr/bin/env bash
# edge-setup.sh – Edge bootstrap: WireGuard + Logstash + Pipelines aus Git
set -euo pipefail

### ===== User-Variablen (kannst du auch per ENV setzen) =====
: "${GIT_URL:=https://example.com/your-org/your-repo.git}"   # <— Repo-URL anpassen
: "${GIT_BRANCH:=dev}"                                       # wir ziehen aus 'dev'
: "${TZ:=Europe/Berlin}"                                     # Zeitzone
### ==========================================================

log()  { echo -e "\e[36m[INFO]\e[0m $*"; }
warn() { echo -e "\e[33m[WARN]\e[0m $*"; }
fail() { echo -e "\e[31m[ERR ]\e[0m $*" >&2; exit 1; }

require_root() { [[ $EUID -eq 0 ]] || fail "Bitte als root ausführen."; }

apt_quiet() { DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Use-Pty=0 "$@"; }

ensure_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Benötigtes Programm fehlt: $1"
}

write_file() {
  # write_file <path> <mode> <owner:group>
  local path="$1" mode="$2" owner="${3:-root:root}"
  install -o "${owner%:*}" -g "${owner#*:}" -m "$mode" /dev/stdin "$path"
}

require_root

log "System updaten & Minimal-Hardening"
apt_quiet update
# Snaps loswerden (wenn nicht gewünscht)
snap remove --purge lxd 2>/dev/null || true
snap remove --purge core* 2>/dev/null || true
apt_quiet purge snapd || true
apt_quiet autoremove --purge || true

# Basis-Tools
apt_quiet install ca-certificates curl git jq

# unnötige Dienste dämpfen
systemctl disable --now motd-news.service motd-news.timer 2>/dev/null || true
systemctl disable --now cloud-init.service 2>/dev/null || true

# Timezone & NTP
timedatectl set-timezone "$TZ"
systemctl enable --now systemd-timesyncd

log "WireGuard installieren & Forwarding aktivieren"
apt_quiet update
apt_quiet install wireguard qrencode

write_file /etc/sysctl.d/99-wg.conf 0644 <<'SYSCTL'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
SYSCTL
sysctl --system >/dev/null

# WG ENV-Datei (Tenant-spezifische Werte hier pflegen)
if [[ ! -f /etc/wireguard/edge.env ]]; then
  log "Erzeuge /etc/wireguard/edge.env (bitte bei Bedarf anpassen)…"
  # Falls kein PrivKey gesetzt, generieren wir einen
  if [[ -z "${WG_PRIVATE_KEY:-}" ]]; then
    umask 077
    WG_PRIVATE_KEY="$(wg genkey)"
  fi
  # Public Key (nur zur Anzeige)
  WG_PUBLIC_KEY="$(printf %s "$WG_PRIVATE_KEY" | wg pubkey)"

  write_file /etc/wireguard/edge.env 0600 <<ENV
# WireGuard Edge ENV
WG_PRIVATE_KEY="$WG_PRIVATE_KEY"
# /32 wenn das Edge nur als Client fungiert
WG_ADDRESS="10.0.100.4/32"
WG_LISTEN_PORT="51820"

# Peer (RZ/Hub)
WG_PEER_PUBLIC_KEY=""        # <- vom RZ eintragen
WG_ENDPOINT="vpn.labor-habermehl.de:51820"
WG_ALLOWED_IPS="10.0.100.1/32,172.16.60.1/32"
WG_KEEPALIVE="25"
ENV

  echo
  log "PublicKey dieses Edge (in UTM/RZ eintragen):"
  echo "  $WG_PUBLIC_KEY"
  echo
else
  log "/etc/wireguard/edge.env existiert – verwende vorhandene Werte."
fi

# shellcheck disable=SC1091
set -a; source /etc/wireguard/edge.env; set +a

log "Schreibe /etc/wireguard/wg0.conf"
write_file /etc/wireguard/wg0.conf 0600 <<WGCONF
[Interface]
PrivateKey = ${WG_PRIVATE_KEY}
Address = ${WG_ADDRESS}
ListenPort = ${WG_LISTEN_PORT}

[Peer]
PublicKey = ${WG_PEER_PUBLIC_KEY}
Endpoint  = ${WG_ENDPOINT}
AllowedIPs = ${WG_ALLOWED_IPS}
PersistentKeepalive = ${WG_KEEPALIVE}
WGCONF

systemctl enable --now wg-quick@wg0 || warn "wg-quick@wg0 konnte nicht gestartet werden (Peer-Key/Endpoint prüfen)."

log "Elastic APT Repo & Logstash installieren"
curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch | gpg --dearmor -o /usr/share/keyrings/elastic.gpg
echo 'deb [signed-by=/usr/share/keyrings/elastic.gpg] https://artifacts.elastic.co/packages/8.x/apt stable main' >/etc/apt/sources.list.d/elastic-8.x.list
apt_quiet update
apt_quiet install logstash

# Verzeichnis-Layout für Edge-Forwarder
mkdir -p /etc/logstash/pipelines/forwarder

log "Pipelines & Config aus Git holen (Branch: $GIT_BRANCH)"
ensure_cmd git
TMP_CLONE="$(mktemp -d)"
git clone --depth 1 --branch "$GIT_BRANCH" "$GIT_URL" "$TMP_CLONE"

# Kopiere Forwarder-Pipelines (Groß-/Kleinschreibung im Repo beachten!)
if [[ -d "$TMP_CLONE/logstash/Edge/Pipelines" ]]; then
  cp -a "$TMP_CLONE/logstash/Edge/Pipelines/." /etc/logstash/pipelines/forwarder/
else
  warn "Verzeichnis fehlt im Repo: logstash/Edge/Pipelines – überspringe"
fi

# pipelines.yml & logstash.yml bereitstellen (du sagtest: aus logstash/rz/)
# → wir nehmen das als „Baseline“, wenn vorhanden.
if [[ -f "$TMP_CLONE/logstash/rz/pipelines.yml" ]]; then
  cp -a "$TMP_CLONE/logstash/rz/pipelines.yml" /etc/logstash/pipelines.yml
else
  # Fallback: minimaler pipelines.yml für Edge Forwarder
  log "Erzeuge minimale /etc/logstash/pipelines.yml (Edge-Forwarder)…"
  write_file /etc/logstash/pipelines.yml 0644 <<'PLY'
- pipeline.id: edge-forwarder
  path.config: "/etc/logstash/pipelines/forwarder/*.conf"
  pipeline.workers: 2
  pipeline.batch.size: 125
PLY
fi

if [[ -f "$TMP_CLONE/logstash/rz/logstash.yml" ]]; then
  cp -a "$TMP_CLONE/logstash/rz/logstash.yml" /etc/logstash/logstash.yml
fi

# Besitzrechte
chown -R logstash:logstash /etc/logstash

# Konfigtest & Start
log "Logstash Konfiguration testen…"
if /usr/share/logstash/bin/logstash --path.settings /etc/logstash -t; then
  systemctl enable --now logstash
  systemctl restart logstash
  log "Logstash gestartet."
else
  fail "Logstash Configtest fehlgeschlagen. Bitte /var/log/logstash prüfen."
fi

# Zusammenfassung
echo
log "Fertig 🎉  Bitte prüfen:"
echo "  - WireGuard:  systemctl status wg-quick@wg0; wg show"
echo "  - Logstash :  journalctl -u logstash -f"
echo "  - Pipelines:  /etc/logstash/pipelines/forwarder/"
echo
echo "Hinweis:"
echo "  - Peer PublicKey (WG_PEER_PUBLIC_KEY) in /etc/wireguard/edge.env pflegen,"
echo "    dann: systemctl restart wg-quick@wg0"
echo

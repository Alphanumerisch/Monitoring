#!/bin/bash

set -e

CERT_DIR="/opt/elk/certs"
CA_DIR="$CERT_DIR/ca"
ES_HOT_DIR="$CERT_DIR/es-hot"
ES_WARM_DIR="$CERT_DIR/es-warm"

COUNTRY="DE"
STATE="NRW"
LOCALITY="Ort"
ORG="Firma"
ORG_UNIT="IT"
CA_CN="elk-ca"

HOT_CN="es-hot"
WARM_CN="es-warm"

IP_1="172.18.0.2"
IP_2="172.18.0.3"
IP_3="172.16.60.1"

echo "🧹 Alte Zertifikate und Schlüssel werden gelöscht..."
rm -rf "$CA_DIR" "$ES_HOT_DIR" "$ES_WARM_DIR"

echo "📁 Ordnerstruktur wird erstellt..."
mkdir -p "$CA_DIR" "$ES_HOT_DIR" "$ES_WARM_DIR"

echo "🔐 CA-Zertifikat wird erstellt..."
openssl genrsa -out "$CA_DIR/elastic-stack-ca.key" 4096
openssl req -x509 -new -nodes -key "$CA_DIR/elastic-stack-ca.key" -sha256 -days 3650 \
  -subj "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=$ORG/OU=$ORG_UNIT/CN=$CA_CN" \
  -out "$CA_DIR/elastic-stack-ca.crt"

generate_node_cert() {
  NODE_CN="$1"
  NODE_DIR="$2"

  echo "📄 Erzeuge Zertifikat für $NODE_CN (mit IPs $IP_1 und $IP_2)..."

  cat > "$NODE_DIR/$NODE_CN.cnf" <<EOF
[ req ]
default_bits       = 2048
prompt             = no
default_md         = sha256
req_extensions     = req_ext
distinguished_name = dn

[ dn ]
C  = $COUNTRY
ST = $STATE
L  = $LOCALITY
O  = $ORG
OU = $ORG_UNIT
CN = $NODE_CN

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = $NODE_CN
IP.1  = $IP_1
IP.2  = $IP_2
IP.3 =  $IP_3

[ v3_ext ]
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names
EOF

  openssl genrsa -out "$NODE_DIR/$NODE_CN.key" 4096
  openssl req -new -key "$NODE_DIR/$NODE_CN.key" -out "$NODE_DIR/$NODE_CN.csr" -config "$NODE_DIR/$NODE_CN.cnf"

  openssl x509 -req -in "$NODE_DIR/$NODE_CN.csr" -CA "$CA_DIR/elastic-stack-ca.crt" -CAkey "$CA_DIR/elastic-stack-ca.key" \
    -CAcreateserial -out "$NODE_DIR/$NODE_CN.crt" -days 3650 -sha256 -extfile "$NODE_DIR/$NODE_CN.cnf" -extensions v3_ext
}

generate_node_cert "$HOT_CN" "$ES_HOT_DIR"
generate_node_cert "$WARM_CN" "$ES_WARM_DIR"

echo "✅ Alle Zertifikate wurden erfolgreich erstellt – beide IPs enthalten."

echo "🛡️ Setze Dateiberechtigungen..."

# CA
chmod 600 "$CA_DIR/elastic-stack-ca.key"
chmod 644 "$CA_DIR/elastic-stack-ca.crt"
chown root:root "$CA_DIR/"*

# es-hot
chmod 644 "$ES_HOT_DIR/es-hot.key"
chmod 644 "$ES_HOT_DIR/es-hot.crt" "$ES_HOT_DIR/es-hot.csr" "$ES_HOT_DIR/es-hot.cnf"
chown root:root "$ES_HOT_DIR/"*

# es-warm
chmod 644 "$ES_WARM_DIR/es-warm.key"
chmod 644 "$ES_WARM_DIR/es-warm.crt" "$ES_WARM_DIR/es-warm.csr" "$ES_WARM_DIR/es-warm.cnf"
chown root:root "$ES_WARM_DIR/"*

echo "✅ Dateirechte erfolgreich gesetzt."

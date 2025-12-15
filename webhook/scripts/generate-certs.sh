#!/bin/bash
set -e

# Script to generate TLS certificates for the webhook

# Get script directory and webhook root
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
WEBHOOK_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"

NAMESPACE="gpu-webhook"
SERVICE_NAME="gpu-webhook"
SECRET_NAME="gpu-webhook-certs"

# Create a temporary directory for certificate generation
CERT_DIR=$(mktemp -d)
echo "Generating certificates in $CERT_DIR"

# Generate CA private key
openssl genrsa -out $CERT_DIR/ca.key 2048

# Generate CA certificate
openssl req -x509 -new -nodes -key $CERT_DIR/ca.key \
  -subj "/CN=GPU Webhook CA" \
  -days 3650 \
  -out $CERT_DIR/ca.crt

# Generate server private key
openssl genrsa -out $CERT_DIR/tls.key 2048

# Create CSR config
cat > $CERT_DIR/csr.conf <<EOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[v3_req]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = ${SERVICE_NAME}
DNS.2 = ${SERVICE_NAME}.${NAMESPACE}
DNS.3 = ${SERVICE_NAME}.${NAMESPACE}.svc
DNS.4 = ${SERVICE_NAME}.${NAMESPACE}.svc.cluster.local
EOF

# Generate CSR
openssl req -new -key $CERT_DIR/tls.key \
  -subj "/CN=${SERVICE_NAME}.${NAMESPACE}.svc" \
  -out $CERT_DIR/tls.csr \
  -config $CERT_DIR/csr.conf

# Sign the CSR with CA
openssl x509 -req -in $CERT_DIR/tls.csr \
  -CA $CERT_DIR/ca.crt \
  -CAkey $CERT_DIR/ca.key \
  -CAcreateserial \
  -out $CERT_DIR/tls.crt \
  -days 3650 \
  -extensions v3_req \
  -extfile $CERT_DIR/csr.conf

echo "Certificates generated successfully"

# Create namespace if it doesn't exist
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# Create secret with certificates
kubectl create secret tls $SECRET_NAME \
  --cert=$CERT_DIR/tls.crt \
  --key=$CERT_DIR/tls.key \
  --namespace=$NAMESPACE \
  --dry-run=client -o yaml | kubectl apply -f -

# Get CA bundle and update webhook configuration
CA_BUNDLE=$(cat $CERT_DIR/ca.crt | base64 | tr -d '\n')

# Update webhook configuration with CA bundle
sed "s/CA_BUNDLE_PLACEHOLDER/${CA_BUNDLE}/g" "$WEBHOOK_ROOT/deploy/04-webhook-config.yaml" > $CERT_DIR/webhook-config-patched.yaml

echo "CA Bundle ready for webhook configuration"
echo "Updated webhook config saved to: $CERT_DIR/webhook-config-patched.yaml"

# Save the patched config for deployment
cp $CERT_DIR/webhook-config-patched.yaml "$WEBHOOK_ROOT/deploy/04-webhook-config-patched.yaml"

# Clean up temporary directory (keep for debugging)
echo "Certificate files in: $CERT_DIR"
echo "Secret created in namespace: $NAMESPACE"

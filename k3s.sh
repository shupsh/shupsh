#!/bin/bash
set -e
set -o pipefail

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

prompt_var() {
    local prompt="$1"
    local __var_name="$2"

    if [ -t 0 ]; then
        read -r -p "$prompt" "$__var_name"
    elif [ -t 1 ] && [ -e /dev/tty ]; then
        read -r -p "$prompt" "$__var_name" </dev/tty
    else
        echo "ERROR: No TTY available for prompts. Run this script in an interactive shell." >&2
        exit 1
    fi
}

echo -e "${GREEN}=== K3S + Postgres (TimescaleDB) + SSL Automation Setup ===${NC}"

# 1. Detect External IP
SERVER_IP=$(curl -4 -s ifconfig.me)
echo -e "${GREEN}Current Server IP: ${SERVER_IP}${NC}"

# 2. Request User Input
prompt_var "Enter your domain (e.g., domain.com): " DOMAIN
prompt_var "Enter your email for Let's Encrypt: " EMAIL
echo -e "\n${GREEN}--- Database Configuration ---${NC}"
prompt_var "Enter DB Name (e.g., backend-prod): " DB_NAME
prompt_var "Enter DB Username: " DB_USER
prompt_var "Enter DB Password (leave blank for auto-generate): " DB_PASS

# Auto-generate password if empty
if [ -z "$DB_PASS" ]; then
    DB_PASS="lv_$(date +%s | sha256sum | base64 | head -c 12)"
fi

# 3. DNS Validation
echo -e "\nValidating DNS for $DOMAIN..."
sudo apt update && sudo apt install -y dnsutils > /dev/null 2>&1
RESOLVED_IP=$(dig +short $DOMAIN | tail -n1)

if [ "$RESOLVED_IP" != "$SERVER_IP" ]; then
    echo -e "${RED}WARNING: Domain $DOMAIN points to $RESOLVED_IP, but your server IP is $SERVER_IP${NC}"
    echo "Please update your DNS records!"
else
  echo -e "${GREEN}DNS Verified! Starting installation...${NC}"
fi


# 4. Install Kubectl
if ! command -v kubectl &> /dev/null; then
    echo -e "${GREEN}Installing kubectl...${NC}"
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
    esac
    K8S_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
    curl -LO "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/${ARCH}/kubectl"
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    rm kubectl
fi

# 5. Install K3s (No Traefik)
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik" sh -s -

# Wait for k3s to create the config file
echo "Waiting for k3s configuration file..."
for i in {1..30}; do
    [ -f /etc/rancher/k3s/k3s.yaml ] && break
    echo "Waiting... ($i/30)"
    sleep 2
done

if [ ! -f /etc/rancher/k3s/k3s.yaml ]; then
    echo -e "${RED}Error: /etc/rancher/k3s/k3s.yaml not found. K3s installation might have failed.${NC}"
    exit 1
fi

# Setup kubeconfig
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
export KUBECONFIG=~/.kube/config

# 6. Install Helm
if ! command -v helm &> /dev/null; then
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# 7. Install Ingress & Cert-Manager
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx --namespace ingress-nginx --create-namespace
helm upgrade --install cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace --set crds.enabled=true

echo "Waiting for components to start (45s)..."
sleep 45

# 8. Create ClusterIssuer
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: $EMAIL
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: nginx
EOF

# 9. Deploy PostgreSQL 15 + TimescaleDB
POSTGRES_NS="postgres"
kubectl create namespace $POSTGRES_NS --dry-run=client -o yaml | kubectl apply -f -

# Update or create secret
if kubectl get secret postgres-secret -n $POSTGRES_NS > /dev/null 2>&1; then
    kubectl patch secret postgres-secret -n $POSTGRES_NS -p "{\"data\":{\"postgres-password\":\"$(echo -n "$DB_PASS" | base64)\"}}"
else
    kubectl create secret generic postgres-secret -n $POSTGRES_NS --from-literal=postgres-password="$DB_PASS"
fi

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-pvc
  namespace: $POSTGRES_NS
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 5Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  namespace: $POSTGRES_NS
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
      - name: postgres
        image: timescale/timescaledb:latest-pg15
        env:
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: postgres-secret
              key: postgres-password
        ports:
        - containerPort: 5432
        volumeMounts:
        - name: postgres-storage
          mountPath: /var/lib/postgresql/data
      volumes:
      - name: postgres-storage
        persistentVolumeClaim:
          claimName: postgres-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: postgres-service
  namespace: $POSTGRES_NS
spec:
  selector:
    app: postgres
  ports:
    - protocol: TCP
      port: 5432
      targetPort: 5432
EOF

# 10. Configure User, DB, and Permissions
echo "Waiting for Postgres Pod..."
kubectl wait --for=condition=ready pod -l app=postgres -n $POSTGRES_NS --timeout=120s

echo "Configuring database $DB_NAME and user $DB_USER..."
# Wait for PostgreSQL to actually start responding to connections
MAX_RETRIES=30
RETRY_COUNT=0
until kubectl exec deployment/postgres -n $POSTGRES_NS -- psql -U postgres -c "SELECT 1" > /dev/null 2>&1 || [ $RETRY_COUNT -eq $MAX_RETRIES ]; do
    echo "Waiting for PostgreSQL to be ready to accept connections... ($((RETRY_COUNT+1))/$MAX_RETRIES)"
    sleep 2
    RETRY_COUNT=$((RETRY_COUNT+1))
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    echo -e "${RED}Error: PostgreSQL did not become ready in time.${NC}"
    exit 1
fi

# Execute as superuser 'postgres' to create the custom user and database idempotently
kubectl exec -i deployment/postgres -n $POSTGRES_NS -- psql -U postgres <<EOF
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '$DB_USER') THEN
        CREATE ROLE $DB_USER WITH LOGIN PASSWORD '$DB_PASS';
    ELSE
        ALTER ROLE $DB_USER WITH PASSWORD '$DB_PASS';
    END IF;
END
\$\$;
SELECT 'CREATE DATABASE $DB_NAME' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$DB_NAME')\gexec
\c $DB_NAME
ALTER SCHEMA public OWNER TO $DB_USER;
GRANT ALL ON SCHEMA public TO $DB_USER;
CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;
EOF

# 11. Deploy Temporary Application (hello-k8s)
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-k8s
  namespace: $POSTGRES_NS
spec:
  replicas: 1
  selector:
    matchLabels:
      app: hello-k8s
  template:
    metadata:
      labels:
        app: hello-k8s
    spec:
      containers:
      - name: hello-k8s
        image: paulbouwer/hello-kubernetes:1.10
        ports:
        - containerPort: 8080
        env:
        - name: MESSAGE
          value: "Hello from k3s on $DOMAIN"
---
apiVersion: v1
kind: Service
metadata:
  name: hello-k8s-service
  namespace: $POSTGRES_NS
spec:
  selector:
    app: hello-k8s
  ports:
    - protocol: TCP
      port: 80
      targetPort: 8080
EOF

echo "Waiting for hello-k8s Pod..."
kubectl wait --for=condition=ready pod -l app=hello-k8s -n $POSTGRES_NS --timeout=60s

# 12. Create Ingress
# Remove potential conflicting ingress in 'default' namespace
kubectl delete ingress main-ingress --namespace default --ignore-not-found

cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: main-ingress
  namespace: $POSTGRES_NS
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  ingressClassName: nginx
  tls:
  - hosts: [$DOMAIN]
    secretName: secret-tls
  rules:
  - host: $DOMAIN
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: hello-k8s-service
            port:
              number: 80
EOF

echo -e "\n${GREEN}=== Setup Complete! ===${NC}"
echo -e "External URL: https://$DOMAIN"
echo -e "DB Internal Host: postgres-service.$POSTGRES_NS.svc.cluster.local"
echo -e "Database Name: $DB_NAME"
echo -e "Database User: $DB_USER"
echo -e "Database Password: $DB_PASS"

# 13. Generate Kubeconfig for External Access
KUBECONFIG_PATH="./k3s-external.yaml"
sudo cp /etc/rancher/k3s/k3s.yaml "$KUBECONFIG_PATH"
sudo chown $USER:$USER "$KUBECONFIG_PATH"

# Replace 127.0.0.1 with external IP
sed -i "s/127.0.0.1/$SERVER_IP/g" "$KUBECONFIG_PATH"

# Replace cluster, context and user name 'default' with domain
sed -i "s/cluster: default/cluster: $DOMAIN/g" "$KUBECONFIG_PATH"
sed -i "s/user: default/user: $DOMAIN/g" "$KUBECONFIG_PATH"
sed -i "s/name: default/name: $DOMAIN/g" "$KUBECONFIG_PATH"
sed -i "s/current-context: default/current-context: $DOMAIN/g" "$KUBECONFIG_PATH"

chmod 600 "$KUBECONFIG_PATH"

echo -e "\n${GREEN}Kubernetes config for external access created: ${KUBECONFIG_PATH}${NC}"
echo -e "You can use it with: export KUBECONFIG=\$(pwd)/k3s-external.yaml"

# 14. Update Firewall
sudo ufw allow 6443/tcp > /dev/null 2>&1 || true
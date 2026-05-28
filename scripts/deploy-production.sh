#!/usr/bin/env bash
#
# Production VM setup for Cursor AI Chat API
# Usage: sudo ./scripts/deploy-production.sh <domain> [certbot-email]
#
# Example:
#   sudo ./scripts/deploy-production.sh api.example.com admin@example.com
#
set -euo pipefail

DOMAIN="${1:-}"
CERTBOT_EMAIL="${2:-}"
INSTALL_DIR="${INSTALL_DIR:-/opt/cursor-ai}"
REPO_URL="${REPO_URL:-https://github.com/bonni-brandzzy/cursor-ai.git}"
BRANCH="${BRANCH:-main}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "Run as root: sudo $0 <domain> [certbot-email]"
    exit 1
  fi
}

usage() {
  cat <<EOF
Usage: sudo $0 <domain> [certbot-email]

  domain         Public hostname (e.g. api.example.com). DNS must point to this VM.
  certbot-email  Email for Let's Encrypt (required on first TLS issue)

Environment (optional):
  INSTALL_DIR=/opt/cursor-ai   Install path
  REPO_URL=<git url>           Git repository
  BRANCH=main                  Git branch

Before running, ensure ports 80 and 443 are open on the VM firewall.
EOF
}

validate_domain() {
  if [[ -z "${DOMAIN}" ]]; then
    usage
    exit 1
  fi
  if [[ ! "${DOMAIN}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
    err "Invalid domain: ${DOMAIN}"
    exit 1
  fi
}

detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_VERSION="${VERSION_ID:-}"
  else
    err "Cannot detect OS. Supported: Ubuntu/Debian."
    exit 1
  fi
  case "${OS_ID}" in
    ubuntu|debian) ;;
    *)
      warn "Untested OS: ${OS_ID}. Continuing anyway..."
      ;;
  esac
}

install_packages() {
  log "Installing system packages..."
  apt-get update -qq
  apt-get install -y -qq \
    ca-certificates \
    curl \
    git \
    gnupg \
    lsb-release \
    certbot \
    ufw
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log "Docker already installed."
    return
  fi

  log "Installing Docker..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/"${OS_ID}"/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${OS_ID} \
    $(. /etc/os-release && echo "${VERSION_CODENAME:-$VERSION_ID}") stable" \
    >/etc/apt/sources.list.d/docker.list

  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
}

configure_firewall() {
  if ! command -v ufw >/dev/null 2>&1; then
    return
  fi
  log "Configuring UFW (SSH + HTTP + HTTPS)..."
  ufw --force enable || true
  ufw allow OpenSSH || true
  ufw allow 80/tcp || true
  ufw allow 443/tcp || true
}

clone_or_update_repo() {
  log "Deploying application to ${INSTALL_DIR}..."
  if [[ -d "${INSTALL_DIR}/.git" ]]; then
    git -C "${INSTALL_DIR}" fetch origin
    git -C "${INSTALL_DIR}" checkout "${BRANCH}"
    git -C "${INSTALL_DIR}" pull --ff-only origin "${BRANCH}"
  else
    mkdir -p "$(dirname "${INSTALL_DIR}")"
    git clone --branch "${BRANCH}" --depth 1 "${REPO_URL}" "${INSTALL_DIR}"
  fi
  cd "${INSTALL_DIR}"
  chmod +x scripts/deploy-production.sh 2>/dev/null || true
}

ensure_env_file() {
  cd "${INSTALL_DIR}"
  if [[ -f .env ]]; then
    log ".env exists — keeping current values."
    # Ensure production defaults
    grep -q '^ENVIRONMENT=' .env && sed -i 's/^ENVIRONMENT=.*/ENVIRONMENT=production/' .env \
      || echo 'ENVIRONMENT=production' >> .env
    grep -q '^CURSOR_WORKSPACE=' .env && sed -i 's|^CURSOR_WORKSPACE=.*|CURSOR_WORKSPACE=/app|' .env \
      || echo 'CURSOR_WORKSPACE=/app' >> .env
    return
  fi

  warn ".env not found. Creating from .env.example..."
  cp .env.example .env
  sed -i 's/^ENVIRONMENT=.*/ENVIRONMENT=production/' .env
  sed -i 's|^CURSOR_WORKSPACE=.*|CURSOR_WORKSPACE=/app|' .env

  local api_key cursor_key
  echo ""
  echo "Enter secrets for .env (input hidden):"
  read -rsp "API_KEY (your HTTP API secret): " api_key
  echo ""
  read -rsp "CURSOR_API_KEY (from Cursor dashboard): " cursor_key
  echo ""

  if [[ -z "${api_key}" || -z "${cursor_key}" ]]; then
    err "API_KEY and CURSOR_API_KEY are required."
    err "Edit ${INSTALL_DIR}/.env and re-run this script."
    exit 1
  fi

  set_env_var() {
    local key="$1" val="$2" file="$3"
    touch "$file"
    grep -v "^${key}=" "$file" > "${file}.tmp" 2>/dev/null || true
    printf '%s=%s\n' "$key" "$val" >> "${file}.tmp"
    mv "${file}.tmp" "$file"
  }
  set_env_var "API_KEY" "${api_key}" .env
  set_env_var "CURSOR_API_KEY" "${cursor_key}" .env
  chmod 600 .env
  log ".env created (mode 600)."
}

write_nginx_http_bootstrap() {
  log "Writing nginx HTTP config (ACME + temporary proxy)..."
  mkdir -p "${INSTALL_DIR}/docker/certbot/www"
  cat >"${INSTALL_DIR}/docker/nginx/conf.d/api.conf" <<NGINX
upstream cursor_api {
    server api:8000;
    keepalive 32;
}

server {
    listen 80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        proxy_pass http://cursor_api;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
NGINX
}

write_nginx_ssl() {
  log "Writing nginx HTTPS config..."
  cat >"${INSTALL_DIR}/docker/nginx/conf.d/api.conf" <<NGINX
upstream cursor_api {
    server api:8000;
    keepalive 32;
}

server {
    listen 80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    http2 on;
    server_name ${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_protocols TLSv1.2 TLSv1.3;

    location / {
        proxy_pass http://cursor_api;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
NGINX
}

docker_compose() {
  docker compose -f docker-compose.yml -f docker-compose.prod.yml "$@"
}

start_stack_http() {
  log "Building and starting Docker stack (HTTP)..."
  cd "${INSTALL_DIR}"
  docker_compose build --pull
  docker_compose up -d
  log "Waiting for API health..."
  local i
  for i in {1..60}; do
    if curl -fsS "http://127.0.0.1:8000/health" >/dev/null 2>&1; then
      log "API is healthy."
      return
    fi
    sleep 2
  done
  err "API did not become healthy. Check: docker compose -f docker-compose.yml -f docker-compose.prod.yml logs api"
  exit 1
}

issue_tls_certificate() {
  if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
    log "TLS certificate already exists for ${DOMAIN}."
    return
  fi

  if [[ -z "${CERTBOT_EMAIL}" ]]; then
    err "Certbot email required on first run."
    err "Usage: sudo $0 ${DOMAIN} you@example.com"
    exit 1
  fi

  log "Requesting Let's Encrypt certificate for ${DOMAIN}..."
  certbot certonly \
    --webroot \
    -w "${INSTALL_DIR}/docker/certbot/www" \
    -d "${DOMAIN}" \
    --email "${CERTBOT_EMAIL}" \
    --agree-tos \
    --non-interactive \
    --no-eff-email
}

enable_https_and_restart() {
  write_nginx_ssl
  log "Restarting nginx with TLS..."
  cd "${INSTALL_DIR}"
  docker_compose restart nginx
}

setup_certbot_renewal() {
  log "Installing certbot renewal hook..."
  cat >/etc/cron.d/certbot-cursor-ai <<CRON
0 3 * * * root certbot renew --quiet --deploy-hook "cd ${INSTALL_DIR} && docker compose -f docker-compose.yml -f docker-compose.prod.yml restart nginx"
CRON
  chmod 644 /etc/cron.d/certbot-cursor-ai
}

print_summary() {
  local api_key_hint
  api_key_hint="(set in ${INSTALL_DIR}/.env)"
  cat <<EOF

${GREEN}Deployment complete!${NC}

  URL:      https://${DOMAIN}
  Health:   https://${DOMAIN}/health
  Chat:     POST https://${DOMAIN}/chat
  Stream:   POST https://${DOMAIN}/chat/stream

  Header:   X-API-Key: ${api_key_hint}

  Install:  ${INSTALL_DIR}
  Logs:     cd ${INSTALL_DIR} && docker compose -f docker-compose.yml -f docker-compose.prod.yml logs -f

  Test:
    curl -fsS https://${DOMAIN}/health
    curl -X POST https://${DOMAIN}/chat \\
      -H "Content-Type: application/json" \\
      -H "X-API-Key: YOUR_API_KEY" \\
      -d '{"message":"Hello"}'

EOF
}

main() {
  require_root
  validate_domain
  detect_os

  log "Domain: ${DOMAIN}"
  log "Install directory: ${INSTALL_DIR}"

  if command -v dig >/dev/null 2>&1; then
    local resolved
    resolved="$(dig +short "${DOMAIN}" A 2>/dev/null | head -1 || true)"
    if [[ -n "${resolved}" ]]; then
      log "DNS ${DOMAIN} -> ${resolved}"
    else
      warn "DNS may not be configured for ${DOMAIN}. Point an A record to this VM before using HTTPS."
    fi
  fi

  install_packages
  install_docker
  configure_firewall
  clone_or_update_repo
  ensure_env_file
  write_nginx_http_bootstrap
  start_stack_http
  issue_tls_certificate
  enable_https_and_restart
  setup_certbot_renewal
  print_summary
}

main "$@"

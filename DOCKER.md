# Docker production setup

Run the Cursor AI Chat API in Docker on a VM with API-key auth, a single worker (required for the Cursor SDK bridge), and optional nginx in front.

## Prerequisites

- Docker Engine 24+ and Docker Compose v2
- VM with outbound HTTPS (Cursor API + SDK bridge)
- Linux x86_64 or arm64 (matches `cursor-sdk` wheels)
- Keys ready:
  - `API_KEY` — protects your HTTP API (`X-API-Key` header)
  - `CURSOR_API_KEY` — from [Cursor Integrations](https://cursor.com/dashboard/integrations)

## Automated VM setup (recommended)

On Ubuntu/Debian with your domain DNS already pointing at the VM:

```bash
git clone https://github.com/bonni-brandzzy/cursor-ai.git /opt/cursor-ai
cd /opt/cursor-ai
sudo ./scripts/deploy-production.sh api.yourdomain.com you@yourdomain.com
```

The script will:

1. Install Docker, git, certbot, and configure UFW (22, 80, 443)
2. Clone or update the repo under `/opt/cursor-ai`
3. Create `.env` interactively if missing
4. Build and start the API + nginx
5. Issue a Let's Encrypt certificate and enable HTTPS
6. Schedule certificate renewal

Override install path: `sudo INSTALL_DIR=/srv/cursor-ai ./scripts/deploy-production.sh ...`

---

## 1. Configure environment

Copy and edit secrets on the VM (never commit `.env`):

```bash
cp .env.example .env
```

Required in `.env`:

```env
API_KEY=<long-random-secret>
CURSOR_API_KEY=cursor_...
CURSOR_WORKSPACE=/app
CURSOR_MODEL=composer-2.5
ENVIRONMENT=production
PORT=8000
```

Generate `API_KEY`:

```bash
python3 -c "import secrets; print(secrets.token_urlsafe(32))"
```

## 2. Build and run (API only)

```bash
docker compose build
docker compose up -d
docker compose ps
docker compose logs -f api
```

Health check:

```bash
curl http://127.0.0.1:8000/health
```

Chat (requires API key):

```bash
curl -X POST http://127.0.0.1:8000/chat \
  -H "Content-Type: application/json" \
  -H "X-API-Key: YOUR_API_KEY" \
  -d '{"message": "What is FastAPI?"}'
```

Stop:

```bash
docker compose down
```

## 3. Production compose (localhost bind + nginx)

Binds the API to `127.0.0.1` on the host and starts nginx on ports 80/443:

```bash
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --build
```

Clients hit nginx:

```bash
curl http://YOUR_VM_IP/health
curl -X POST http://YOUR_VM_IP/chat \
  -H "Content-Type: application/json" \
  -H "X-API-Key: YOUR_API_KEY" \
  -d '{"message": "Hello"}'
```

### TLS (recommended)

1. Point DNS to the VM.
2. Use certbot on the host or mount certs into `docker/nginx`.
3. Extend `docker/nginx/conf.d/api.conf` with `listen 443 ssl` and certificate paths.

For a quick test without TLS, restrict VM firewall to your IP on port 80.

## 4. VM checklist

| Item | Action |
|------|--------|
| Firewall | Allow 80/443 (or only 443); do not expose 8000 publicly when using nginx |
| Secrets | `.env` mode `600`; use Docker secrets or cloud secret manager in hardened setups |
| Updates | `docker compose pull && docker compose up -d --build` |
| Logs | `docker compose logs -f api` |
| Restart | `restart: unless-stopped` in compose |
| Workers | Always **1** uvicorn worker (SDK bridge is per-process) |
| Docs | Disabled when `ENVIRONMENT=production` |

## 5. Architecture

```text
Internet → nginx:80/443 → api:8000 (uvicorn, 1 worker)
                              └── Cursor SDK bridge → Cursor cloud
```

Inside the container:

- `CURSOR_WORKSPACE=/app` — project files copied at build time
- `API_KEY` — your clients must send `X-API-Key`
- `CURSOR_API_KEY` — SDK authentication to Cursor

## 6. Rebuild after code changes

```bash
docker compose build --no-cache api
docker compose up -d api
```

## 7. Resource limits

`docker-compose.prod.yml` sets CPU/memory limits. Adjust for your VM size. Chat runs can be long-running; nginx `proxy_read_timeout` is set to 3600s for SSE.

## 8. Troubleshooting

| Symptom | Fix |
|---------|-----|
| `401` on `/chat` | Set `X-API-Key` to match `API_KEY` in `.env` |
| Container unhealthy | Wait for `start_period` (bridge startup); check `docker compose logs api` |
| `502` from API | Invalid `CURSOR_API_KEY` or Cursor API/network issue |
| Works locally, fails in Docker | Ensure VM arch matches image (`linux/amd64` vs `arm64`) |
| `agent_id` resume fails after scale | Run only **one** API replica |

## 9. Build for a specific platform (VM ≠ your laptop)

```bash
docker build --platform linux/amd64 -t cursor-ai-chat-api:latest .
```

Or in `docker-compose.yml`:

```yaml
build:
  platforms:
    - linux/amd64
```

## 10. Hardening (optional)

- Remove `ports` from `api` in production; only nginx publishes ports.
- Use Docker Swarm/Kubernetes secrets instead of `env_file: .env`.
- Rate-limit at nginx (`limit_req`).
- Rotate `API_KEY` and `CURSOR_API_KEY` periodically.

# Cursor AI Chat API

FastAPI service that exposes chat endpoints powered by the [Cursor Python SDK](https://cursor.com/docs/sdk/python). Use it to integrate Cursor agents into your apps, bots, or backend services.

## Features

- **POST `/chat`** — full assistant reply (JSON)
- **POST `/chat/stream`** — Server-Sent Events (SSE) streaming
- **API key auth** — `X-API-Key` header on chat routes
- **Multi-turn chat** — pass `agent_id` from a previous response
- **Docker** — production-ready image with optional nginx reverse proxy
- **Local Cursor agents** — runs against a workspace directory via the SDK bridge

## Requirements

- Python 3.10+
- [Cursor API key](https://cursor.com/dashboard/integrations)
- Docker (optional, recommended for production)

## Quick start (local)

```bash
git clone https://github.com/bonni-brandzzy/cursor-ai.git
cd cursor-ai

python3.13 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

cp .env.example .env
# Edit .env: API_KEY, CURSOR_API_KEY

uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

Open http://localhost:8000/docs (when `ENVIRONMENT=development`).

## Environment variables

| Variable | Required | Description |
|----------|----------|-------------|
| `API_KEY` | Yes | Secret for clients (`X-API-Key` header) |
| `CURSOR_API_KEY` | Yes | Cursor SDK key from [Integrations](https://cursor.com/dashboard/integrations) |
| `CURSOR_WORKSPACE` | No | Local agent workspace path (default: project root; use `/app` in Docker) |
| `CURSOR_MODEL` | No | Model ID (default: `composer-2.5`) |
| `ENVIRONMENT` | No | `development` or `production` (production hides `/docs`) |
| `PORT` | No | Host port for Docker Compose (default: `8000`) |

Generate a secure `API_KEY`:

```bash
python3 -c "import secrets; print(secrets.token_urlsafe(32))"
```

## API usage

### Health (no auth)

```bash
curl http://localhost:8000/health
```

### Chat

```bash
curl -X POST http://localhost:8000/chat \
  -H "Content-Type: application/json" \
  -H "X-API-Key: YOUR_API_KEY" \
  -d '{"message": "What is FastAPI?"}'
```

Response:

```json
{
  "agent_id": "agent-...",
  "run_id": "run-...",
  "message": "...",
  "status": "finished"
}
```

### Continue a conversation

```bash
curl -X POST http://localhost:8000/chat \
  -H "Content-Type: application/json" \
  -H "X-API-Key: YOUR_API_KEY" \
  -d '{"message": "Give a short example", "agent_id": "agent-..."}'
```

### Streaming (SSE)

```bash
curl -N -X POST http://localhost:8000/chat/stream \
  -H "Content-Type: application/json" \
  -H "X-API-Key: YOUR_API_KEY" \
  -d '{"message": "Explain async Python in 3 bullets"}'
```

Events: `{"type":"text","content":"..."}` then `{"type":"done",...}`.

## Docker

```bash
cp .env.example .env
# Edit .env with your keys

docker compose build
docker compose up -d
curl http://localhost:8000/health
```

Production (nginx + localhost API bind):

```bash
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --build
```

See [DOCKER.md](./DOCKER.md) for VM deployment, TLS, troubleshooting, and architecture.

## Project structure

```text
app/
  main.py              # FastAPI routes
  config.py            # Settings from env
  security.py          # API key validation
  schemas.py           # Request/response models
  services/
    cursor_agent.py    # Cursor SDK integration
docker/
  nginx/               # Reverse proxy config
Dockerfile
docker-compose.yml
docker-compose.prod.yml
```

## Production notes

- Run **one** uvicorn worker (`--workers 1`) — the Cursor SDK bridge is per process.
- Do not commit `.env`; use secrets management on the VM.
- Use `ENVIRONMENT=production` to disable OpenAPI docs.
- Put nginx or another reverse proxy in front for HTTPS; do not expose port 8000 publicly.

## License

MIT (or your chosen license — update as needed.)

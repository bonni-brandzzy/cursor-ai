import logging
from contextlib import asynccontextmanager

from dotenv import load_dotenv
from cursor_sdk import CursorAgentError
from fastapi import Depends, FastAPI, HTTPException
from fastapi.responses import StreamingResponse

from app.config import PROJECT_ROOT, get_settings
from app.schemas import ChatRequest, ChatResponse, ErrorResponse
from app.security import require_api_key
from app.services.cursor_agent import CursorAgentService

load_dotenv(PROJECT_ROOT / ".env")

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

_settings = get_settings()
_docs_kwargs = (
    {"docs_url": None, "redoc_url": None, "openapi_url": None}
    if _settings.is_production
    else {}
)


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = get_settings()
    service = CursorAgentService(settings)
    await service.startup()
    app.state.cursor_service = service
    app.state.settings = settings
    yield
    await service.shutdown()


app = FastAPI(
    title="Cursor AI Chat API",
    description="FastAPI chat endpoints powered by the Cursor SDK",
    version="1.0.0",
    lifespan=lifespan,
    **_docs_kwargs,
)


def get_cursor_service() -> CursorAgentService:
    return app.state.cursor_service


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.post(
    "/chat",
    response_model=ChatResponse,
    dependencies=[Depends(require_api_key)],
    responses={
        401: {"model": ErrorResponse, "description": "Missing or invalid API key"},
        502: {"model": ErrorResponse, "description": "Cursor agent failed to start"},
        500: {"model": ErrorResponse, "description": "Agent run failed"},
    },
)
async def chat(
    body: ChatRequest,
    service: CursorAgentService = Depends(get_cursor_service),
):
    """Send a message and receive the full assistant reply."""
    try:
        result = await service.chat(
            message=body.message,
            agent_id=body.agent_id,
            model=body.model,
        )
        return ChatResponse(**result)
    except CursorAgentError as err:
        logger.exception("Cursor agent startup or run error")
        status = 502 if err.is_retryable else 502
        raise HTTPException(
            status_code=status,
            detail={
                "detail": err.message,
                "retryable": err.is_retryable,
            },
        ) from err


@app.post(
    "/chat/stream",
    dependencies=[Depends(require_api_key)],
    responses={401: {"model": ErrorResponse, "description": "Missing or invalid API key"}},
)
async def chat_stream(
    body: ChatRequest,
    service: CursorAgentService = Depends(get_cursor_service),
):
    """Stream assistant text as Server-Sent Events (SSE)."""

    async def event_generator():
        async for event in service.chat_stream(
            message=body.message,
            agent_id=body.agent_id,
            model=body.model,
        ):
            yield event

    return StreamingResponse(
        event_generator(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )

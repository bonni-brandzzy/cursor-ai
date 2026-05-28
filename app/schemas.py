from typing import Literal

from pydantic import BaseModel, Field


class ChatRequest(BaseModel):
    message: str = Field(..., min_length=1, description="User message to send to the agent")
    agent_id: str | None = Field(
        default=None,
        description="Existing agent ID for multi-turn chat. Omit to start a new conversation.",
    )
    model: str | None = Field(
        default=None,
        description="Model ID (e.g. composer-2.5). Uses server default when omitted on resume.",
    )


class ChatResponse(BaseModel):
    agent_id: str
    run_id: str
    message: str
    status: Literal["finished", "error", "cancelled"]


class ErrorResponse(BaseModel):
    detail: str
    retryable: bool | None = None

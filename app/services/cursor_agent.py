import json
import logging
from collections.abc import AsyncIterator
from pathlib import Path

from cursor_sdk import AgentOptions, AsyncClient, CursorAgentError, LocalAgentOptions

from app.config import Settings

logger = logging.getLogger(__name__)


class CursorAgentService:
    """Wraps the Cursor SDK async client for chat requests."""

    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._client: AsyncClient | None = None

    async def startup(self) -> None:
        workspace = str(self._settings.cursor_workspace.resolve())
        self._client = await AsyncClient.launch_bridge(workspace=workspace)
        logger.info("Cursor SDK bridge started for workspace=%s", workspace)

    async def shutdown(self) -> None:
        if self._client is not None:
            await self._client.aclose()
            self._client = None
            logger.info("Cursor SDK bridge closed")

    @property
    def client(self) -> AsyncClient:
        if self._client is None:
            raise RuntimeError("Cursor client is not initialized")
        return self._client

    def _local_options(self) -> LocalAgentOptions:
        cwd = str(self._settings.cursor_workspace.resolve())
        return LocalAgentOptions(cwd=cwd)

    async def _open_agent(self, agent_id: str | None, model: str | None):
        client = self.client
        api_key = self._settings.cursor_api_key
        resolved_model = model or self._settings.cursor_model
        local = self._local_options()

        if agent_id:
            options = AgentOptions(
                api_key=api_key,
                model=resolved_model,
                local=local,
            )
            return await client.agents.resume(agent_id, options)

        return await client.agents.create(
            model=resolved_model,
            api_key=api_key,
            local=local,
        )

    async def chat(self, message: str, agent_id: str | None, model: str | None) -> dict:
        try:
            async with await self._open_agent(agent_id, model) as agent:
                run = await agent.send(message)
                text = await run.text()
                result = await run.wait()

                if result.status == "error":
                    raise CursorAgentError(
                        f"Agent run failed: {result.id}",
                        is_retryable=False,
                    )

                return {
                    "agent_id": agent.agent_id,
                    "run_id": result.id,
                    "message": text,
                    "status": result.status,
                }
        except CursorAgentError:
            raise

    async def chat_stream(
        self,
        message: str,
        agent_id: str | None,
        model: str | None,
    ) -> AsyncIterator[str]:
        try:
            async with await self._open_agent(agent_id, model) as agent:
                run = await agent.send(message)

                async for chunk in run.iter_text():
                    if chunk:
                        yield _sse({"type": "text", "content": chunk})

                result = await run.wait()

                if result.status == "error":
                    yield _sse(
                        {
                            "type": "error",
                            "detail": f"Run failed: {result.id}",
                            "status": result.status,
                        }
                    )
                    return

                yield _sse(
                    {
                        "type": "done",
                        "agent_id": agent.agent_id,
                        "run_id": result.id,
                        "status": result.status,
                    }
                )
        except CursorAgentError as err:
            yield _sse(
                {
                    "type": "error",
                    "detail": err.message,
                    "retryable": err.is_retryable,
                }
            )


def _sse(payload: dict) -> str:
    return f"data: {json.dumps(payload)}\n\n"

import secrets

from fastapi import Depends, HTTPException, Security, status
from fastapi.security import APIKeyHeader

from app.config import Settings, get_settings

_api_key_header = APIKeyHeader(name="X-API-Key", auto_error=False)


async def require_api_key(
    key: str | None = Security(_api_key_header),
    settings: Settings = Depends(get_settings),
) -> None:
    """Reject requests without a valid API key from settings."""
    if not key or not secrets.compare_digest(key, settings.api_key):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or missing API key",
            headers={"WWW-Authenticate": "ApiKey"},
        )

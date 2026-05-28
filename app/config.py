from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict

PROJECT_ROOT = Path(__file__).resolve().parent.parent


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=PROJECT_ROOT / ".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    cursor_api_key: str
    api_key: str
    cursor_workspace: Path = PROJECT_ROOT
    cursor_model: str = "composer-2.5"
    host: str = "0.0.0.0"
    port: int = 8000
    environment: str = "development"

    @property
    def is_production(self) -> bool:
        return self.environment.lower() == "production"


def get_settings() -> Settings:
    return Settings()

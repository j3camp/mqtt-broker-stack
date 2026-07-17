from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, Field, field_validator


class LoginRequest(BaseModel):
    username: str = Field(min_length=1, max_length=255)
    password: str = Field(min_length=1, max_length=1024)


class ClientCreate(BaseModel):
    username: str = Field(pattern=r"^[A-Za-z0-9_.:@-]{1,128}$")
    password: str = Field(min_length=12, max_length=1024)
    clientid: str | None = Field(default=None, max_length=255)
    textname: str | None = Field(default=None, max_length=255)
    textdescription: str | None = Field(default=None, max_length=1024)


class PasswordRotate(BaseModel):
    password: str = Field(min_length=12, max_length=1024)


class NamedObject(BaseModel):
    name: str = Field(pattern=r"^[A-Za-z0-9_.:@-]{1,128}$")
    textname: str | None = Field(default=None, max_length=255)
    textdescription: str | None = Field(default=None, max_length=1024)


class Assignment(BaseModel):
    name: str = Field(pattern=r"^[A-Za-z0-9_.:@-]{1,128}$")
    priority: int = Field(default=-1, ge=-1, le=100000)


ACLType = Literal[
    "publishClientSend", "publishClientReceive", "subscribeLiteral",
    "subscribePattern", "unsubscribeLiteral", "unsubscribePattern",
]


class ACLCreate(BaseModel):
    acltype: ACLType
    topic: str = Field(min_length=1, max_length=65535)
    allow: bool
    priority: int = Field(default=-1, ge=-1, le=100000)
    elevated_confirmation: bool = False

    @field_validator("topic")
    @classmethod
    def validate_topic(cls, value: str) -> str:
        if "\x00" in value or "//" in value:
            raise ValueError("topic filter contains an invalid level")
        levels = value.split("/")
        for index, level in enumerate(levels):
            if "#" in level and (level != "#" or index != len(levels) - 1):
                raise ValueError("# must occupy the final topic level")
            if "+" in level and level != "+":
                raise ValueError("+ must occupy an entire topic level")
            if ("%u" in level or "%c" in level) and level not in {"%u", "%c"}:
                raise ValueError("%u and %c must occupy an entire topic level")
        return value


class PermissionQuery(BaseModel):
    username: str = Field(min_length=1, max_length=128)
    clientid: str = Field(default="", max_length=255)
    topic: str = Field(min_length=1, max_length=65535)
    action: ACLType


class AuditMetadata(BaseModel):
    before: dict[str, Any] | None = None
    after: dict[str, Any] | None = None


"""Event types for the OrbitAgents simulation event bus."""

from enum import Enum


class EventType(str, Enum):
    # Agent lifecycle
    AGENT_START  = "agent_start"
    AGENT_IDLE   = "agent_idle"
    AGENT_DONE   = "agent_done"
    AGENT_THOUGHT = "agent_thought"

    # Tool execution
    TOOL_CALL    = "tool_call"
    TOOL_RESULT  = "tool_result"

    # Trades
    TRADE        = "trade"

    # Oracle / market resolution
    PRICE_UPDATE = "price_update"
    NEWS_EVENT   = "news_event"

    # System
    STATUS       = "status"
    ERROR        = "error"

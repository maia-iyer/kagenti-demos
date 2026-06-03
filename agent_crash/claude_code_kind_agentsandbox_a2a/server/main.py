"""A2A server that bridges to Claude Code via claude-agent-sdk.

Each inbound A2A message/send is handed to query() with resume=<session_id>
so the conversation continues across requests. The session_id is persisted
to /root/.claude/a2a-session-id so it also survives pod restarts (the file
lives on the PVC mounted at /root/.claude).

Targets a2a-sdk 1.1.x (proto-backed types) and claude-agent-sdk 0.1.x.
"""

from __future__ import annotations

import os
from pathlib import Path

import uvicorn
from a2a import types as T
from a2a.server.agent_execution import AgentExecutor, RequestContext
from a2a.server.events import EventQueue
from a2a.server.request_handlers import DefaultRequestHandler
from a2a.server.routes import create_agent_card_routes, create_jsonrpc_routes
from a2a.server.tasks import InMemoryTaskStore, TaskUpdater
from claude_agent_sdk import (
    AssistantMessage,
    ClaudeAgentOptions,
    ResultMessage,
    TextBlock,
    query,
)
from starlette.applications import Starlette

SESSION_FILE = Path("/root/.claude/a2a-session-id")
WORKSPACE = "/workspace"


def load_session_id() -> str | None:
    if SESSION_FILE.exists():
        sid = SESSION_FILE.read_text().strip()
        return sid or None
    return None


def save_session_id(session_id: str) -> None:
    SESSION_FILE.parent.mkdir(parents=True, exist_ok=True)
    SESSION_FILE.write_text(session_id)


class ClaudeCodeAgentExecutor(AgentExecutor):
    async def execute(self, context: RequestContext, event_queue: EventQueue) -> None:
        updater = TaskUpdater(event_queue, context.task_id, context.context_id)
        await updater.start_work(
            message=updater.new_agent_message(
                parts=[T.Part(text="Forwarding to Claude Code...")]
            )
        )

        prompt = context.get_user_input() or ""
        if not prompt:
            await updater.complete(
                message=updater.new_agent_message(
                    parts=[T.Part(text="No text input provided.")]
                )
            )
            return

        resume_id = load_session_id()
        options = ClaudeAgentOptions(
            cwd=WORKSPACE,
            setting_sources=[],
            resume=resume_id,
        )

        collected: list[str] = []
        last_session_id: str | None = None
        final_result: str | None = None

        async for message in query(prompt=prompt, options=options):
            if isinstance(message, AssistantMessage):
                for block in message.content:
                    if isinstance(block, TextBlock):
                        collected.append(block.text)
            elif isinstance(message, ResultMessage):
                last_session_id = message.session_id
                final_result = message.result

        if last_session_id and last_session_id != resume_id:
            save_session_id(last_session_id)

        text = final_result or "".join(collected) or "(no text returned)"
        await updater.add_artifact(parts=[T.Part(text=text)], name="reply")
        await updater.complete()

    async def cancel(self, context: RequestContext, event_queue: EventQueue) -> None:
        raise NotImplementedError("cancel not supported")


def build_agent_card(host: str, port: int) -> T.AgentCard:
    skill = T.AgentSkill(
        id="claude_code",
        name="Claude Code",
        description=(
            "Run a Claude Code prompt against the pod's /workspace; "
            "session resumes across requests."
        ),
        tags=["claude-code", "kagenti", "agent-crash"],
        examples=[
            "Create notes.md with three sections.",
            "Add a Risks section after Open Questions.",
        ],
        input_modes=["text/plain"],
        output_modes=["text/plain"],
    )
    public_url = os.environ.get("A2A_PUBLIC_URL", f"http://{host}:{port}")
    return T.AgentCard(
        name="claude-code-a2a",
        description="Claude Code wrapped behind A2A, running in a Kagenti agent-sandbox.",
        version="0.1.0",
        default_input_modes=["text/plain"],
        default_output_modes=["text/plain"],
        capabilities=T.AgentCapabilities(streaming=False),
        supported_interfaces=[
            T.AgentInterface(protocol_binding="JSONRPC", url=public_url),
        ],
        skills=[skill],
    )


def main() -> None:
    host = os.environ.get("A2A_HOST", "0.0.0.0")
    port = int(os.environ.get("A2A_PORT", "8000"))
    agent_card = build_agent_card(host, port)
    handler = DefaultRequestHandler(
        agent_executor=ClaudeCodeAgentExecutor(),
        task_store=InMemoryTaskStore(),
        agent_card=agent_card,
    )
    routes = []
    routes.extend(create_agent_card_routes(agent_card))
    routes.extend(create_jsonrpc_routes(handler, "/"))
    app = Starlette(routes=routes)
    uvicorn.run(app, host=host, port=port)


if __name__ == "__main__":
    main()

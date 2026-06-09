FROM node:20-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python3-pip python3-venv ca-certificates \
 && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

ENV VIRTUAL_ENV=/opt/venv
RUN python3 -m venv "$VIRTUAL_ENV"
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

COPY server/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

COPY server /app/server
ENV PYTHONPATH=/app

# Run as a non-root user. Claude Code refuses --dangerously-skip-permissions
# (i.e. the SDK's permission_mode="bypassPermissions") as root.
# node:20-slim ships a `node` user at uid 1000 — reuse it instead of adding
# another (useradd would collide on the uid).
RUN mkdir -p /workspace /home/node/.claude \
 && chown -R node:node /workspace /home/node /app

ENV HOME=/home/node
USER 1000

WORKDIR /workspace

EXPOSE 8000

CMD ["python", "-m", "server.main"]

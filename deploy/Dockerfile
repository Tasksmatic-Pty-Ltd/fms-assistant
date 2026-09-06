# fms-assistant — the DeepSeek Harness web instance image.
#
# ONE image, TWO processes, each guarded separately by its own compose service
# (see docker-compose.assistant.yml): the harness web UI (:3080, default CMD)
# and the auth proxy (:3082, command override). A crash in either restarts
# only that service — no shared-container "one dies, both down" failure mode.
#
# The Rails app hosts the MCP server (POST /mcp); the harness connects via
# mcp-client (streamable-http). The agent preset has NO shell and NO file
# tools, so the MCP endpoint is the only data path — read-only, filtered by
# the employee's Ability server-side.
FROM node:22-slim

WORKDIR /app

# Pin the framework version — upgrade deliberately, verify against the current
# harness semantics first.
# dsh-files (vendored at custom-plugins/dsh-files, v0.4.1) pulls mammoth /
# pdfjs-dist / read-excel-file at runtime — pure JS, pinned to the versions
# verified against this dsh pin. They land in /app/node_modules, which the
# profile's module up-walk reaches; COPY custom-plugins/ below adds dsh-files
# itself. (npm runs BEFORE that COPY on purpose: npm prunes extraneous
# packages and would delete copied plugins installed earlier.)
RUN npm install --no-audit --no-fund @deepseek-ai/dsh@0.1.1-rc.2 mammoth@1.12.2 pdfjs-dist@4.10.38 read-excel-file@5.8.8

# Harness home (profile + hardened fms-employee preset), the auth proxy, and
# the custom plugins (CITO brand UI + workspace pin + vendored dsh-files). The
# plugins are copied into /app/node_modules so BOTH the loader (resolves from
# the profile dir via the up-walk) and the client-modules registry (dsh.client
# scan) can find them.
COPY harness/ ./harness/
COPY auth-proxy.js ./deploy/auth-proxy.js
COPY custom-plugins/ ./node_modules/

ENV DSH_HOME=/app/harness \
    DSH_PERMISSION_MODE=read-only

# Default: the harness itself. The compose auth-proxy service overrides
# command to run the proxy instead.
# The /api browser-trust fence must accept the PUBLIC origin the browser
# reaches the proxy at (e.g. 127.0.0.1:3082 locally, fms.example.com behind
# nginx) — otherwise every /api RPC is 403 Forbidden and the chat cannot open.
CMD ["sh", "-c", "npx dsh --profile assistant --port 3080 --trusted-host ${FMS_TRUSTED_HOST:-127.0.0.1:3082}"]

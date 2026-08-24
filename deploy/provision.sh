#!/usr/bin/env bash
# fms-assistant provisioning notes — run the Rails-side steps, then each
# employee mints their own MCP token in the FMS web UI.
#
# 1. Rails-side migrations (once, needs superuser DB):
#      bin/rails db:migrate
#
# 2. Enable LOGIN on the mcp_readonly DB role (once, per DB):
#      MCP_READONLY_PASSWORD=<强密码> bin/rails mcp:readonly_password
#    and put MCP_READONLY_DB_* (host/port/name/user/password) into the
#    RAILS deployment's environment — the read-only connection is opened by
#    the Rails app itself, not by the assistant container.
#
# 3. Per employee: they log into FMS → Settings → MCP access tokens → mint a
#    token (optionally expiring), and that token goes into the assistant
#    container's .env as FMS_MCP_TOKEN.
#
# 4. Deploy:
#      docker compose --env-file .env.employee -f docker-compose.assistant.yml up -d
#
# Revocation: the employee revokes the token in the same Settings page; the
# assistant instance loses access immediately (401 on every call).
echo "See the numbered steps in this script's header."

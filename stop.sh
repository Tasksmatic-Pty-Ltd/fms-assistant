#!/usr/bin/env bash
# fms-assistant stop (Linux/macOS) — 停止 harness + proxy。
# [d]sh / [a]uth-proxy 括号写法避免 pkill 匹配到自身命令行。
set -euo pipefail
pkill -f '[d]sh --profile assistant' 2>/dev/null || true
pkill -f '[a]uth-proxy.js' 2>/dev/null || true
echo "已停止（harness + proxy）"

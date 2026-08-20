#!/bin/bash
# {{COMMANDER_NAME}}エージェントチーム — 操作ログ記録
# PostToolUse で呼ばれ、全操作を .agents/logs/ に記録する

# Claude Code / Antigravity はフック情報を stdin の JSON で渡す（環境変数ではない）
INPUT=$(cat)

WORKSPACE_PATH=$(printf '%s' "$INPUT" | jq -r '.workspacePaths[0] // empty' 2>/dev/null)
LOG_DIR="${WORKSPACE_PATH:-${CLAUDE_PROJECT_DIR:-.}}/.agents/logs"
mkdir -p "$LOG_DIR"

LOG_FILE="$LOG_DIR/$(date '+%Y-%m-%d').jsonl"

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // .toolCall.name // "unknown"' 2>/dev/null)
TOOL_NAME="${TOOL_NAME:-unknown}"
TIMESTAMP=$(date '+%Y-%m-%dT%H:%M:%S')

# ツール入力からファイルパスやコマンドを抽出（軽量に）
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .toolCall.args.TargetFile // .tool_input.pattern // .toolCall.args.Pattern // .tool_input.command // .toolCall.args.CommandLine // empty' 2>/dev/null | head -c 200)

echo "{\"ts\":\"$TIMESTAMP\",\"tool\":\"$TOOL_NAME\",\"target\":\"$FILE_PATH\"}" >> "$LOG_FILE"

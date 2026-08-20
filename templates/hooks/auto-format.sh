#!/bin/bash
# {{COMMANDER_NAME}}エージェントチーム — 自動フォーマット
# PostToolUse(Write|Edit|MultiEdit) で呼ばれ、対象ファイルをフォーマットする

# Claude Code / Antigravity はフック情報を stdin の JSON で渡す（環境変数ではない）
INPUT=$(cat)
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .toolCall.args.TargetFile // empty' 2>/dev/null)

if [ -z "$FILE_PATH" ] || [ ! -f "$FILE_PATH" ]; then
  exit 0
fi

# Markdown ファイルはスキップ（.agents/ 内の設計書等）
if echo "$FILE_PATH" | grep -qE '\.(md|markdown)$'; then
  exit 0
fi

WORKSPACE_PATH=$(printf '%s' "$INPUT" | jq -r '.workspacePaths[0] // empty' 2>/dev/null)
PROJECT_DIR="${WORKSPACE_PATH:-${CLAUDE_PROJECT_DIR:-.}}"

# prettier が利用可能ならフォーマット
if [ -f "$PROJECT_DIR/node_modules/.bin/prettier" ]; then
  "$PROJECT_DIR/node_modules/.bin/prettier" --write "$FILE_PATH" 2>/dev/null
elif command -v npx >/dev/null 2>&1 && [ -f "$PROJECT_DIR/package.json" ]; then
  npx --no-install prettier --write "$FILE_PATH" 2>/dev/null
fi

exit 0

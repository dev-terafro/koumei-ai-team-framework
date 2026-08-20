#!/bin/bash
# {{COMMANDER_NAME}}エージェントチーム — 品質ゲート
# PreToolUse(Write|Edit) で呼ばれ、重要ファイルの直接編集をブロック
#
# ブロック対象:
#   - .agents/TEAM.md（チーム設定は koumei.config.yaml 編集 + setup.sh --update で再生成する）

# Claude Code / Antigravity はフック情報を stdin の JSON で渡す（環境変数ではない）
INPUT=$(cat)
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .toolCall.args.TargetFile // empty' 2>/dev/null)

if [ -z "$FILE_PATH" ]; then
  exit 0
fi

# TEAM.md の直接編集をブロック（設定変更は config 編集 → setup.sh --update）
if echo "$FILE_PATH" | grep -qE '\.agents/TEAM\.md$'; then
  echo "⚠️ .agents/TEAM.md は生成ファイルです。koumei.config.yaml を編集して setup.sh --update で再生成してください。" >&2
  exit 2
fi

exit 0

#!/bin/bash
# {{COMMANDER_NAME}}エージェントチーム — フェーズ完了通知
# PostToolUse(Write) で呼ばれ、成果物ファイルの書き込みを検知して通知

# Claude Code / Antigravity はフック情報を stdin の JSON で渡す（環境変数ではない）
INPUT=$(cat)
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .toolCall.args.TargetFile // empty' 2>/dev/null)

if [ -z "$FILE_PATH" ]; then
  exit 0
fi

NOTIFY_MSG=""

# deliverables（成果物）への書き込みを検知
if echo "$FILE_PATH" | grep -qE '\.agents/.*/deliverables/'; then
  ROLE=$(echo "$FILE_PATH" | sed -E 's|.*\.agents/([^/]+)/deliverables/.*|\1|')
  NOTIFY_MSG="{{COMMANDER_NAME}}チーム: ${ROLE} の成果物が完成しました"
fi

# reviews（レビュー結果）への書き込みを検知
if echo "$FILE_PATH" | grep -qE '\.agents/devils-advocate/reviews/'; then
  NOTIFY_MSG="{{COMMANDER_NAME}}チーム: レビューが完了しました"
fi

# reports（最終報告）への書き込みを検知
if echo "$FILE_PATH" | grep -qE '\.agents/koumei/reports/'; then
  NOTIFY_MSG="{{COMMANDER_NAME}}チーム: フェーズ完了報告が提出されました"
fi

if [ -n "$NOTIFY_MSG" ]; then
  osascript -e "display notification \"$NOTIFY_MSG\" with title \"{{COMMANDER_NAME}}\"" 2>/dev/null || true
fi

exit 0

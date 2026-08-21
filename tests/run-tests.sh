#!/bin/bash
# ============================================================
# koumei-ai-team-framework 自動テストスイート
# ============================================================
# 使い方: bash tests/run-tests.sh
# 依存: bash, perl, jq, git（yq は任意 — 無い環境では awk フォールバック経路を検証）
# ============================================================

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SETUP="${REPO_DIR}/setup.sh"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

PASS=0
FAIL=0
FAILED_TESTS=()

ok()   { PASS=$((PASS+1)); echo "  ✅ $1"; }
ng()   { FAIL=$((FAIL+1)); FAILED_TESTS+=("$1"); echo "  ❌ $1"; }
assert() {
  # assert <説明> <コマンド...>（成功で pass）
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else ng "$desc"; fi
}
assert_not() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ng "$desc"; else ok "$desc"; fi
}

# テスト用プロジェクトを作る（config は example ベース + sed 変換）
make_project() {
  local dir="$1"; shift
  mkdir -p "$dir" && cd "$dir"
  git init -q
  git config user.email "test@test.local"
  git config user.name "test"
  if [[ $# -gt 0 ]]; then
    sed "$(printf '%s;' "$@")" "${REPO_DIR}/koumei.config.example.yaml" > koumei.config.yaml
  else
    cp "${REPO_DIR}/koumei.config.example.yaml" koumei.config.yaml
  fi
}

echo "=========================================="
echo " koumei-ai-team-framework test suite"
echo " yq: $(command -v yq >/dev/null && echo あり || echo なし（awkフォールバック経路）)"
echo "=========================================="

# ------------------------------------------------------------
echo ""
echo "[T1] 構文チェック"
assert "setup.sh の bash 構文" bash -n "$SETUP"
for f in "${REPO_DIR}"/templates/hooks/*.sh; do
  assert "$(basename "$f") の bash 構文" bash -n "$f"
done
assert "settings.json が正しい JSON" jq empty "${REPO_DIR}/templates/claude/settings.json"
assert "hooks.json が正しい JSON" jq empty "${REPO_DIR}/templates/agents/hooks.json"

# ------------------------------------------------------------
echo ""
echo "[T2] プレースホルダ供給監査"
missing_placeholders=$(
  grep -rhoE '\{\{[A-Z_0-9]+\}\}' "${REPO_DIR}/templates" | sort -u | sed 's/[{}]//g' | \
  while read -r v; do
    grep -q "KOUMEI_VAR_${v}=" "$SETUP" || grep -q "vars_dir}/${v}\"" "$SETUP" || echo "$v"
  done
)
if [[ -z "$missing_placeholders" ]]; then
  ok "全プレースホルダが setup.sh から供給されている"
else
  ng "未供給プレースホルダ: $(echo "$missing_placeholders" | tr '\n' ' ')"
fi

# ------------------------------------------------------------
echo ""
echo "[T3] 条件ブロック整合"
cond_errors=""
while IFS= read -r f; do
  opens=$(grep -cE '\{\{#IF_[A-Z_]+([ }])' "$f" || true)
  closes=$(grep -cE '\{\{/IF_[A-Z_]+\}\}' "$f" || true)
  [[ "$opens" != "$closes" ]] && cond_errors+="${f#"$REPO_DIR"/}(open=$opens close=$closes) "
done < <(find "${REPO_DIR}/templates" -name '*.tmpl')
if [[ -z "$cond_errors" ]]; then
  ok "全テンプレートで {{#IF_*}} と {{/IF_*}} の数が一致"
else
  ng "条件ブロック不整合: $cond_errors"
fi
# 使用されている条件タイプが process_conditions に実装されているか
used_types=$(grep -rhoE '\{\{#(IF_[A-Z_]+)' "${REPO_DIR}/templates" --include='*.tmpl' | sed 's/{{#//' | sort -u)
for t in $used_types; do
  base_type="${t%% *}"
  assert "条件タイプ ${base_type} が実装済み" grep -q "$base_type" "$SETUP"
done
# IF_CLI の引数が既知の3値のみか（typo・複数値指定は正規表現の仕様上マッチせず、
# 該当ブロックが全ターゲットに常時出力される、または黙って消えるバグになるため検知する）
bad_cli_tags=""
while IFS= read -r cli_val; do
  [[ -z "$cli_val" ]] && continue
  case "$cli_val" in
    claude|codex|antigravity) ;;
    *) bad_cli_tags+="[$cli_val] " ;;
  esac
done < <(grep -rhoE '\{\{#IF_CLI[[:space:]]+[^}]+\}\}' "${REPO_DIR}/templates" --include='*.tmpl' | sed -E 's/\{\{#IF_CLI[[:space:]]+([^}]+)\}\}/\1/')
if [[ -z "$bad_cli_tags" ]]; then
  ok "IF_CLI の引数はすべて既知の3値（claude/codex/antigravity）"
else
  ng "未知のIF_CLI値（typoまたは複数値指定の可能性）: $bad_cli_tags"
fi

# ------------------------------------------------------------
echo ""
echo "[T4] 生成: claude / コアロールのみ（デフォルト設定）"
make_project "$WORK_DIR/t4"
bash "$SETUP" > setup.log 2>&1 || ng "setup.sh 実行 (log: $(tail -3 setup.log | tr '\n' ' '))"
assert "TEAM.md 生成" test -f .agents/TEAM.md
assert "koumei ロール生成" test -f .agents/koumei/CLAUDE.md
assert "devils-advocate ロール生成" test -f .agents/devils-advocate/CLAUDE.md
assert "task-manager 生成（claude限定機能）" test -f .agents/task-manager/CLAUDE.md
assert_not "analyst は未生成（ロール無効）" test -d .agents/analyst
assert_not "analyze スキルは未生成" test -d .claude/skills/koumei-analyze
assert_not "inquisitor は未生成（ロール無効）" test -d .agents/inquisitor
assert_not "grill スキルは未生成" test -d .claude/skills/koumei-grill
assert "start スキル + docs 生成" test -f .claude/skills/koumei-start/docs/phases.md
assert "review スキル + docs 生成" test -f .claude/skills/koumei-review/docs/extended-modes.md
assert "hooks 4本配布" test "$(ls hooks/*.sh | wc -l)" -eq 4
assert "settings.json 配布" test -f .claude/settings.json
assert "matcher がスラッシュなし形式" grep -q '"Write|Edit|MultiEdit"' .claude/settings.json
assert_not "未解決プレースホルダなし" grep -rqE '\{\{[A-Z_0-9]+\}\}' .agents .claude hooks
assert_not "check_command 空 → lint ゲート節なし" grep -q "Lint/Format チェック" .claude/skills/koumei-implement/SKILL.md
assert "TEAM.md に analyst 行なし（IF_ROLE）" test "$(grep -c 'システム分析担当' .agents/TEAM.md)" -eq 0
assert "TEAM.md に inquisitor 行なし（IF_ROLE）" test "$(grep -c '諫議大夫' .agents/TEAM.md)" -eq 0
assert_not "inquisitor 無効時は Phase 2.5 の記述が漏れない" grep -rq "Phase 2.5" .claude/skills
assert_not "inquisitor 無効時は design-brief 参照が漏れない" grep -rq "design-brief" .claude/skills .agents
assert "inquisitor 無効時のスキップ表は 3,4 のまま" grep -q "Phase 3,4をスキップ" .claude/skills/koumei-start/docs/rules.md
assert_not "scribe は未生成（ロール無効）" test -d .agents/scribe
assert_not "condense スキルは未生成" test -d .claude/skills/koumei-condense
assert "TEAM.md に主簿の行なし（IF_ROLE）" test "$(grep -c '主簿' .agents/TEAM.md)" -eq 0
assert "scribe 無効時もガードレール検査は残る" grep -q "フェーズ完了時の検査" .claude/skills/koumei-start/docs/phases.md
assert "scribe 無効時は指揮者が自ら再編" grep -q "自ら再編してよい" .claude/skills/koumei-start/docs/phases.md
assert "phases.md に単騎駆けモード" grep -q "単騎駆けモード（軽微修正のみ）" .claude/skills/koumei-start/docs/phases.md
assert "rules.md に単騎駆けの節" grep -q "単騎駆け（軽微修正の単独実行）" .claude/skills/koumei-start/docs/rules.md
assert "スキップ表の軽微修正が単騎駆けに切替" grep -q "5(\*\*単騎駆け\*\*)" .claude/skills/koumei-start/docs/rules.md
assert "参照ドキュメント空 → （登録なし）" grep -q "（登録なし）" .agents/TEAM.md
assert "Phase 7 にドキュメント反映ステップ" grep -q "requirements-spec-design.md" .claude/skills/koumei-start/docs/phases.md
assert "claude ターゲットでは Agent tool 記述が残る（IF_CLI誤爆なし）" grep -q "Agent tool" .claude/skills/koumei-start/docs/phases.md
assert "multi-task.md は claude ターゲットで生成される" test -f .claude/skills/koumei-start/docs/multi-task.md
assert "claude ターゲットでは AskUserQuestion 記述が残る（IF_CLI誤爆なし）" grep -q "AskUserQuestion" .claude/skills/koumei-start/SKILL.md
assert "claude ターゲットでは description にマルチタスク記載が残る" grep -q "マルチタスク" .claude/skills/koumei-start/SKILL.md
assert "claude ターゲットでは rules.md の task-manager 説明が残る" grep -q "マルチタスクモードの実行単位" .claude/skills/koumei-start/docs/rules.md
assert "TEAM.md に2層構成の説明" grep -q "requirements-spec-design.md" .agents/TEAM.md
assert "SKILL.md の Phase表もドキュメント反映を明記" grep -q "ドキュメント反映 + PR作成" .claude/skills/koumei-start/SKILL.md
assert "task-template のチェックリストも同期" grep -q "Phase 7: ドキュメント反映 + PR作成" .claude/skills/koumei-start/docs/task-template.md

# ------------------------------------------------------------
echo ""
echo "[T5] 生成: claude / フル設定（全ロール・km prefix・指揮者名変更・check_command）"
make_project "$WORK_DIR/t5" \
  's/^skill_prefix: "koumei"/skill_prefix: "km"/' \
  's/^  # - analyst.*/  - analyst/' \
  's/^  # - inquisitor.*/  - inquisitor/' \
  's/^  # - ux-designer.*/  - ux-designer/' \
  's/^  # - scribe.*/  - scribe/' \
  's/^  name: "諸葛孔明"/  name: "臥龍"/' \
  's/^  check_command: ""\(.*\)$/  check_command: "npm run check"/'
bash "$SETUP" > setup.log 2>&1 || ng "setup.sh 実行"
assert "スキルが km- プレフィックス" test -d .claude/skills/km-start
assert_not "koumei- 残存なし" grep -rq "koumei-" .claude/skills .agents
assert "frontmatter name も km-" grep -q "name: km-start" .claude/skills/km-start/SKILL.md
assert "docs 内パスも km- 解決" grep -q ".claude/skills/km-analyze" .claude/skills/km-start/docs/phases.md
assert "指揮者名が TEAM.md に反映" grep -q "臥龍 (koumei)" .agents/TEAM.md
assert "通知フックにも指揮者名反映" grep -q "臥龍" hooks/notify-phase.sh
assert_not "孔明の残存なし（ペルソナモデル説明を除く）" grep -rq "孔明" hooks .claude/skills
assert "check_command ゲートあり" grep -q "npm run check" .claude/skills/km-implement/SKILL.md
assert "analyst ロール生成" test -f .agents/analyst/CLAUDE.md
assert "design スキル生成（ux有効）" test -d .claude/skills/km-design
# --- inquisitor（Phase 2.5 詰問） ---
assert "inquisitor ロール生成" test -f .agents/inquisitor/CLAUDE.md
assert "inquisitor ワークスペース生成" test -d .agents/inquisitor/deliverables
assert "grill スキル生成" test -f .claude/skills/km-grill/SKILL.md
assert "TEAM.md に諫議大夫の行" grep -q "諫議大夫" .agents/TEAM.md
assert "TEAM.md のスキル一覧に km-grill" grep -q "km-grill" .agents/TEAM.md
assert "inquisitor の既定モデルは fable" grep -qE '\| \*\*諫議大夫\*\* \|.*\*\*fable\*\* \|' .agents/TEAM.md
assert "phases.md に Phase 2.5" grep -q "Phase 2.5: 詰問" .claude/skills/km-start/docs/phases.md
assert "SKILL.md の Phase表に 2.5 行" grep -q "詰問（grilling）" .claude/skills/km-start/SKILL.md
assert "task-template に Phase 2.5 チェック項目" grep -q "Phase 2.5: 詰問" .claude/skills/km-start/docs/task-template.md
assert "スキップ表が 2.5 込みに切替" grep -q "Phase 2.5,3,4をスキップ" .claude/skills/km-start/docs/rules.md
assert "grilling.max_rounds が展開されている" grep -q "最大 \*\*3\*\* ラウンド" .claude/skills/km-grill/SKILL.md
assert "grilling.escalate が展開されている" grep -q 'エスカレーション方針: \*\*`high`\*\*' .claude/skills/km-grill/SKILL.md
assert "設計スキルが design-brief を入力に取る" grep -q "design-brief" .claude/skills/km-design/SKILL.md
assert "design-tech も design-brief を参照" grep -q "design-brief" .claude/skills/km-design-tech/SKILL.md
assert "design-ux も design-brief を参照" grep -q "design-brief" .claude/skills/km-design-ux/SKILL.md
assert "devils-advocate に design-brief 突合観点" grep -q "設計前ブリーフ（design-brief）との突合" .agents/devils-advocate/CLAUDE.md
assert "分析成果物の観点が重複していない" test "$(grep -c '^### 分析成果物' .agents/devils-advocate/CLAUDE.md)" -eq 1
assert "rules.md に詰問の役割分離ルール" grep -q "問う者と答える者を分ける" .claude/skills/km-start/docs/rules.md
assert "status が grill を次アクションに提案" grep -q "km-grill" .claude/skills/km-status/SKILL.md
# --- scribe（主簿・圧縮構造化） ---
assert "scribe ロール生成" test -f .agents/scribe/CLAUDE.md
assert "scribe ワークスペース生成" test -d .agents/scribe/instructions
assert "condense スキル生成" test -f .claude/skills/km-condense/SKILL.md
assert "TEAM.md に主簿の行" grep -q "主簿" .agents/TEAM.md
assert "scribe の既定モデルは sonnet" grep -qE '\| \*\*主簿\*\* \|.*sonnet \|' .agents/TEAM.md
assert "ガードレールが scribe 起動に切替" grep -q "scribe（主簿）を起動して再編" .claude/skills/km-start/docs/phases.md
assert "token-economy.md が condense を案内" grep -q "km-condense" .claude/skills/km-start/docs/token-economy.md
assert "condense スキルの節参照が km 解決" grep -q ".agents/scribe/CLAUDE.md" .claude/skills/km-condense/SKILL.md

# ------------------------------------------------------------
echo ""
echo "[T6] 生成: codex ターゲット"
make_project "$WORK_DIR/t6" 's/^target_cli: "claude"/target_cli: "codex"/' 's/^  # - inquisitor.*/  - inquisitor/'
bash "$SETUP" > setup.log 2>&1 || ng "setup.sh 実行"
assert "スキルは .codex/skills に配置" test -d .codex/skills/koumei-start
assert "ロール定義は AGENTS.md" test -f .agents/koumei/AGENTS.md
assert_not "hooks 未配布" test -d hooks
assert_not "settings.json 未配布" test -f .claude/settings.json
assert_not "task-manager 未配布" test -d .agents/task-manager
assert_not "claude固有frontmatterなし" grep -q "disable-model-invocation" .codex/skills/koumei-start/SKILL.md
assert "docs 内パスが .codex/skills" grep -q ".codex/skills/koumei-analyze" .codex/skills/koumei-start/docs/phases.md
assert "ロール参照が AGENTS.md" grep -q "agents/koumei/AGENTS.md" .codex/skills/koumei-start/SKILL.md
assert_not "TEAM.md にマルチタスク節なし" grep -q "マルチタスク実行" .agents/TEAM.md
assert_not "multi-task.md 未生成（claude限定機能）" test -f .codex/skills/koumei-start/docs/multi-task.md
assert_not "実行手順書に Agent tool 参照なし（Claude Code固有機構、issue#13）" grep -rq "Agent tool" .codex/skills
assert_not "実行手順書に AskUserQuestion 参照なし（Claude Code固有機構）" grep -rq "AskUserQuestion" .codex/skills
assert_not "description にマルチタスクモード記載なし" grep -q "マルチタスク" .codex/skills/koumei-start/SKILL.md
assert_not "rules.md の task-manager 説明にマルチタスクモード記載なし" grep -q "マルチタスクモード" .codex/skills/koumei-start/docs/rules.md
assert_not "modelパラメータ表記なし（issue#13の取り残し検出）" grep -q '`model` パラメータ' .codex/skills/koumei-start/SKILL.md
# inquisitor 有効下での cross-CLI 検査。grill スキルには IF_CLI claude ブロックが複数あり、
# 生成されなければ上の再帰 grep 群が空振りする（issue#13 と同じ穴）
assert "grill スキルが生成されている（上の再帰grepを空振りさせない）" test -f .codex/skills/koumei-grill/SKILL.md
assert "inquisitor ロール定義は AGENTS.md" test -f .agents/inquisitor/AGENTS.md
assert_not "grill: claude固有frontmatterなし" grep -qE 'allowed-tools|disable-model-invocation|argument-hint' .codex/skills/koumei-grill/SKILL.md
assert_not "grill: subagent_type 参照なし" grep -q "subagent_type" .codex/skills/koumei-grill/SKILL.md
assert "grill: ロール参照が AGENTS.md" grep -q "agents/inquisitor/AGENTS.md" .codex/skills/koumei-grill/SKILL.md
assert_not "grill: CLAUDE.md 参照が残っていない" grep -q "inquisitor/CLAUDE.md" .codex/skills/koumei-grill/SKILL.md

# ------------------------------------------------------------
echo ""
echo "[T7] 生成: antigravity ターゲット"
make_project "$WORK_DIR/t7" 's/^target_cli: "claude"/target_cli: "antigravity"/' 's/^  # - inquisitor.*/  - inquisitor/'
bash "$SETUP" > setup.log 2>&1 || ng "setup.sh 実行"
assert "スキルは .agents/skills に配置" test -d .agents/skills/koumei-start
assert "ロール定義は AGENTS.md" test -f .agents/koumei/AGENTS.md
assert "hooks が配布されている" test -d hooks
assert "hooks.json が生成されている" test -f .agents/hooks.json
assert "task-manager が生成されている" test -f .agents/task-manager/AGENTS.md
assert "multi-task.md が生成されている" test -f .agents/skills/koumei-start/docs/multi-task.md
assert_not "実行手順書に Agent tool 参照なし（Claude Code固有機構、issue#13）" grep -rq "Agent tool" .agents/skills
assert_not "実行手順書に AskUserQuestion 参照なし（Claude Code固有機構）" grep -rq "AskUserQuestion" .agents/skills
assert "grill スキルが生成されている（上の再帰grepを空振りさせない）" test -f .agents/skills/koumei-grill/SKILL.md
assert_not "grill: claude固有frontmatterなし" grep -qE 'allowed-tools|disable-model-invocation|argument-hint' .agents/skills/koumei-grill/SKILL.md
assert_not "grill: subagent_type 参照なし" grep -q "subagent_type" .agents/skills/koumei-grill/SKILL.md
assert "grill: ロール参照が AGENTS.md" grep -q "agents/inquisitor/AGENTS.md" .agents/skills/koumei-grill/SKILL.md

# ------------------------------------------------------------
echo ""
echo "[T8] hooks 実動作（stdin JSON インターフェース）"
cd "$WORK_DIR/t4"
out=$(echo '{"tool_name":"Write","tool_input":{"file_path":".agents/TEAM.md"}}' | bash hooks/quality-gate.sh 2>&1; echo "exit=$?")
assert "quality-gate: TEAM.md をブロック (exit 2)" grep -q "exit=2" <<<"$out"
out=$(echo '{"tool_name":"Write","tool_input":{"file_path":"src/app.ts"}}' | bash hooks/quality-gate.sh 2>&1; echo "exit=$?")
assert "quality-gate: 通常ファイルは許可 (exit 0)" grep -q "exit=0" <<<"$out"
echo '{"tool_name":"Bash","tool_input":{"command":"npm test"}}' | CLAUDE_PROJECT_DIR="$PWD" bash hooks/log-operation.sh
assert "log-operation: tool_name を記録" grep -q '"tool":"Bash"' .agents/logs/*.jsonl
assert "log-operation: command を記録" grep -q '"target":"npm test"' .agents/logs/*.jsonl
out=$(echo '{"tool_name":"Write","tool_input":{"file_path":"design.md"}}' | bash hooks/auto-format.sh; echo "exit=$?")
assert "auto-format: .md はスキップして正常終了" grep -q "exit=0" <<<"$out"

# Antigravity 形式の stdin JSON テスト
out=$(echo '{"toolCall":{"name":"write_to_file","args":{"TargetFile":".agents/TEAM.md"}},"workspacePaths":["'$PWD'"]}' | bash hooks/quality-gate.sh 2>&1; echo "exit=$?")
assert "quality-gate (Antigravity): TEAM.md をブロック (exit 2)" grep -q "exit=2" <<<"$out"
out=$(echo '{"toolCall":{"name":"write_to_file","args":{"TargetFile":"src/index.ts"}},"workspacePaths":["'$PWD'"]}' | bash hooks/quality-gate.sh 2>&1; echo "exit=$?")
assert "quality-gate (Antigravity): 通常ファイルは許可 (exit 0)" grep -q "exit=0" <<<"$out"
echo '{"toolCall":{"name":"run_command","args":{"CommandLine":"pytest"}},"workspacePaths":["'$PWD'"]}' | bash hooks/log-operation.sh
assert "log-operation (Antigravity): toolCall.name を記録" grep -q '"tool":"run_command"' .agents/logs/*.jsonl
assert "log-operation (Antigravity): CommandLine を記録" grep -q '"target":"pytest"' .agents/logs/*.jsonl

# ------------------------------------------------------------
echo ""
echo "[T9] --update と差分検知"
cd "$WORK_DIR/t4"
assert "完全な config で --update 成功" bash "$SETUP" --update
# 旧スキーマ（新キー欠落）config
make_project "$WORK_DIR/t9"
perl -i -ne 'print unless /tech-lead-design|tech-lead-implement|devils-advocate: "fable"/' koumei.config.yaml
out=$(bash "$SETUP" --update 2>&1; echo "exit=$?")
assert "欠落キーを検知して停止 (exit 1)" grep -q "exit=1" <<<"$out"
assert "欠落キー名を報告" grep -q "tech-lead-design" <<<"$out"
assert "--reconfig を案内" grep -q "reconfig" <<<"$out"

# ------------------------------------------------------------
echo ""
echo "[T10] TEAM.md の強制再生成（コミット済みでも config 変更が反映）"
cd "$WORK_DIR/t4"
git add .agents/TEAM.md koumei.config.yaml && git commit -qm "commit team"
perl -i -pe 's/^  koumei: "sonnet"/  koumei: "opus"/' koumei.config.yaml
bash "$SETUP" --update > /dev/null 2>&1
assert "コミット済み TEAM.md にモデル変更が反映" grep -q "全体統括、タスク分割、指示出し、最終判断 | opus" .agents/TEAM.md

# ------------------------------------------------------------
echo ""
echo "[T11] --clean（ユーザーファイル温存・非空 hooks でも正常終了）"
cd "$WORK_DIR/t5"
touch hooks/user-own-hook.sh
out=$(bash "$SETUP" --clean 2>&1; echo "exit=$?")
assert "--clean が正常終了" grep -q "exit=0" <<<"$out"
assert_not ".agents が削除されている" test -d .agents
assert "ユーザー自作フックは温存" test -f hooks/user-own-hook.sh
assert_not "フレームワークのフックは削除" test -f hooks/quality-gate.sh

# ------------------------------------------------------------
echo ""
echo "[T12] レガシーレイアウト検出"
make_project "$WORK_DIR/t12"
mkdir -p .agents/commander/requests .claude/skills/koumei-run
touch .claude/skills/koumei-run/SKILL.md
out=$(bash "$SETUP" 2>&1)
assert "廃止済み koumei-run を自動削除" grep -q "廃止された旧スキル" <<<"$out"
assert_not "koumei-run が消えている" test -d .claude/skills/koumei-run
assert "旧ワークスペースを警告" grep -q "旧レイアウトのワークスペース" <<<"$out"
assert "旧ワークスペースは削除しない（成果物保護）" test -d .agents/commander

# ------------------------------------------------------------
echo ""
echo "[T13] タスク定義の欠落検査（文書配布と検出スクリプトの実動作）"

# --- 文書がロール構成に関わらず配布されるか（scribe 限定ブロックへの混入を防ぐ） ---
for sc in on off; do
  if [[ "$sc" == on ]]; then
    make_project "$WORK_DIR/t13-$sc" 's/^  # - scribe.*/  - scribe/'
  else
    make_project "$WORK_DIR/t13-$sc"
  fi
  bash "$SETUP" > setup.log 2>&1 || ng "setup.sh 実行 (scribe=$sc)"
  assert "scribe=$sc: phases.md に欠落検査の節" grep -q "タスク定義の欠落検査" .claude/skills/koumei-start/docs/phases.md
  assert "scribe=$sc: rules.md に保全ルール" grep -q "タスク定義の保全" .claude/skills/koumei-start/docs/rules.md
  assert "scribe=$sc: error-handling.md に復旧手順" grep -q "記録が欠落していた場合" .claude/skills/koumei-start/docs/error-handling.md
  assert "scribe=$sc: worktree の在り処を git に問う" grep -q "git worktree list --porcelain" .claude/skills/koumei-start/docs/phases.md
  assert_not "scribe=$sc: worktree パスの決め打ちが残っていない" grep -q 'ROOT"/.claude/worktrees/\*' .claude/skills/koumei-start/docs/phases.md
  assert "scribe=$sc: 素性による処置の書き分けがある" grep -q "差し戻してはならない" .claude/skills/koumei-start/docs/phases.md
  assert "scribe=$sc: 復旧手順が素性の確認を先に命じる" grep -q "素性を確かめる" .claude/skills/koumei-start/docs/error-handling.md
  assert "scribe=$sc: 基準を --git-common-dir から求める" grep -q "git-common-dir" .claude/skills/koumei-start/docs/phases.md
  assert_not "scribe=$sc: --show-toplevel を基準に使っていない" grep -q '^MAIN=$(git rev-parse --show-toplevel)' .claude/skills/koumei-start/docs/phases.md
done

# --- 検出スクリプトの実動作。生成物から抜き出してそのまま走らせる ---
CHK="$WORK_DIR/stray-check.sh"
awk '/^MAIN=\$\(dirname/,/^else rm -f "\$STRAY" "\$INFO"/' \
  "$WORK_DIR/t13-on/.claude/skills/koumei-start/docs/phases.md" > "$CHK"
assert "検査スクリプトを生成物から抽出できる" test -s "$CHK"

# 検査用リポジトリを作る: mkfix <名前> → $WORK_DIR/f-<名前>
mkfix() {
  local d="$WORK_DIR/f-$1"
  mkdir -p "$d/.agents/koumei/tasks"; cd "$d"
  git init -q; git config user.email t@t.local; git config user.name t
  printf 'x\n' > seed; git add -A; git commit -qm init
  echo "$d"
}
# run_chk <dir> [set-e]  → 出力と exit を "exit=N" 付きで返す
run_chk() {
  local d="$1"; local prefix=""
  [[ "${2:-}" == "set-e" ]] && prefix="set -e"
  ( cd "$d" && { [[ -n "$prefix" ]] && echo "$prefix"; cat "$CHK"; } > _r.sh && sh _r.sh 2>&1; echo "exit=$?" )
}
# run_chk_at <走らせる場所> <スクリプト置き場>  → 場所を変えて同じ検査を走らせる
run_chk_at() {
  ( cd "$1" && cp "$CHK" _r.sh && sh _r.sh 2>&1; echo "exit=$?" )
}

# (1) worktree 無し → 迷子なし・exit 0
d=$(mkfix none)
out=$(run_chk "$d")
assert "worktree 無し: 迷子なしと報告" grep -q "迷子なし" <<<"$out"
assert "worktree 無し: exit 0" grep -q "exit=0" <<<"$out"

# (2) 迷子あり → 検出・exit 1。かつ set -e 下でも黙って止まらない
d=$(mkfix stray); cd "$d"
git worktree add -q wtA -b bA; git worktree add -q wtB -b bB
mkdir -p wtA/.agents/koumei/tasks wtB/.agents/koumei/tasks
printf '# T1\n共通行\n' > .agents/koumei/tasks/task-1.md
printf '# T2\n共通行\n' > .agents/koumei/tasks/task-2.md
printf '# T1\n共通行\n' > wtA/.agents/koumei/tasks/task-1.md
printf '# T2\n共通行\n失われた記録\n' > wtB/.agents/koumei/tasks/task-2.md
out=$(run_chk "$d")
assert "迷子あり: 検出する" grep -q "未コミットの記録" <<<"$out"
assert "迷子あり: exit 1" grep -q "exit=1" <<<"$out"
out=$(run_chk "$d" set-e)
assert "set -e 下でも迷子を報告する（清浄ファイルで中断しない）" grep -q "未コミットの記録" <<<"$out"

# (3) .claude/worktrees 以外に作られた worktree も捕捉する
d=$(mkfix outside); cd "$d"
git worktree add -q ../f-outside-wt -b bo
mkdir -p ../f-outside-wt/.agents/koumei/tasks
printf '# T1\n' > .agents/koumei/tasks/task-1.md
printf '# T1\n裁定9箇条\n' > ../f-outside-wt/.agents/koumei/tasks/task-1.md
out=$(run_chk "$d")
assert "決め打ち外の worktree も捕捉する" grep -q "未コミットの記録" <<<"$out"

# (4) 定型行のみで構成された迷子も見逃さない（多重集合で照合しているか）
d=$(mkfix dup); cd "$d"
git worktree add -q wt -b w; mkdir -p wt/.agents/koumei/tasks
printf '# T1\n## Phase 4\n- [x] 完了\n判定: APPROVED\n' > .agents/koumei/tasks/task-1.md
printf '# T1\n## Phase 4\n- [x] 完了\n判定: APPROVED\n- [x] 完了\n判定: APPROVED\n' > wt/.agents/koumei/tasks/task-1.md
out=$(run_chk "$d")
assert "既出の定型行だけの迷子も検出する" grep -q "未コミットの記録 2 行" <<<"$out"

# (5) 畳み込み後に本体へ追記された記録を誤検出しない（本体∪原本で照合しているか）
d=$(mkfix folded); cd "$d"
git worktree add -q wt -b w; mkdir -p wt/.agents/koumei/tasks
printf '# T1\n## Phase 4\n判定A\n' > .agents/koumei/tasks/task-1-full.md
printf '# T1\n（要約）\n## Phase 5\n実装記録X\n' > .agents/koumei/tasks/task-1.md
printf '# T1\n## Phase 4\n判定A\n## Phase 5\n実装記録X\n' > wt/.agents/koumei/tasks/task-1.md
out=$(run_chk "$d")
assert "畳み込み後の追記を偽陽性にしない" grep -q "迷子なし" <<<"$out"

# (6) 本体にタスク定義が無い場合は別文言で警告する
d=$(mkfix missing); cd "$d"
git worktree add -q wt -b w; mkdir -p wt/.agents/koumei/tasks
printf '# T1\n記録\n' > wt/.agents/koumei/tasks/task-1.md
out=$(run_chk "$d")
assert "本体に無いタスク定義を警告する" grep -q "本体に存在しないタスク定義" <<<"$out"

# (7) 未コミットの迷子は差し戻し要として報じ、exit 1 になる
d=$(mkfix uncommitted); cd "$d"
printf '# T1\n初期\n' > .agents/koumei/tasks/task-1.md
git add -A; git commit -qm base
git worktree add -q wt -b w
printf '## Phase 4 判定\n裁定9箇条\n' >> wt/.agents/koumei/tasks/task-1.md
out=$(run_chk "$d")
assert "未コミットの迷子を差し戻し要として報じる" grep -q "未コミットの記録 2 行（差し戻し要）" <<<"$out"
assert "未コミットの迷子は exit 1" grep -q "exit=1" <<<"$out"

# (8) ブランチ上のマージ待ちは差し戻し不要として報じ、exit 0（異常ではない）
d=$(mkfix pending); cd "$d"
printf '# T1\n初期\n' > .agents/koumei/tasks/task-1.md
git add -A; git commit -qm base
git worktree add -q wt -b feature/work
printf '## Phase 5 実装記録\n' >> wt/.agents/koumei/tasks/task-1.md
git -C wt add -A; git -C wt commit -qm rec
out=$(run_chk "$d")
assert "マージ待ちを差し戻し不要として報じる" grep -q "マージ待ち・差し戻し不要" <<<"$out"
assert "マージ待ちはブランチ名を添える" grep -q "\[feature/work\]" <<<"$out"
assert_not "マージ待ちを差し戻し要と誤報しない" grep -q "差し戻し要" <<<"$out"
assert "マージ待ちのみなら exit 0（異常ではない）" grep -q "exit=0" <<<"$out"

# (9) worktree の中から走らせても、本体から走らせた場合と同じ答えを返す
#     （迷子が生まれるのは cwd が worktree に在るときであり、そこで沈黙しては用をなさない）
d=$(mkfix fromwt); cd "$d"
printf '# T1\n- [x] Phase 1\n' > .agents/koumei/tasks/task-1.md
git add -A; git commit -qm base
git worktree add -q wt -b w
printf '## Phase 4 判定\n裁定9箇条\n' >> wt/.agents/koumei/tasks/task-1.md
from_main=$(run_chk_at "$d")
from_wt=$(run_chk_at "$d/wt")
assert "本体から走らせると迷子を検出する" grep -q "未コミットの記録 2 行" <<<"$from_main"
assert "worktree の中から走らせても迷子を検出する" grep -q "未コミットの記録 2 行" <<<"$from_wt"
assert "答えが走らせた場所に依らない" test "$from_main" = "$from_wt"

# (10) worktree が古い複製の場合、本体を迷子として告発しない（主客転倒の防止）
d=$(mkfix stale); cd "$d"
printf '# T1\n古い\n' > .agents/koumei/tasks/task-1.md
git add -A; git commit -qm base
git worktree add -q wt -b w
printf '## Phase 5 本体側で正しく追記\n' >> .agents/koumei/tasks/task-1.md
out=$(run_chk_at "$d/wt")
assert "古い複製から走らせても本体を告発しない" grep -q "迷子なし" <<<"$out"
assert "主客転倒しないので exit 0" grep -q "exit=0" <<<"$out"

# ------------------------------------------------------------
echo ""
echo "[T14] Git運用とPR作成（派生元の分岐・ホスト差異）"

# gh pr create が必ず --base を伴うか（無指定だと既定ブランチへ向いたPRが立つ）
gh_always_based() { ! grep "gh pr create" "$1" | grep -qv -- "--base"; }

for sc in dev nodev; do
  if [[ "$sc" == dev ]]; then
    make_project "$WORK_DIR/t14-$sc"
  else
    make_project "$WORK_DIR/t14-$sc" 's/^  develop_branch:.*/  develop_branch: ""/'
  fi
  bash "$SETUP" > setup.log 2>&1 || ng "setup.sh 実行 ($sc)"
  P=.claude/skills/koumei-start/docs/phases.md

  assert "$sc: Git運用の節が配布される" grep -q "^## Git 運用（全フェーズ共通）" "$P"
  assert "$sc: 作業ブランチの作成手順がある" grep -q "git checkout -b" "$P"
  assert "$sc: フェーズ完了ごとの commit/push を命じる" grep -q "フェーズ完了ごとにコミットし、直ちに push" "$P"
  assert "$sc: 汚れた作業ツリーでの分岐を禁じる" grep -q "git status --porcelain" "$P"
  assert_not "$sc: 未置換の占位子が残っていない" grep -q "{{" "$P"

  # 派生元の出し分け。ここを誤ると無人の夜に本番ブランチ向けのPRが立つ
  if [[ "$sc" == dev ]]; then
    assert "$sc: 派生元・PR先が develop" grep -q "^BASE=develop" "$P"
    assert_not "$sc: main が漏れ出していない" grep -q "^BASE=main" "$P"
  else
    assert "$sc: 派生元・PR先が main" grep -q "^BASE=main" "$P"
    assert_not "$sc: develop が漏れ出していない" grep -q "^BASE=develop" "$P"
  fi

  assert "$sc: GitHub は --base 付きで gh を叩く" grep -q 'gh pr create --base' "$P"
  assert "$sc: --base を欠く gh pr create が無い" gh_always_based "$P"
  assert "$sc: ホストを見極める分岐がある" grep -qF '*bitbucket.org*) HOST=bitbucket' "$P"
  assert "$sc: Bitbucket ではPRを自動作成しない" grep -q "自動では作成しない" "$P"
  assert "$sc: PR作成の失敗でタスクを失敗扱いにしない" grep -q "失敗扱いにしてはならない" "$P"
done

# --- PR作成URLの組み立てを生成物から抜き出し、実際のリモート表記で走らせる ---
SLUGSH="$WORK_DIR/slug.sh"
awk '/^SLUG=\$\(git remote get-url origin/,/\.git\$#/' \
  "$WORK_DIR/t14-dev/.claude/skills/koumei-start/docs/phases.md" > "$SLUGSH"
echo 'echo "$SLUG"' >> "$SLUGSH"
assert "URL組み立てを生成物から抽出できる" test -s "$SLUGSH"

for r in "git@bitbucket.org:acme/repo.git" "https://bitbucket.org/acme/repo.git" "https://bitbucket.org/acme/repo"; do
  d="$WORK_DIR/t14-url"; rm -rf "$d"; mkdir -p "$d"; cd "$d"
  git init -q; git remote add origin "$r"
  assert "URL: $r から acme/repo を得る" test "$(bash "$SLUGSH")" = "acme/repo"
done

# ------------------------------------------------------------
echo ""
echo "[T15] STAGING確認チェックリスト（様式と移植タスクの上乗せ）"

for mg in on off; do
  if [[ "$mg" == on ]]; then
    make_project "$WORK_DIR/t15-$mg" '/^migration:/,/^$/s/^  enabled: false/  enabled: true/'
  else
    make_project "$WORK_DIR/t15-$mg"
  fi
  bash "$SETUP" > setup.log 2>&1 || ng "setup.sh 実行 (migration=$mg)"
  P=.claude/skills/koumei-start/docs/phases.md

  assert "mg=$mg: チェックリストの節が配布される" grep -q "STAGING確認チェックリスト" "$P"
  assert "mg=$mg: 出力先を明記している" grep -q "staging-check.md" "$P"
  assert "mg=$mg: チケットのコメントにも記すよう命じる" grep -q "チケットのコメントにも記す" "$P"
  assert "mg=$mg: 期待する結果の空欄を禁じる" grep -q "空欄にしてはならない" "$P"
  assert "mg=$mg: 事前条件を冒頭に置かせる" grep -q "事前条件は必ず冒頭に置く" "$P"
  assert "mg=$mg: 回帰を別表に分けさせる" grep -q "回帰は別表に分ける" "$P"
  assert "mg=$mg: 未検証領域の明記を命じる" grep -q "自動で確かめられなかったことを正直に書く" "$P"
  assert "mg=$mg: 判定の行き先が三分岐" grep -q "判断に迷う" "$P"
  assert "mg=$mg: 種別ごとの項目数上限がある" grep -q "バグ修正（中） | 4〜6" "$P"
  assert "mg=$mg: PR作成の節番が繰り下がっている" grep -q "^### 3. PR作成" "$P"

  # 移植の上乗せ。移行元との突き合わせを欠いた移植確認は何も確認していない
  if [[ "$mg" == on ]]; then
    assert "mg=$mg: 移行元との突き合わせを必須にする" grep -q "移行元との突き合わせ" "$P"
  else
    assert_not "mg=$mg: 非移植PJに移植専用の掟が漏れない" grep -q "移行元との突き合わせ" "$P"
  fi
done

# ------------------------------------------------------------
echo ""
echo "[T16] 無人運転（行列・待避・戦況表・課題管理連携）"

U=.claude/skills/koumei-start/docs/unattended.md

# --- 連携なし（既定）。設定を書いていない既存プロジェクトが無傷であること ---
make_project "$WORK_DIR/t16-off"
bash "$SETUP" > setup.log 2>&1 || ng "setup.sh 実行 (ticket=off)"
assert "off: 無人運転の手順書が配布される" test -f "$U"
assert "off: 問うてはならぬ大原則がある" grep -q "問うてはならない。待避せよ" "$U"
assert "off: 連携なしでもタスク定義から行列を引く" grep -q "task-\*.md" "$U"
assert_not "off: 課題管理連携の記述が漏れない" grep -q "課題管理システムに問い合わせ" "$U"
assert_not "off: 未置換の占位子が残らない" grep -q "{{" "$U"
assert "off: --unattended を最優先で判定させる" grep -q "この判定を最優先する" .claude/skills/koumei-start/SKILL.md

# --- 連携あり ---
make_project "$WORK_DIR/t16-on" \
  '/^ticket:/,/^$/s/^  enabled: false/  enabled: true/' \
  's/^  status_designing: ""/  status_designing: "AI-PLANREVIEW"/' \
  's/^  status_implementing: ""/  status_implementing: "AI-PROGRESS"/' \
  's/^  status_review_ready: ""/  status_review_ready: "AI-PR"/' \
  's/^  status_parked: ""/  status_parked: "ペンディング"/'
# queue は引用符を含むためブロックスカラーで置く（プレーンだと yq 無し環境で引用符が剥がれる）
perl -i -pe 's{^  queue: ""$}{  queue: |\n    status = "AI-READY" AND assignee = currentUser()}' koumei.config.yaml
bash "$SETUP" > setup.log 2>&1 || ng "setup.sh 実行 (ticket=on)"
assert "on: 行列の条件が展開される" grep -q "assignee = currentUser()" "$U"
assert "on: JQLの引用符が剥がれない" grep -qF 'status = "AI-READY"' "$U"
assert "on: 設計中の状態名が展開される" grep -q "AI-PLANREVIEW" "$U"
assert "on: 実装中の状態名が展開される" grep -q "AI-PROGRESS" "$U"
assert "on: PR待ちの状態名が展開される" grep -q "AI-PR" "$U"
assert "on: 待避先の状態名が展開される" grep -q "ペンディング" "$U"
assert "on: 行列を勝手に広げるなと戒める" grep -q "その場で広げてはならない" "$U"
assert "on: 完了コメントにチェックリスト全文を載せさせる" grep -q "STAGING確認チェックリストの全文" "$U"
assert_not "on: 未置換の占位子が残らない" grep -q "{{" "$U"

# --- 待避と戦況表 ---
assert "待避で「何が決まれば進むか」を書かせる" grep -q "何が決まれば進めるか" "$U"
assert "待避前に commit + push させる" grep -q "そこまでの成果を commit + push" "$U"
assert "三件続けて待避したら運転を終える" grep -q "三件続けて待避した" "$U"
assert "戦況表の出力先が定まっている" grep -q "night-{YYYY-MM-DD}.md" "$U"
assert "戦況表はコミットさせない" grep -q "コミットしない" "$U"
assert "待避を先に、完遂を後に書かせる" grep -q "待避を先に、完遂を後に書く" "$U"
assert "一件も処理できなかった夜も表を書かせる" grep -q "一件も処理できなかった夜も" "$U"

# --- 安全弁: 絞り込みを欠いた連携は無効化される（他の担当者のチケットを拾わせない） ---
make_project "$WORK_DIR/t16-noqueue" '/^ticket:/,/^$/s/^  enabled: false/  enabled: true/'
bash "$SETUP" > setup.log 2>&1 || ng "setup.sh 実行 (ticket=絞り込みなし)"
assert "絞り込みが無ければ警告する" grep -q "ticket.queue が空" setup.log
assert_not "絞り込みが無ければ連携記述を出さない" grep -q "課題管理システムに問い合わせ" "$U"

# --- 後方互換: ticket セクションを持たない既存プロジェクトを壊さない ---
# 新設キーを CONFIG_REQUIRED_KEYS に加えると --update が drift 判定で止まるため、その回帰を張る
make_project "$WORK_DIR/t16-legacy" '/^ticket:/,/^$/d'
assert_not "検証用configに ticket 節が無い" grep -q "^ticket:" koumei.config.yaml
bash "$SETUP" > setup.log 2>&1 || ng "setup.sh 実行 (ticket 節なし)"
assert "節が無くても生成が通る" test -f "$U"
assert_not "節が無ければ連携記述を出さない" grep -q "課題管理システムに問い合わせ" "$U"
bash "$SETUP" --update > update.log 2>&1 || ng "--update 実行 (ticket 節なし)"
assert_not "節が無くても --update が reconfig を要求しない" grep -q "reconfig" update.log

# ------------------------------------------------------------
echo ""
echo "[T17] git 操作の排他とブランチ運用"

make_project "$WORK_DIR/t17"
bash "$SETUP" > setup.log 2>&1 || ng "setup.sh 実行 (T17)"
P=.claude/skills/koumei-start/docs/phases.md
R=.claude/skills/koumei-start/docs/rules.md
TT=.claude/skills/koumei-start/docs/task-template.md

# --- 不変則の宣言 ---
assert "rules.md に git 操作の排他が立つ" grep -q "^## git 操作の排他（厳格ルール）" "$R"
assert "粒度が「一作業ツリーに一人」である" grep -q "一つの作業ツリーにつき、git を触る者は一人" "$R"
assert "理由（HEAD と index の共有）が書かれている" grep -q "HEAD\` と index は作業ツリーに一つしかない" "$R"
assert "rules.md にブランチ運用が立つ" grep -q "^## ブランチ運用（厳格ルール）" "$R"
assert "config が正であると明記する" grep -q "設定が正である。上書きは例外" "$R"
assert "上書きの三条件がある" grep -q "書けないなら、それは上書きすべき場面ではない" "$R"
assert "無人運転では上書きを許さない" grep -q "無人運転（\`--unattended\`）では上書きを一切許さない" "$R"

# --- 禁止が全ての実行経路に届いているか（元の欠陥: 3経路中1つにしか無かった） ---
p5=$(awk '/^## Phase 5/,/^## Phase 6/' "$P")
for mode in 通常モード agy委譲モード Codex委譲モード; do
  blk=$(awk -v m="### $mode" 'index($0,m)==1{f=1;next} f&&/^### /{exit} f' <<<"$p5")
  if [[ -z "$blk" ]]; then
    ng "Phase 5 に $mode の節がある"
  elif grep -q "git commit は行わない\|git 操作を一切行わない" <<<"$blk"; then
    ok "Phase 5 $mode のプロンプトに git 禁止が届く"
  else
    ng "Phase 5 $mode のプロンプトに git 禁止が届く"
  fi
done
assert "tech-lead の役割定義自体にも git 禁止を刻む" grep -q "git 操作を一切行わないこと" .agents/tech-lead/CLAUDE.md
assert "役割定義に禁止の理由も添える" grep -q "並列に動く" .agents/tech-lead/CLAUDE.md

# --- 決定の記録先 ---
assert "タスク定義にブランチの項がある" grep -q "^## ブランチ" "$TT"
assert "派生元を記録させる" grep -q "^- 派生元:" "$TT"
assert "PR先を記録させる" grep -q "^- PR先:" "$TT"
assert "上書きの理由を記録させる" grep -q "^- 既定と異なる理由:" "$TT"
assert "Phase 0/7 が config ではなくこの項を読むと明記" grep -q "config ではなくこの項を読む" "$TT"
assert "Phase 0 の分岐がタスク定義を先に確定させる" grep -q "先にタスク定義ファイルの \`## ブランチ\` を確定させ" "$P"
assert "既定より タスク定義 が優先されると明記" grep -q "そちらを優先する" "$P"

# --- Phase 7 の照合（気づかぬうちに本番へ向くのを防ぐ） ---
assert "PR作成前にブランチ名を照合させる" grep -q "同じ項の「ブランチ名」と一致することを確かめる" "$P"
assert "食い違えばPRを作らず待避させる" grep -q "一致しなければPRを作らず、報告して待避する" "$P"

# --- 無人運転側の待避条件 ---
U=.claude/skills/koumei-start/docs/unattended.md
assert "無人運転: 既定と異なる派生元が要れば待避する" grep -q "異なる派生元・PR先が必要" "$U"
assert "無人運転: 照合の食い違いでも待避する" grep -q "タスク定義の記載と食い違った" "$U"

# ------------------------------------------------------------
echo ""
echo "[T18] git 記述の全体整合（古い前提の残留検知）"

make_project "$WORK_DIR/t18"
bash "$SETUP" > setup.log 2>&1 || ng "setup.sh 実行 (T18)"
P=.claude/skills/koumei-start/docs/phases.md
R=.claude/skills/koumei-start/docs/rules.md
EH=.claude/skills/koumei-start/docs/error-handling.md
TM=.agents/task-manager/CLAUDE.md
S=.claude/skills/koumei-start/SKILL.md

# --- PR先が「メインブランチ」で固定されていた古い記述 ---
assert_not "指揮者の役割定義にメインブランチ固定のPRが残らない" grep -q "メインブランチにPR" .agents/koumei/CLAUDE.md
assert_not "TEAM.md のフロー図にメインブランチ固定のPRが残らない" grep -q "メインブランチへ PR" .agents/TEAM.md
assert "指揮者の役割定義が config を正とする" grep -q "既定のPR先ブランチへPR" .agents/koumei/CLAUDE.md

# --- task-manager の worktree 作成（命名が config を無視し、派生元が暗黙だった） ---
assert_not "worktree のブランチ名が決め打ちでない" grep -q -- "-b feature/task-{番号}" "$TM"
assert "worktree の派生元を明示する" grep -q 'git worktree add .* "origin/\$BASE"' "$TM"
assert "worktree の命名が branch_pattern に従う" grep -q "に従って組み立てる" "$TM"
assert "派生元の省略を禁じる理由を書く" grep -q "省けば worktree は現在の" "$TM"

# --- 外部CLI委譲: PATH に在るだけで委譲してはならない ---
assert "委譲の可否は TEAM.md の指定で決まる" grep -q "委譲するか否かは TEAM.md の指定で決まる" "$P"
assert "PATH 常駐だけでの委譲を禁じる" grep -q "PATH に在るというだけで委譲してはならない" "$P"
assert_not "旧: command -v 成功だけで委譲する記述が残らない" grep -q "が指定または \`command -v" "$P"

# --- 委譲先の作業ツリー（別 worktree だと commit されず迷子になる） ---
assert "委譲先を同じ作業ツリーで動かす" grep -q "同じ作業ツリーで動かす" "$P"
assert_not "worktree 内実行の推奨が残らない（phases）" grep -q "worktree 内での実行を推奨" "$P"
assert_not "worktree 内実行の推奨が残らない（TEAM）" grep -q "worktree 内での実行を推奨" .agents/TEAM.md
assert "隔離はブランチとコミットが担うと明記" grep -q "隔離は worktree ではなく" "$P"

# --- 読み取り専用 git は禁じない（レビューが git diff を使うため） ---
assert "読み取り専用の git を許すと明記" grep -q "読み取りは禁じない" "$R"
assert "禁ずるのは状態を変える操作だと明記" grep -q "禁ずるのは\*\*状態を変える操作\*\*" "$R"

# --- PR作成失敗の扱い（旧: 停止する → 新: 止めない） ---
assert_not "旧: gh 固定の節見出しが残らない" grep -q "^## \`gh pr create\` 失敗" "$EH"
assert "PR作成失敗でタスクを失敗扱いにしない" grep -q "タスクを失敗扱いにしてはならない" "$EH"
assert_not "PR失敗で停止する古い指示が残らない" grep -q "ブランチ未プッシュ等の原因を案内して停止する" "$EH"
assert "Bitbucket で自動作成しないのは失敗ではないと明記" grep -q "これは失敗ではない" "$EH"

# --- 要件指示書 → タスク定義 への受け渡し（訊いて捨てる構図の解消） ---
assert "Phase 0 で要件指示書のブランチ戦略を写させる" grep -q "その内容をタスク定義へ書き写す" "$S"
assert "写さなければ確認の意味が消えると警告する" grep -q "要件指示書に書かれたまま放置してはならない" "$S"
assert "argument-hint に --unattended がある" grep -q -- "--unattended" "$S"

# ------------------------------------------------------------
echo ""
echo "[T19] 利用者向け文書の追随（機能を入れて README を忘れる事故の回帰）"

# テンプレートに掟を刻んでも、README/configuration.md が古いままだと
# 「決めたつもりが伝わっていない」状態になる。実際に二度取り残した
RM="${REPO_DIR}/README.md"
CF="${REPO_DIR}/docs/configuration.md"

# 無人運転
assert "README: --unattended が載る" grep -q -- "--unattended" "$RM"
assert "README: 待避（PARK）の概念が載る" grep -q "待避（PARK）" "$RM"
assert "README: 戦況表が載る" grep -q "戦況表" "$RM"
# Git 運用・PR
assert "README: フェーズ毎の commit/push が載る" grep -q "フェーズ完了ごとの commit/push" "$RM"
assert "README: Bitbucket 対応が載る" grep -q "Bitbucket" "$RM"
assert "README: STAGING確認チェックリストが載る" grep -q "STAGING確認チェックリスト" "$RM"
# git 操作の排他・ブランチ運用
assert "README: git 操作の排他が載る" grep -q "git 操作の排他" "$RM"
assert "README: 粒度（一作業ツリーに一人）が載る" grep -q "一つの作業ツリーにつき、git を触る者は一人" "$RM"
assert "README: 読み取りは禁じない旨が載る" grep -q "読み取りの \`git diff\` 等は禁じない" "$RM"
assert "README: ブランチ運用の一元化が載る" grep -q "ブランチ運用の一元化" "$RM"
assert "README: 決定をタスク定義に記録する旨が載る" grep -q "タスク定義の \`## ブランチ\` に記録する" "$RM"
# 課題管理連携
assert "README: 機能マトリクスに無人運転がある" grep -q "無人運転（--unattended" "$RM"
assert "README: 機能マトリクスに ticket 連携がある" grep -q "課題管理システム連携（ticket" "$RM"
# 設定文書
assert "configuration: ticket セクションがある" grep -q "^## ticket（課題管理システム連携・任意）" "$CF"
assert "configuration: queue のブロックスカラー必須を警告する" grep -q "ブロック形式で書く" "$CF"
assert "configuration: status_ を入れ子にするなと警告する" grep -q "入れ子（\`status:\` の下）にしてはならない" "$CF"
assert "configuration: branch_pattern の {type} が載る" grep -q "{type}" "$CF"
assert "configuration: main/develop が PR先にも配線済みと明記" grep -q "PRの向け先" "$CF"


# ------------------------------------------------------------
echo ""
echo "[T20] 外部CLI委譲が実際に動く形になっているか（黙って Claude へ落ちる事故の回帰）"

# --- テンプレート側 ---
assert "settings テンプレに permissions.allow がある" \
  jq -e '.permissions.allow | length > 0' "${REPO_DIR}/templates/claude/settings.json"
assert "settings テンプレが agy を許可する" \
  jq -e '.permissions.allow | index("Bash(agy -p:*)")' "${REPO_DIR}/templates/claude/settings.json"
assert "settings テンプレが codex を許可する" \
  jq -e '.permissions.allow | index("Bash(codex exec:*)")' "${REPO_DIR}/templates/claude/settings.json"

# --- 新規プロジェクト（cp 経路） ---
make_project "$WORK_DIR/t20a"
bash "$SETUP" > setup.log 2>&1 || ng "setup.sh 実行 (T20a)"
assert "新規: 生成された settings.json が agy を許可する" \
  jq -e '.permissions.allow | index("Bash(agy -p:*)")' .claude/settings.json

# --- 既存 settings.json がある場合（マージ経路。元の欠陥: hooks キーしか拾わず permissions が落ちた） ---
make_project "$WORK_DIR/t20b"
mkdir -p .claude
cat > .claude/settings.json <<'EXISTING'
{
  "permissions": { "allow": ["Bash(echo hello)"], "deny": ["Bash(rm -rf /)"] },
  "env": { "MY_VAR": "keep-me" }
}
EXISTING
bash "$SETUP" > setup.log 2>&1 || ng "setup.sh 実行 (T20b)"
assert "既存あり: agy の許可が追加される" \
  jq -e '.permissions.allow | index("Bash(agy -p:*)")' .claude/settings.json
assert "既存あり: 元の許可が保たれる" \
  jq -e '.permissions.allow | index("Bash(echo hello)")' .claude/settings.json
assert "既存あり: 元の deny が消えない" \
  jq -e '.permissions.deny | index("Bash(rm -rf /)")' .claude/settings.json
assert "既存あり: 無関係のキーが消えない" \
  jq -e '.env.MY_VAR == "keep-me"' .claude/settings.json
assert "既存あり: hooks も入る" jq -e '.hooks.PreToolUse' .claude/settings.json

# --- 既存 hooks があっても permissions は入る（hooks は手動マージを促すだけ） ---
make_project "$WORK_DIR/t20c"
mkdir -p .claude
echo '{"hooks":{"PreToolUse":[{"matcher":"MyOwn","hooks":[]}]}}' > .claude/settings.json
bash "$SETUP" > setup.log 2>&1 || ng "setup.sh 実行 (T20c)"
assert "既存hooks: permissions は入る" \
  jq -e '.permissions.allow | index("Bash(agy -p:*)")' .claude/settings.json
assert "既存hooks: 利用者の hooks を上書きしない" \
  jq -e '.hooks.PreToolUse[0].matcher == "MyOwn"' .claude/settings.json

# --- 呼び出し方法（TEAM.md） ---
make_project "$WORK_DIR/t20d"
bash "$SETUP" > setup.log 2>&1 || ng "setup.sh 実行 (T20d)"
TMD=.agents/TEAM.md
PH=.claude/skills/koumei-start/docs/phases.md
RL=.claude/skills/koumei-start/docs/rules.md
UN=.claude/skills/koumei-start/docs/unattended.md

assert "TEAM.md: agy に --add-dir がある" grep -q -- '--add-dir "\$PWD"' "$TMD"
assert "TEAM.md: agy にモデル明示がある" grep -q -- "--model gemini-3.7-flash-medium" "$TMD"
assert "TEAM.md: agy に --print-timeout がある" grep -q -- "--print-timeout 30m" "$TMD"
assert "TEAM.md: agy に --output-format json がある" grep -q -- "--output-format json" "$TMD"
assert_not "TEAM.md: 存在しない gemini-3.5-pro が残らない" grep -q "gemini-3.5-pro" "$TMD"
assert_not "TEAM.md: agy-pro が残らない" grep -q "^| agy-pro " "$TMD"
assert "TEAM.md: agy-high がある" grep -q "^| agy-high " "$TMD"
assert "TEAM.md: 三つの落とし穴が書かれている" grep -q "agy の三つの落とし穴" "$TMD"
assert "TEAM.md: --add-dir 無しで消えると警告する" grep -q "scratch" "$TMD"
assert "TEAM.md: status を判定に使うなと書く" grep -q "status\` は成否の判定に使えない" "$TMD"
assert "TEAM.md: 消費ゼロが未実行の署名だと書く" grep -q "usage.total_tokens\` が 0" "$TMD"

# --- 背景実行（前景の2分/10分制限を避ける） ---
assert "phases: agy委譲が run_in_background を指示する" grep -q "run_in_background" "$PH"
assert "phases: 前景禁止の理由（2分・10分）を書く" grep -q "既定2分" "$PH"
assert_not "phases: 前景で実行させる古い記述が残らない" \
  grep -q 'Bash tool で `agy -p "{指示プロンプト}" --dangerously-skip-permissions` を実行' "$PH"
# Phase 1 にも Codex委譲モードが立ったため、節名だけの awk では Phase 1 を先に拾う。
# この検査は Phase 5 のものなので、フェーズで切ってから節を取る
p5codex=$(awk '/^## Phase 5/,/^## Phase 6/' "$PH" | awk 'index($0,"### Codex委譲モード")==1{f=1;next} f&&/^### /{exit} f')
assert "phases: Phase 5 の Codex 委譲も背景実行にする" grep -q "run_in_background" <<<"$p5codex"

# --- ログの置き場（元の欠陥: フックの副作用でしか作られず、委譲ごと失敗した） ---
assert "生成物に .agents/logs がある" test -d .agents/logs
assert "phases: agy 委譲が logs を自前で作る" grep -q "mkdir -p .agents/logs" "$PH"
assert "phases: Phase 5 の codex 委譲も logs を自前で作る" grep -q "mkdir -p .agents/logs" <<<"$p5codex"

# --- 成否の判定（status を信じない） ---
assert "phases: 一次判定が git の差分である" grep -q "git status --porcelain" "$PH"
assert "phases: status を合否に使うなと明記" grep -q "status\` と終了コードを合否の判定に使ってはならない" "$PH"
assert "phases: 成功時も ERROR が返ると書く" grep -q "status: ERROR\`、終了コード 0 が返る" "$PH"
assert "phases: 消費ゼロで停止させる" grep -q "usage.total_tokens\` が 0" "$PH"
assert "phases: 設定不備をフォールバックで隠すなと書く" grep -q "自動フォールバックで隠してはならない" "$PH"

# --- 背景実行中の作業ツリー不可侵 ---
assert "rules: 背景実行中の不可侵が立つ" grep -q "背景実行している間" "$RL"
assert "rules: 待ちが不可侵の時間だと書く" grep -q "不可侵の時間" "$RL"
assert "phases: 待機中に触れるなと書く" grep -q "作業ツリーに一切触れてはならない" "$PH"
assert "unattended: 待機中に次タスクへ進むなと書く" grep -q "行列の次のタスクへ着手してはならない" "$UN"
assert "unattended: 設定不備は待避させる" grep -q "一度も動かなかった" "$UN"

# --- 利用者向け文書の追随 ---
RM2="${REPO_DIR}/README.md"
CF2="${REPO_DIR}/docs/configuration.md"
assert "README: 外部CLI委譲の要件が載る" grep -q "外部CLI委譲の要件" "$RM2"
assert "README: --add-dir が載る" grep -q -- '--add-dir "\$PWD"' "$RM2"
assert "README: 背景実行が載る" grep -q "run_in_background" "$RM2"
assert "README: 実物で判定する旨が載る" grep -q "成否は実物で判定する" "$RM2"
assert "README: 実装は差分とビルドだと載る" grep -q "git status\` の差分とビルド" "$RM2"
assert "README: 消費ゼロの署名が載る" grep -q "消費ゼロは設定不備の署名" "$RM2"
assert "configuration: 委譲の要件表がある" grep -q "外部CLI委譲を指定したときの要件" "$CF2"
assert "configuration: pro が格上げにならないと書く" grep -q "格上げにならない" "$CF2"
assert_not "configuration: agy-pro が残らない" grep -q "agy-pro" "$CF2"
# ------------------------------------------------------------
echo ""
echo "[T21] STAGING確認の判定が現場の状態名で出るか（issue #23）"

STG_ON='/^ticket:/,/^$/s/^  enabled: false/  enabled: true/'
STG_Q='s|^  queue: ""|  queue: \|\n    status = "AI-READY" AND assignee = currentUser()|'

# --- ticket 無効: 一般形で出る（既存プロジェクトを壊さない） ---
make_project "$WORK_DIR/t21-off"
bash "$SETUP" > setup.log 2>&1 || ng "setup.sh 実行 (T21 off)"
PJ=.claude/skills/koumei-start/docs/phases.md
assert "無効: 判定が一般形で出る" grep -q "確認済みとして次工程へ進める" "$PJ"
assert_not "無効: Jira 語彙がハードコードされて残らない" grep -q "本番デプロイ待ち" "$PJ"
assert "無効: 設定すれば実名で出る旨を案内する" grep -q "status_staging_ok" "$PJ"

# --- 三つ揃い: 実際の状態名で出る ---
make_project "$WORK_DIR/t21-on" "$STG_ON" "$STG_Q" \
  's|^  status_parked: ""|  status_parked: "ペンディング"|' \
  's|^  status_staging_ok: ""|  status_staging_ok: "本番デプロイ待ち"|' \
  's|^  status_staging_ng: ""|  status_staging_ng: "PR実装の差し戻し"|'
bash "$SETUP" > setup.log 2>&1 || ng "setup.sh 実行 (T21 on)"
assert "有効: 合格の遷移先が設定値で出る" grep -q "チケットを \*\*本番デプロイ待ち\*\* へ" "$PJ"
assert "有効: 不合格の遷移先が設定値で出る" grep -q "\*\*PR実装の差し戻し\*\* へ移し" "$PJ"
assert "有効: 保留の遷移先が設定値で出る" grep -q "\*\*ペンディング\*\* へ" "$PJ"
assert_not "有効: 一般形は出ない" grep -q "確認済みとして次工程へ進める" "$PJ"
assert "有効: 言い換えるなと戒める" grep -q "勝手に言い換えてはならない" "$PJ"

# --- 一つ欠け: 空の遷移指示を出さず一般形へ落ちる ---
make_project "$WORK_DIR/t21-partial" "$STG_ON" "$STG_Q" \
  's|^  status_parked: ""|  status_parked: "ペンディング"|' \
  's|^  status_staging_ok: ""|  status_staging_ok: "本番デプロイ待ち"|'
bash "$SETUP" > setup.log 2>&1 || ng "setup.sh 実行 (T21 partial)"
assert "欠け: 一般形へ落ちる" grep -q "確認済みとして次工程へ進める" "$PJ"
assert_not "欠け: 空の遷移指示を出さない" grep -qE '\*\*\s*\*\* へ' "$PJ"
assert_not "欠け: 中途半端に片方だけ出さない" grep -q "チケットを \*\*本番デプロイ待ち\*\* へ" "$PJ"

# --- 後方互換: ticket 節を持たない既存プロジェクト ---
make_project "$WORK_DIR/t21-legacy" '/^ticket:/,/^$/d'
bash "$SETUP" > setup.log 2>&1 || ng "setup.sh 実行 (T21 legacy)"
assert "節なし: 一般形で出る" grep -q "確認済みとして次工程へ進める" "$PJ"
assert "節なし: 条件タグが生の文字列で残らない" \
  bash -c '! grep -q "IF_TICKET_STAGING" '"$PJ"

# --- 利用者向け文書（元の欠陥: 機能を入れて README を忘れる事故が過去に三度） ---
assert "configuration: staging の状態名が載る" grep -q "status_staging_ok" "${REPO_DIR}/docs/configuration.md"
assert "configuration: 三つ揃いが条件だと明記" grep -q "三つが揃ったときだけ" "${REPO_DIR}/docs/configuration.md"
RM3="${REPO_DIR}/README.md"
assert "README: ticket 連携の節がある" grep -q "^### 課題管理システム連携（ticket・任意）" "$RM3"
assert "README: 特定システムを前提としないと明記" grep -q "特定の課題管理システムを前提としない" "$RM3"
assert "README: staging の状態名が載る" grep -q "status_staging_ok" "$RM3"
assert "README: 三つ揃いが条件だと明記" grep -q "三つが揃ったときだけ" "$RM3"
assert "README: queue 空なら無効と明記" grep -q "連携は無効" "$RM3"
assert "README: 節なしなら既存プロジェクトが無傷と明記" grep -q "既存プロジェクトはそのまま動く" "$RM3"
assert "README: 接続手段は管轄外と明記" grep -q "接続手段（MCP・CLI・API）は枠組みの管轄外" "$RM3"

# ------------------------------------------------------------
echo ""
echo "[T22] 分析フェーズ（Phase 1）の外部CLI委譲（issue #30）"

make_project "$WORK_DIR/t22" \
  's/^  # - analyst.*/  - analyst/' \
  's/^  # - ux-designer.*/  - ux-designer/'
bash "$SETUP" > setup.log 2>&1 || ng "setup.sh 実行 (T22)"
PH=.claude/skills/koumei-start/docs/phases.md
TMD=.agents/TEAM.md
AN=.claude/skills/koumei-analyze/SKILL.md

p1=$(awk '/^## Phase 1: 分析実行/,/^## Phase 2: 分析レビュー/' "$PH")

# --- Phase 5 と同じ三つの構えが Phase 1 にも立っているか ---
for mode in 通常モード agy委譲モード Codex委譲モード; do
  blk=$(awk -v m="### $mode" 'index($0,m)==1{f=1;next} f&&/^### /{exit} f' <<<"$p1")
  if [[ -z "$blk" ]]; then
    ng "Phase 1 に $mode の節がある"
  else
    ok "Phase 1 に $mode の節がある"
  fi
done

# --- 委譲の可否は config が決める（PATH 常駐だけで委譲しない） ---
assert "Phase 1: 委譲の可否は TEAM.md の指定で決まる" \
  grep -q "委譲するか否かは TEAM.md の指定で決まる" <<<"$p1"
assert "Phase 1: PATH 常駐だけでの委譲を禁じる" \
  grep -q "PATH に在るというだけで委譲してはならない" <<<"$p1"
assert "Phase 1: 委譲先を同じ作業ツリーで動かす" grep -q "同じ作業ツリーで動かす" <<<"$p1"

# --- #25 の要件（前景で殺されて黙って Claude に落ちる事故の回帰） ---
# フェーズで切るだけでは、片方の節が持つ記述にもう片方が救われる。モード単位で切る
p1agy=$(awk 'index($0,"### agy委譲モード")==1{f=1;next} f&&/^### /{exit} f' <<<"$p1")
p1codex=$(awk 'index($0,"### Codex委譲モード")==1{f=1;next} f&&/^### /{exit} f' <<<"$p1")
assert "Phase 1 agy: 背景実行を指示する" grep -q "run_in_background" <<<"$p1agy"
assert "Phase 1 agy: 前景禁止の理由（2分・10分）を書く" grep -q "既定2分" <<<"$p1agy"
assert "Phase 1 codex: 背景実行を指示する" grep -q "run_in_background" <<<"$p1codex"
assert "Phase 1 agy: logs を自前で作る" grep -q "mkdir -p .agents/logs" <<<"$p1agy"
assert "Phase 1 codex: logs を自前で作る" grep -q "mkdir -p .agents/logs" <<<"$p1codex"
assert "Phase 1 agy: --add-dir がある" grep -q -- '--add-dir "\$PWD"' <<<"$p1agy"
assert "Phase 1 agy: モデル明示がある" grep -q -- "--model gemini-3.7-flash-medium" <<<"$p1agy"
assert "Phase 1 agy: --print-timeout がある" grep -q -- "--print-timeout 30m" <<<"$p1agy"
assert "Phase 1 agy: --output-format json がある" grep -q -- "--output-format json" <<<"$p1agy"
assert "Phase 1: 待機中は作業ツリーに触れない" grep -q "作業ツリーに一切触れてはならない" <<<"$p1"

# --- 合否は実物で判じる（元の欠陥: 成果物ファイルの存在だけで合格にしていた） ---
assert "Phase 1: status を合否に使うなと明記" \
  grep -q "status\` と終了コードを合否の判定に使ってはならない" <<<"$p1"
assert "Phase 1: 一次判定が成果物の実在とサイズ" grep -q "成果物ファイルの実在と本文サイズ" <<<"$p1"
assert "Phase 1: ファイル存在だけで合格としない" \
  grep -q "ファイルが在るというだけで合格としてはならない" <<<"$p1"
assert "Phase 1: 分析品質基準を合否の実物とする" grep -q "分析品質基準の照合" <<<"$p1"
assert_not "旧: 存在確認だけで済ませる記述が残らない" \
  grep -q "成果物ファイルの存在を確認する。ファイルが生成されていない場合はエラー" <<<"$p1"

# 品質基準の四項目が名指しで検査対象になっているか（役割定義との対応が切れると空文になる）
for k in 実データ確認 仮説と事実の区別 既存実装の事前チェック 影響範囲; do
  assert "Phase 1: 照合項目に $k がある" grep -q "$k" <<<"$p1"
done
assert "役割定義に分析品質基準が実在する" grep -q "^## 分析品質基準" .agents/analyst/CLAUDE.md

# --- 設定不備をフォールバックで隠さない ---
assert "Phase 1: 消費ゼロで停止させる" grep -q "usage.total_tokens\` が 0" <<<"$p1"
assert "Phase 1: 設定不備をフォールバックで隠すなと書く" \
  grep -q "自動フォールバックで隠してはならない" <<<"$p1"

# --- 付け替えが割に合うかを後から測れるようにする（issue #30 の検証項目） ---
assert "Phase 1: 委譲先の消費をフェーズ台帳へ書かせる" grep -q "フェーズ台帳へ書く" <<<"$p1agy"
assert "Phase 1: 記録先を一箇所に定めると明記" grep -q "完了報告ではなく台帳に書く" <<<"$p1agy"

# --- git 禁止が Phase 1 の全経路に届くか（Phase 5 と同じ検査） ---
assert "Phase 1 agy: プロンプトに git 禁止が届く" grep -q "git 操作を一切行わないこと" <<<"$p1agy"
assert "Phase 1 codex: プロンプトに git 禁止が届く" \
  grep -q "git 操作を一切行わないこと\|agy委譲モードと同じ" <<<"$p1codex"

# --- 単独実行の経路（/koumei-analyze）も同じ要件を負うか ---
assert "analyze スキル: 背景実行を指示する" grep -q "run_in_background" "$AN"
assert "analyze スキル: 前景禁止と明記" grep -q "前景で実行してはならない" "$AN"
assert "analyze スキル: ファイル存在だけで合格としない" \
  grep -q "ファイルが在るというだけで合格としてはならない" "$AN"
assert "analyze スキル: status を合否に使うなと明記" grep -q "合否に使ってはならない" "$AN"
assert "analyze スキル: 消費ゼロで停止させる" grep -q "usage.total_tokens" "$AN"
assert "analyze スキル: 委譲先に git 禁止を課す" grep -q "git 操作を一切行わないこと" "$AN"
assert "analyze スキル: --add-dir を省略不可とする" grep -q -- '--add-dir "\$PWD"' "$AN"
assert_not "旧: 資料を全文でプロンプトに展開する記述が残らない" grep -q "指示書の全文" "$AN"

# --- TEAM.md: どこまで委譲できるか・何を基準に選ぶか ---
assert "TEAM.md: 委譲対応は二フェーズだと明記" grep -q "委譲に対応しているフェーズは次の二つだけです" "$TMD"
assert "TEAM.md: 委譲例の analyst が agy になっている" grep -q "^| analyst | agy |" "$TMD"
assert "TEAM.md: 見分ける基準の節がある" grep -q "^#### 委譲の向き不向きを見分ける基準" "$TMD"
assert "TEAM.md: 基準は出力量でなく入力量だと書く" grep -q "基準は出力量ではなく\*\*入力量\*\*である" "$TMD"
assert "TEAM.md: 機械的に検証できるかを基準に挙げる" grep -q "機械的に検証できるか" "$TMD"
assert "TEAM.md: 誤りが下流まで潜るかを基準に挙げる" grep -q "下流まで潜るか" "$TMD"
assert "TEAM.md: 固定費を明記する" grep -q "14〜16k" "$TMD"

# --- 据え置きの根拠が実測に置き換わっているか（旧: 印象論） ---
assert "TEAM.md: devils-advocate の据え置きが実測根拠" grep -q "総計76KB" "$TMD"
assert_not "旧: 品質ゲートは信頼性重視 という印象論が残らない" grep -q "品質ゲートは信頼性重視" "$TMD"
assert_not "旧: ux-designer は創造的だから という理由が残らない" grep -q "創造的なUX判断が多い" "$TMD"
assert "TEAM.md: ux-designer は判断保留として載る" grep -q "ux-designer は判断保留" "$TMD"
assert "TEAM.md: 保留の解除条件が analyst の実測だと書く" grep -q "analyst の実測結果を見てから判じる" "$TMD"

# --- ロール無効時に漏れないか ---
make_project "$WORK_DIR/t22-noux" 's/^  # - analyst.*/  - analyst/'
bash "$SETUP" > setup.log 2>&1 || ng "setup.sh 実行 (T22 noux)"
assert_not "ux-designer 無効時は保留の記述が漏れない" grep -q "ux-designer は判断保留" .agents/TEAM.md
assert "ux-designer 無効でも委譲の基準は残る" grep -q "委譲の向き不向きを見分ける基準" .agents/TEAM.md

# --- 利用者向け文書の追随（README を忘れる事故が過去に四度） ---
RM4="${REPO_DIR}/README.md"
CF4="${REPO_DIR}/docs/configuration.md"
assert "README: 分析フェーズも委譲対象だと載る" grep -q "分析フェーズ（Phase 1）" "$RM4"
assert "README: 委譲できるのは二つだと載る" grep -q "委譲できるのは分析（Phase 1 / analyst）と実装" "$RM4"
assert "README: 選ぶ基準が出力量でないと載る" grep -q "選ぶ基準は出力量ではなく" "$RM4"
assert "configuration: 実物はロールで変わると載る" grep -q "「実物」はロールによって変わる" "$CF4"
assert "configuration: 分析はファイル存在だけで合格としないと載る" \
  grep -q "ファイルが在るというだけで合格としてはならない" "$CF4"
assert "configuration: 委譲できるフェーズの節がある" grep -q "^#### 委譲できるフェーズと、向き不向き" "$CF4"
assert "config 例: 委譲対応フェーズが注記される" \
  grep -q "外部CLI委譲に対応しているのは analyst（Phase 1）と tech-lead-implement（Phase 5）" \
  "${REPO_DIR}/koumei.config.example.yaml"

# ------------------------------------------------------------
echo ""
echo "[T23] 実行諸元のフェーズ台帳（モデル配置を比べるための記録）"

make_project "$WORK_DIR/t23" 's/^  # - analyst.*/  - analyst/'
bash "$SETUP" > setup.log 2>&1 || ng "setup.sh 実行 (T23)"
PH=.claude/skills/koumei-start/docs/phases.md
AN=.claude/skills/koumei-analyze/SKILL.md
TMD=.agents/TEAM.md

guard=$(awk '/^## フェーズ完了時の検査/,/^## Git 運用/' "$PH")

# --- 台帳の実体 ---
assert "台帳の節が立つ" grep -q "^### 実行諸元の記録（フェーズ台帳）" <<<"$guard"
assert "台帳のパスが定まっている" grep -q "task-{番号}-execution.md" <<<"$guard"
assert "台帳に実行諸元の列がある" grep -q "実行諸元" <<<"$guard"
assert "台帳に委譲先の消費の列がある" grep -q "委譲先の消費" <<<"$guard"
assert "TEAM.md の命名規則に台帳がある" grep -q "実行台帳: \`{タスクID}-execution.md\`" "$TMD"

# --- なぜ要るか（判定は残るが、書いた者は残らない） ---
assert "実行モデルは成果物に残らないと明記" grep -q "実行モデルは成果物のどこにも残らない" <<<"$guard"
assert "書いたのが何かは残らないと明記" grep -q "それを書いたのが何だったかは残らない" <<<"$guard"
assert "モデル列を書き換えると区別がつかなくなると明記" grep -q "過去と現在の区別がつかなくなる" <<<"$guard"
assert "差し戻し回数・指摘件数の比較が目的だと書く" grep -q "差し戻し回数やレビュー指摘件数" <<<"$guard"
assert "配置を変えてから記録しても遅いと戒める" grep -q "配置を変えてから記録を始めても遅い" <<<"$guard"

# --- 書き手（規則と理由の両方を留める。理由だけだと規則の反転を素通りする） ---
assert "書くのは指揮者だと明記" grep -q "であって、成果物を作ったエージェントではない" <<<"$guard"
assert_not "作成エージェントの自己申告に反転していない" grep -q "成果物を作ったエージェントが自分で書く" <<<"$guard"
assert "自己申告が外れる理由も残す" grep -q "書き手に自己申告させれば外れる" <<<"$guard"
assert "サブエージェントは自分のモデルを知らないと明記" \
  grep -q "自分がどのモデルで起動されたかを確実には知らない" <<<"$guard"

# --- 置き場所（独立指示は落ちる。#30 の実測で実際に落ちた） ---
assert "サイズ検査に相乗りさせるのが意図的だと明記" grep -q "相乗りさせるのは意図的である" <<<"$guard"
assert "独立指示は落ちると明記" grep -q "という形の指示は実行時に落ちる" <<<"$guard"
assert "台帳も絶対パスで追記させる" grep -q "リポジトリルートからの絶対パス" <<<"$guard"

# --- 記録先の一本化（二箇所あると食い違う） ---
assert "委譲の消費も台帳へ集約する" grep -q "フェーズ台帳へ書く" "$PH"
assert "完了報告ではなく台帳だと明記" grep -q "完了報告ではなく台帳に書く" "$PH"
assert_not "旧: phases から 完了報告に1行記す が消える" grep -q "完了報告に1行記す" "$PH"
assert_not "旧: analyze スキルからも消える" grep -q "完了報告に1行記す" "$AN"
assert "analyze スキルも台帳を指す" grep -q "task-{番号}-execution.md" "$AN"

# --- ロール構成に依らず残る（台帳は指揮者の仕事であってロールではない） ---
make_project "$WORK_DIR/t23-min"
bash "$SETUP" > setup.log 2>&1 || ng "setup.sh 実行 (T23 min)"
assert "最小ロールでも台帳の節は残る" \
  grep -q "^### 実行諸元の記録（フェーズ台帳）" .claude/skills/koumei-start/docs/phases.md

# ------------------------------------------------------------
echo ""
echo "=========================================="
echo " 結果: PASS=$PASS FAIL=$FAIL"
if [[ $FAIL -gt 0 ]]; then
  echo " 失敗したテスト:"
  for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
  echo "=========================================="
  exit 1
fi
echo "=========================================="
exit 0

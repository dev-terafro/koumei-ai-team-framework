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

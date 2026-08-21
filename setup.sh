#!/bin/bash
# ============================================================
# koumei-ai-team-framework セットアップスクリプト
# ============================================================
# 使い方:
#   ./setup.sh                    # 初回セットアップ
#   ./setup.sh --update           # 最新テンプレで再展開（configは変更しない。成果物は保持）
#                                  # ※新しい設定項目が必要な場合は再生成せず --reconfig を案内する
#   ./setup.sh --reconfig         # 既存プロジェクトの設定を見直す（--init のエイリアス）
#   ./setup.sh --clean            # 展開済みファイルを削除
#   ./setup.sh --dry-run          # 実際にファイルを作成せずプレビュー
# ============================================================

set -euo pipefail

# --- 定数 ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATES_DIR="${SCRIPT_DIR}/templates"
CONFIG_FILE="koumei.config.yaml"
VERSION="1.0.0"
DEFAULT_TARGET_CLI="claude"

# --- カラー出力 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $1"; }

# --- 引数処理 ---
MODE="setup"
DRY_RUN=false
TICKET_MAP_ARG=""
TICKET_MAP_DEFAULT="${HOME}/.koumei/ticket-status-map.yaml"

_expect_ticket_map=false
for arg in "$@"; do
  # for ループでは shift が効かないため、値は次の周回で受ける
  if [[ "$_expect_ticket_map" == true ]]; then
    TICKET_MAP_ARG="$arg"; _expect_ticket_map=false; continue
  fi
  case "$arg" in
    --init)      MODE="init" ;;
    --reconfig)  MODE="init" ;;
    --roles)     MODE="roles" ;;
    --cli)       MODE="cli" ;;
    --update)    MODE="update" ;;
    --clean)     MODE="clean" ;;
    --dry-run)   DRY_RUN=true ;;
    --ticket-map)   _expect_ticket_map=true ;;
    --ticket-map=*) TICKET_MAP_ARG="${arg#*=}" ;;
    --help|-h)
      echo "koumei-ai-team-framework setup v${VERSION}"
      echo ""
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  (none)      Initial setup (auto-runs wizard if no config found)"
      echo "  --init      Run config wizard (create/overwrite koumei.config.yaml)"
      echo "  --reconfig  Revisit settings on an existing project (alias for --init)"
      echo "  --roles     Change role composition only"
      echo "  --cli       Change target CLI only (codex/claude/antigravity)"
      echo "  --update    Re-generate from the current config using the latest templates."
      echo "              Does not modify koumei.config.yaml. If the framework has added"
      echo "              config keys your project doesn't have yet, this stops and tells"
      echo "              you to run --reconfig instead of silently skipping them."
      echo "  --clean     Remove all generated files"
      echo "  --dry-run   Preview without creating files"
      echo "  --ticket-map <path>"
      echo "              Fill the wizard's ticket status names from a shared map file"
      echo "              (default: ~/.koumei/ticket-status-map.yaml when present)."
      echo "              The map seeds koumei.config.yaml; it is never read at generation"
      echo "              time, so anyone can run setup.sh and get the same output."
      echo "              'queue' is never imported -- narrowing the queue is per-project."
      echo "  --help      Show this help"
      exit 0
      ;;
  esac
done
if [[ "$_expect_ticket_map" == true ]]; then
  log_error "--ticket-map にはファイルパスが必要です。"
  exit 1
fi

# ============================================================
# 対話式セットアップウィザード
# ============================================================

# ユーザー入力を取得（デフォルト値付き）
prompt_input() {
  local prompt="$1"
  local default="$2"
  local result

  if [[ -n "$default" ]]; then
    printf "${BLUE}%s${NC} [${GREEN}%s${NC}]: " "$prompt" "$default" >&2
  else
    printf "${BLUE}%s${NC}: " "$prompt" >&2
  fi
  read -r result </dev/tty 2>/dev/null || read -r result
  echo "${result:-$default}"
}

# Yes/No入力
prompt_yn() {
  local prompt="$1"
  local default="${2:-n}"
  local result

  if [[ "$default" == "y" ]]; then
    printf "${BLUE}%s${NC} [${GREEN}Y${NC}/n]: " "$prompt" >&2
  else
    printf "${BLUE}%s${NC} [y/${GREEN}N${NC}]: " "$prompt" >&2
  fi
  read -r result </dev/tty 2>/dev/null || read -r result
  result="${result:-$default}"
  [[ "$result" =~ ^[Yy] ]]
}

# ロール選択ウィザード（説明付き）
# 結果はグローバル変数 WIZARD_SELECTED_ROLES に格納
wizard_select_roles() {
  WIZARD_SELECTED_ROLES=("koumei" "tech-lead" "devils-advocate")

  echo ""
  echo -e "${BLUE}━━━ ロール構成 ━━━${NC}"
  echo ""
  echo -e "${GREEN}【コアロール（必須）】${NC}"
  echo -e "  ✅ ${GREEN}koumei${NC}          … 全体統括・タスク分割・指示出し・最終判断を行う最高指揮者（諸葛孔明）"
  echo -e "  ✅ ${GREEN}tech-lead${NC}       … 技術設計・アーキテクチャ決定・実装を担当"
  echo -e "  ✅ ${GREEN}devils-advocate${NC} … 全成果物のレビュー・問題提起を担当する悪魔の代弁者"
  echo ""
  echo -e "${YELLOW}【オプションロール】${NC}"
  echo ""

  # analyst
  echo -e "  ${YELLOW}analyst${NC} … 既存コードベースの調査・分析を担当"
  echo -e "           移行プロジェクトや大規模リファクタリングで特に有用。"
  echo -e "           既存の実装パターン・依存関係・技術的負債を可視化する。"
  if prompt_yn "  analyst を有効にしますか？"; then
    WIZARD_SELECTED_ROLES+=("analyst")
    echo -e "  → ${GREEN}✅ 有効${NC}"
  else
    echo -e "  → ☐ 無効"
  fi

  echo ""

  # inquisitor
  echo -e "  ${YELLOW}inquisitor${NC} … 設計に着手する前に要件・前提・境界条件を詰問する諫議大夫"
  echo -e "              曖昧なまま設計に入ることを防ぎ、確定事項と未決の前提を明文化する。"
  echo -e "              全自動フローでは AI が根拠に基づいて自答し、根拠なき点のみ前提として残す。"
  echo -e "              設計の手戻りが多いプロジェクトで特に有用。"
  if prompt_yn "  inquisitor を有効にしますか？"; then
    WIZARD_SELECTED_ROLES+=("inquisitor")
    echo -e "  → ${GREEN}✅ 有効${NC}"
  else
    echo -e "  → ☐ 無効"
  fi

  echo ""

  # ux-designer
  echo -e "  ${YELLOW}ux-designer${NC} … UI/UX設計・コンポーネント設計・画面遷移設計を担当"
  echo -e "               フロントエンド開発やユーザー向け機能の実装で特に有用。"
  echo -e "               tech-lead と並列で設計を行い、設計の質を向上させる。"
  if prompt_yn "  ux-designer を有効にしますか？"; then
    WIZARD_SELECTED_ROLES+=("ux-designer")
    echo -e "  → ${GREEN}✅ 有効${NC}"
  else
    echo -e "  → ☐ 無効"
  fi

  echo ""

  # scribe
  echo -e "  ${YELLOW}scribe${NC} … 成果物の圧縮・構造化・差分パッケージ作成を担う主簿"
  echo -e "           トークン経済ルールの執行実務を担当。20KB超の成果物の再編、"
  echo -e "           2回目レビュー用の差分パッケージ作成、タスク定義の畳み込みを行う。"
  echo -e "           成果物が重くなる大規模タスク・夜間の全自動実行で特に有用。"
  if prompt_yn "  scribe を有効にしますか？"; then
    WIZARD_SELECTED_ROLES+=("scribe")
    echo -e "  → ${GREEN}✅ 有効${NC}"
  else
    echo -e "  → ☐ 無効"
  fi

  echo ""
  echo -e "選択されたロール: ${GREEN}${WIZARD_SELECTED_ROLES[*]}${NC}"
}

# ============================================================
# プロジェクト自動検出
# ============================================================

# package.json から依存関係を検出
detect_pkg_dep() {
  local pkg="$1"
  local file="package.json"
  [[ ! -f "$file" ]] && return 1
  grep -q "\"$pkg\"" "$file" 2>/dev/null
}

# package.json の scripts からコマンドを検出
detect_pkg_script() {
  local script="$1"
  local file="package.json"
  [[ ! -f "$file" ]] && return 1
  grep -q "\"$script\":" "$file" 2>/dev/null
}

# 技術スタックの自動検出
detect_tech_stack() {
  DETECTED_LANG=""
  DETECTED_FW=""
  DETECTED_UI_LIB=""
  DETECTED_STYLING=""
  DETECTED_DB=""
  DETECTED_TESTING=""
  DETECTED_BUILD_CMD=""
  DETECTED_TEST_CMD=""
  DETECTED_DEV_CMD=""
  DETECTED_CHECK_CMD=""

  # --- 言語検出 ---
  if [[ -f "tsconfig.json" ]]; then
    DETECTED_LANG="TypeScript"
  elif [[ -f "package.json" ]]; then
    DETECTED_LANG="JavaScript"
  elif [[ -f "requirements.txt" ]] || [[ -f "pyproject.toml" ]] || [[ -f "setup.py" ]]; then
    DETECTED_LANG="Python"
  elif [[ -f "Gemfile" ]]; then
    DETECTED_LANG="Ruby"
  elif [[ -f "go.mod" ]]; then
    DETECTED_LANG="Go"
  elif [[ -f "Cargo.toml" ]]; then
    DETECTED_LANG="Rust"
  fi

  # --- フレームワーク検出 ---
  if detect_pkg_dep "next"; then
    local next_ver
    next_ver=$(grep '"next"' package.json 2>/dev/null | head -1 | sed 's/.*: *"\^*~*\([0-9]*\).*/\1/')
    DETECTED_FW="Next.js ${next_ver}"
  elif detect_pkg_dep "nuxt"; then
    local nuxt_ver
    nuxt_ver=$(grep '"nuxt"' package.json 2>/dev/null | head -1 | sed 's/.*: *"\^*~*\([0-9]*\).*/\1/')
    DETECTED_FW="Nuxt ${nuxt_ver}"
  elif detect_pkg_dep "vue"; then
    DETECTED_FW="Vue"
  elif detect_pkg_dep "react"; then
    DETECTED_FW="React"
  elif detect_pkg_dep "express"; then
    DETECTED_FW="Express"
  elif [[ -f "requirements.txt" ]] && grep -q "django" requirements.txt 2>/dev/null; then
    DETECTED_FW="Django"
  elif [[ -f "requirements.txt" ]] && grep -q "flask" requirements.txt 2>/dev/null; then
    DETECTED_FW="Flask"
  elif [[ -f "Gemfile" ]] && grep -q "rails" Gemfile 2>/dev/null; then
    DETECTED_FW="Rails"
  fi

  # --- UIライブラリ検出 ---
  if detect_pkg_dep "@shadcn" || [[ -f "components.json" ]]; then
    DETECTED_UI_LIB="shadcn/ui"
  elif detect_pkg_dep "@mui/material"; then
    DETECTED_UI_LIB="MUI"
  elif detect_pkg_dep "vuetify" || detect_pkg_dep "@nuxtjs/vuetify"; then
    DETECTED_UI_LIB="Vuetify"
  elif detect_pkg_dep "antd"; then
    DETECTED_UI_LIB="Ant Design"
  elif detect_pkg_dep "@chakra-ui"; then
    DETECTED_UI_LIB="Chakra UI"
  fi

  # --- スタイリング検出 ---
  if detect_pkg_dep "tailwindcss"; then
    local tw_ver
    tw_ver=$(grep '"tailwindcss"' package.json 2>/dev/null | head -1 | sed 's/.*: *"\^*~*\([0-9]*\).*/\1/')
    DETECTED_STYLING="Tailwind CSS v${tw_ver}"
  elif [[ -f "styled-components" ]] || detect_pkg_dep "styled-components"; then
    DETECTED_STYLING="styled-components"
  elif detect_pkg_dep "@emotion/react"; then
    DETECTED_STYLING="Emotion"
  fi
  # CSS Modules は設定ファイルなしで使えるため検出困難

  # --- データベース検出 ---
  if detect_pkg_dep "firebase" || detect_pkg_dep "firebase-admin"; then
    DETECTED_DB="Firestore"
  elif detect_pkg_dep "prisma" || detect_pkg_dep "@prisma/client"; then
    DETECTED_DB="PostgreSQL (Prisma)"
  elif detect_pkg_dep "mongoose"; then
    DETECTED_DB="MongoDB"
  elif detect_pkg_dep "mysql2"; then
    DETECTED_DB="MySQL"
  elif detect_pkg_dep "pg"; then
    DETECTED_DB="PostgreSQL"
  elif detect_pkg_dep "better-sqlite3" || detect_pkg_dep "sqlite3"; then
    DETECTED_DB="SQLite"
  fi

  # --- テストFW検出 ---
  if detect_pkg_dep "vitest"; then
    DETECTED_TESTING="Vitest"
  elif detect_pkg_dep "jest"; then
    DETECTED_TESTING="Jest"
  elif detect_pkg_dep "mocha"; then
    DETECTED_TESTING="Mocha"
  elif [[ -f "pytest.ini" ]] || [[ -f "pyproject.toml" ]] && grep -q "pytest" pyproject.toml 2>/dev/null; then
    DETECTED_TESTING="pytest"
  fi

  # --- コマンド検出 ---
  if detect_pkg_script "build"; then
    DETECTED_BUILD_CMD="npm run build"
  elif [[ -f "Makefile" ]]; then
    DETECTED_BUILD_CMD="make build"
  fi

  if detect_pkg_script "test"; then
    DETECTED_TEST_CMD="npm run test"
  elif [[ -f "pytest.ini" ]] || [[ -f "pyproject.toml" ]]; then
    DETECTED_TEST_CMD="pytest"
  fi

  if detect_pkg_script "dev"; then
    DETECTED_DEV_CMD="npm run dev"
  elif detect_pkg_script "start"; then
    DETECTED_DEV_CMD="npm start"
  fi

  # lint/format チェックコマンド検出（"check" を優先、なければ "lint"）
  if detect_pkg_script "check"; then
    DETECTED_CHECK_CMD="npm run check"
  elif detect_pkg_script "lint"; then
    DETECTED_CHECK_CMD="npm run lint"
  fi
}

# Git ブランチの自動検出
detect_git_branches() {
  DETECTED_MAIN_BRANCH=""
  DETECTED_DEVELOP_BRANCH=""

  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    return
  fi

  # メインブランチ検出
  if git show-ref --verify --quiet refs/heads/main 2>/dev/null; then
    DETECTED_MAIN_BRANCH="main"
  elif git show-ref --verify --quiet refs/heads/master 2>/dev/null; then
    DETECTED_MAIN_BRANCH="master"
  fi

  # 開発ブランチ検出
  if git show-ref --verify --quiet refs/heads/develop 2>/dev/null; then
    DETECTED_DEVELOP_BRANCH="develop"
  elif git show-ref --verify --quiet refs/heads/development 2>/dev/null; then
    DETECTED_DEVELOP_BRANCH="development"
  fi
}

# 検出結果を表示（値があれば緑✅、なければ黄色で未検出）
show_detected() {
  local label="$1"
  local value="$2"
  if [[ -n "$value" ]]; then
    printf "  %-16s ${GREEN}%s ✅${NC}\n" "$label:" "$value" >&2
  else
    printf "  %-16s ${YELLOW}（未検出）${NC}\n" "$label:" >&2
  fi
}

# フルウィザード（koumei.config.yaml 生成）
run_wizard() {
  echo ""
  echo -e "${BLUE}╔══════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║   koumei-ai-team-framework 初期設定ウィザード       ║${NC}"
  echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}"
  echo ""

  # --- プロジェクト基本情報 ---
  echo -e "${BLUE}━━━ プロジェクト基本情報 ━━━${NC}"
  local proj_name proj_desc
  local default_name
  default_name=$(basename "$(pwd)")
  proj_name=$(prompt_input "プロジェクト名" "$default_name")
  proj_desc=$(prompt_input "プロジェクトの説明" "")

  # --- 技術スタック（自動検出 → 確認） ---
  echo ""
  echo -e "${BLUE}━━━ 技術スタック ━━━${NC}"
  echo -e "  AIがコードを書く際に従うべき技術スタックです。"
  echo -e "  プロジェクトのファイルから自動検出を試みます..."
  echo ""

  detect_tech_stack

  local has_detection=false
  [[ -n "$DETECTED_LANG" || -n "$DETECTED_FW" || -n "$DETECTED_UI_LIB" || -n "$DETECTED_STYLING" || -n "$DETECTED_DB" || -n "$DETECTED_TESTING" ]] && has_detection=true

  if $has_detection; then
    echo -e "  ${GREEN}検出結果:${NC}"
    echo ""
    echo -e "  ${YELLOW}【コード生成に影響する設定】${NC}"
    echo -e "  ${YELLOW}  AIがコードを書く際、以下の技術に従って実装します${NC}"
    show_detected "言語" "$DETECTED_LANG"
    show_detected "フレームワーク" "$DETECTED_FW"
    show_detected "UIライブラリ" "$DETECTED_UI_LIB"
    echo -e "    ${YELLOW}↑ ボタン・フォーム等の既製UIコンポーネント集${NC}"
    show_detected "スタイリング" "$DETECTED_STYLING"
    echo -e "    ${YELLOW}↑ CSS の書き方（ユーティリティクラス / CSS-in-JS 等）${NC}"
    show_detected "データベース" "$DETECTED_DB"
    show_detected "テストFW" "$DETECTED_TESTING"
    echo ""
    echo -e "  ${YELLOW}【実装後の検証コマンド】${NC}"
    echo -e "  ${YELLOW}  AIが実装後にビルド・テストを実行して動作確認します${NC}"
    show_detected "ビルド" "$DETECTED_BUILD_CMD"
    show_detected "テスト" "$DETECTED_TEST_CMD"
    show_detected "Lint/Format" "$DETECTED_CHECK_CMD"
    echo -e "    ${YELLOW}↑ PR前に実行する lint/format チェック（Biome/ESLint等）${NC}"
    echo ""
  fi

  local lang fw ui_lib styling db testing
  local build_cmd test_cmd check_cmd

  if $has_detection && prompt_yn "検出結果をベースに進めますか？（個別に修正可能）" "y"; then
    echo ""
    echo -e "  ${YELLOW}変更したい項目だけ入力してください。そのままならEnter。${NC}"
    echo ""
    lang=$(prompt_input "言語" "${DETECTED_LANG:-TypeScript}")
    fw=$(prompt_input "フレームワーク" "${DETECTED_FW:-}")
    ui_lib=$(prompt_input "UIライブラリ（なければ空Enter）" "${DETECTED_UI_LIB:-}")
    styling=$(prompt_input "スタイリング（なければ空Enter）" "${DETECTED_STYLING:-}")
    db=$(prompt_input "データベース（なければ空Enter）" "${DETECTED_DB:-}")
    testing=$(prompt_input "テストFW（なければ空Enter）" "${DETECTED_TESTING:-}")
    build_cmd=$(prompt_input "ビルドコマンド" "${DETECTED_BUILD_CMD:-npm run build}")
    test_cmd=$(prompt_input "テストコマンド（なければ空Enter）" "${DETECTED_TEST_CMD:-}")
    echo -e "  ${YELLOW}Lint/Format: PR前に実行する lint/format チェック。空なら工程ごとスキップ${NC}"
    check_cmd=$(prompt_input "Lint/Formatチェックコマンド（なければ空Enter）" "${DETECTED_CHECK_CMD:-}")
  else
    echo ""
    echo -e "  ${YELLOW}手動で入力してください。${NC}"
    echo ""
    lang=$(prompt_input "言語（AIが書くコードの言語）" "TypeScript")
    fw=$(prompt_input "フレームワーク（プロジェクトのFW）" "")
    echo -e "  ${YELLOW}UIライブラリ: AIがUI実装時に使用するコンポーネントライブラリ（例: shadcn/ui, MUI, Vuetify）${NC}"
    ui_lib=$(prompt_input "UIライブラリ（なければ空Enter）" "")
    echo -e "  ${YELLOW}スタイリング: CSSの記述方法（例: Tailwind CSS v4, CSS Modules, styled-components）${NC}"
    styling=$(prompt_input "スタイリング（なければ空Enter）" "")
    echo -e "  ${YELLOW}データベース: AIがクエリやスキーマを書く際の対象DB${NC}"
    db=$(prompt_input "データベース（なければ空Enter）" "")
    echo -e "  ${YELLOW}テストFW: AIがテストを書く際に使用するFW（例: Vitest, Jest, pytest）${NC}"
    testing=$(prompt_input "テストフレームワーク（なければ空Enter）" "")
    echo ""
    echo -e "  ${YELLOW}以下はAIが実装後の検証で実行するコマンドです。${NC}"
    build_cmd=$(prompt_input "ビルドコマンド" "npm run build")
    test_cmd=$(prompt_input "テストコマンド（なければ空Enter）" "")
    echo -e "  ${YELLOW}Lint/Format: PR前に実行する lint/format チェック。空なら工程ごとスキップ${NC}"
    check_cmd=$(prompt_input "Lint/Formatチェックコマンド（なければ空Enter）" "")
  fi

  # --- 成果物出力 ---
  echo ""
  echo -e "${BLUE}━━━ 成果物の出力設定 ━━━${NC}"
  echo -e "  ${YELLOW}AIが生成する設計書・分析レポート・レビュー結果の保存先です。${NC}"
  echo -e "  ${YELLOW}.agents/ 内部ではなくプロジェクトのドキュメントとして残ります。${NC}"
  echo -e "  ${YELLOW}例: 「docs」「docs-confidential」「documents」${NC}"
  echo ""
  local output_dir output_instructions
  output_dir=$(prompt_input "出力先ディレクトリ（プロジェクトルートからの相対パス）" "docs-official")
  echo -e "  ${YELLOW}追加指示: 出力フォーマットの指定等（例: 「既存の.mdファイルを参考にすること」）${NC}"
  output_instructions=$(prompt_input "追加指示（なければ空Enter）" "")

  # --- Git（自動検出 → 確認） ---
  echo ""
  echo -e "${BLUE}━━━ Git運用 ━━━${NC}"
  echo -e "  AIがブランチ作成・PR先決定で従うルールです。"

  detect_git_branches

  if [[ -n "$DETECTED_MAIN_BRANCH" ]]; then
    echo ""
    echo -e "  ${GREEN}検出結果:${NC}"
    show_detected "メインブランチ" "$DETECTED_MAIN_BRANCH"
    show_detected "開発ブランチ" "$DETECTED_DEVELOP_BRANCH"
    echo ""
  fi

  local git_main git_develop git_branch_pattern
  git_main=$(prompt_input "メインブランチ（本番ブランチ）" "${DETECTED_MAIN_BRANCH:-main}")
  echo -e "  ${YELLOW}開発ブランチ: PRの向き先。空ならメインブランチに直接PR${NC}"
  git_develop=$(prompt_input "開発ブランチ（なければ空Enter）" "${DETECTED_DEVELOP_BRANCH:-}")
  echo -e "  ${YELLOW}ブランチ名パターン: {number}はタスク番号、{summary}はタスク概要に自動置換${NC}"
  local default_bp='feature/task-{number}-{summary}'
  git_branch_pattern=$(prompt_input "ブランチ命名パターン" "$default_bp")

  # --- ターゲットCLI選択 ---
  echo ""
  echo -e "${BLUE}━━━ ターゲットCLI選択 ━━━${NC}"
  echo -e "  ${YELLOW}展開先のCLIツールを選択してください。${NC}"
  echo -e "  ${YELLOW}スキルファイルの配置先やエージェント指示ファイル名が変わります。${NC}"
  echo ""
  echo -e "  1) Claude Code     ${GREEN}(.claude/skills + CLAUDE.md)${NC}"
  echo -e "  2) Codex CLI       ${GREEN}(.codex/skills + AGENTS.md)${NC}"
  echo -e "  3) Antigravity CLI ${GREEN}(.agents/skills + AGENTS.md)${NC}"
  echo ""
  local cli_choice
  cli_choice=$(prompt_input "ターゲットCLI [1-3]" "1")
  # wizard_default_model: koumei/analyst/ux-designer 用
  # wizard_design_model: tech-lead設計・devils-advocate 用（判断のレバレッジが高い箇所に上位モデル）
  # wizard_impl_model:   tech-lead実装 用（トークン量が多いため設計より1段下）
  local wizard_target_cli wizard_default_model wizard_design_model wizard_impl_model
  case "$cli_choice" in
    2) wizard_target_cli="codex";       wizard_default_model="gpt-5.3-codex"; wizard_design_model="gpt-5.3-codex"; wizard_impl_model="gpt-5.3-codex" ;;
    3) wizard_target_cli="antigravity"; wizard_default_model="gemini-3.5-pro"; wizard_design_model="gemini-3.5-pro"; wizard_impl_model="gemini-3.5-pro" ;;
    *) wizard_target_cli="claude";      wizard_default_model="sonnet"; wizard_design_model="fable"; wizard_impl_model="opus" ;;
  esac

  # --- スキルプレフィックス ---
  echo ""
  echo -e "${BLUE}━━━ スキルコマンド設定 ━━━${NC}"
  echo -e "  ${YELLOW}スキルコマンドの接頭辞です。${NC}"
  echo -e "  ${YELLOW}この接頭辞でスキルディレクトリ名とコマンド名が決まります。${NC}"
  echo -e "  例: 「koumei」→ /koumei-start, /koumei-review"
  echo -e "  例: 「km」→ /km-start, /km-review"
  echo -e "  例: 「dev」→ /dev-start, /dev-review"
  local skill_prefix
  skill_prefix=$(prompt_input "スキルプレフィックス" "koumei")

  # --- 指揮者 ---
  echo ""
  echo -e "${BLUE}━━━ 指揮者設定 ━━━${NC}"
  echo -e "  ${YELLOW}AIチームの最高指揮者（koumei）のコードネームです。${NC}"
  echo -e "  ${YELLOW}スキル説明やタスク定義書に表示されます。${NC}"
  echo -e "  例: 「諸葛孔明」「Commander」「Archimedes」"
  local commander_name
  commander_name=$(prompt_input "指揮者の名前" "諸葛孔明")

  # --- ロール選択 ---
  wizard_select_roles

  # --- 移行プロジェクト ---
  echo ""
  echo -e "${BLUE}━━━ 移行プロジェクト設定 ━━━${NC}"
  echo -e "  ${YELLOW}既存システムから新システムへの移行プロジェクトの場合に設定します。${NC}"
  echo -e "  ${YELLOW}※現バージョンでは設定の記録のみ（テンプレートへの配線は今後対応）。${NC}"
  local mig_enabled="false" mig_source="" mig_source_fw="" mig_target_fw=""
  if prompt_yn "既存システムからの移行プロジェクトですか？"; then
    mig_enabled="true"
    mig_source=$(prompt_input "移行元プロジェクトのパス" "")
    mig_source_fw=$(prompt_input "移行元フレームワーク（例: Nuxt 2, Rails 5）" "")
    mig_target_fw=$(prompt_input "移行先フレームワーク（例: Next.js 15）" "$fw")
  fi

  # --- YAML生成 ---
  echo ""
  log_step "koumei.config.yaml を生成中..."

  # ロール配列を生成
  local roles_yaml=""
  for r in "${WIZARD_SELECTED_ROLES[@]}"; do
    roles_yaml+="  - ${r}"$'\n'
  done

  # output.instructions のYAMLフォーマット
  local output_inst_yaml=""
  if [[ -n "$output_instructions" ]]; then
    output_inst_yaml="  instructions: |
    ${output_instructions}"
  else
    output_inst_yaml="  instructions: \"\""
  fi

  # --- 課題管理システム連携 ---
  #
  # Yes / No のどちらでも節を書き出す。節が無い config と enabled:false の config は
  # 生成物としては同一だが、利用者にとっては全く違う。枠があればコメントごと目に入り、
  # キーの綴りも「入れ子にしない」という制約も一緒に伝わる。
  # 後から自力で書き足させると、間違えても黙って空を返すため気づけない。
  echo ""
  log_info "課題管理システム連携（無人運転で使用。後から変更できます）"

  read_ticket_map ""          # 変数を必ず初期化する（マップ無しでも空文字で揃える）
  local ticket_map_path="" ticket_map_explicit="false"
  if [[ -n "$TICKET_MAP_ARG" ]]; then
    ticket_map_path="$TICKET_MAP_ARG"; ticket_map_explicit="true"
  elif [[ -r "$TICKET_MAP_DEFAULT" ]]; then
    ticket_map_path="$TICKET_MAP_DEFAULT"
  fi

  if [[ -n "$ticket_map_path" ]]; then
    if read_ticket_map "$ticket_map_path"; then
      log_info "  状態名マップを読み込みました: ${ticket_map_path}"
    elif [[ "$ticket_map_explicit" == "true" ]]; then
      # 明示したのに読めないなら止める。黙って空で進めば、
      # 「マップから入ったつもりの空欄」が残り、遷移しない理由が判らなくなる
      log_error "--ticket-map で指定したファイルを読めません: ${ticket_map_path}"
      exit 1
    fi
  fi

  local t_enabled="false" t_queue=""
  if prompt_yn "  課題管理システムと連携しますか？（チケットで行列を作り、状態を遷移させます）"; then
    t_enabled="true"
    echo ""
    log_info "  行列の条件は「必ず自分の担当に絞る」こと。絞らなければ夜中に他の担当者のチケットまで拾います。"
    log_info "  例: status = \"AI-READY\" AND assignee = currentUser()"
    t_queue=$(prompt_input "  行列の条件（空欄なら後で config に書く）" "")
  fi
  if [[ "$TICKET_MAP_LOADED" != "true" ]]; then
    # 連携しない場合にも告げる。節は必ず書き出されるので、後から有効にする人が居る。
    # そのとき状態名7項目を手入力させれば、間違いを撒くだけである
    log_info "  状態名は config の ticket 節に後から書けます。"
    log_info "  組織で共通なら ${TICKET_MAP_DEFAULT} に置くと、次回から自動で埋まります（--ticket-map でも指定可）。"
  fi

  local t_queue_yaml='  queue: ""'
  if [[ -n "$t_queue" ]]; then
    # 引用符や # を含むため必ず | ブロック形式。プレーンスカラーは yq 無し環境で壊れる
    t_queue_yaml="  queue: |
    ${t_queue}"
  fi

  local ticket_yaml
  ticket_yaml="# === 課題管理システム連携（任意） ===
# 無人運転（/${skill_prefix}-start --unattended）で消費される。
# 接続手段（MCP・CLI・API）は枠組みの管轄外。ここで定めるのは
# 「どこから引き、いつ何処へ動かすか」のみ。
# status_* は入れ子にしないこと（yq 無し環境のパーサは2階層までしか読めず黙って空を返す）
ticket:
  enabled: ${t_enabled}
  # 無人運転が引く行列の条件。必ず自分の担当に絞ること。
  # 空欄のまま enabled: true にすると連携は無効となり、無人運転は起動せず報告して終える
  # ※ 引用符や # を含むため、必ず | ブロック形式で記述すること
${t_queue_yaml}
  # この現場で実際に使われている状態名を書く。空欄の項目は遷移させない
  status_designing: \"${MAP_STATUS_DESIGNING}\"
  status_implementing: \"${MAP_STATUS_IMPLEMENTING}\"
  status_review_ready: \"${MAP_STATUS_REVIEW_READY}\"
  status_parked: \"${MAP_STATUS_PARKED}\"
  # 下の三つ（staging_ok / staging_ng / parked）が揃ったときだけ、
  # Phase 7 のSTAGING確認チェックリストが状態遷移の指示として生成される
  status_staging_ok: \"${MAP_STATUS_STAGING_OK}\"
  status_staging_ng: \"${MAP_STATUS_STAGING_NG}\""

  cat > "$CONFIG_FILE" << YAML_EOF
# ============================================================
# koumei-ai-team-framework 設定ファイル
# Generated by setup wizard v${VERSION}
# ============================================================

# === プロジェクト基本情報 ===
project:
  name: "${proj_name}"
  description: "${proj_desc}"
  path: "."

# === 移行プロジェクト設定 ===
migration:
  enabled: ${mig_enabled}
  source_path: "${mig_source}"
  source_framework: "${mig_source_fw}"
  target_framework: "${mig_target_fw}"

# === ロール構成 ===
# コアロール（koumei, tech-lead, devils-advocate）は必須
# setup.sh --roles で後から変更可能
roles:
${roles_yaml}
# === スキルコマンド設定 ===
target_cli: "${wizard_target_cli}"
skill_prefix: "${skill_prefix}"

# === 指揮者設定 ===
commander:
  name: "${commander_name}"

# === 各ロール モデル設定 ===
# tech-lead はフェーズ分割（設計/実装）。高単価モデルは判断のレバレッジが高い箇所（設計・レビュー判定）に置く
models:
  koumei: "${wizard_default_model}"
  analyst: "${wizard_default_model}"
  inquisitor: "${wizard_design_model}"
  ux-designer: "${wizard_default_model}"
  tech-lead-design: "${wizard_design_model}"
  tech-lead-implement: "${wizard_impl_model}"
  devils-advocate: "${wizard_design_model}"
  scribe: "${wizard_default_model}"

# === レビュー設定 ===
review:
  mode: "default"                    # default（codex→claude） | economy（codex→lmstudio→claude） | claude-only
  timeout: 600                       # 外部CLIレビューのタイムアウト（秒）。超過で次順位モデルにフォールバック

# === 詰問設定（inquisitor ロール有効時） ===
grilling:
  max_rounds: 3                      # 詰問の最大ラウンド数。論点が出尽くせば早期終了する
  escalate: "high"                   # high（リスク高の未決のみユーザーに確認）| none（一切停止せずAI判断で確定）

# === 技術スタック ===
tech_stack:
  language: "${lang}"
  framework: "${fw}"
  ui_library: "${ui_lib}"
  styling: "${styling}"
  database: "${db}"
  testing: "${testing}"
  build_command: "${build_cmd}"
  test_command: "${test_cmd}"
  check_command: "${check_cmd}"

# === 成果物の出力設定 ===
output:
  dir: "${output_dir}"
  format: "md"
${output_inst_yaml}

# === Git運用 ===
git:
  main_branch: "${git_main}"
  develop_branch: "${git_develop}"
  branch_pattern: "${git_branch_pattern}"
  dev_rules: ""                      # TEAM.md の開発規約に追記する行（任意・複数行は | 形式で）

${ticket_yaml}

# === カスタム指示（各ロールの指示ファイルに追記される） ===
custom_instructions:
  koumei: ""
  tech-lead: ""
  devils-advocate: ""
  analyst: ""
  inquisitor: ""
  ux-designer: ""
  scribe: ""

# === 参照ドキュメント ===
reference_docs: []
YAML_EOF

  log_info "koumei.config.yaml を生成しました。"
  echo ""
}

# 状態名マップを読む
#
# 状態名の対応表は「組織の事実」であってプロジェクトの事実ではない。同じワークフローを
# 使う限り全プロジェクト共通であり、7項目をプロジェクトごとに手入力するのは間違いを撒く作業。
#
# **マップは「設定を書くための材料」であって、生成時に読むものではない。**
# 生成時に読む方式にすると、マップを持たない人が同じリポジトリで setup.sh を叩いたとき
# 違う生成物ができる。書き込み方式なら config が自己完結し、誰が叩いても同じものが出る。
#
# queue は取り込まない。行列条件はプロジェクト固有であり、「自分の担当に絞る」ことが
# 安全性の根拠である。共有ファイルに置けば、絞り込みの共有＝他人のチケットを夜中に拾う事故を招く。
read_ticket_map() {
  local path="$1"
  TICKET_MAP_LOADED="false"
  MAP_STATUS_DESIGNING=""; MAP_STATUS_IMPLEMENTING=""; MAP_STATUS_REVIEW_READY=""
  MAP_STATUS_PARKED="";    MAP_STATUS_STAGING_OK="";   MAP_STATUS_STAGING_NG=""
  [[ -z "$path" ]] && return 0
  [[ -r "$path" ]] || return 1

  local k v
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*([a-z_]+)[[:space:]]*:[[:space:]]*(.*)$ ]] || continue
    k="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"
    v="${v%%#*}"                                  # 行末コメントを落とす
    v="$(printf '%s' "$v" | sed 's/[[:space:]]*$//')"
    v="${v%\"}"; v="${v#\"}"                       # 引用符を剥がす
    case "$k" in
      status_designing)    MAP_STATUS_DESIGNING="$v" ;;
      status_implementing) MAP_STATUS_IMPLEMENTING="$v" ;;
      status_review_ready) MAP_STATUS_REVIEW_READY="$v" ;;
      status_parked)       MAP_STATUS_PARKED="$v" ;;
      status_staging_ok)   MAP_STATUS_STAGING_OK="$v" ;;
      status_staging_ng)   MAP_STATUS_STAGING_NG="$v" ;;
      queue) log_warn "状態名マップに queue がありますが取り込みません（行列条件はプロジェクト固有のため）。" ;;
    esac
  done < "$path"
  TICKET_MAP_LOADED="true"
  return 0
}

# ロール変更ウィザード（既存config のロール部分だけ書き換え）
run_roles_wizard() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "koumei.config.yaml が見つかりません。先に setup.sh を実行してください。"
    exit 1
  fi

  echo ""
  echo -e "${BLUE}╔══════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║   ロール構成の変更                       ║${NC}"
  echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}"

  # 現在のロールを表示
  echo ""
  echo -e "現在のロール構成:"
  local current_roles=()
  while IFS= read -r role; do
    [[ -n "$role" ]] && current_roles+=("$role")
  done < <(yaml_get_array "roles")
  echo -e "  ${GREEN}${current_roles[*]}${NC}"

  # 新しいロールを選択
  wizard_select_roles

  # config ファイルのロール部分を書き換え（Perl で）
  local roles_yaml=""
  for r in "${WIZARD_SELECTED_ROLES[@]}"; do
    roles_yaml+="  - ${r}\n"
  done

  perl -i -0777 -pe "
    s/^roles:\n(  - .+\n)+/roles:\n${roles_yaml}/m;
  " "$CONFIG_FILE"

  log_info "ロール構成を更新しました: ${WIZARD_SELECTED_ROLES[*]}"
  echo ""
  log_step "変更を反映するためにセットアップを実行します..."
  echo ""
}

# CLI ラベルを返す（codex/claude/antigravity）
cli_display_label() {
  case "$1" in
    codex)       echo "Codex CLI (.codex/skills + AGENTS.md)" ;;
    claude)      echo "Claude Code (.claude/skills + CLAUDE.md)" ;;
    antigravity) echo "Antigravity CLI (.agents/skills + AGENTS.md)" ;;
    *)           echo "$1" ;;
  esac
}

# CLI 変更ウィザード（既存config の target_cli だけ書き換え）
# 旧CLI用のスキル/エージェント指示ファイルは PREVIOUS_TARGET_CLI に記録し、
# do_setup の前に cleanup_previous_cli で削除する。
PREVIOUS_TARGET_CLI=""
run_cli_wizard() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "koumei.config.yaml が見つかりません。先に setup.sh を実行してください。"
    exit 1
  fi

  echo ""
  echo -e "${BLUE}╔══════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║   対象CLIの変更                          ║${NC}"
  echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}"

  # 現在のCLIを表示
  local current_cli
  current_cli=$(yaml_get "target_cli")
  current_cli="${current_cli:-$DEFAULT_TARGET_CLI}"
  echo ""
  echo -e "現在の対象CLI: ${GREEN}$(cli_display_label "$current_cli")${NC}"
  echo ""

  echo -e "  1) Claude Code     ${GREEN}(.claude/skills + CLAUDE.md)${NC}"
  echo -e "  2) Codex CLI       ${GREEN}(.codex/skills + AGENTS.md)${NC}"
  echo -e "  3) Antigravity CLI ${GREEN}(.agents/skills + AGENTS.md)${NC}"
  echo ""

  local cli_choice new_cli
  cli_choice=$(prompt_input "新しい対象CLI [1-3]" "1")
  case "$cli_choice" in
    2) new_cli="codex" ;;
    3) new_cli="antigravity" ;;
    *) new_cli="claude" ;;
  esac

  if [[ "$new_cli" == "$current_cli" ]]; then
    log_info "対象CLIに変更はありません: ${new_cli}"
    PREVIOUS_TARGET_CLI=""
    return
  fi

  # target_cli の値を書き換え
  perl -i -pe 's/^target_cli:\s*.*$/target_cli: "'"$new_cli"'"/' "$CONFIG_FILE"

  PREVIOUS_TARGET_CLI="$current_cli"
  log_info "対象CLIを更新しました: ${current_cli} → ${new_cli}"
  echo ""
  log_step "旧CLI用のファイルを整理し、新CLIで再展開します..."
  echo ""
}

# 旧CLI用のスキル/エージェント指示ファイルを削除
# 引数: $1 = 旧CLI ("codex"|"claude"|"antigravity")
cleanup_previous_cli() {
  local previous_cli="$1"
  [[ -z "$previous_cli" ]] && return

  local previous_skills_dir previous_agent_filename
  case "$previous_cli" in
    codex)       previous_skills_dir=".codex/skills";  previous_agent_filename="AGENTS.md" ;;
    claude)      previous_skills_dir=".claude/skills"; previous_agent_filename="CLAUDE.md" ;;
    antigravity) previous_skills_dir=".agents/skills"; previous_agent_filename="AGENTS.md" ;;
    *)           return ;;
  esac

  local prefix="${SKILL_PREFIX:-koumei}"

  # 旧CLI用のスキルディレクトリを削除（新CLIと共有する .agents/skills は対象外）
  if [[ "$previous_skills_dir" != "$SKILLS_DIR" && -d "$previous_skills_dir" ]]; then
    local removed_any=false
    for dir in "${previous_skills_dir}"/${prefix}-*; do
      if [[ -d "$dir" ]]; then
        if $DRY_RUN; then
          log_info "[DRY-RUN] Would remove: $dir"
        else
          rm -rf "$dir"
          log_info "削除: $dir"
        fi
        removed_any=true
      fi
    done
    # スキルディレクトリが空になったら削除
    if ! $DRY_RUN && $removed_any && [[ -d "$previous_skills_dir" ]] && [[ -z "$(ls -A "$previous_skills_dir" 2>/dev/null)" ]]; then
      rmdir "$previous_skills_dir" 2>/dev/null || true
    fi
  fi

  # 旧CLI用のエージェント指示ファイル名が新CLIと異なる場合は削除（do_setup で新ファイル名のものを生成）
  if [[ "$previous_agent_filename" != "$AGENT_INSTRUCTIONS_FILENAME" ]]; then
    for role_dir in koumei tech-lead devils-advocate analyst inquisitor ux-designer task-manager; do
      local old_file=".agents/${role_dir}/${previous_agent_filename}"
      if [[ -f "$old_file" ]]; then
        if is_git_tracked "$old_file"; then
          log_warn "スキップ: ${old_file}（Git管理下のため手動で削除してください）"
        elif $DRY_RUN; then
          log_info "[DRY-RUN] Would remove: $old_file"
        else
          rm -f "$old_file"
          log_info "削除: $old_file"
        fi
      fi
    done
  fi
}

# ============================================================
# YAML パーサー（yq優先、なければ簡易awkパーサー）
# ============================================================

# yq が利用可能かチェック
has_yq() {
  command -v yq &>/dev/null
}

# yq でYAML値を取得
yq_get() {
  local key="$1"
  yq eval "$key" "$CONFIG_FILE" 2>/dev/null
}

# awk ベースの簡易YAMLパーサー
# ネストされたキーは "." で区切る（例: "project.name"）
awk_yaml_get() {
  local key="$1"
  local file="$2"

  # トップレベルの単純なキー
  if [[ "$key" != *.* ]]; then
    awk -v key="$key" '
      $0 ~ "^"key":" { gsub(/^[^:]+:[[:space:]]*/, ""); sub(/[[:space:]]+#.*/, ""); gsub(/["\x27]/, ""); print; exit }
    ' "$file"
    return
  fi

  # ネストされたキー（2レベルまで対応）
  local parent="${key%%.*}"
  local child="${key#*.}"

  awk -v parent="$parent" -v child="$child" '
    BEGIN { in_parent = 0 }
    $0 ~ "^"parent":" { in_parent = 1; next }
    in_parent && /^[a-zA-Z_]/ { in_parent = 0 }
    in_parent && $0 ~ "^[[:space:]]+"child":" {
      gsub(/^[[:space:]]+[^:]+:[[:space:]]*/, "")
      sub(/[[:space:]]+#.*/, "")
      gsub(/["\x27]/, "")
      print
      exit
    }
  ' "$file"
}

# YAML配列の要素を取得（rolesなど）
awk_yaml_get_array() {
  local key="$1"
  local file="$2"

  awk -v key="$key" '
    BEGIN { in_key = 0 }
    $0 ~ "^"key":" { in_key = 1; next }
    in_key && /^[a-zA-Z_]/ { exit }
    in_key && /^[[:space:]]*-[[:space:]]/ {
      gsub(/^[[:space:]]*-[[:space:]]*/, "")
      sub(/[[:space:]]+#.*/, "")
      gsub(/["\x27[:space:]]/, "")
      if ($0 !~ /^#/ && $0 != "") print
    }
  ' "$file"
}

# YAML複数行値を取得（custom_instructions等）
awk_yaml_get_multiline() {
  local parent="$1"
  local child="$2"
  local file="$3"

  awk -v parent="$parent" -v child="$child" '
    BEGIN { in_parent = 0; in_child = 0; indent = 0 }
    $0 ~ "^"parent":" { in_parent = 1; next }
    in_parent && /^[a-zA-Z_]/ { in_parent = 0 }
    in_parent && $0 ~ "^[[:space:]]+"child":[[:space:]]*\\|" {
      in_child = 1
      # インデントレベルを記録
      match($0, /^[[:space:]]+/)
      indent = RLENGTH + 2
      next
    }
    in_parent && in_child {
      # インデントが浅くなったら終了
      if ($0 !~ /^[[:space:]]*$/ && $0 !~ "^"sprintf("%*s", indent, "")) {
        exit
      }
      # インデントを削除して出力
      sub("^"sprintf("%*s", indent, ""), "")
      print
    }
  ' "$file"
}

# 統合的なYAML値取得関数
yaml_get() {
  local key="$1"
  if has_yq; then
    local result
    result=$(yq_get ".$key")
    # yq は値がない場合 "null" を返す
    if [[ "$result" == "null" || -z "$result" ]]; then
      echo ""
    else
      echo "$result"
    fi
  else
    awk_yaml_get "$key" "$CONFIG_FILE"
  fi
}

# 統合的なYAML配列取得関数
yaml_get_array() {
  local key="$1"
  if has_yq; then
    yq_get ".${key}[]" 2>/dev/null | grep -v '^$' || true
  else
    awk_yaml_get_array "$key" "$CONFIG_FILE"
  fi
}

# 統合的なYAML複数行値取得関数
yaml_get_multiline() {
  local parent="$1"
  local child="$2"
  if has_yq; then
    local result
    result=$(yq_get ".${parent}.${child}")
    if [[ "$result" == "null" || -z "$result" ]]; then
      echo ""
    else
      echo "$result"
    fi
  else
    awk_yaml_get_multiline "$parent" "$child" "$CONFIG_FILE"
  fi
}

# キーが存在するかどうかだけを判定（値の中身は見ない。空文字の正規設定と「未設定」を区別するため）
# ネストされたキーは "." で区切る（例: "tech_stack.check_command"）
yaml_has_key() {
  local key="$1"
  local file="$2"

  if [[ "$key" != *.* ]]; then
    grep -qE "^${key}:" "$file"
    return
  fi

  local parent="${key%%.*}"
  local child="${key#*.}"

  awk -v parent="$parent" -v child="$child" '
    BEGIN { in_parent = 0; found = 0 }
    $0 ~ "^"parent":" { in_parent = 1; next }
    in_parent && /^[a-zA-Z_]/ { in_parent = 0 }
    in_parent && $0 ~ "^[[:space:]]+"child":" { found = 1; exit }
    END { exit !found }
  ' "$file"
}

# ============================================================
# 設定の読み込み
# ============================================================

load_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo ""
    log_warn "koumei.config.yaml が見つかりません。"
    echo ""
    if prompt_yn "初期設定ウィザードを開始しますか？" "y"; then
      run_wizard
    else
      log_info "手動で作成する場合はサンプルをコピーしてください:"
      log_info "  cp ${SCRIPT_DIR}/koumei.config.example.yaml ./${CONFIG_FILE}"
      exit 0
    fi
  fi

  log_step "設定ファイルを読み込み中..."

  # プロジェクト情報
  PROJECT_NAME=$(yaml_get "project.name")
  PROJECT_DESCRIPTION=$(yaml_get "project.description")
  PROJECT_PATH=$(yaml_get "project.path")

  # 移行設定
  MIGRATION_ENABLED=$(yaml_get "migration.enabled")
  MIGRATION_SOURCE_PATH=$(yaml_get "migration.source_path")
  MIGRATION_SOURCE_FRAMEWORK=$(yaml_get "migration.source_framework")
  MIGRATION_TARGET_FRAMEWORK=$(yaml_get "migration.target_framework")

  # スキルプレフィックス
  TARGET_CLI=$(yaml_get "target_cli")
  TARGET_CLI="${TARGET_CLI:-$DEFAULT_TARGET_CLI}"
  case "$TARGET_CLI" in
    codex)
      AI_CLI_NAME="Codex CLI"
      SKILLS_DIR=".codex/skills"
      AGENT_INSTRUCTIONS_FILENAME="AGENTS.md"
      ;;
    claude)
      AI_CLI_NAME="Claude Code"
      SKILLS_DIR=".claude/skills"
      AGENT_INSTRUCTIONS_FILENAME="CLAUDE.md"
      ;;
    antigravity)
      AI_CLI_NAME="Antigravity CLI"
      SKILLS_DIR=".agents/skills"
      AGENT_INSTRUCTIONS_FILENAME="AGENTS.md"
      ;;
    *)
      log_warn "不明な target_cli '${TARGET_CLI}' のため claude として扱います。"
      TARGET_CLI="claude"
      AI_CLI_NAME="Claude Code"
      SKILLS_DIR=".claude/skills"
      AGENT_INSTRUCTIONS_FILENAME="CLAUDE.md"
      ;;
  esac

  # スキルプレフィックス
  SKILL_PREFIX=$(yaml_get "skill_prefix")
  SKILL_PREFIX="${SKILL_PREFIX:-koumei}"

  # 指揮者設定
  COMMANDER_NAME=$(yaml_get "commander.name")
  COMMANDER_NAME="${COMMANDER_NAME:-諸葛孔明}"

  # モデル設定
  MODEL_KOUMEI=$(yaml_get "models.koumei")
  MODEL_ANALYST=$(yaml_get "models.analyst")
  MODEL_INQUISITOR=$(yaml_get "models.inquisitor")
  MODEL_UX_DESIGNER=$(yaml_get "models.ux-designer")
  MODEL_TECH_LEAD_DESIGN=$(yaml_get "models.tech-lead-design")
  MODEL_TECH_LEAD_IMPLEMENT=$(yaml_get "models.tech-lead-implement")
  MODEL_DEVILS_ADVOCATE=$(yaml_get "models.devils-advocate")
  MODEL_SCRIBE=$(yaml_get "models.scribe")
  case "$TARGET_CLI" in
    codex)
      MODEL_KOUMEI="${MODEL_KOUMEI:-gpt-5.3-codex}"
      MODEL_ANALYST="${MODEL_ANALYST:-gpt-5.3-codex}"
      MODEL_INQUISITOR="${MODEL_INQUISITOR:-gpt-5.3-codex}"
      MODEL_UX_DESIGNER="${MODEL_UX_DESIGNER:-gpt-5.3-codex}"
      MODEL_TECH_LEAD_DESIGN="${MODEL_TECH_LEAD_DESIGN:-gpt-5.3-codex}"
      MODEL_TECH_LEAD_IMPLEMENT="${MODEL_TECH_LEAD_IMPLEMENT:-gpt-5.3-codex}"
      MODEL_DEVILS_ADVOCATE="${MODEL_DEVILS_ADVOCATE:-gpt-5.3-codex}"
      MODEL_SCRIBE="${MODEL_SCRIBE:-gpt-5.3-codex}"
      ;;
    antigravity)
      MODEL_KOUMEI="${MODEL_KOUMEI:-gemini-3.5-pro}"
      MODEL_ANALYST="${MODEL_ANALYST:-gemini-3.5-flash}"
      MODEL_INQUISITOR="${MODEL_INQUISITOR:-gemini-3.5-pro}"
      MODEL_UX_DESIGNER="${MODEL_UX_DESIGNER:-gemini-3.5-flash}"
      MODEL_TECH_LEAD_DESIGN="${MODEL_TECH_LEAD_DESIGN:-gemini-3.5-pro}"
      MODEL_TECH_LEAD_IMPLEMENT="${MODEL_TECH_LEAD_IMPLEMENT:-gemini-3.5-pro}"
      MODEL_DEVILS_ADVOCATE="${MODEL_DEVILS_ADVOCATE:-gemini-3.5-pro}"
      MODEL_SCRIBE="${MODEL_SCRIBE:-gemini-3.5-pro}"
      ;;
    *)
      MODEL_KOUMEI="${MODEL_KOUMEI:-sonnet}"
      MODEL_ANALYST="${MODEL_ANALYST:-sonnet}"
      MODEL_INQUISITOR="${MODEL_INQUISITOR:-fable}"
      MODEL_UX_DESIGNER="${MODEL_UX_DESIGNER:-sonnet}"
      MODEL_TECH_LEAD_DESIGN="${MODEL_TECH_LEAD_DESIGN:-fable}"
      MODEL_TECH_LEAD_IMPLEMENT="${MODEL_TECH_LEAD_IMPLEMENT:-opus}"
      MODEL_DEVILS_ADVOCATE="${MODEL_DEVILS_ADVOCATE:-fable}"
      # scribe: 要約・選別は理解を要し、取りこぼしは下流で検知できない。
      # 重い資料の書き出しで軽量モデルが停止する実測（token-economy.md 定め7）もあるため haiku は避ける
      MODEL_SCRIBE="${MODEL_SCRIBE:-sonnet}"
      ;;
  esac

  # レビュー設定
  REVIEW_MODE=$(yaml_get "review.mode")
  REVIEW_MODE="${REVIEW_MODE:-default}"
  REVIEW_TIMEOUT=$(yaml_get "review.timeout")
  REVIEW_TIMEOUT="${REVIEW_TIMEOUT:-600}"

  # 詰問設定（inquisitor ロール有効時のみ消費される）
  GRILLING_MAX_ROUNDS=$(yaml_get "grilling.max_rounds")
  GRILLING_MAX_ROUNDS="${GRILLING_MAX_ROUNDS:-3}"
  GRILLING_ESCALATE=$(yaml_get "grilling.escalate")
  GRILLING_ESCALATE="${GRILLING_ESCALATE:-high}"
  if [[ "$GRILLING_ESCALATE" != "high" && "$GRILLING_ESCALATE" != "none" ]]; then
    log_warn "grilling.escalate の値が不正です（'${GRILLING_ESCALATE}'）。high / none のいずれかを指定してください。high として扱います。"
    GRILLING_ESCALATE="high"
  fi

  # 課題管理システム連携（任意・無人運転で消費される）
  # 未設定のプロジェクトを壊さないため CONFIG_REQUIRED_KEYS には加えない。
  # 欠落＝無効として扱い、連携の記述は一切展開しない
  TICKET_QUEUE_MISSING="false"
  TICKET_ENABLED=$(yaml_get "ticket.enabled")
  # queue は引用符・# を含むため multiline 経由で取る（プレーンスカラーだと引用符が剥がれる）
  TICKET_QUEUE=$(yaml_get_multiline "ticket" "queue")
  # ネストは2階層まで（awk フォールバックの制約）。status.* ではなく status_* と平らに持つ
  TICKET_STATUS_DESIGNING=$(yaml_get "ticket.status_designing")
  TICKET_STATUS_IMPLEMENTING=$(yaml_get "ticket.status_implementing")
  TICKET_STATUS_REVIEW_READY=$(yaml_get "ticket.status_review_ready")
  TICKET_STATUS_PARKED=$(yaml_get "ticket.status_parked")
  TICKET_STATUS_STAGING_OK=$(yaml_get "ticket.status_staging_ok")
  TICKET_STATUS_STAGING_NG=$(yaml_get "ticket.status_staging_ng")
  if [[ "$TICKET_ENABLED" == "true" ]]; then
    # 行列の絞り込みを欠いた連携は、他人のチケットまで夜中に拾う。有効化させない
    if [[ -z "$TICKET_QUEUE" ]]; then
      log_warn "ticket.enabled: true ですが ticket.queue が空です。無人運転が他の担当者のチケットまで拾うため、連携を無効として扱います。"
      TICKET_ENABLED="false"
      # 無効化しただけでは「チケット駆動で回すつもりだった」という意思が消える。
      # 対話実行はこの警告を人が読めるが、無人運転には読む人が居ない。
      # 旗を立てて、無人運転側の起動前検査に「落とせ」と書かせる
      TICKET_QUEUE_MISSING="true"
    fi
  else
    TICKET_ENABLED="false"
  fi

  # STAGING確認の判定は「合格・不合格・保留」の三つの行き先を持つ。
  # 三つ揃ってはじめて状態遷移の指示として書ける。一つでも欠ければ
  # 「**  ** へ移す」という空の指示が生成物に出てしまうため、
  # その場合は判定を一般形（その現場の言葉で書く）のまま出す。
  TICKET_STAGING_ENABLED="false"
  if [[ "$TICKET_ENABLED" == "true" \
        && -n "$TICKET_STATUS_STAGING_OK" \
        && -n "$TICKET_STATUS_STAGING_NG" \
        && -n "$TICKET_STATUS_PARKED" ]]; then
    TICKET_STAGING_ENABLED="true"
  fi

  # 開発規約の追加行（任意）
  # ブロックスカラー（dev_rules: |）優先、プレーンスカラー（dev_rules: "..."）にもフォールバック
  # （awk フォールバックパーサーはブロックスカラーしか読めず、yq 有無で挙動が割れるため）
  DEV_RULES=$(yaml_get_multiline "git" "dev_rules")
  [[ -z "$DEV_RULES" ]] && DEV_RULES=$(yaml_get "git.dev_rules")

  # 技術スタック
  TECH_LANGUAGE=$(yaml_get "tech_stack.language")
  TECH_FRAMEWORK=$(yaml_get "tech_stack.framework")
  TECH_UI_LIBRARY=$(yaml_get "tech_stack.ui_library")
  TECH_STYLING=$(yaml_get "tech_stack.styling")
  TECH_DATABASE=$(yaml_get "tech_stack.database")
  TECH_TESTING=$(yaml_get "tech_stack.testing")
  BUILD_COMMAND=$(yaml_get "tech_stack.build_command")
  BUILD_COMMAND="${BUILD_COMMAND:-npm run build}"
  TEST_COMMAND=$(yaml_get "tech_stack.test_command")
  TEST_COMMAND="${TEST_COMMAND:-npm run test}"
  # lint/format チェック: デフォルトなし（空ならチェック工程をスキップ）
  CHECK_COMMAND=$(yaml_get "tech_stack.check_command")

  # Git設定
  GIT_MAIN_BRANCH=$(yaml_get "git.main_branch")
  GIT_MAIN_BRANCH="${GIT_MAIN_BRANCH:-main}"
  GIT_DEVELOP_BRANCH=$(yaml_get "git.develop_branch")
  GIT_BRANCH_PATTERN=$(yaml_get "git.branch_pattern")
  local default_branch_pattern='feature/task-{number}-{summary}'
  GIT_BRANCH_PATTERN="${GIT_BRANCH_PATTERN:-$default_branch_pattern}"

  # 成果物出力設定
  OUTPUT_DIR=$(yaml_get "output.dir")
  OUTPUT_DIR="${OUTPUT_DIR:-docs-official}"
  OUTPUT_FORMAT=$(yaml_get "output.format")
  OUTPUT_FORMAT="${OUTPUT_FORMAT:-md}"
  OUTPUT_INSTRUCTIONS=$(yaml_get_multiline "output" "instructions")

  # ロール一覧
  ROLES=()
  while IFS= read -r role; do
    [[ -n "$role" ]] && ROLES+=("$role")
  done < <(yaml_get_array "roles")

  # カスタム指示
  CUSTOM_INSTRUCTIONS_KOUMEI=$(yaml_get_multiline "custom_instructions" "koumei")
  CUSTOM_INSTRUCTIONS_TECH_LEAD=$(yaml_get_multiline "custom_instructions" "tech-lead")
  CUSTOM_INSTRUCTIONS_DEVILS_ADVOCATE=$(yaml_get_multiline "custom_instructions" "devils-advocate")
  CUSTOM_INSTRUCTIONS_ANALYST=$(yaml_get_multiline "custom_instructions" "analyst")
  CUSTOM_INSTRUCTIONS_INQUISITOR=$(yaml_get_multiline "custom_instructions" "inquisitor")
  CUSTOM_INSTRUCTIONS_UX_DESIGNER=$(yaml_get_multiline "custom_instructions" "ux-designer")
  CUSTOM_INSTRUCTIONS_SCRIBE=$(yaml_get_multiline "custom_instructions" "scribe")

  # 参照ドキュメント
  REFERENCE_DOCS=""
  if has_yq; then
    local count
    count=$(yq_get '.reference_docs | length')
    if [[ "$count" != "0" && "$count" != "null" ]]; then
      for i in $(seq 0 $((count - 1))); do
        local path desc
        path=$(yq_get ".reference_docs[$i].path")
        desc=$(yq_get ".reference_docs[$i].description")
        REFERENCE_DOCS+="- \`${path}\` - ${desc}"$'\n'
      done
    fi
  elif grep -qE '^reference_docs:' "$CONFIG_FILE" && ! grep -qE '^reference_docs:[[:space:]]*\[\]' "$CONFIG_FILE"; then
    # awk フォールバックはオブジェクト配列を解析できない
    log_warn "reference_docs の読み込みには yq が必要です（未インストールのため空として扱います）: brew install yq"
  fi
  # 空のままなら生成物で「登録なし」と明示する
  REFERENCE_DOCS="${REFERENCE_DOCS:-（登録なし）}"

  # Perlテンプレートエンジン用に環境変数をエクスポート
  # 注意: ここに置くのはテンプレートが実際に消費する {{PLACEHOLDER}} のみ。
  # 未消費の export はテンプレート作者に「生きた契約」と誤認されるため追加しない
  export KOUMEI_VAR_PROJECT_NAME="$PROJECT_NAME"
  export KOUMEI_VAR_PROJECT_PATH="$PROJECT_PATH"
  export KOUMEI_VAR_SKILLS_DIR="$SKILLS_DIR"
  export KOUMEI_VAR_AGENT_INSTRUCTIONS_FILENAME="$AGENT_INSTRUCTIONS_FILENAME"
  export KOUMEI_VAR_COMMANDER_NAME="$COMMANDER_NAME"
  export KOUMEI_VAR_SKILL_PREFIX="$SKILL_PREFIX"
  export KOUMEI_VAR_BUILD_COMMAND="$BUILD_COMMAND"
  export KOUMEI_VAR_CHECK_COMMAND="$CHECK_COMMAND"
  export KOUMEI_VAR_GIT_BRANCH_PATTERN="$GIT_BRANCH_PATTERN"
  export KOUMEI_VAR_GIT_MAIN_BRANCH="$GIT_MAIN_BRANCH"
  export KOUMEI_VAR_GIT_DEVELOP_BRANCH="$GIT_DEVELOP_BRANCH"
  export KOUMEI_VAR_TICKET_QUEUE="$TICKET_QUEUE"
  export KOUMEI_VAR_TICKET_STATUS_DESIGNING="$TICKET_STATUS_DESIGNING"
  export KOUMEI_VAR_TICKET_STATUS_IMPLEMENTING="$TICKET_STATUS_IMPLEMENTING"
  export KOUMEI_VAR_TICKET_STATUS_REVIEW_READY="$TICKET_STATUS_REVIEW_READY"
  export KOUMEI_VAR_TICKET_STATUS_PARKED="$TICKET_STATUS_PARKED"
  export KOUMEI_VAR_TICKET_STATUS_STAGING_OK="$TICKET_STATUS_STAGING_OK"
  export KOUMEI_VAR_TICKET_STATUS_STAGING_NG="$TICKET_STATUS_STAGING_NG"
  export KOUMEI_VAR_MODEL_KOUMEI="$MODEL_KOUMEI"
  export KOUMEI_VAR_MODEL_ANALYST="$MODEL_ANALYST"
  export KOUMEI_VAR_MODEL_INQUISITOR="$MODEL_INQUISITOR"
  export KOUMEI_VAR_MODEL_UX_DESIGNER="$MODEL_UX_DESIGNER"
  export KOUMEI_VAR_MODEL_TECH_LEAD_DESIGN="$MODEL_TECH_LEAD_DESIGN"
  export KOUMEI_VAR_MODEL_TECH_LEAD_IMPLEMENT="$MODEL_TECH_LEAD_IMPLEMENT"
  export KOUMEI_VAR_MODEL_DEVILS_ADVOCATE="$MODEL_DEVILS_ADVOCATE"
  export KOUMEI_VAR_MODEL_SCRIBE="$MODEL_SCRIBE"
  export KOUMEI_VAR_REVIEW_MODE="$REVIEW_MODE"
  export KOUMEI_VAR_REVIEW_TIMEOUT="$REVIEW_TIMEOUT"
  export KOUMEI_VAR_GRILLING_MAX_ROUNDS="$GRILLING_MAX_ROUNDS"
  export KOUMEI_VAR_GRILLING_ESCALATE="$GRILLING_ESCALATE"
  # 技術スタック系プレースホルダ
  export KOUMEI_VAR_FRAMEWORK="$TECH_FRAMEWORK"
  export KOUMEI_VAR_TECH_STACK_SUMMARY="${TECH_LANGUAGE}${TECH_FRAMEWORK:+ / ${TECH_FRAMEWORK}}"
  export KOUMEI_VAR_UI_LIBRARY="$TECH_UI_LIBRARY"
  export KOUMEI_VAR_STYLING="$TECH_STYLING"
  export KOUMEI_VAR_OUTPUT_DIR="$OUTPUT_DIR"

  log_info "プロジェクト: ${PROJECT_NAME}"
  log_info "対象CLI: ${AI_CLI_NAME}"
  log_info "ロール: ${ROLES[*]}"
  log_info "スキルプレフィックス: ${SKILL_PREFIX}"
}

# ============================================================
# config差分検知（--update 用）
# ============================================================
# koumei.config.example.yaml にあってプロジェクトの koumei.config.yaml に
# 無いキーを検知する。値は比較しない（空文字は正規の設定であり「未設定」ではないため、
# 値比較だとユーザーの意図的なカスタマイズを誤検知してしまう）。
# ロール依存のキー（analyst/ux-designer関連）は、該当ロールが有効な場合のみチェックする。
#
# 既知の限界: キーが存在していても「使われ方の意味」が変わったケースは検知できない。
# その場合は CHANGELOG での明示的な告知に頼る（今回はスコープ外として保留）。
#
# 注意: ここに載せるのは実際に load_config() が yaml_get 等で読んでいるキーのみ。
# example にあるだけで未使用のキー（例: git.feature_prefix, tech_stack.dev_command）を
# 含めると、何も壊れないのに警告が出るノイズになる。

# 常に存在すべきキー
CONFIG_REQUIRED_KEYS=(
  "project.name" "project.description" "project.path"
  "migration.enabled" "migration.source_path" "migration.source_framework" "migration.target_framework"
  "roles"
  "target_cli" "skill_prefix"
  "commander.name"
  "models.koumei" "models.tech-lead-design" "models.tech-lead-implement" "models.devils-advocate"
  "review.mode" "review.timeout"
  "tech_stack.language" "tech_stack.framework" "tech_stack.ui_library" "tech_stack.styling"
  "tech_stack.database" "tech_stack.testing"
  "tech_stack.build_command" "tech_stack.test_command" "tech_stack.check_command"
  "git.main_branch" "git.develop_branch" "git.branch_pattern"
  "output.dir" "output.format" "output.instructions"
  "custom_instructions.koumei" "custom_instructions.tech-lead" "custom_instructions.devils-advocate"
  "reference_docs"
)

# ロールが有効な場合のみ存在すべきキー（"ロール名:キー"）
CONFIG_ROLE_CONDITIONAL_KEYS=(
  "analyst:models.analyst"
  "analyst:custom_instructions.analyst"
  "inquisitor:models.inquisitor"
  "inquisitor:custom_instructions.inquisitor"
  "inquisitor:grilling.max_rounds"
  "inquisitor:grilling.escalate"
  "ux-designer:models.ux-designer"
  "ux-designer:custom_instructions.ux-designer"
  "scribe:models.scribe"
  "scribe:custom_instructions.scribe"
)

# 差分がなければ0、差分があれば1を返し、案内メッセージを表示する
check_config_drift() {
  local missing=()

  for key in "${CONFIG_REQUIRED_KEYS[@]}"; do
    yaml_has_key "$key" "$CONFIG_FILE" || missing+=("$key")
  done

  for entry in "${CONFIG_ROLE_CONDITIONAL_KEYS[@]}"; do
    local role="${entry%%:*}"
    local key="${entry#*:}"
    if has_role "$role"; then
      yaml_has_key "$key" "$CONFIG_FILE" || missing+=("$key")
    fi
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    return 0
  fi

  echo ""
  log_warn "このフレームワークの更新には、あなたの koumei.config.yaml に無い新しい設定項目が含まれています:"
  for key in "${missing[@]}"; do
    echo "  - ${key}"
  done
  echo ""
  log_info "config自体の見直しが必要なため、再生成はスキップしました。"
  log_info "次を実行してください: ${SCRIPT_DIR}/setup.sh --reconfig"
  echo ""
  return 1
}

# ============================================================
# ヘルパー関数
# ============================================================

# ロールが有効かチェック
has_role() {
  local target="$1"
  for role in "${ROLES[@]}"; do
    [[ "$role" == "$target" ]] && return 0
  done
  return 1
}

# 技術スタックテーブルを生成
generate_tech_stack_table() {
  local table="| 項目 | 技術 |"$'\n'
  table+="|------|------|"$'\n'
  [[ -n "$TECH_LANGUAGE" ]]    && table+="| 言語 | ${TECH_LANGUAGE} |"$'\n'
  [[ -n "$TECH_FRAMEWORK" ]]   && table+="| フレームワーク | ${TECH_FRAMEWORK} |"$'\n'
  [[ -n "$TECH_UI_LIBRARY" ]]  && table+="| UIライブラリ | ${TECH_UI_LIBRARY} |"$'\n'
  [[ -n "$TECH_STYLING" ]]     && table+="| スタイリング | ${TECH_STYLING} |"$'\n'
  [[ -n "$TECH_DATABASE" ]]    && table+="| データベース | ${TECH_DATABASE} |"$'\n'
  [[ -n "$TECH_TESTING" ]]     && table+="| テスト | ${TECH_TESTING} |"$'\n'
  [[ -n "$CHECK_COMMAND" ]]    && table+="| Lint/Format | \`${CHECK_COMMAND}\` |"$'\n'
  echo "$table"
}


# テンプレート変数を置換（全てファイルベースで処理）
# 注意: 本関数は常にコマンド置換（サブシェル）経由で呼ばれるため、
# 親シェル変数へのキャッシュは機能しない。vars_dir は毎回構築・毎回削除する
process_template() {
  local input_content="$1"

  local vars_dir
  vars_dir=$(mktemp -d)
  generate_tech_stack_table > "${vars_dir}/TECH_STACK_TABLE"
  printf '%s' "$DEV_RULES" > "${vars_dir}/DEV_RULES"
  printf '%s' "$REFERENCE_DOCS" > "${vars_dir}/REFERENCE_DOCS"
  printf '%s' "$OUTPUT_INSTRUCTIONS" > "${vars_dir}/OUTPUT_INSTRUCTIONS"

  # 入力をファイルに書き出し
  local input_file
  input_file=$(mktemp)
  printf '%s' "$input_content" > "$input_file"

  # 全ての置換を1つのPerlスクリプトで実行
  local result
  result=$(perl -e '
    use strict;
    use warnings;

    my $vars_dir = $ARGV[0];
    my $input_file = $ARGV[1];

    # 入力ファイル読み込み
    open(my $fh, "<", $input_file) or die "Cannot open input: $!";
    local $/;
    my $content = <$fh>;
    close $fh;

    # 1. 環境変数ベースの置換（KOUMEI_VAR_* → 単純変数）
    my %env_vars;
    foreach my $key (keys %ENV) {
      if ($key =~ /^KOUMEI_VAR_(.+)$/) {
        $env_vars{$1} = $ENV{$key};
      }
    }
    # キー長い順にソートして部分マッチを防ぐ
    for my $key (sort { length($b) <=> length($a) } keys %env_vars) {
      my $val = $env_vars{$key};
      my $qkey = quotemeta($key);
      # 置換値をリテラルとして扱う（\Q...\E相当）
      $val =~ s/\\/\\\\/g;
      $val =~ s/\$/\\\$/g;
      $val =~ s/\@/\\\@/g;
      $content =~ s/\{\{$qkey\}\}/$val/g;
    }

    # 2. ファイルベースの置換（動的生成値）
    opendir(my $dh, $vars_dir) or die "Cannot open vars dir: $!";
    my @var_files = grep { -f "$vars_dir/$_" } readdir($dh);
    closedir $dh;

    for my $var_name (sort { length($b) <=> length($a) } @var_files) {
      open(my $vfh, "<", "$vars_dir/$var_name") or next;
      local $/;
      my $val = <$vfh>;
      close $vfh;
      $val = "" unless defined $val;
      my $qname = quotemeta($var_name);
      # 置換値をリテラルとして扱う
      $val =~ s/\\/\\\\/g;
      $val =~ s/\$/\\\$/g;
      $val =~ s/\@/\\\@/g;
      $content =~ s/\{\{$qname\}\}/$val/g;
    }

    print $content;
  ' "$vars_dir" "$input_file")

  rm -rf "$vars_dir" "$input_file"
  printf '%s' "$result"
}

# テンプレートを描画して返す（cat → 変数置換 → 条件ブロック処理）
render_template() {
  local src="$1"
  local content
  content=$(cat "$src")
  content=$(process_template "$content")
  process_conditions "$content"
}

# テンプレートを描画してファイルに書き出す
render_template_file() {
  local src="$1"
  local dest="$2"
  local force="${3:-}"
  local content
  content=$(render_template "$src")
  write_file "$dest" "$content" "$force"
}

# 条件ブロックを処理（Perl版）
process_conditions() {
  local content="$1"

  # 有効ロール一覧をカンマ区切りで
  local roles_csv
  roles_csv=$(printf '%s,' "${ROLES[@]}")

  local tmpfile_cond
  tmpfile_cond=$(mktemp)
  printf '%s' "$content" > "$tmpfile_cond"

  content=$(perl -e '
    use strict;
    my %active_roles = map { $_ => 1 } split(/,/, $ARGV[0]);
    my $migration = $ARGV[1] eq "true" ? 1 : 0;
    my $has_develop = length($ARGV[2]) > 0 ? 1 : 0;
    my $has_check = length($ARGV[3]) > 0 ? 1 : 0;
    my $target_cli = $ARGV[5] // "";
    my $has_ticket = ($ARGV[6] // "") eq "true" ? 1 : 0;
    my $has_ticket_staging = ($ARGV[7] // "") eq "true" ? 1 : 0;
    my $ticket_queue_missing = ($ARGV[8] // "") eq "true" ? 1 : 0;

    open(my $fh, "<", $ARGV[4]) or die "Cannot open: $!";
    my @lines = <$fh>;
    close $fh;

    my @skip_stack;
    my @result;

    for my $line (@lines) {
      chomp $line;

      # {{#IF_ROLE role}}
      if ($line =~ /\{\{#IF_ROLE\s+(\S+)\}\}/) {
        my $role = $1;
        if (@skip_stack && $skip_stack[-1]) {
          push @skip_stack, 1;
        } else {
          push @skip_stack, $active_roles{$role} ? 0 : 1;
        }
        next;
      }

      # {{#IF_NO_ROLE role}}
      if ($line =~ /\{\{#IF_NO_ROLE\s+(\S+)\}\}/) {
        my $role = $1;
        if (@skip_stack && $skip_stack[-1]) {
          push @skip_stack, 1;
        } else {
          push @skip_stack, $active_roles{$role} ? 1 : 0;
        }
        next;
      }

      # {{#IF_MIGRATION}}
      if ($line =~ /\{\{#IF_MIGRATION\}\}/) {
        if (@skip_stack && $skip_stack[-1]) {
          push @skip_stack, 1;
        } else {
          push @skip_stack, $migration ? 0 : 1;
        }
        next;
      }

      # {{#IF_DEVELOP_BRANCH}}
      if ($line =~ /\{\{#IF_DEVELOP_BRANCH\}\}/) {
        if (@skip_stack && $skip_stack[-1]) {
          push @skip_stack, 1;
        } else {
          push @skip_stack, $has_develop ? 0 : 1;
        }
        next;
      }

      # {{#IF_NO_DEVELOP_BRANCH}}
      if ($line =~ /\{\{#IF_NO_DEVELOP_BRANCH\}\}/) {
        if (@skip_stack && $skip_stack[-1]) {
          push @skip_stack, 1;
        } else {
          push @skip_stack, $has_develop ? 1 : 0;
        }
        next;
      }

      # {{#IF_TICKET}}
      if ($line =~ /\{\{#IF_TICKET\}\}/) {
        if (@skip_stack && $skip_stack[-1]) {
          push @skip_stack, 1;
        } else {
          push @skip_stack, $has_ticket ? 0 : 1;
        }
        next;
      }

      # {{#IF_NO_TICKET}}
      if ($line =~ /\{\{#IF_NO_TICKET\}\}/) {
        if (@skip_stack && $skip_stack[-1]) {
          push @skip_stack, 1;
        } else {
          push @skip_stack, $has_ticket ? 1 : 0;
        }
        next;
      }

      # {{#IF_TICKET_QUEUE_MISSING}}
      if ($line =~ /\{\{#IF_TICKET_QUEUE_MISSING\}\}/) {
        if (@skip_stack && $skip_stack[-1]) {
          push @skip_stack, 1;
        } else {
          push @skip_stack, $ticket_queue_missing ? 0 : 1;
        }
        next;
      }

      # {{#IF_TICKET_STAGING}}
      if ($line =~ /\{\{#IF_TICKET_STAGING\}\}/) {
        if (@skip_stack && $skip_stack[-1]) {
          push @skip_stack, 1;
        } else {
          push @skip_stack, $has_ticket_staging ? 0 : 1;
        }
        next;
      }

      # {{#IF_NO_TICKET_STAGING}}
      if ($line =~ /\{\{#IF_NO_TICKET_STAGING\}\}/) {
        if (@skip_stack && $skip_stack[-1]) {
          push @skip_stack, 1;
        } else {
          push @skip_stack, $has_ticket_staging ? 1 : 0;
        }
        next;
      }

      # {{#IF_CHECK_COMMAND}}
      if ($line =~ /\{\{#IF_CHECK_COMMAND\}\}/) {
        if (@skip_stack && $skip_stack[-1]) {
          push @skip_stack, 1;
        } else {
          push @skip_stack, $has_check ? 0 : 1;
        }
        next;
      }

      # {{#IF_NO_CHECK_COMMAND}}
      if ($line =~ /\{\{#IF_NO_CHECK_COMMAND\}\}/) {
        if (@skip_stack && $skip_stack[-1]) {
          push @skip_stack, 1;
        } else {
          push @skip_stack, $has_check ? 1 : 0;
        }
        next;
      }

      # {{#IF_CLI <cli>}} — target_cli が一致するときだけ出力
      if ($line =~ /\{\{#IF_CLI\s+(\S+)\}\}/) {
        my $cli = $1;
        if (@skip_stack && $skip_stack[-1]) {
          push @skip_stack, 1;
        } else {
          push @skip_stack, ($target_cli eq $cli) ? 0 : 1;
        }
        next;
      }

      # Closing tags
      if ($line =~ /\{\{\/(IF_ROLE|IF_NO_ROLE|IF_MIGRATION|IF_DEVELOP_BRANCH|IF_NO_DEVELOP_BRANCH|IF_TICKET_QUEUE_MISSING|IF_TICKET_STAGING|IF_NO_TICKET_STAGING|IF_TICKET|IF_NO_TICKET|IF_CHECK_COMMAND|IF_NO_CHECK_COMMAND|IF_CLI)\}\}/) {
        pop @skip_stack if @skip_stack;
        next;
      }

      # Output line if not skipping
      if (!@skip_stack || !$skip_stack[-1]) {
        push @result, $line;
      }
    }

    print join("\n", @result) . "\n";
  ' "$roles_csv" "$MIGRATION_ENABLED" "$GIT_DEVELOP_BRANCH" "$CHECK_COMMAND" "$tmpfile_cond" "$TARGET_CLI" "$TICKET_ENABLED" "$TICKET_STAGING_ENABLED" "${TICKET_QUEUE_MISSING:-false}")

  rm -f "$tmpfile_cond"
  echo "$content"
}

# ファイルがGit管理下かチェック
is_git_tracked() {
  local file="$1"
  git ls-files --error-unmatch "$file" &>/dev/null 2>&1
}

# 既存ファイルのバックアップ
backup_file() {
  local file="$1"
  local backup_dir=".agents/.backup"
  local timestamp
  timestamp=$(date +%Y%m%d-%H%M%S)
  local backup_path="${backup_dir}/${file//\//_}.${timestamp}.bak"

  mkdir -p "$backup_dir"
  cp "$file" "$backup_path"
  log_info "バックアップ: ${file} → ${backup_path}"
}

# ファイルを書き出し（既存ファイル保護付き）
write_file() {
  local dest="$1"
  local content="$2"
  local force="${3:-}"   # "force" 指定時は Git 管理下でもバックアップの上で上書き
                          # （TEAM.md 等の純粋な生成ファイル用。コミット済みだと更新経路が無くなるため）

  if $DRY_RUN; then
    log_info "[DRY-RUN] Would create: ${dest}"
    return
  fi

  # 既存ファイルがある場合の保護処理
  if [[ -f "$dest" ]]; then
    if is_git_tracked "$dest" && [[ "$force" != "force" ]]; then
      # Git管理下 → 上書きしない
      log_warn "スキップ: ${dest}（Git管理下の既存ファイル）"
      return
    else
      # バックアップしてから上書き
      backup_file "$dest"
    fi
  fi

  local dir
  dir=$(dirname "$dest")
  mkdir -p "$dir"
  printf '%s\n' "$content" > "$dest"
  log_info "作成: ${dest}"
}

# ディレクトリを作成（.gitkeep付き）
create_dir_with_gitkeep() {
  local dir="$1"

  if $DRY_RUN; then
    log_info "[DRY-RUN] Would create dir: ${dir}"
    return
  fi

  mkdir -p "$dir"
  if [[ ! -f "${dir}/.gitkeep" ]]; then
    touch "${dir}/.gitkeep"
  fi
}

# ============================================================
# メイン処理
# ============================================================

do_clean() {
  log_step "展開済みファイルを削除中..."

  # スキルディレクトリ内のkoumei-ai-team-framework生成ファイルを削除
  local prefix="${SKILL_PREFIX:-koumei}"

  for skills_base in ".codex/skills" ".claude/skills" ".agents/skills"; do
    [[ -d "$skills_base" ]] || continue
    for dir in "${skills_base}"/${prefix}-*; do
      [[ -d "$dir" ]] && rm -rf "$dir" && log_info "削除: $dir"
    done
  done

  # .agents/ ディレクトリを削除（成果物も含む）
  if [[ -d ".agents" ]]; then
    rm -rf .agents
    log_info "削除: .agents/"
  fi

  # Hooks（本フレームワークが配布したスクリプトのみ削除。テンプレート一覧と同期し、
  # テンプレートディレクトリが見つからない場合は既知の配布済みフック名にフォールバック）
  local hook_names=()
  for hook_file in "${TEMPLATES_DIR}"/hooks/*.sh; do
    [[ -f "$hook_file" ]] && hook_names+=("$(basename "$hook_file")")
  done
  if [[ ${#hook_names[@]} -eq 0 ]]; then
    hook_names=(quality-gate.sh log-operation.sh auto-format.sh notify-phase.sh)
  fi
  for hook_name in "${hook_names[@]}"; do
    if [[ -f "hooks/${hook_name}" ]]; then
      rm -f "hooks/${hook_name}"
      log_info "削除: hooks/${hook_name}"
    fi
  done
  [[ -d hooks ]] && rmdir hooks 2>/dev/null || true
  # .claude/settings.json の hooks 設定は手動で削除が必要な旨を案内
  if [[ -f ".claude/settings.json" ]] && command -v jq &>/dev/null && jq -e '.hooks' .claude/settings.json >/dev/null 2>&1; then
    log_warn ".claude/settings.json の hooks 設定は自動削除しません。不要なら手動で削除してください。"
  fi

  log_info "クリーン完了"
}

# 旧レイアウト（origin 統合前: commander/reviewer ロール・koumei-run スキル）の残骸を検出・整理
cleanup_legacy_layout() {
  # 旧 koumei-run スキル（純粋な生成物なので Git 管理外なら自動削除）
  for skills_base in ".claude/skills" ".codex/skills" ".agents/skills"; do
    local old_run="${skills_base}/${SKILL_PREFIX}-run"
    if [[ -d "$old_run" ]]; then
      if [[ -n "$(git ls-files "$old_run" 2>/dev/null)" ]]; then
        log_warn "旧スキル ${old_run} が Git 管理下に残っています。/${SKILL_PREFIX}-run は廃止されたため git rm -r で削除してください。"
      elif $DRY_RUN; then
        log_info "[DRY-RUN] Would remove legacy skill: ${old_run}"
      else
        rm -rf "$old_run"
        log_info "削除: ${old_run}（廃止された旧スキル）"
      fi
    fi
  done

  # 旧ロールワークスペース（ユーザー成果物を含む可能性があるため自動削除しない）
  local legacy_found=false
  for old_role in commander reviewer; do
    [[ -d ".agents/${old_role}" ]] && legacy_found=true
  done
  if $legacy_found; then
    log_warn "旧レイアウトのワークスペース（.agents/commander/ または .agents/reviewer/）が残っています。"
    log_warn "必要な成果物を .agents/koumei/ / .agents/devils-advocate/ へ移した上で、旧ディレクトリを手動で削除してください。"
  fi
}

do_setup() {
  local is_update=false
  [[ "$MODE" == "update" ]] && is_update=true

  if $is_update; then
    log_step "設定を再展開中（成果物は保持）..."
  else
    log_step "初回セットアップ開始..."
  fi

  # 旧レイアウトの残骸チェック
  cleanup_legacy_layout

  # --- エージェント定義の展開 ---
  log_step "エージェント定義を展開中..."

  # 操作ログ・外部CLI委譲ログの置き場。従来はフック（log-operation.sh）の副作用で
  # 実行時に作られていたが、利用者に既存 hooks があるとフックがマージされず、
  # ディレクトリも作られない。そこへ委譲ログを書こうとして委譲ごと失敗するため、
  # ターゲットCLIやフックの有無に依らず先に作る。
  create_dir_with_gitkeep ".agents/logs"

  # TEAM.md は純粋な生成ファイル（quality-gate hook が直接編集をブロックし、
  # マルチタスク機能は .agents/ のコミットを要求する）ため、Git 管理下でも強制再生成する
  render_template_file "${TEMPLATES_DIR}/agents/TEAM.md.tmpl" ".agents/TEAM.md" "force"

  # ロール展開（コア: koumei/tech-lead/devils-advocate、オプション: analyst/ux-designer、
  # task-manager はネストsubagent前提のため claude ターゲット限定）
  for role_dir in koumei tech-lead devils-advocate analyst inquisitor ux-designer scribe task-manager; do
    case "$role_dir" in
      analyst|inquisitor|ux-designer|scribe) has_role "$role_dir" || continue ;;
      task-manager)                          [[ "$TARGET_CLI" == "claude" || "$TARGET_CLI" == "antigravity" ]] || continue ;;
    esac

    local tmpl="${TEMPLATES_DIR}/agents/${role_dir}/CLAUDE.md.tmpl"
    if [[ -f "$tmpl" ]]; then
      local content
      content=$(render_template "$tmpl")

      # カスタム指示の注入（origin テンプレートにはプレースホルダが無いため末尾に追記）
      local ci=""
      case "$role_dir" in
        koumei)          ci="$CUSTOM_INSTRUCTIONS_KOUMEI" ;;
        tech-lead)       ci="$CUSTOM_INSTRUCTIONS_TECH_LEAD" ;;
        devils-advocate) ci="$CUSTOM_INSTRUCTIONS_DEVILS_ADVOCATE" ;;
        analyst)         ci="$CUSTOM_INSTRUCTIONS_ANALYST" ;;
        inquisitor)      ci="$CUSTOM_INSTRUCTIONS_INQUISITOR" ;;
        ux-designer)     ci="$CUSTOM_INSTRUCTIONS_UX_DESIGNER" ;;
        scribe)          ci="$CUSTOM_INSTRUCTIONS_SCRIBE" ;;
      esac
      if [[ -n "$ci" ]]; then
        content+=$'\n\n'"## プロジェクト固有の指示"$'\n\n'"$ci"
      fi

      write_file ".agents/${role_dir}/${AGENT_INSTRUCTIONS_FILENAME}" "$content"
    fi

    # ワークスペースディレクトリ
    case "$role_dir" in
      koumei)
        create_dir_with_gitkeep ".agents/koumei/tasks"
        create_dir_with_gitkeep ".agents/koumei/reports"
        create_dir_with_gitkeep ".agents/koumei/requests"
        ;;
      devils-advocate)
        create_dir_with_gitkeep ".agents/devils-advocate/instructions"
        create_dir_with_gitkeep ".agents/devils-advocate/reviews"
        ;;
      task-manager)
        ;;  # 使い捨て実行役のためワークスペース不要
      *)
        create_dir_with_gitkeep ".agents/${role_dir}/instructions"
        create_dir_with_gitkeep ".agents/${role_dir}/deliverables"
        ;;
    esac
  done

  # カスタムロールテンプレート（参照用）
  for cr_tmpl in "${TEMPLATES_DIR}"/agents/custom-roles/*/CLAUDE.md.tmpl; do
    [[ -f "$cr_tmpl" ]] || continue
    local cr_name
    cr_name=$(basename "$(dirname "$cr_tmpl")")
    render_template_file "$cr_tmpl" ".agents/custom-roles/${cr_name}/${AGENT_INSTRUCTIONS_FILENAME}"
  done
  if [[ -f "${TEMPLATES_DIR}/agents/custom-roles/README.md.tmpl" ]]; then
    render_template_file "${TEMPLATES_DIR}/agents/custom-roles/README.md.tmpl" ".agents/custom-roles/README.md"
  fi

  # --- スキルファイルの展開 ---
  log_step "スキルファイルを展開中..."

  for skill_dir in "${TEMPLATES_DIR}"/skills/koumei-*/; do
    local skill_name
    skill_name=$(basename "$skill_dir")

    # ロール依存スキルは有効時のみ展開
    local should_install=true
    case "$skill_name" in
      koumei-analyze)                 has_role "analyst" || should_install=false ;;
      koumei-grill)                   has_role "inquisitor" || should_install=false ;;
      koumei-design|koumei-design-ux) has_role "ux-designer" || should_install=false ;;
      koumei-condense)                has_role "scribe" || should_install=false ;;
    esac
    $should_install || continue

    # プレフィックスを置換
    local target_name="${skill_name/koumei-/${SKILL_PREFIX}-}"

    local tmpl="${skill_dir}SKILL.md.tmpl"
    if [[ -f "$tmpl" ]]; then
      render_template_file "$tmpl" "${SKILLS_DIR}/${target_name}/SKILL.md"
    fi

    # docs/ サブディレクトリ（koumei-start / koumei-review の手順書）
    if [[ -d "${skill_dir}docs" ]]; then
      for doc_tmpl in "${skill_dir}docs/"*.md.tmpl; do
        [[ -f "$doc_tmpl" ]] || continue
        local doc_name
        doc_name=$(basename "$doc_tmpl" .tmpl)
        # ticket.md は連携を有効にした環境にのみ展開する（無効なら記述を一切出さない）
        if [[ "$doc_name" == "ticket.md" && "$TICKET_ENABLED" != "true" ]]; then
          # 無効化・設定変更の前に生成された残骸を消す（残れば「使える」と誤解させる）
          [[ -f "${SKILLS_DIR}/${target_name}/docs/${doc_name}" ]] && rm -f "${SKILLS_DIR}/${target_name}/docs/${doc_name}"
          continue
        fi
        # multi-task.md はネストsubagent/invoke_subagent前提（claude / antigravity ターゲットのみ展開）
        if [[ "$doc_name" == "multi-task.md" && "$TARGET_CLI" != "claude" && "$TARGET_CLI" != "antigravity" ]]; then
          # 旧バージョン・target_cli変更前に生成された残骸があれば削除（非対応CLIの陳腐化ファイル）
          [[ -f "${SKILLS_DIR}/${target_name}/docs/${doc_name}" ]] && rm -f "${SKILLS_DIR}/${target_name}/docs/${doc_name}"
          continue
        fi
        render_template_file "$doc_tmpl" "${SKILLS_DIR}/${target_name}/docs/${doc_name}"
      done
    fi
  done

  # --- Hooks / settings.json（Claude Code / Antigravity ターゲット対応） ---
  if [[ "$TARGET_CLI" == "claude" || "$TARGET_CLI" == "antigravity" ]]; then
    log_step "Hooks を展開中..."
    for hook_file in "${TEMPLATES_DIR}"/hooks/*.sh; do
      [[ -f "$hook_file" ]] || continue
      local hook_name
      hook_name=$(basename "$hook_file")
      # hooks も {{COMMANDER_NAME}} 等を含むためテンプレートとして描画する
      # （bash の ${VAR} 記法はテンプレートエンジンの {{VAR}} と衝突しないので安全）
      render_template_file "$hook_file" "hooks/${hook_name}"
      # write_file がスキップしたファイル（Git管理下）や dry-run 中は触らない
      if ! $DRY_RUN && [[ -f "hooks/${hook_name}" ]] && ! is_git_tracked "hooks/${hook_name}"; then
        chmod +x "hooks/${hook_name}"
      fi
    done

    if [[ "$TARGET_CLI" == "claude" ]]; then
      # settings.json（hooks 設定のマージ）
      local settings_tmpl="${TEMPLATES_DIR}/claude/settings.json"
      if [[ -f "$settings_tmpl" ]]; then
        if $DRY_RUN; then
          log_info "[DRY-RUN] Would merge: .claude/settings.json"
        elif [[ ! -f ".claude/settings.json" ]]; then
          mkdir -p .claude
          cp "$settings_tmpl" ".claude/settings.json"
          log_info "作成: .claude/settings.json"
        elif command -v jq &>/dev/null; then
          # hooks は既存があれば触らない（手動マージを促す）。
          # permissions.allow は既存の有無に依らず必ず足す —— 外部CLI委譲（agy / codex）は
          # 許可が無いとヘッドレス実行で承認要求に阻まれ、黙って Claude にフォールバックするため。
          local keep_hooks=false
          if jq -e '.hooks' .claude/settings.json >/dev/null 2>&1; then
            keep_hooks=true
            log_warn ".claude/settings.json に既存の hooks 設定があります。${settings_tmpl} を参考に手動でマージしてください。"
          fi
          local merged
          if merged=$(jq -s --argjson keep "$keep_hooks" '
                .[0] as $cur | .[1] as $tmpl |
                $cur
                + (if $keep then {} else {hooks: $tmpl.hooks} end)
                + {permissions: (($cur.permissions // {})
                    + {allow: ((($cur.permissions.allow) // []) + (($tmpl.permissions.allow) // []) | unique)})}
              ' .claude/settings.json "$settings_tmpl" 2>/dev/null) && [[ -n "$merged" ]]; then
            printf '%s\n' "$merged" > .claude/settings.json
            if $keep_hooks; then
              log_info "マージ: .claude/settings.json に permissions.allow を追加"
            else
              log_info "マージ: .claude/settings.json に hooks 設定と permissions.allow を追加"
            fi
          else
            log_warn ".claude/settings.json の自動マージに失敗しました。${settings_tmpl} を参考に手動で追加してください。"
          fi
        else
          log_warn "jq が無いため .claude/settings.json をマージできません。${settings_tmpl} を参考に手動で追加してください。"
        fi
      fi
    elif [[ "$TARGET_CLI" == "antigravity" ]]; then
      # hooks.json（hooks 設定のマージ）
      local hooks_tmpl="${TEMPLATES_DIR}/agents/hooks.json"
      if [[ -f "$hooks_tmpl" ]]; then
        if $DRY_RUN; then
          log_info "[DRY-RUN] Would merge: .agents/hooks.json"
        elif [[ ! -f ".agents/hooks.json" ]]; then
          mkdir -p .agents
          cp "$hooks_tmpl" ".agents/hooks.json"
          log_info "作成: .agents/hooks.json"
        elif command -v jq &>/dev/null; then
          local merged
          if merged=$(jq -s '.[0] * .[1]' .agents/hooks.json "$hooks_tmpl" 2>/dev/null) && [[ -n "$merged" ]]; then
            printf '%s\n' "$merged" > .agents/hooks.json
            log_info "マージ: .agents/hooks.json に hooks 設定を追加"
          else
            log_warn ".agents/hooks.json の自動マージに失敗しました。${hooks_tmpl} を参考に手動で追加してください。"
          fi
        else
          log_warn "jq が無いため .agents/hooks.json をマージできません。${hooks_tmpl} を参考に手動で追加してください。"
        fi
      fi
    fi
  fi

  # --- 完了 ---
  echo ""
  log_info "=============================="
  log_info "セットアップ完了!"
  log_info "=============================="
  echo ""
  log_info "利用可能なスキルコマンド:"
  log_info "  /${SKILL_PREFIX}-request   要件整理・指示書作成"
  log_info "  /${SKILL_PREFIX}-start     タスク定義・全自動実行（--manual で手動進行）"
  if has_role "analyst"; then
    log_info "  /${SKILL_PREFIX}-analyze   既存コード分析"
  fi
  if has_role "inquisitor"; then
    log_info "  /${SKILL_PREFIX}-grill     設計前の詰問（--auto で自動 / 既定は一問一答）"
  fi
  if has_role "ux-designer"; then
    log_info "  /${SKILL_PREFIX}-design    UX+技術設計（並列実行）"
    log_info "  /${SKILL_PREFIX}-design-ux UX設計（単体実行）"
  fi
  if has_role "scribe"; then
    log_info "  /${SKILL_PREFIX}-condense  成果物の圧縮・構造化（主簿）"
  fi
  log_info "  /${SKILL_PREFIX}-design-tech 技術設計"
  log_info "  /${SKILL_PREFIX}-review    レビュー（--security / --second-opinion / --model 対応）"
  log_info "  /${SKILL_PREFIX}-implement 実装"
  log_info "  /${SKILL_PREFIX}-status    進捗確認"
  echo ""
  log_info "要件整理から始める場合は /${SKILL_PREFIX}-request を使ってください。"
  log_info "要件が明確な場合は /${SKILL_PREFIX}-start で直接タスクを開始できます。"
  echo ""
  # モデル配置は「聞かずに知らせる」。初回に8ロール分を問うても、
  # 消費も出来も見えていない段階では選びようがない。既定で回してから触る性質のもの
  log_info "モデルはロール別に指定できます（既定はこの配置）:"
  log_info "  koumei=${MODEL_KOUMEI} / tech-lead=${MODEL_TECH_LEAD_DESIGN}（設計）・${MODEL_TECH_LEAD_IMPLEMENT}（実装） / devils-advocate=${MODEL_DEVILS_ADVOCATE}"
  if has_role "analyst" || has_role "inquisitor" || has_role "ux-designer" || has_role "scribe"; then
    _opt=""
    has_role "analyst"     && _opt="${_opt} analyst=${MODEL_ANALYST}"
    has_role "inquisitor"  && _opt="${_opt} inquisitor=${MODEL_INQUISITOR}"
    has_role "ux-designer" && _opt="${_opt} ux-designer=${MODEL_UX_DESIGNER}"
    has_role "scribe"      && _opt="${_opt} scribe=${MODEL_SCRIBE}"
    log_info " ${_opt}"
  fi
  log_info "  配置の理由は .agents/TEAM.md「配置の原則」に、変え方は docs/configuration.md#models にあります。"
  log_info "  変更は koumei.config.yaml の models: を編集して setup.sh --update（TEAM.md の直接編集は不可）。"
}

# ============================================================
# 実行
# ============================================================

# --init: ウィザードのみ実行（configなくてもOK）
if [[ "$MODE" == "init" ]]; then
  run_wizard
  # 生成後にセットアップも実行
  load_config
  do_setup
  exit 0
fi

# --roles: ロール変更のみ
if [[ "$MODE" == "roles" ]]; then
  load_config  # 既存config読み込み（yaml_get_array 用）
  run_roles_wizard
  load_config  # 更新されたconfigを再読み込み
  do_setup
  exit 0
fi

# --cli: 対象CLI変更のみ
if [[ "$MODE" == "cli" ]]; then
  load_config            # 既存config読み込み（旧CLI情報を表示するため）
  run_cli_wizard         # target_cli を書き換え、PREVIOUS_TARGET_CLI を記録
  load_config            # 新CLIで SKILLS_DIR / AGENT_INSTRUCTIONS_FILENAME を確定
  cleanup_previous_cli "$PREVIOUS_TARGET_CLI"
  do_setup
  exit 0
fi

# --update: 差分検知してから再生成（configは変更しない）
if [[ "$MODE" == "update" ]]; then
  load_config
  if ! check_config_drift; then
    exit 1
  fi
  do_setup
  exit 0
fi

# 通常フロー
load_config

case "$MODE" in
  clean)  do_clean ;;
  *)      do_setup ;;
esac

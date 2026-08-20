# koumei-ai-team-framework

諸葛孔明率いるAIエージェントチームによるマルチエージェント開発フローシステム。

上流の [koumei](https://github.com/kuruusuniku/koumei)（MIT）のチームアーキテクチャ（ロール構成・レビュー体制・運用ルール）を、config 駆動の配布エンジン（対話式ウィザード・テンプレート自動展開・更新機構・マルチCLI対応）に載せたフレームワークです。取り込み経緯は `docs/origin-import.md` を参照。

最高指揮者（諸葛孔明）が各専門ロールへ指示を出し、タスク定義 → 分析 → 詰問 → 設計（UX+技術 並列）→ レビュー → 実装 → コードレビューの段階的開発フローを実行します。

## 特徴

- **対話式セットアップ**: ウィザード形式で設定ファイルを自動生成（技術スタック自動検出付き）
- **孔明ペルソナのチーム運用**: 最高指揮者=諸葛孔明、レビュアー=悪魔の代弁者（devils-advocate）による品質ゲート
- **設計前の詰問（grilling）**: 諫議大夫（inquisitor）が設計着手前に前提・境界条件を問い質し、確定事項と未決の前提を明文化。**完全自動でも設計精度を上げる**
- **レビュアーの独立性**: 自己レビュー禁止を絶対ルールとし、独立エージェント/外部モデルでレビューを実行
- **トークン経済ガードレール**: 成果物20KB上限・必読/参照の2階層資料渡し・差分レビュー・逐次書き出しの絶対命令で、サブエージェント起動数に乗算される資料コストを構造的に抑制。主簿（scribe）ロールが執行実務を担当
- **単騎駆け**: 軽微修正はサブエージェントを起動せず指揮者本体が直接実装（独立コードレビューは維持）
- **フェーズ別モデル配置**: 高単価モデルを「判断のレバレッジが高い所」（設計・レビュー判定）に配置（tech-lead は設計/実装でモデル分割）
- **レビュー拡張**: `--security`（OWASP+STRIDE監査）/ `--second-opinion`（外部モデル突合）/ `--model`（一時切替）/ タイムアウトフォールバック
- **マルチタスク並列実行**: `--multi` で「1タスク=1ブランチ=1PR」を git worktree で並列実行（claude / antigravity 対応）
- **Hooks**: TEAM.md 保護・操作ログ・自動フォーマット・フェーズ完了通知（claude / antigravity 対応）
- **クロスCLI・外部委譲**: Claude CLI から Antigravity（agy）や Codex へ実装フェーズを安全に委譲（worktree 隔離・レートリミット時の自動引き継ぎ・フォールバック機能付き）
- **config 駆動の更新機構**: `--update` はスキーマ差分を検知し、必要なら `--reconfig` を案内
- **マルチCLI対応**: `target_cli` で claude / codex / antigravity に展開（機能マトリクスは後述）

## クイックスタート

```bash
# 1. リポジトリをクローン
git clone <repository-url> /path/to/koumei-ai-team-framework

# 2. プロジェクトディレクトリでセットアップ実行（configが無ければウィザード起動）
cd /path/to/my-project
/path/to/koumei-ai-team-framework/setup.sh

# 3. スキルコマンドを実行
#    要件整理から始める場合
/koumei-request "GA4アナリティクス計測設定"
#    要件が明確な場合（タスク定義から全自動実行）
/koumei-start "ユーザープロフィール編集機能"
```

## セットアップコマンド

```bash
setup.sh              # 初回セットアップ（config未存在時はウィザード起動）
setup.sh --init        # ウィザードを明示的に実行（config作成/上書き）
setup.sh --reconfig    # 既存プロジェクトの設定を見直す（--init のエイリアス）
setup.sh --roles       # ロール構成のみ変更（対話式）
setup.sh --cli         # 対象CLIのみ変更（claude/codex/antigravity、対話式）
setup.sh --update      # 最新テンプレで再展開（configは変更しない・成果物は保持）
                        # フレームワーク側に新しい設定項目が追加されている場合は
                        # 再生成せず --reconfig の実行を案内する
setup.sh --clean       # 展開済みファイルを削除
setup.sh --dry-run     # 実際にファイルを作成せずプレビュー
```

## ロール構成

### コアロール（必須）

| ロール | コードネーム | 責務 | 既定モデル(claude) |
|--------|------------|------|------|
| **koumei** | 諸葛孔明 | 全体統括・タスク分割・指示出し・最終判断 | sonnet |
| **tech-lead** | - | 技術設計・実装 | fable（設計）/ opus（実装） |
| **devils-advocate** | 悪魔の代弁者 | 全成果物のレビュー・問題提起（品質ゲート） | fable |

### オプションロール

| ロール | 責務 |
|--------|------|
| **analyst** | 既存コードベースの調査・分析。移行や大規模リファクタリングで有用 |
| **inquisitor** | 諫議大夫。設計前に要件・前提・境界条件を詰問し `design-brief` を作成。設計の手戻りが多いプロジェクトで有用 |
| **ux-designer** | UI/UX設計。tech-lead と並列で設計を実行 |
| **scribe** | 主簿。成果物の圧縮・構造化（20KB超の再編）、差分パッケージ作成、タスク定義の畳み込み。トークン経済ルールの執行実務。成果物が重くなる大規模タスクで有用 |

ロール構成は `setup.sh --roles` で変更可能。カスタムロール（api-designer / data-engineer / infra-architect）のテンプレートも `.agents/custom-roles/` に展開されます。

## ワークフロー

```
【設計フェーズ】
1. /koumei-request {要件}     → 要件整理・指示書作成（任意）
2. /koumei-start {要件}       → タスク定義・指示書生成 → 以降を全自動実行
3. /koumei-analyze             → 既存システム分析（analyst有効時）
4. /koumei-grill               → 設計前の詰問（inquisitor有効時）
5. /koumei-design              → UX設計 + 技術設計を並列実行
6. /koumei-review              → 全成果物レビュー
   → 差し戻し: /koumei-design-ux or /koumei-design-tech で個別再実行

【実装フェーズ】
7. /koumei-implement           → 実装（レビュー通過後のみ）
8. /koumei-review              → コードレビュー（どのタスク種別でも省略しない）

【検証フェーズ】
9. /koumei-status              → 進捗確認・次のアクション提案
```

- `--manual` で手動進行、`--multi` でマルチタスク並列実行（claude / antigravity 対応）
- `/koumei-grill` は既定で**一問一答**（人が回答）。全自動フローでは `--auto` で起動し、AIが根拠に基づいて自答する
- タスク種別（軽微修正/バグ修正/機能追加）に応じてフェーズを自動省略（コードレビューは常に実施）
- **軽微修正は単騎駆け**: typo・文言・設定値など修正箇所特定済みの1-2ファイル修正では、実装サブエージェントを起動せず指揮者本体が直接実装する。省けるのは実装エージェントだけで、独立コードレビューは必ず実施
- scribe（主簿）有効時は、フェーズ完了ごとに成果物サイズを検査し、20KB超の再編・2回目レビュー用の差分パッケージ作成・タスク定義の畳み込みを `/koumei-condense` で自動実行（情報は削除せず分離のみ。原本は `-full.md` として温存）
- 差し戻しはフェーズ別に最大2回、3回目でユーザーにエスカレーション

## CLI別機能マトリクス

| 機能 | claude | codex | antigravity |
|---|---|---|---|
| コアワークフロー・ロール・ペルソナ | ✅ | ✅ | ✅ |
| レビュアー独立実行・外部CLIモデル | ✅ | ✅ | ✅ |
| Hooks（TEAM.md保護/ログ/フォーマット/通知） | ✅ | ❌ | ✅ |
| セカンドオピニオン / タイムアウトFB | ✅ | △ | △ |
| マルチタスク（--multi / worktree並列） | ✅ | ❌ | ✅ |

フル体験は claude および antigravity ターゲット（codex はコアワークフローのみ）。

## ターゲットCLI別の実行フロー・ロール遷移

各ターゲット環境に応じたエージェント起動・ロールバトンタッチの詳細は [docs/target-cli-flows.md](docs/target-cli-flows.md) を参照してください。

- **`claude` (Claude Code)**: `Agent` ツールによる自律サブエージェント呼び出し。ロールごとに異なるモデル（Fable/Opus/Sonnet）を起動し、`.claude/settings.json` の Hooks で安全性を担保。
- **`antigravity` (Antigravity / `agy`)**: `invoke_subagent` ツールによるサブエージェント起動。`TEAM.md` のモデル定義から `pro` / `flash` の階層を動的に解決。`Subagents` 配列によるネイティブ並列マルチタスクと `.agents/hooks.json` に対応。
- **`codex` (Codex CLI)**: サブエージェントネストを持たないため、単一セッション内でロール定義（`AGENTS.md`）を順次読み替えながら直列実行。
- **クロスCLI・ハイブリッド連携**: Claude CLI を司令塔（設計・オーケストレーション・レビュー）とし、最もトークンを消費する実装フェーズ（Phase 5）のみを `git worktree` 内で `agy`（Gemini）に委譲。レートリミット（429）検知時の自律引き継ぎ・フォールバックを完備。

## 成果物の配置（2層構成）

- **作業成果物**（分析・設計・レビュー・完了報告）: `.agents/{ロール}/deliverables/` 等の各ワークスペース（AI内部の作業記録・タスク単位で上書き）
- **公式ドキュメント**: `koumei.config.yaml` の `output.dir`（既定: `docs-official/`）配下に **`{機能スラッグ}/requirements-spec-design.md`** として、機能/エピック単位で要件・仕様・設計を1ファイルに集約する。タスクごとに新規ファイルを作らず、Phase 7（PR作成前）で該当セクションを更新する「今の正」を反映する生きたドキュメント

## ディレクトリ構成（生成後）

```
プロジェクトルート/
├── koumei.config.yaml              ← プロジェクト固有の設定（これが単一の真実源）
├── .claude/
│   ├── settings.json               ← Hooks 設定（claude時、自動マージ）
│   └── skills/                     ← スキルコマンド定義（target_cliで配置先が変わる）
│       ├── koumei-start/           ←   SKILL.md + docs/（phases/rules/error-handling等）
│       ├── koumei-review/          ←   SKILL.md + docs/（extended-modes/review-models）
│       └── ...
├── hooks/                          ← Hooks スクリプト4種（claude時）
├── .agents/                        ← AIチームのワークスペース
│   ├── TEAM.md                     ← チーム構成・規約（configから生成。直接編集はhookがブロック）
│   ├── koumei/                     ← 最高指揮者（tasks/ reports/ requests/）
│   ├── tech-lead/                  ← instructions/ deliverables/
│   ├── devils-advocate/            ← instructions/ reviews/
│   ├── analyst/ inquisitor/        ← オプションロール（roles 有効時のみ生成）
│   ├── ux-designer/ scribe/        ←   scribe は成果物の圧縮・構造化を担う主簿
│   ├── task-manager/               ← マルチタスク実行役（claude時）
│   └── custom-roles/               ← カスタムロールテンプレート
└── docs-official/                  ← 公式ドキュメント（output.dir で変更可）
```

## 設定変更の流れ

`TEAM.md` や各ロールの指示ファイルは **config からの生成物**です。設定を変えたい場合:

1. `koumei.config.yaml` を編集（モデル・ロール・レビューモード・カスタム指示など）
2. `setup.sh --update` で再生成

quality-gate hook が `.agents/TEAM.md` の直接編集をブロックするため、変更は必ずこの経路で行ってください。

## ドキュメント

- [設定ファイル詳細](docs/configuration.md)
- [カスタマイズガイド](docs/customization.md)
- [origin 取り込み記録](docs/origin-import.md)
- [統合計画書](docs/integration-proposal-origin-base.md)

## ライセンス

MIT。チームアーキテクチャ・スキル定義・Hooks は [kuruusuniku/koumei](https://github.com/kuruusuniku/koumei)（MIT）由来です。

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
- **無人運転**: `--unattended` で、人に一切問わず行列を直列処理。判断を要する場面では停止せず**待避（PARK）**して次のタスクへ進み、朝に「何が決まれば進むか」を書いた**戦況表**を残す。課題管理システムの状態遷移・コメントも連携可能（任意）
- **Git運用の明文化とホスト対応**: 派生元からの分岐・**フェーズ完了ごとの commit/push** を掟として定め、無人でも成果が失われない。PR は GitHub / Bitbucket を判別して作成（Bitbucket は PR作成URLを提示）
- **STAGING確認チェックリスト**: Phase 7 で「人がステージングで確かめるべきこと」を、**書いた本人以外が読める形**で生成（期待する結果の空欄を禁止・回帰と未検証領域を分離・移植タスクでは移行元との突き合わせを必須化）
- **git 操作の排他**: **一つの作業ツリーにつき、git を触る者は一人**（指揮者）。サブエージェント・外部委譲先はブランチ操作・commit・push・PR作成を行わない。整頓のためではなく、`HEAD` と index を共有する**並列実行が壊れないための要件**（読み取りの `git diff` 等は禁じない）
- **ブランチ運用の一元化**: 派生元・PR先・命名は config が正。上書きは例外とし、**明示・タスク定義への記録・理由**の三条件を課す。Phase 0 の分岐も Phase 7 の PR も config ではなく**タスク定義を読む**（決定を対話に置けば、十万トークン後の実行者には届かないため）。無人運転では上書きを一切許さない
- **Hooks**: TEAM.md 保護・操作ログ・自動フォーマット・フェーズ完了通知（claude / antigravity 対応）
- **クロスCLI・外部委譲**: Claude CLI から Antigravity（agy）や Codex へ**分析フェーズ（Phase 1）と実装フェーズ（Phase 5）**を安全に委譲（委譲の可否は config の指定が決める。隔離は作業ブランチとフェーズ毎のコミットが担う。レートリミット時の自動引き継ぎ・フォールバック付き）
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
#    人が離れている間に、行列のタスクを自律処理させる場合
/koumei-start --unattended
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

| ロール | 責務 | 既定モデル(claude) |
|--------|------|------|
| **analyst** | 既存コードベースの調査・分析。移行や大規模リファクタリングで有用 | sonnet |
| **inquisitor** | 諫議大夫。設計前に要件・前提・境界条件を詰問し `design-brief` を作成。設計の手戻りが多いプロジェクトで有用 | fable |
| **ux-designer** | UI/UX設計。tech-lead と並列で設計を実行 | sonnet |
| **scribe** | 主簿。成果物の圧縮・構造化（20KB超の再編）、差分パッケージ作成、タスク定義の畳み込み。トークン経済ルールの執行実務。成果物が重くなる大規模タスクで有用 | sonnet |

ロール構成は `setup.sh --roles` で変更可能。カスタムロール（api-designer / data-engineer / infra-architect）のテンプレートも `.agents/custom-roles/` に展開されます。

### モデルはロール別に変えられる

**上の「既定モデル」は固定値ではありません。** `koumei.config.yaml` の `models:` で
**ロールごとに**指定でき、tech-lead は設計と実装で別々に指定できます。

```yaml
models:
  koumei: "sonnet"
  analyst: "agy"                 # 外部CLIへ委譲（Phase 1）
  inquisitor: "fable"
  ux-designer: "sonnet"
  tech-lead-design: "opus"
  tech-lead-implement: "agy"     # 外部CLIへ委譲（Phase 5）
  devils-advocate: "fable"
  scribe: "sonnet"
```

- 指定できる値: `haiku` / `sonnet` / `opus` / `fable`（またはフルモデルID）、
  および TEAM.md「外部CLIモデル定義」に登録した名前（`agy` / `agy-high` / `codex` / `grok` 等）
- 変更は **`koumei.config.yaml` を編集して `setup.sh --update`**。
  `.agents/TEAM.md` の直接編集は生成物への書き込みであり、hook がブロックし `--update` で消えます
- **どこに何を置くかの理由**は生成後の `.agents/TEAM.md`「配置の原則」に、
  設定の詳細は [docs/configuration.md](docs/configuration.md#models) にあります

**まず既定のまま回して、消費と出来が見えてから触るのが順序です。**
初回に選び分ける材料は、まだ手元にありません。

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

- `--manual` で手動進行、`--multi` でマルチタスク並列実行（claude / antigravity 対応）、`--unattended` で無人運転
- **無人運転（`--unattended`）**: 行列を直列に、人に問わず処理する。`phases.md` が「ユーザーに判断を仰ぐ」とする箇所は**すべて待避（PARK）に読み替える**（問えば朝まで止まるため）。待避時は成果を commit+push した上で「何処まで進んだか／何で止まったか／**何が決まれば進めるか**」を残し、直ちに次へ移る。三件続けて待避したら運転を終える
- **ブランチは Phase 0 で確定させ、タスク定義の `## ブランチ` に記録する**（派生元・ブランチ名・PR先・上書き理由）。Phase 7 は PR作成前にブランチ名を照合し、食い違えばPRを作らず待避する
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
| 無人運転（--unattended / 待避・戦況表） | ✅ | ✅ | ✅ |
| 課題管理システム連携（ticket・任意） | ✅ | ✅ | ✅ |

フル体験は claude および antigravity ターゲット（codex はコアワークフローのみ）。

### 課題管理システム連携（ticket・任意）

**枠組みは特定の課題管理システムを前提としない。** 状態名は `koumei.config.yaml` の `ticket` セクションで
宣言し、生成物にはその現場の名前が展開される。Jira でも GitHub Issues でも Linear でも、
自分の現場で使っている状態名をそのまま書けばよい。

```yaml
ticket:
  enabled: true
  queue: |
    status = "AI-READY" AND assignee = currentUser()   # 行列の条件。必ず自分の担当に絞る
  status_designing:    "AI-PLANREVIEW"    # 設計フェーズ中
  status_implementing: "AI-PROGRESS"      # 実装フェーズ中
  status_review_ready: "AI-PR"            # 作業完了・PR待ち
  status_parked:       "ペンディング"      # 待避（判断できず手を止めた）
  status_staging_ok:   "本番デプロイ待ち"   # STAGING確認 合格
  status_staging_ng:   "PR実装の差し戻し"   # STAGING確認 不合格
```

- **Phase 7 の STAGING確認チェックリストの判定先**も、この設定から生成される。
  `status_staging_ok` / `status_staging_ng` / `status_parked` の**三つが揃ったときだけ**
  状態遷移の指示になり、一つでも空なら「その現場の言葉で書く」一般形のまま出る
  （片方だけ設定できると `** ** へ移す` という空の指示が出て、確認する人がそこで止まるため）
- **`queue` を空のまま `enabled: true` にしても連携は無効**として扱う。
  行列を絞らずに走らせれば、夜中に他の担当者のチケットまで拾ってしまう。
  さらに**無人運転はこの設定では起動しない** —— `enabled: true` は「チケットで回す」という
  意思表示であり、それが満たせないのに**黙ってローカルのタスクファイルへ読み替えて夜通し走れば、
  朝、意図と違うものが処理されている**ことになる。一件も処理せず報告して終える
  （対話実行は人が警告を読めるため、従来どおり警告のみで継続する）
- **セクションごと書かなければ連携は一切行われない。** 既存プロジェクトはそのまま動く
- **接続手段（MCP・CLI・API）は枠組みの管轄外。** 実行環境が備えるものを使う前提とし、
  枠組みが持つのは「どこから引き、いつ何処へ動かすか」の作法のみ

詳細は [docs/configuration.md](docs/configuration.md#ticket課題管理システム連携任意) を参照。

## ターゲットCLI別の実行フロー・ロール遷移

各ターゲット環境に応じたエージェント起動・ロールバトンタッチの詳細は [docs/target-cli-flows.md](docs/target-cli-flows.md) を参照してください。

- **`claude` (Claude Code)**: `Agent` ツールによる自律サブエージェント呼び出し。ロールごとに異なるモデル（Fable/Opus/Sonnet）を起動し、`.claude/settings.json` の Hooks で安全性を担保。
- **`antigravity` (Antigravity / `agy`)**: `invoke_subagent` ツールによるサブエージェント起動。`TEAM.md` のモデル定義から `pro` / `flash` の階層を動的に解決。`Subagents` 配列によるネイティブ並列マルチタスクと `.agents/hooks.json` に対応。
- **`codex` (Codex CLI)**: サブエージェントネストを持たないため、単一セッション内でロール定義（`AGENTS.md`）を順次読み替えながら直列実行。
- **クロスCLI・ハイブリッド連携**: Claude CLI を司令塔（設計・オーケストレーション・レビュー）とし、**入力の重い分析フェーズ（Phase 1）とトークン量の多い実装フェーズ（Phase 5）**を `agy`（Gemini）に委譲（**指揮者と同じ作業ツリーの作業ブランチ上**で実行。隔離はブランチとフェーズ毎のコミットが担う）。レートリミット（429）検知時の自律引き継ぎ・フォールバックを完備。

### 外部CLI委譲の要件（agy / codex）

委譲は「動かない時に黙って Claude へ落ちる」ため、不備が露見しにくい。以下は省略不可。

- **実行の許可**: `.claude/settings.json` の `permissions.allow` に委譲コマンドを載せる。無いとヘッドレス実行で承認要求に阻まれ、**一度も実行されないままフォールバックする**（setup.sh が自動で配置）
- **`--add-dir "$PWD"`**: agy は cwd をワークスペースとみなさない。無指定だと実装が agy の作業領域へ書かれて**消える**
- **背景実行**: 前景の Bash は既定2分・上限10分で打ち切られる。実装も分析もこれを超えうるため `run_in_background` で起動する
- **成否は実物で判定する**: 委譲先の `status` は成功時も `ERROR` を返すことがある。実装なら `git status` の差分とビルド、分析なら成果物ファイルと「分析品質基準」で判じる（**ファイルが在るというだけで合格としない**）
- **消費ゼロは設定不備の署名**: ログの `usage.total_tokens` が 0 なら一度も動いていない。フォールバックで隠さず報告して停止する

**委譲できるのは分析（Phase 1 / analyst）と実装（Phase 5 / tech-lead）の二つ**です。
選ぶ基準は出力量ではなく、**① 固定費（agy で14〜16k/回）を上回る入力があるか
② 成果物の誤りを機械的に検証できるか ③ 誤りが次のゲートで捕まるか**の三つ。
詳細は [docs/configuration.md](docs/configuration.md#外部cli委譲を指定したときの要件) を参照。

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

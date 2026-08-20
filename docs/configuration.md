# 設定ファイル詳細（koumei.config.yaml）

`setup.sh` が読み込む唯一の設定ファイル。**TEAM.md・各ロールの役割定義・スキルはすべてこの config からの生成物**であり、設定変更は「config を編集 → `setup.sh --update`」で反映する（TEAM.md の直接編集は quality-gate hook がブロックする）。

## project

| キー | 説明 |
|------|------|
| `name` | プロジェクト名。TEAM.md・各ロール定義に表示される |
| `description` | 概要（任意） |
| `path` | プロジェクトルート相対パス（通常 `.`） |

## migration（任意）

既存システムからの移行プロジェクトの場合に設定。

> ⚠️ **現バージョンでは未配線**: この設定は記録されるのみで、生成テンプレートはまだ参照しない（origin 統合で旧テンプレートの消費箇所が置き換わったため）。配線は今後のフェーズで対応予定。

| キー | 例 |
|------|-----|
| `enabled` | `true` / `false` |
| `source_path` | 移行元プロジェクトのパス |
| `source_framework` / `target_framework` | `"Nuxt 2"` / `"Next.js 15"` |

## roles

コアロール（`koumei` / `tech-lead` / `devils-advocate`）は必須。オプションロール（`analyst` / `inquisitor` / `ux-designer`）は記載時のみ有効化され、対応するスキル（`-analyze` / `-grill` / `-design` / `-design-ux`）・ワークスペース・TEAM.md の記載が展開される。無効ロールのフェーズはワークフロー上自動的にスキップされる。

| ロール | 有効化で追加されるもの |
|--------|--------------------|
| `analyst` | Phase 1（分析）・Phase 2（分析レビュー）、`/koumei-analyze` |
| `inquisitor` | **Phase 2.5（詰問）**、`/koumei-grill`、`grilling` 設定ブロック |
| `ux-designer` | Phase 3 の UX設計、`/koumei-design`・`/koumei-design-ux` |

## target_cli / skill_prefix

| キー | 値 | 説明 |
|------|-----|------|
| `target_cli` | `"claude"`（既定） / `"codex"` / `"antigravity"` | スキル配置先と役割定義ファイル名が変わる（claude: `.claude/skills` + `CLAUDE.md`、codex: `.codex/skills` + `AGENTS.md`、antigravity: `.agents/skills` + `AGENTS.md`）。**task-manager・マルチタスクは claude 限定（Hooks は claude / antigravity で利用可）** |
| `skill_prefix` | `"koumei"`（既定） | コマンド接頭辞。`km` にすると `/km-start` 等になり、スキル名・相互参照・手順書内パスもすべて追従する |

## commander

| キー | 説明 |
|------|------|
| `name` | 最高指揮者のコードネーム（既定: `"諸葛孔明"`）。TEAM.md・koumei ペルソナ・各スキルの名乗りに反映される |

## models

tech-lead は**フェーズ分割**（設計と実装で別モデル）。配置の原則は「高単価モデルは、トークン量が多い場所ではなく判断のレバレッジが高く出力が小さい場所へ」。

| キー | claude 既定 | 役割 |
|------|------|------|
| `koumei` | sonnet | オーケストレーション（機械的） |
| `analyst` | sonnet | 読み取り中心の分析 |
| `inquisitor` | **fable** | 「何を問わなかったか」は誰にも検知できない。問いの質が下流の設計精度を決める |
| `ux-designer` | sonnet | UX設計 |
| `tech-lead-design` | **fable** | 設計ミスは実装で増幅されるため最上位 |
| `tech-lead-implement` | **opus** | トークン量が多いため1段下 |
| `devils-advocate` | **fable** | レビューVERDICTは品質ゲート。誤判定コストが最大 |

指定可能な値: `haiku` / `sonnet` / `opus` / `fable`（またはフルモデルID）、および TEAM.md「外部CLIモデル定義」に登録した外部モデル名（`grok` / `codex` 等。この場合 Agent tool ではなく Bash 経由で起動される）。

## review

| キー | 既定 | 説明 |
|------|------|------|
| `mode` | `"default"` | `default`（codex→claude） / `economy`（codex→lmstudio→claude） / `claude-only` |
| `timeout` | `600` | 外部CLIレビューのタイムアウト（秒）。超過で次順位モデルへ自動フォールバック |

一時的なモデル切替は `/koumei-review --model claude` のようにフラグで可能（config 変更不要）。

## grilling

`inquisitor` ロールが有効な場合のみ使用される。Phase 2.5（設計前の詰問）の挙動を制御する。

| キー | 既定 | 説明 |
|------|------|------|
| `max_rounds` | `3` | 詰問の最大ラウンド数。前ラウンドの回答から派生する問いを立てて掘り下げる。論点が出尽くせば上限前に終了する |
| `escalate` | `"high"` | `high` = 根拠なき前提のうちリスク「高」のものだけユーザーに確認して停止 / `none` = 一切停止せず、AI判断で確定させて design-brief に明記して進む |

**`escalate` の選び方:**

- **`high`（既定）** — 全自動フローでも、設計をやり直すレベルの前提だけは人に確認する。停止は多くて1回
- **`none`** — 夜間バッチ等の無人実行向け。停止しない代わりに、リスク「高」の前提が design-brief の「設計者への申し送り」に「**AI判断・要事後確認**」として残るので、翌朝そこだけ見ればよい

不正な値を指定した場合は警告のうえ `high` として扱われる。

**この工程が精度を上げる仕組み:**

1. **役割分離** — 問いを立てるのは inquisitor サブエージェント、答えるのはオーケストレーター本体。自問自答させると「自分が答えられる問いしか立てない」ため、分離が必須
2. **根拠の格付け** — 回答には出典（要件指示書 / 公式ドキュメント / 既存コード / 既存慣習からの類推）を必ず付す。出典を示せないものは確定させず「前提（ASSUMPTION）」としてリスク度付きで記録する
3. **成果物化** — `.agents/inquisitor/deliverables/task-{番号}-design-brief.md` が Phase 3（設計）の入力になり、Phase 4（設計レビュー）では devils-advocate がブリーフと設計の突合を行う

## tech_stack

AIがコードを書く際に従う技術情報と、実装後の検証コマンド。

| キー | 説明 |
|------|------|
| `language` / `framework` / `ui_library` / `styling` / `database` / `testing` | 技術スタック（TEAM.md の技術スタック表と各ロール定義に反映） |
| `build_command` | 実装完了後のビルド確認に使用 |
| `test_command` | テストコマンド（任意） |
| `check_command` | **PR前 lint/format ゲート**。設定すると実装フェーズの完了条件に「チェックが通ること」が追加される。空ならゲート自体をスキップ |

## git

| キー | 説明 |
|------|------|
| `main_branch` / `develop_branch` | ブランチ運用の既定値（現状エージェントに自動配線されるのは `branch_pattern` のみ。ベース/PR先ブランチは `/koumei-request` の対話で確認される） |
| `branch_pattern` | 作業ブランチの命名パターン（`{number}` `{summary}` が置換される） |
| `dev_rules` | TEAM.md の開発規約セクションに追記する行（任意）。**`#` や引用符を含む値・複数行は必ず `\|` ブロック形式で**（プレーンスカラーは yq 無し環境で `#` 以降が切り捨てられる） |

## output（成果物の2層構成）

- **作業成果物**（分析・設計・レビュー・報告）は `.agents/{ロール}/deliverables/` 等の各ワークスペースに置かれ、config の対象外。タスク単位・上書き型の内部記録
- `output.dir` は**公式ドキュメント**の出力先。`{機能スラッグ}/requirements-spec-design.md` として**機能/エピック単位で要件・仕様・設計を1ファイルに集約**する。タスクの度に新規ファイルを作るのではなく、Phase 7（PR作成前）で該当セクションを更新する「今の正」を反映する生きたドキュメント

| キー | 既定 | 説明 |
|------|------|------|
| `dir` | `"docs-official"` | 公式ドキュメントの出力ディレクトリ |
| `format` | `"md"` | 現在は md のみ |
| `instructions` | — | 公式ドキュメントに関する追加指示（任意・複数行可） |

## custom_instructions

ロール別のプロジェクト固有指示。生成される各ロールの役割定義ファイル末尾に「プロジェクト固有の指示」として追記される。キー: `koumei` / `tech-lead` / `devils-advocate` / `analyst` / `inquisitor` / `ux-designer`。

`inquisitor` には「このプロジェクトで特に詰めるべき論点」を書くとよい（例: `- 課金・請求に関わる論点は必ずリスク「高」として扱うこと`）。過去に手戻りが起きた領域を書いておくと、同じ穴を繰り返さなくなる。

## reference_docs

各ロールが作業前に参照すべきドキュメントのリスト（`path` + `description`）。TEAM.md の「参照ドキュメント」セクションに反映される。

> ⚠️ この項目の読み込みには **yq が必要**（`brew install yq`）。yq 無し環境では警告を出した上で「（登録なし）」として生成される。

## 設定変更の反映と差分検知

```bash
setup.sh --update     # config はそのまま、最新テンプレートで再生成
setup.sh --reconfig   # ウィザードで config を作り直してから再生成
```

- `--update` は config スキーマの差分を検知する。フレームワーク更新で新しい設定項目が必要になった場合、再生成せず `--reconfig` を案内して停止する
- 生成ファイルのうち Git 管理下のものは上書きスキップされる（例外: **TEAM.md は純粋な生成物のため常に強制再生成**。上書き前のバックアップは `.agents/.backup/` に保存される）

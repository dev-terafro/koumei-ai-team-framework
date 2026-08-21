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

コアロール（`koumei` / `tech-lead` / `devils-advocate`）は必須。オプションロール（`analyst` / `inquisitor` / `ux-designer` / `scribe`）は記載時のみ有効化され、対応するスキル（`-analyze` / `-grill` / `-design` / `-design-ux` / `-condense`）・ワークスペース・TEAM.md の記載が展開される。無効ロールのフェーズはワークフロー上自動的にスキップされる。

| ロール | 有効化で追加されるもの |
|--------|--------------------|
| `analyst` | Phase 1（分析）・Phase 2（分析レビュー）、`/koumei-analyze` |
| `inquisitor` | **Phase 2.5（詰問）**、`/koumei-grill`、`grilling` 設定ブロック |
| `ux-designer` | Phase 3 の UX設計、`/koumei-design`・`/koumei-design-ux` |
| `scribe` | フェーズ完了時のガードレール検査で主簿が起動（20KB超の再編・差分パッケージ・タスク定義の畳み込み）、`/koumei-condense`。無効時は指揮者本体がトークン経済の定めを直接運用する |

## target_cli / skill_prefix

| キー | 値 | 説明 |
|------|-----|------|
| `target_cli` | `"claude"`（既定） / `"codex"` / `"antigravity"` | スキル配置先と役割定義ファイル名が変わる（claude: `.claude/skills` + `CLAUDE.md`、codex: `.codex/skills` + `AGENTS.md`、antigravity: `.agents/skills` + `AGENTS.md`）。**Hooks・マルチタスクは claude / antigravity で利用可（codex はコアワークフローのみ）** |
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
| `scribe` | sonnet | 要約・選別は原文の理解を要し、取りこぼしは下流で検知できない。haiku は重い資料の書き出しで停止する実測があるため充てない |

指定可能な値: `haiku` / `sonnet` / `opus` / `fable`（またはフルモデルID）、および TEAM.md「外部CLIモデル定義」に登録した外部モデル名（`agy` / `agy-high` / `codex` / `grok` 等。この場合 Agent tool ではなく Bash 経由で起動される）。

### 外部CLI委譲を指定したときの要件

外部モデル名を指定すると Bash 経由の起動になり、Agent tool とは前提が変わる。
**委譲が動かない場合は Claude へ自動フォールバックするため、不備が表に出にくい。**
以下は setup.sh が自動で整えるが、手で settings.json を管理している場合は確認すること。
**要件はどのロールに委譲する場合も等しく必要**である。

| 要件 | 無いとどうなるか |
|------|------------------|
| `.claude/settings.json` の `permissions.allow` に委譲コマンド | ヘッドレスで承認要求に阻まれ、**一度も実行されない** |
| `--add-dir "$PWD"`（agy） | cwd がワークスペースにならず、**成果物が消える** |
| `run_in_background` での起動 | 前景の Bash が既定2分（上限10分）で打ち切る |
| **実物**での成否判定 | 委譲先の `status` は成功時も `ERROR` を返すことがある |
| `usage.total_tokens == 0` の検出 | 「委譲したつもりで一度も動いていない」状態に気づけない |

**「実物」はロールによって変わる。** 実装（Phase 5）なら `git status` の差分とビルド、
分析（Phase 1）なら成果物ファイルと役割定義の「分析品質基準」である。
分析では**ファイルが在るというだけで合格としてはならない**。
実装で「差分があること」ではなく「ビルドが通ること」を求めるのと同じ理で、
浅い走査で書かれた**それらしく見えて中身の無い分析**を通してしまう。

#### 委譲できるフェーズと、向き不向き

委譲に対応しているのは**分析（Phase 1 / analyst）と実装（Phase 5 / tech-lead）の二つ**。
他のロールにモデル委譲を設定しても委譲は起きない。

外部CLI には1呼び出しあたりの固定費がある（agy の実測で14〜16k トークン）ため、
**出力が大きい役を選ぶのではなく、次の三つで測る**。

1. **固定費を上回る"入力"があるか** — 基準は出力量ではなく入力量。コードベースを広く走査する
   analyst は、委譲すれば読み取りごと外へ出る
2. **成果物の誤りを機械的に検証できるか** — 事実の集約（分析・実装）は原本と突き合わせられる。
   判断（設計・レビュー）は突き合わせる原本が無い
3. **誤りが次のゲートで捕まるか、下流まで潜るか** — 設計の誤りは実装で増幅され、表に出るまでが遠い

**モデルは TEAM.md 側で明示指定すること。** `--model` を省くと利用者のグローバル設定
（`~/.gemini/antigravity-cli/settings.json` 等）に依存し、他用途で変えた瞬間に
プロジェクトの実装モデルが黙って変わる。

なお agy の `pro` 系は 3.1 世代で止まっており、`flash` は 3.7 まで来ている。
**「pro に上げる」は格上げにならない。** 推論を強めたい場合は
`agy-high`（`gemini-3.7-flash-high`）のように同世代で effort を上げる。

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
| `main_branch` / `develop_branch` | 作業ブランチの**派生元**、および**PRの向け先**。`develop_branch` が空でなければそちらが優先される（空なら `main_branch`）。Phase 0 の分岐と Phase 7 の PR 作成の双方に配線されている |
| `branch_pattern` | 作業ブランチの命名パターン。`{number}`（チケットキー、無ければタスク番号）／`{summary}`（英小文字ケバブケース）／`{type}`（種別から導出。軽微修正・バグ修正 → `fix`、機能追加/移植 → `feature`）が置換される |
| `dev_rules` | TEAM.md の開発規約セクションに追記する行（任意）。**`#` や引用符を含む値・複数行は必ず `\|` ブロック形式で**（プレーンスカラーは yq 無し環境で `#` 以降が切り捨てられる） |

## ticket（課題管理システム連携・任意）

無人運転（`/koumei-start --unattended`）で消費される。**セクションごと書かなければ連携は一切行われず、既存プロジェクトはそのまま動く**（`--update` が `--reconfig` を要求することもない）。

**接続手段は枠組みの管轄外。** MCP・CLI・API のいずれであれ、実行環境が備えるものを使う前提とし、ここで定めるのは「どこから引き、いつ何処へ動かすか」のみ。

| キー | 説明 |
|------|------|
| `enabled` | `true` で連携する |
| `queue` | 無人運転が引く行列の条件。**必ず自分の担当に絞ること**（絞らなければ他の担当者のチケットまで夜中に処理してしまう）。空欄のまま `enabled: true` にしても連携は無効として扱われ、警告が出る。**加えて無人運転はこの設定では起動せず、一件も処理せずに報告して終える**（意思表示と設定が食い違ったまま別の行列で夜通し走るのを防ぐため。対話実行は警告のみで継続する）。**引用符や `#` を含むため必ず `\|` ブロック形式で書く**（プレーンスカラーは yq 無し環境で引用符が剥がれ、検索条件が壊れる） |
| `status_designing` | 分析・詰問・設計フェーズの間の状態名 |
| `status_implementing` | 実装・コードレビューフェーズの間の状態名 |
| `status_review_ready` | AIの作業完了・PR待ちの状態名 |
| `status_parked` | 待避（AIが判断できず手を止めた）の状態名。Phase 7 の「判断に迷う」の行き先も兼ねる |
| `status_staging_ok` | Phase 7 STAGING確認 **合格**（例: `本番デプロイ待ち`） |
| `status_staging_ng` | Phase 7 STAGING確認 **不合格・差し戻し**（例: `PR実装の差し戻し`） |

状態名は**その現場で実際に使われている名**を書く。空欄の項目は遷移させない。
`status_*` を入れ子（`status:` の下）にしてはならない — yq が無い環境のフォールバックパーサーは2階層までしか読めず、黙って空を返す。

```yaml
ticket:
  enabled: true
  queue: |
    status = "AI-READY" AND assignee = currentUser()
  status_designing: "AI-PLANREVIEW"
  status_implementing: "AI-PROGRESS"
  status_review_ready: "AI-PR"
  status_parked: "ペンディング"
  status_staging_ok: "本番デプロイ待ち"
  status_staging_ng: "PR実装の差し戻し"
```

### STAGING確認の判定先（Phase 7）

Phase 7 の STAGING確認チェックリストは「合格・不合格・保留」の三つの行き先を持つ。
その行き先は `status_staging_ok` / `status_staging_ng` / `status_parked` から展開される。

**この三つが揃ったときだけ**、判定が状態遷移の指示として生成される。
一つでも空なら、判定は現場の言葉で書くための一般形のまま出る。

片方だけ設定できる作りにすると `**  ** へ移す` という空の指示が生成物に出る。
確認する人はそれを読んで手が止まる。中途半端に出すくらいなら、
一般形のまま出して人に書かせるほうが確実である。

## output（成果物の2層構成）

- **作業成果物**（分析・設計・レビュー・報告）は `.agents/{ロール}/deliverables/` 等の各ワークスペースに置かれ、config の対象外。タスク単位・上書き型の内部記録
- `output.dir` は**公式ドキュメント**の出力先。`{機能スラッグ}/requirements-spec-design.md` として**機能/エピック単位で要件・仕様・設計を1ファイルに集約**する。タスクの度に新規ファイルを作るのではなく、Phase 7（PR作成前）で該当セクションを更新する「今の正」を反映する生きたドキュメント

| キー | 既定 | 説明 |
|------|------|------|
| `dir` | `"docs-official"` | 公式ドキュメントの出力ディレクトリ |
| `format` | `"md"` | 現在は md のみ |
| `instructions` | — | 公式ドキュメントに関する追加指示（任意・複数行可） |

## custom_instructions

ロール別のプロジェクト固有指示。生成される各ロールの役割定義ファイル末尾に「プロジェクト固有の指示」として追記される。キー: `koumei` / `tech-lead` / `devils-advocate` / `analyst` / `inquisitor` / `ux-designer` / `scribe`。

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

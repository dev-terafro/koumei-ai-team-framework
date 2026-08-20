# koumei 統合計画書: origin アーキテクチャの取り込み

> 決定事項:
> - **アーキテクチャは origin 準拠**（ロール構成・ペルソナ・レビュー体制・Hooks・マルチタスク・規約）
> - **リポジトリは framework**（`donkey-maru/koumei-ai-team-framework`）。本リポジトリの開発にテックリーダーは関与しない
> - **origin（`kuruusuniku/koumei`）は上流OSSとして扱う**: MIT ライセンスに基づきコンテンツを取り込み、出典コミットを記録。以後の追従は任意（良い改善だけ手動で取り込む）
> - **マルチCLI展開（claude / codex / antigravity）は維持**。CLI 別機能マトリクスで段階対応
>
> 比較の詳細は `integration-comparison-origin.md` を参照。

---

## 1. 基本方針

| 項目 | 内容 |
|---|---|
| リポジトリ | **framework** のまま。統合作業はすべて本リポジトリへの PR |
| origin の扱い | **上流スナップショット取り込み**。取り込み元コミットを記録（現時点の main: `a00de20`）。LICENSE/README に出典と MIT 表記を残す。origin 側の今後の開発に追従義務はなく、有用な改善のみ `git log {取り込みコミット}..` で差分レビューして手動移植 |
| アーキテクチャ | **origin 準拠**: ロール構成（koumei / analyst / ux-designer / tech-lead / devils-advocate / task-manager）、`.agents/` レイアウト、レビュー体制、フェーズ省略ルール、差し戻しカウンタ |
| 規約 | origin 準拠を**自分の選択として**採用: 諸葛孔明ペルソナ、`disable-model-invocation: true`、コミットメッセージの Co-Authored-By 禁止。いずれも自分の裁量でいつでも変更可 |
| マルチCLI | **維持**。framework の `target_cli` + `{{#IF_CLI}}` 条件生成で CLI 別に出し分け。Claude Code 固有機能は claude ターゲット限定として明示 |

## 2. origin から取り込むもの（アーキテクチャ・コンテンツ）

- ロール名・ペルソナ（koumei=諸葛孔明、devils-advocate、部将 等）→ framework の commander / reviewer 命名を置き換え
- レビュー体制一式（自動種別判定 / `--security` / `--second-opinion` / `--model` / タイムアウトフォールバック / **自己レビュー絶対禁止ルール**）
- モデル運用（fable設計・fableレビュー / opus実装のフェーズ分割、外部CLIモデル定義、economy モード、codex 委譲）
- マルチタスクモード（`--multi`、git worktree、1タスク=1ブランチ=1PR、task-manager）
- Hooks 4種（quality-gate / log-operation / auto-format / notify-phase）※claude ターゲット限定
- タスク種別によるフェーズ省略ルール（コードレビューは絶対に省略しない）
- カスタムロール機構（テンプレート3種 + 実行時自動検出）
- 運用ルール文書（rules.md / phases.md / error-handling.md / multi-task.md）
- レビュー成果物命名（`task-{n}-{analysis|design|code}-review.md`）→ framework の3系統不整合を解消

## 3. framework に残すもの（配布・設定エンジン）

- `koumei.config.yaml` + 対話式ウィザード（技術スタック自動検出付き）
- テンプレート変数の自動展開（origin の手動プレースホルダ置換を解消）
- `--update`（config スキーマ差分検知付き再生成）/ `--reconfig` / `--roles` / `--cli` / `--clean` / `--dry-run`
- Git 管理下ファイルの上書き保護 + バックアップ
- マルチCLI展開（`target_cli` + `{{#IF_CLI}}` 条件生成）
- `koumei-request`（要件整理スキル。origin に存在しない）→ 孔明ペルソナに合わせて改修
- `check_command`（PR前 lint ゲート）
- `custom_instructions`（ロール別カスタム指示の注入）
- **TEAM.md の生成化**: origin の「TEAM.md 内 Markdown 表設定」（モデル列 / 外部CLIモデル定義 / review_mode / セカンドオピニオン設定等）を config のキーに吸収し、TEAM.md は config から生成する
  - origin の quality-gate hook（TEAM.md 直接編集ブロック）と整合: 設定変更 = config 編集 → `--update` が正規ルートになる
  - 生成後の TEAM.md の内容・書式は現行 origin と同一に保つ（スキル群から見て無変更）

## 4. CLI 別機能マトリクス（マルチCLI維持の実際）

origin の一部機能は Claude Code 固有機構（Hooks / Agent tool / サブエージェント5段ネスト）に依存するため、CLI 別に提供範囲を明示する。

| 機能 | claude | codex | antigravity |
|---|---|---|---|
| コアワークフロー（request→start→analyze→design→review→implement→status） | ✅ | ✅ | ✅ |
| ロール定義・ペルソナ・フェーズ省略ルール・差し戻しカウンタ | ✅ | ✅ | ✅ |
| ドキュメント2層化（docs-official 公式層） | ✅ | ✅ | ✅ |
| check_command lint ゲート | ✅ | ✅ | ✅ |
| レビュアー独立実行 | ✅ Agent tool | ✅ 外部CLI呼出（Bash）で代替 | ✅ 同左 |
| 外部CLIモデル（grok / gemini 等） | ✅ | ✅（Bash 前提） | ✅（同左） |
| Hooks（quality-gate / log / auto-format / notify） | ✅ | ❌（Claude Code hooks 固有） | ✅ |
| セカンドオピニオン / タイムアウトフォールバック | ✅ | △（Bash 呼出部分のみ） | △ |
| マルチタスク（--multi / task-manager / worktree 並列） | ✅ | ❌（ネストsubagent前提） | ✅ |
| フェーズ別モデル指定（Agent tool model param） | ✅ | △（CLI 呼出時の -m 指定等で部分対応） | △ |

- 生成時に `{{#IF_CLI claude}}` で該当セクションごと出し分ける（codex/antigravity 版のスキルには Hooks・マルチタスクの記述自体が入らない）
- README に本マトリクスを掲載し、「フル体験は claude、codex/antigravity はコアワークフロー」と明示する

## 5. 新規実装（どちらにもない、合意済みの新機能）

**ドキュメント2層化**:

- 作業成果物 → `.agents/{ロール}/deliverables/`（= origin の現行そのまま）
- 公式ドキュメント → `docs-official/`（config で変更可）に**機能/エピック単位で要件・仕様・設計を1ファイル**
- ワークフロー最終フェーズに「ドキュメント反映」を追加: 実装完了・レビュー通過後、承認済みの内容を該当機能のファイルへ更新（無ければ作成、あれば該当セクション更新）
- `docs-official` は常に「現在の正」を反映する生きたドキュメント。履歴は git と `.agents/` が持つ

## 6. 落とすもの

| 項目 | 判断 | 理由 |
|---|---|---|
| framework のロール名（commander / reviewer） | 落とす | origin 命名（koumei / devils-advocate）に統一。移行スクリプトでリネーム対応 |
| framework の koumei-run（独立全自動スキル） | 落とす | origin は koumei-start に全自動が統合済み |
| framework のレビュー命名3系統 | 落とす | origin の `task-{n}-{analysis\|design\|code}-review.md` に統一 |
| framework の `{{OUTPUT_DIR}}` へのタスク単位成果物出力 | 落とす | 2層化で置き換え（作業成果物は `.agents/`、公式は機能単位1ファイル） |
| origin の手動プレースホルダ置換 | 落とす | テンプレートエンジンで自動化 |
| origin quality-gate.sh の tachikoma 由来デッドコード | 落とす | 移植時に清掃 |

## 7. 段階的実行計画（すべて framework への PR。承認待ち工程なし）

| Phase | 内容 | 規模感 |
|---|---|---|
| 1 | **origin コンテンツ取り込み + テンプレート化**（統合の山場）: origin の `.agents/` 一式・skills・hooks・ルール文書を framework の `templates/` に `.tmpl` として取り込み（取り込み元コミットを記録、MIT 出典表記）。`{{#IF_CLI}}` で CLI 別出し分け。ロール名を origin 準拠に刷新。TEAM.md 生成化（origin の表設定を config キーへ吸収） | 大 |
| 2 | **スキル統合**: koumei-request を孔明ペルソナで統合 / koumei-run 廃止（start に統合）/ check_command・custom_instructions の組み込み / `disable-model-invocation: true` 復活 | 中 |
| 3 | **origin 固有機能の動作確認**: レビュー拡張（--security / --second-opinion / タイムアウトFB）・マルチタスク・Hooks が生成後のプロジェクトで動くことを claude ターゲットで検証。codex/antigravity 版の生成内容確認 | 中 |
| 4 | **ドキュメント2層化**（新規実装） | 中 |
| 5 | **移行**: framework 利用7プロジェクトを新バージョンへ移行（ロール名リネーム + config 変換スクリプト） | 中 |

各 Phase は独立して価値が出る構成（Phase 1 が入った時点で origin 相当の運用が config 駆動で使える）。

## 8. 既存プロジェクトの移行方針

対象は framework 利用7プロジェクトのみ（terafro-neoclient / youtube_dl / admin-next / prevoapi / client-next / client-n3 / shonan_prevo）。

- 変換スクリプトを用意: `.agents/commander/` → `.agents/koumei/`、`reviewer/` → `devils-advocate/` のリネーム + 参照パス一括置換 + config スキーマ変換（models フェーズ分割対応等）
- 進行中タスクがあるプロジェクトはタスク完了後に移行
- スキル名（`/koumei-start` 等）は共通なので操作感の変化は小さい。`/koumei-run` 利用は `/koumei-start`（全自動）へ移行

※ origin 利用プロジェクト（テックリーダー側）の移行は本計画のスコープ外。

## 9. リスクと対策

| リスク | 対策 |
|---|---|
| 上流乖離: origin は今後も進化し、取り込み後に差が開く | 追従義務なしと割り切る。取り込みコミットを記録し、必要時に `git log {コミット}..` で差分レビューして有用な改善だけ手動移植 |
| ライセンス・出典 | origin は MIT。LICENSE への出典表記と取り込みコミットの記録で対応 |
| マルチCLI維持による保守コスト増（origin 機能 × 3 CLI の検証マトリクス） | CLI 別機能マトリクスで「保証範囲」を明文化し、codex/antigravity はコアワークフローのみサポートと割り切る。検証は claude を主対象に |
| TEAM.md 生成化による設定フローの変化 | 生成後の TEAM.md は現行 origin と同一書式を維持。設定変更手段は「config 編集 + --update」に一本化 |
| 7プロジェクトのロール名リネームで過去の成果物参照が切れる | 移行スクリプトでディレクトリごとリネームし、参照パスも一括置換 |

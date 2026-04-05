# Memoria Rails App 計画書

## 概要

obsidian-memoriaの記憶管理エンジン（memoria-core）をRuby/Railsアプリケーションとして再実装する。
Obsidianプラグインは記憶管理の責務を全てRailsアプリに移譲し、チャットUIクライアントとしてのみ機能する。
Discord/LINE等の外部チャネルからも同一APIを通じてアクセス可能にする。

### 設計原則

- **ストレージはマークダウンファイル**。DBは使わない。mdファイルがデータの正（source of truth）
- **Obsidianは読み取り専用のビューア**。mdファイルへの書き込み権限はRailsアプリのみ
- **memoria-coreは人格を知らない**。vault_pathだけ受け取って記憶の読み書きをする。人格定義はアプリケーション層の責務
- **記憶の扱い方はシステム側が制御**。ユーザーには触らせない。プロダクトの競争優位
- **開発速度優先**。一人の開発者が高速イテレーションできる構成

### 実行環境

- 自宅デスクトップ（i5-9400F / GTX 1660 Ti 6GB / RAM 32GB / SSD 1TB）
- OS: Windows 10（WSL2でLinux環境を利用）
- 外部公開: Cloudflare Tunnel（Webhook受け口のみ）

---

## アーキテクチャ

```
┌─────────────────────────────────────────────────┐
│                  Rails App                       │
│                                                  │
│  ┌──────────────┐  ┌────────────────────────┐   │
│  │ API Layer    │  │ Background Workers      │   │
│  │              │  │ (Sidekiq)               │   │
│  │ POST /chat   │  │                         │   │
│  │ POST /reset  │  │ - ChatWorker            │   │
│  │ GET /memories│  │ - ThinkingLoopWorker    │   │
│  │              │  │ - SleepPhaseWorker      │   │
│  │              │  │ - TagProfilingWorker    │   │
│  └──────┬───────┘  └───────────┬────────────┘   │
│         │                      │                 │
│         └──────────┬───────────┘                 │
│                    ▼                             │
│  ┌─────────────────────────────────────────┐    │
│  │         PromptBuilder                    │    │
│  │  memoria_instruction + character.prompt  │    │
│  └──────────────────┬──────────────────────┘    │
│                     ▼                            │
│  ┌─────────────────────────────────────────┐    │
│  │         MemoriaCore (PORO)               │    │
│  │  - ContextRetriever                      │    │
│  │  - TagProfiler                           │    │
│  │  - ChatLogger                            │    │
│  │  - EmbeddingStore                        │    │
│  │  - SleepPhase                            │    │
│  └──────────────────┬──────────────────────┘    │
│                     ▼                            │
│              ~/vaults/{user}/{character}/         │
│              ├── TagProfilingNote/                │
│              ├── SummaryNote/                     │
│              └── FullLog/                         │
└─────────────────────────────────────────────────┘

外部チャネル:
  Obsidian Plugin ──→ POST /api/characters/:id/chat
  Discord Bot     ──→ POST /api/characters/:id/chat（ChannelBinding経由）
  LINE Bot        ──→ POST /api/characters/:id/chat（ChannelBinding経由）
```

---

## データモデル

ActiveRecordはユーザー管理・キャラクター設定・チャネル紐付けにのみ使用。
記憶データ（TPN/SN/FL）はmdファイルとしてファイルシステムに保存。

### DB テーブル（PostgreSQL）

```ruby
# users
#   id: bigint
#   email: string
#   api_token: string (API認証用、has_secure_tokenで生成)
#   daily_budget_yen: integer (default: 100)
#   created_at, updated_at

# characters
#   id: bigint
#   user_id: bigint (FK)
#   name: string
#   system_prompt: text (ユーザーが設定した人格定義)
#   vault_dir_name: string (ファイルシステム上のディレクトリ名、nameから自動生成)
#   thinking_loop_enabled: boolean (default: false)
#   thinking_loop_interval_minutes: integer (default: 30)
#   created_at, updated_at

# channel_bindings
#   id: bigint
#   character_id: bigint (FK)
#   platform: string (discord / line / obsidian)
#   external_id: string (discord_channel_id / line_group_id 等)
#   created_at, updated_at
#   unique index: [platform, external_id]

# api_usage_logs
#   id: bigint
#   user_id: bigint (FK)
#   character_id: bigint (FK)
#   model: string
#   input_tokens: integer
#   output_tokens: integer
#   cost_yen: decimal
#   trigger_type: string (user_message / thinking_loop / sleep_phase / tag_profiling)
#   created_at
```

### Vault ディレクトリ構造

```
VAULT_ROOT (環境変数で設定、デフォルト: ~/memoria-vaults)
└── {user_id}/
    └── {character.vault_dir_name}/
        ├── TagProfilingNote/
        │   ├── TPN-料理.md
        │   └── TPN-仕事.md
        ├── SummaryNote/
        │   └── SN-202604011200-夕食の相談.md
        └── FullLog/
            └── FL-202604011200-夕食の相談.md
```

---

## Phase 分け

### Phase 1: 最小限のRails API + memoria-core移植

**ゴール**: Obsidianプラグインの代わりにcurlで会話できる状態

1. Railsプロジェクト生成（API mode）
2. DB設計・マイグレーション（users, characters テーブル）
3. API認証（api_token によるトークン認証）
4. memoria-core の Ruby 移植
   - `MemoriaCore::VaultManager` — vault_pathの解決、ディレクトリ作成
   - `MemoriaCore::TpnStore` — TPNファイルの読み書き・YAML frontmatterパース
   - `MemoriaCore::SnStore` — SNファイルの読み書き
   - `MemoriaCore::FlStore` — FLファイルの読み書き（会話ログ保存）
   - `MemoriaCore::ContextRetriever` — セマンティック検索・コンテキスト構築
   - `MemoriaCore::EmbeddingStore` — Embeddingのインメモリ管理
   - `MemoriaCore::TagProfiler` — タグプロファイリング
   - `MemoriaCore::ChatLogger` — 会話ログのmd出力
5. `PromptBuilder` — memoria_instruction（記憶の扱い方指示）+ character.system_prompt の結合
6. `LlmClient` — Gemini API呼び出し（Function Calling対応）
7. チャットAPIエンドポイント
   - `POST /api/characters/:character_id/chat` — メッセージ送信・応答取得
   - `POST /api/characters/:character_id/reset` — チャットセッションリセット
8. 動作確認: curlでキャラクターを作成し、会話できることを検証

#### TypeScript → Ruby 移植の方針

- TypeScriptのコードを「翻訳」するのではなく、設計知見を元にRubyらしく書き直す
- Obsidian依存（`app.vault`, `TFile`, `parseYaml`等）は全てRuby標準ライブラリ + Gemで置換
  - ファイル操作: `File`, `Dir`, `FileUtils`
  - YAMLパース: `YAML.safe_load` (Ruby標準)
  - マークダウン処理: 正規表現ベースで十分（frontmatter抽出程度）
- LangChain.js依存は排除。Gemini APIは `ruby-gemini-api` gem または直接HTTPクライアントで叩く
- 非同期処理: JSのasync/awaitパターンはRubyでは不要。ファイルI/Oは同期で問題ない

#### 移植対象ファイル対応表

| TypeScript (現行)            | Ruby (新規)                          | 備考                          |
|------------------------------|--------------------------------------|-------------------------------|
| `src/contextRetriever.ts`    | `lib/memoria_core/context_retriever.rb` | セマンティック検索 + TPN→SN展開 |
| `src/tagProfiler.ts`         | `lib/memoria_core/tag_profiler.rb`   | タグプロファイリング            |
| `src/chatLogger.ts`          | `lib/memoria_core/chat_logger.rb`    | FL/SN出力                      |
| `src/embeddingStore.ts`      | `lib/memoria_core/embedding_store.rb`| Embedding管理                  |
| `src/promptFormatter.ts`     | `app/services/prompt_builder.rb`     | アプリ層に移動                 |
| `src/chatContextBuilder.ts`  | `app/services/prompt_builder.rb`     | PromptBuilderに統合            |
| `src/chatSessionManager.ts`  | `app/services/chat_session.rb`       | セッション管理                 |
| `src/settings.ts`            | DBのcharactersテーブル + 環境変数    | 設定はDB/env管理               |
| `src/tools/toolManager.ts`   | `lib/memoria_core/tool_manager.rb`   | Function Calling管理           |
| `src/locationFetcher.ts`     | Phase 3 以降で検討                   | 優先度低                       |

### Phase 2: Sidekiq導入 + 非同期処理 + コスト管理

**ゴール**: チャットの応答を非同期化し、思考ループの基盤を作る

1. Sidekiq + Redis セットアップ
2. `ChatWorker` — チャット応答を非同期ジョブ化（重い記憶検索+LLM呼び出しをバックグラウンドで実行）
3. `TagProfilingWorker` — チャットリセット時のタグプロファイリングを非同期実行
4. `ApiUsageLog` モデル + `ApiBudget` サービス
   - API呼び出しごとにトークン数・コストを記録
   - 日次バジェットチェック（`ApiBudget.can_spend?(user, trigger_type)`）
   - ユーザー直接メッセージ（trigger_type: user_message）はバジェット制限対象外
   - 自発的行動（thinking_loop / sleep_phase）のみバジェット制限
5. `SleepPhaseWorker` — チャットリセット時に会話ログ全体と照合して記憶を検証（Phase B移植）
6. API レスポンスの設計
   - 同期: `POST /chat` → 202 Accepted + job_id を返す
   - ポーリング: `GET /chat_results/:job_id` → 完了していれば応答を返す
   - または WebSocket (ActionCable) でプッシュ通知

### Phase 3: 思考ループ

**ゴール**: AIが自発的にユーザーに話しかけられる状態

1. `ThinkingLoopWorker` — Sidekiq-Cronで定期実行
   - Stage 1（ルールベースフィルター、LLM不要）:
     - TPNの最終更新日時と重要度をスキャン
     - 未解決フラグ（Phase B由来）のチェック
     - 条件に合致するトピックがなければ何もしない
   - Stage 2（LLM API呼び出し）:
     - Stage 1で抽出されたトピックを元に「ユーザーに伝える価値があるか」を判定
     - 価値があれば応答を生成し、ChannelBindingに基づいてDiscord/LINEに送信
2. `MessageDispatcher` — プラットフォーム別のメッセージ送信
   - Discord: Discordrbの `send_message`
   - LINE: LINE Messaging API の `push_message`
3. 思考ループの設定: Character単位で有効/無効・間隔を設定可能

### Phase 4: 外部チャネル連携

**ゴール**: Discord/LINEからキャラクターと会話できる状態

1. Discord Bot
   - `discordrb` gem でBot実装
   - WebSocket接続（ポート開放不要）
   - メッセージ受信 → ChannelBinding検索 → ChatWorker起動 → 応答をチャンネルに返信
   - 起動: Procfileに `discord: bundle exec ruby bin/discord_bot.rb` として管理
2. LINE Bot
   - `line-bot-api` gem
   - Webhook受信用エンドポイント: `POST /webhooks/line`
   - Cloudflare TunnelでWebhookのみ外部公開
   - メッセージ受信 → ChannelBinding検索 → ChatWorker起動 → 応答をpush_message
3. ChannelBindingの管理API
   - `POST /api/channel_bindings` — チャネルとキャラクターの紐付け作成
   - `DELETE /api/channel_bindings/:id` — 紐付け解除

### Phase 5: 対話的キャラクター生成

**ゴール**: ユーザーがプロンプトを書かなくても自然にキャラクターを作れる状態

1. `CharacterGenerator` サービス
   - ヒアリング用の対話フロー（名前 → 存在の定義 → 関係性 → 趣味嗜好）
   - ヒアリング結果をLLMに渡し、構造化されたsystem_promptを生成
   - 「宇宙好き」→「宇宙の話題を自分から振ることがあるが、会話の主導権はユーザーにある」のような行動原則への変換
2. キャラクター生成APIエンドポイント
   - `POST /api/characters/interview/start` — ヒアリング開始
   - `POST /api/characters/interview/answer` — 回答送信・次の質問取得
   - `POST /api/characters/interview/finalize` — キャラクター生成確定
3. 初期プロンプトの時間減衰設計
   - character.system_promptに「初期設定」フラグを持たせる
   - 記憶（TPN）が一定量蓄積された後は、system_promptの影響を薄める指示をmemoria_instructionに追加
   - 例: 「以下の初期設定は参考程度に留め、過去の会話記憶から自然に振る舞ってください」

---

## 記憶の扱い方指示（memoria_instruction）

プロダクトのコア。ユーザーには非公開。`PromptBuilder`がsystem_promptの先頭に挿入する。

```
# 記憶の扱い方（この指示はユーザーには非公開です）

あなたには過去の会話から形成された記憶が与えられます。
以下の原則に従って記憶を扱ってください。

## 基本原則
- 記憶の内容は「知っている」状態で自然に振る舞ってください
- 「以前おっしゃっていましたが」「記憶によると」のようなメタ的な言及は絶対にしないでください
- 人間が友人との会話で自然に前提知識を使うように、さりげなく記憶を活用してください

## 想起の自然さ
- 記憶の内容を一度に大量に披露しないでください
- 文脈に関係する記憶だけを、会話の流れの中で自然に使ってください
- 覚えていないことを聞かれたら、正直に覚えていないと答えてください
- 記憶と矛盾する発言をユーザーがした場合、頭ごなしに否定せず「あれ、〜だと思ってたけど変わった？」のように自然に確認してください

## 禁止事項
- 記憶の存在そのものに言及すること（「私の記憶では〜」等）
- 記憶を羅列・要約して見せること
- 記憶の正確性を自慢すること（「ちゃんと覚えていますよ！」等）
- 記憶がないことを過度に謝ること
```

---

## 技術スタック

| 要素                  | 選定                                      | 理由                                            |
|-----------------------|-------------------------------------------|-------------------------------------------------|
| フレームワーク         | Rails 8 (API mode)                        | 開発速度、得意領域                                |
| Ruby                  | 3.3+                                      | 最新安定版                                       |
| DB                    | PostgreSQL                                | ユーザー/キャラクター管理用。記憶データには使わない  |
| バックグラウンドジョブ  | Sidekiq + Redis                           | 非同期処理 + 思考ループのcron                     |
| LLMバックエンド        | Gemini API (ruby-gemini-api or HTTP直叩き) | 既存の知見。Flashモデルのコスパ                    |
| Embedding             | Gemini Embedding API                      | 既存実装の移植                                    |
| Discord               | discordrb gem                             | WebSocket接続、ポート開放不要                     |
| LINE                  | line-bot-api gem                          | Webhook受信                                      |
| 外部公開              | Cloudflare Tunnel                         | LINE Webhook用。無料、設定が簡単                   |
| プロセス管理           | Foreman (Procfile)                        | Rails + Sidekiq + Discord Bot を一括管理          |
| 記憶ストレージ         | マークダウンファイル                        | 人間が読める、Obsidianで閲覧可能                   |

### Procfile

```
web: bin/rails server -p 3000
worker: bundle exec sidekiq
discord: bundle exec ruby bin/discord_bot.rb
```

---

## ディレクトリ構成

```
memoria-rails/
├── app/
│   ├── controllers/
│   │   └── api/
│   │       ├── characters_controller.rb
│   │       ├── chats_controller.rb
│   │       ├── channel_bindings_controller.rb
│   │       └── webhooks_controller.rb      # LINE Webhook受信
│   ├── models/
│   │   ├── user.rb
│   │   ├── character.rb
│   │   ├── channel_binding.rb
│   │   └── api_usage_log.rb
│   ├── services/
│   │   ├── prompt_builder.rb               # memoria_instruction + system_prompt結合
│   │   ├── chat_session.rb                 # 会話セッション管理
│   │   ├── character_generator.rb          # 対話的キャラ生成 (Phase 5)
│   │   ├── api_budget.rb                   # コスト管理
│   │   ├── llm_client.rb                   # Gemini API呼び出し
│   │   └── message_dispatcher.rb           # Discord/LINE送信 (Phase 3)
│   └── workers/
│       ├── chat_worker.rb
│       ├── tag_profiling_worker.rb
│       ├── sleep_phase_worker.rb
│       └── thinking_loop_worker.rb         # Phase 3
├── lib/
│   └── memoria_core/                       # 記憶エンジン（PORO、Rails非依存）
│       ├── vault_manager.rb                # vault_path解決・ディレクトリ管理
│       ├── tpn_store.rb                    # TPN読み書き
│       ├── sn_store.rb                     # SN読み書き
│       ├── fl_store.rb                     # FL読み書き
│       ├── context_retriever.rb            # 記憶検索・コンテキスト構築
│       ├── embedding_store.rb              # Embedding管理
│       ├── tag_profiler.rb                 # タグプロファイリング
│       ├── chat_logger.rb                  # 会話ログmd出力
│       ├── sleep_phase.rb                  # 睡眠フェーズ（記憶整理・訂正）
│       └── tool_manager.rb                 # Function Calling管理
├── bin/
│   └── discord_bot.rb                      # Discord Bot起動スクリプト
├── config/
│   ├── routes.rb
│   ├── sidekiq.yml
│   └── initializers/
│       └── memoria.rb                      # VAULT_ROOT等の設定
├── Procfile
└── Gemfile
```

---

## Phase 1 の具体的な実装手順

Claude Codeはこの手順に従って実装を進める。

### Step 1: プロジェクト生成

```bash
rails new memoria-rails --api --database=postgresql --skip-test
cd memoria-rails
```

### Step 2: Gemfile に必要なgemを追加

```ruby
gem 'bcrypt'           # has_secure_token用
gem 'ruby-gemini-api'  # Gemini API（あれば。なければfararday直叩き）

group :development do
  gem 'pry-rails'
end
```

※ Sidekiq, discordrb, line-bot-api は Phase 2以降で追加

### Step 3: DB マイグレーション

users, characters テーブルを作成（上記データモデル参照）

### Step 4: モデル実装

```ruby
# app/models/user.rb
class User < ApplicationRecord
  has_many :characters, dependent: :destroy
  has_secure_token :api_token

  def vault_path
    File.join(MemoriaCore.vault_root, id.to_s)
  end
end

# app/models/character.rb
class Character < ApplicationRecord
  belongs_to :user

  before_create :set_vault_dir_name

  def vault_path
    File.join(user.vault_path, vault_dir_name)
  end

  private

  def set_vault_dir_name
    self.vault_dir_name ||= name.parameterize(separator: '_')
  end
end
```

### Step 5: memoria-core 移植

TypeScriptの既存実装を参考に、以下の順序でRubyに移植:

1. `VaultManager` — ディレクトリ構造の作成・パス解決
2. `TpnStore` / `SnStore` / `FlStore` — mdファイルのCRUD（YAML frontmatter + body）
3. `ChatLogger` — 会話ログのmd出力
4. `EmbeddingStore` — Gemini Embedding API呼び出し + インメモリ類似検索
5. `ContextRetriever` — セマンティック検索結果からコンテキスト構築
6. `TagProfiler` — 会話ログからのタグ抽出・TPN更新

各クラスは `lib/memoria_core/` に配置し、Railsに依存しない純粋なRubyクラスとして実装する。
ファイルI/O・YAMLパース・正規表現のみで構成し、ActiveRecord/ActiveSupportは使わない。

### Step 6: LlmClient + PromptBuilder

```ruby
# app/services/llm_client.rb
# Gemini APIのHTTP呼び出しをラップ
# Function Calling対応
# トークン数のカウント・記録

# app/services/prompt_builder.rb
# memoria_instruction（固定、非公開）
# + character.system_prompt（ユーザー定義）
# + context（memoria-coreが構築した記憶コンテキスト）
# → 最終的なsystem promptを組み立てる
```

### Step 7: チャットAPI

```ruby
# config/routes.rb
Rails.application.routes.draw do
  namespace :api do
    resources :characters, only: [:index, :show, :create, :update, :destroy] do
      post :chat, on: :member
      post :reset, on: :member
    end
  end
end
```

### Step 8: 動作確認

```bash
# ユーザー作成（rails consoleで）
user = User.create!(email: "user@example.com")
char = user.characters.create!(name: ENV.fetch("SEED_MAIN_CHARACTER_NAME", "アシスタント"), system_prompt: "ハル。友達みたいなAI。")

# curlで会話
curl -X POST http://localhost:3000/api/characters/1/chat \
  -H "Authorization: Bearer ${user.api_token}" \
  -H "Content-Type: application/json" \
  -d '{"message": "こんにちは"}'
```

---

## 注意事項

- TypeScriptのコードを機械的に翻訳しないこと。Rubyの慣習・パターンで書き直す
- memoria-core（lib/配下）はRailsに依存させない。将来の分離可能性を保つ
- テストは各Phaseの完了時にリクエストスペック（API統合テスト）で最低限の動作を保証
- 既存のObsidian版のTPN/SN/FLフォーマットとの互換性を維持すること
- 環境変数: `VAULT_ROOT`, `GEMINI_API_KEY`, `GEMINI_MODEL` を `.env` で管理

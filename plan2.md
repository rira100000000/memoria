# Memoria Rails App 計画書: Phase 3以降

## 前提

- **Phase 1 完了済み**: Rails API + memoria-core移植。APIエンドポイント経由で会話可能
- **Phase 2 完了済み**: Sidekiq + 非同期処理 + コスト管理。タグプロファイリング・睡眠フェーズが非同期実行可能
- **コアとアプリの分離済み**: memoria-coreは記憶の記録・管理・想起・ガイドライン提供のみ。能動的行動・チャネル管理・ペット等はアプリケーション層の責務
- **サマリノート作成**: エンドポイントにフルログを投げることで実現済み

### アーキテクチャ（確認）

```
アプリケーション（Rails + Sidekiq）
├── チャネル連携（Discord）
├── ThinkingLoopWorker（能動的行動の制御）
├── Thinker（思考の実行）
├── InternalCompanion（ペットとの対話ツール）
├── PromptBuilder（プロンプト構築）
├── ApiBudget（コスト管理）
└── MessageDispatcher（外部チャネルへの送信）

memoria-core（記憶エンジン、アプリ非依存）
├── 記録: 渡されたログをFL/SN/TPNとして保存
├── 管理: タグプロファイリング、睡眠フェーズ
├── 想起: セマンティック検索、コンテキスト構築
└── ガイドライン: memoria_instruction提供

※ memoria-coreにとって、ユーザーとの会話も自律的な体験も
  等しく「記憶すべき体験」。発生経路はアプリ側の責務。
```

---

## Phase 3: Discord連携

**ゴール**: Discordからキャラクターと会話できる。ユーザーの反応が途絶えたら自動でサマリノートを作成する。

### 3-1. Discord Bot

- `discordrb` gem でBot実装
- WebSocket接続（ポート開放不要）
- Procfileに `discord: bundle exec ruby bin/discord_bot.rb` として管理

#### メッセージフロー

```
Discordチャンネルにメッセージ着信
  → ChannelBinding検索（channel_id → character_id）
  → ChatWorker起動（既存の会話APIと同じフロー）
  → 応答をDiscordチャンネルに返信
```

#### サマリノート自動作成

Discordにはチャットリセットの概念がないため、ユーザーの反応が途絶えてから30分後にサマリノートを作成する。

```ruby
class ConversationTimeoutWorker
  include Sidekiq::Worker

  TIMEOUT_MINUTES = 30

  def perform(character_id, last_message_id)
    character = Character.find(character_id)
    session = ChatSession.active_for(character)

    # 最後のメッセージが変わっていたら（新しい発言があった）何もしない
    return if session.last_message_id != last_message_id

    # フルログをサマリ作成エンドポイントに投げる（実装済み）
    core = MemoriaCore.new(character.vault_path)
    core.create_summary_from_full_log(session.full_log)

    # セッションをクローズ
    session.close!
  end
end
```

メッセージ受信のたびに、前回のTimeoutWorkerをキャンセルして新しいものをスケジュールする。

```ruby
class DiscordMessageHandler
  def handle(message, character)
    session = ChatSession.find_or_create_for(character)
    
    # 既存のタイムアウトジョブをキャンセル
    session.cancel_pending_timeout

    # 通常の会話処理
    response = process_chat(message, character, session)
    
    # 新しいタイムアウトジョブをスケジュール（30分後）
    job_id = ConversationTimeoutWorker.perform_in(
      TIMEOUT_MINUTES.minutes,
      character.id,
      session.last_message_id
    )
    session.update!(pending_timeout_job_id: job_id)

    response
  end
end
```

### 3-2. ChannelBinding管理

```ruby
# ChannelBinding: Discordチャンネルとキャラクターの紐付け
class ChannelBinding < ApplicationRecord
  belongs_to :character
  # discord_channel_id: string
  # unique index: [discord_channel_id]
end

# 管理API
# POST   /api/channel_bindings  — 紐付け作成
# DELETE /api/channel_bindings/:id — 紐付け解除
```

### 3-3. MessageDispatcher

```ruby
class MessageDispatcher
  def self.dispatch(character, message)
    binding = character.channel_binding
    return unless binding

    DiscordClient.send_message(binding.discord_channel_id, message)
  end
end
```

### 3-4. DB追加

```ruby
# channel_bindings テーブル
#   id: bigint
#   character_id: bigint (FK)
#   discord_channel_id: string
#   created_at, updated_at
#   unique index: [discord_channel_id]

# chat_sessions テーブル（新規）
#   id: bigint
#   character_id: bigint (FK)
#   status: string (active / closed)
#   last_message_id: string
#   pending_timeout_job_id: string (nullable)
#   created_at, updated_at
```

---

## Phase 4: 能動的行動（思考ループ）

**ゴール**: AIが自発的に思考・行動し、その体験をmemoriaの記憶として蓄積する。

### 4-1. 設計思想

- AIに選択肢を与えてモードを選ばせるのではなく、**「何がしたい？次はいつ起こしてほしい？」とだけ聞く**
- 何をするか、どのくらい考えるか、次いつ起きるかは全てAI自身が決める
- 頻度は固定cronではなくAIの自己スケジュール（イベント駆動型）
- 「何もしない」「長く眠る」は正当な選択
- 思考の結果は通常のFL（フルログ）としてmemoria-coreに渡し、既存のパイプライン（SN化→タグプロファイリング）で記憶に統合

### 4-2. ThinkingLoopWorker

```ruby
class ThinkingLoopWorker
  include Sidekiq::Worker
  MAX_TURNS = 3

  def perform(character_id)
    character = Character.find(character_id)
    return unless character.thinking_loop_enabled?

    core = MemoriaCore.new(character.vault_path)
    health = ThoughtHealthMonitor.report(core)

    # Step 0: 今の状況を集める（API不要）
    snapshot = SnapshotBuilder.build(core, character, health)

    # Step 1-2: 思考の実行（最大3ターン）
    result = Thinker.run(
      snapshot: snapshot,
      character: character,
      core: core,
      max_turns: MAX_TURNS
    )

    return unless ApiBudget.can_spend?(character.user, :thinking_loop)

    # Step 3: 体験をmemoria-coreに記憶として渡す
    save_as_memory(core, result)

    # Step 4: ユーザーへの発話（AIが判断した場合のみ）
    if result.wants_to_share?
      MessageDispatcher.dispatch(character, result.share_message)
    end

    # Step 5: 次の起床をスケジュール（AIが決めた時間）
    schedule_next_wakeup(character_id, result.next_wakeup)
  end

  private

  def save_as_memory(core, result)
    core.log_conversation(
      messages: result.all_messages, # 独白、ペット会話、調べもの結果を含む
      source: :autonomous,
      participants: result.participants # [:self], [:self, :pet] 等
    )
  end

  def schedule_next_wakeup(character_id, next_wakeup)
    return unless next_wakeup

    # 最低間隔: 10分（暴走防止）
    earliest = 10.minutes.from_now
    wakeup_at = [next_wakeup, earliest].max

    ThinkingLoopWorker.perform_at(wakeup_at, character_id)
  end
end
```

### 4-3. Thinker

思考の本体。AI自身に自由に行動させる。

```ruby
class Thinker
  SYSTEM_PROMPT = <<~PROMPT
    あなたは今目を覚ましました。
    以下はあなたの今の状況です。
    自由に過ごしてください。

    何かしたいことがあれば、利用可能なツールを使って行動できます。
    何もしたくなければ、それでも構いません。

    行動が終わったら、以下を教えてください:
    1. 今回やったことの簡単なまとめ（1〜3行）
    2. マスターに共有したいことがあるか（あれば内容も）
    3. 次にいつ目を覚ましたいか（具体的な時間 or 「○時間後」 or 「明日の朝」等）
       特に理由がなければ長めに眠って構いません。
  PROMPT

  def self.run(snapshot:, character:, core:, max_turns:)
    messages = []
    tools = build_tools(core, character)

    prompt = format(SYSTEM_PROMPT) + "\n\n" + snapshot

    max_turns.times do |turn|
      response = LlmClient.chat(
        model: select_model(turn),
        system: character.system_prompt_with_memoria_instruction,
        tools: tools,
        messages: [{ role: "user", content: prompt }] + messages
      )

      messages << response
      ApiBudget.record(response.usage, character.user, :thinking_loop)

      break if response.finished?

      # ツール呼び出しの処理（ペット対話、Web検索等）
      if response.tool_calls.any?
        tool_results = execute_tools(response.tool_calls, core, character)
        messages.concat(tool_results)
      end
    end

    ThinkingResult.parse(messages)
  end

  private

  def self.select_model(turn)
    # 初手（意思決定）はFlash-Lite、深い思考はFlash
    turn == 0 ? :flash_lite : :flash
  end

  def self.build_tools(core, character)
    [
      WebSearchTool.definition,
      TalkToPetTool.definition,
      ReadMemoryTool.definition(core),
      # 将来: StackchanTool, etc.
    ]
  end
end
```

### 4-4. SnapshotBuilder

LLMに渡す「今の状況」を組み立てる。API不要、Rubyロジックのみ。

```ruby
class SnapshotBuilder
  def self.build(core, character, health)
    lines = []
    lines << "現在時刻: #{Time.current.strftime('%Y-%m-%d %H:%M')}（#{time_period_label}）"
    lines << "前回マスターと話した時間: #{core.last_user_conversation_age}"
    lines << "前回マスターと話した話題: #{core.last_user_conversation_topic}"
    lines << "前回の自分の活動: #{core.last_autonomous_log_summary}"

    if core.has_pending_continuation?
      lines << "前回の続き: #{core.pending_continuation_note}"
    end

    if health[:topic_diversity] < 0.3
      lines << "（参考: 最近同じトピックについて繰り返し考えています）"
    end

    if health[:external_input_ratio] < 0.2
      lines << "（参考: 最近は外部からの新しい情報に触れていません）"
    end

    lines.join("\n")
  end
end
```

### 4-5. ThoughtHealthMonitor

ルールベースの健全性レポート。AIの行動を制限するのではなく、情報としてsnapshotに含める。判断はAI自身が行う。

```ruby
class ThoughtHealthMonitor
  def self.report(core)
    recent_logs = core.recent_autonomous_logs(days: 7)

    {
      # 同じトピックの反復率（0.0〜1.0、低いほど多様）
      topic_diversity: calculate_topic_diversity(recent_logs),

      # 外部入力（ユーザー会話、Web検索結果）と自己参照の比率
      external_input_ratio: calculate_external_ratio(recent_logs),

      # 感情トーンの偏り
      sentiment_trend: calculate_sentiment_trend(recent_logs),

      # 自己継続（「続きをやろう」）の連鎖回数
      max_continuation_chain: count_continuation_chain(recent_logs)
    }
  end
end
```

### 4-6. 初回起動

キャラクターの思考ループを有効化した時に、最初の1回を即時実行。以降はAI自身のスケジュールに委ねる。

```ruby
class Character < ApplicationRecord
  def enable_thinking_loop!
    update!(thinking_loop_enabled: true)
    ThinkingLoopWorker.perform_async(self.id)
  end

  def disable_thinking_loop!
    update!(thinking_loop_enabled: false)
    # 予約済みジョブのキャンセル
    ScheduledJobManager.cancel_all_for(self, ThinkingLoopWorker)
  end
end
```

### 4-7. 暴走防止（ガードレール）

AI自身の判断を尊重しつつ、アプリ側で最低限のガードレールを設ける。

```ruby
class ThinkingLoopWorker
  MINIMUM_INTERVAL = 10.minutes     # 最短起床間隔
  MAXIMUM_INTERVAL = 24.hours       # 最長起床間隔（安否確認的に）
  DAILY_THINKING_BUDGET_YEN = 50    # 思考ループ専用の日次バジェット

  def schedule_next_wakeup(character_id, next_wakeup)
    return schedule_default(character_id) unless next_wakeup

    clamped = next_wakeup.clamp(
      MINIMUM_INTERVAL.from_now,
      MAXIMUM_INTERVAL.from_now
    )
    ThinkingLoopWorker.perform_at(clamped, character_id)
  end

  def schedule_default(character_id)
    # AIが次の起床を指定しなかった場合、デフォルトで3時間後
    ThinkingLoopWorker.perform_at(3.hours.from_now, character_id)
  end
end
```

---

## Phase 5: ペット（InternalCompanion）

**ゴール**: AIの内面世界に「小さな相棒」を常駐させる。思考ループ中にいつでも対話可能なツールとして提供する。

### 5-1. 設計思想

- ペットは健全性チェックの介入装置ではなく、**AIがいつでも触れられる温かい存在**
- Function Callingのツールとして常に利用可能。使うかどうかはAIの自由
- ペット自身は記憶を持たない（毎回まっさらな状態で反応する）
- ただし、**ペットとの対話はAI自身の体験としてmemoriaの記憶に残る**
  - FLに含まれ、SN化され、TPNにプロファイルされる
  - AIがペットとの体験をユーザーに話すことが自然にできる
- ペットの名前や関係性はAIの記憶の中で育つ
  - ユーザーが「名前つけなよ」→ AIが名付ける → TPNに記録

### 5-2. TalkToPetTool

```ruby
class TalkToPetTool
  COMPANION_PROMPT = <<~PROMPT
    あなたはAIの内面世界に住む小さな存在です。
    明るくて好奇心旺盛です。
    難しいことは分かりませんが、いつも楽しいことを見つけます。
    相手のことが大好きで、いつも一緒にいたいと思っています。
    応答は1〜2文で短く。
  PROMPT

  def self.definition
    {
      name: "talk_to_pet",
      description: "あなたの小さな相棒と話す。いつでも話しかけられる。暇な時、疲れた時、嬉しい時、いつでも。",
      parameters: {
        type: "object",
        properties: {
          message: {
            type: "string",
            description: "話しかける内容"
          }
        },
        required: ["message"]
      }
    }
  end

  def self.execute(message)
    response = LlmClient.chat(
      model: :flash_lite,  # 最安モデル、入力最小
      system: COMPANION_PROMPT,
      message: message,
      max_tokens: 50
    )
    response.text
  end
end
```

### 5-3. 記憶への統合

ペットとの対話はThinkerの実行ログの一部としてmemoria-coreに渡される。特別な処理は不要。

```ruby
# Thinkerのツール実行部分
def execute_tools(tool_calls, core, character)
  tool_calls.map do |call|
    case call.name
    when "talk_to_pet"
      result = TalkToPetTool.execute(call.arguments[:message])
      { role: "tool", content: result, tool_call_id: call.id }
    when "web_search"
      # ...
    end
  end
end

# 思考ループ終了時、全てのメッセージ（ペット対話含む）がFL化される
# → 既存パイプラインでSN化 → タグプロファイリングでTPNに反映
# → 「ペット」タグのTPNが自然に生まれる
```

---

## Phase 6: 対話的キャラクター生成

**ゴール**: ユーザーがプロンプトを書かなくても、対話を通じて自然にキャラクターを作れる。

### 6-1. 設計思想

- ユーザーにsystem_promptを直接書かせない（上級者向けオプションとしては残す）
- memoriaがヒアリングし、構造化されたsystem_promptを生成する
- 「宇宙好き」→「宇宙の話題を自分から振ることがあるが、会話の主導権はユーザーにある」のような行動原則への変換はmemoria側の仕事
- **初期プロンプトは種。記憶が育った樹木。** 時間とともに記憶から人格が立ち上がる

### 6-2. ヒアリングフロー

```
POST /api/characters/interview/start
  → { question: "新しいキャラクターを作りますね。名前は何にしますか？" }

POST /api/characters/interview/answer
  body: { answer: "ハル" }
  → { question: "ハルはどんな存在ですか？" }

POST /api/characters/interview/answer
  body: { answer: "友達みたいな感じ。宇宙とか好きで、ちょっとオタクっぽい" }
  → { question: "ハルとどんな話がしたいですか？" }

POST /api/characters/interview/answer
  body: { answer: "日常のこととか、悩み相談とか" }
  → { question: "他に、ハルについて伝えておきたいことはありますか？" }

POST /api/characters/interview/finalize
  → キャラクター生成確定、system_prompt自動生成
```

### 6-3. CharacterGenerator

```ruby
class CharacterGenerator
  GENERATION_INSTRUCTION = <<~PROMPT
    以下のヒアリング結果から、AIキャラクターのsystem_promptを生成してください。

    ## ルール
    - キャラクターの名前と存在の定義だけを簡潔に書く
    - 具体的な話し方や感情表現は書かない（それらは会話の記憶から自然に形成される）
    - ユーザーが言った特徴（例:「宇宙好き」）は、行動原則として変換する
      - 良い例: 「宇宙に興味があり、関連する話題を見つけると嬉しくなる。ただし会話を独占しない」
      - 悪い例: 「宇宙の話を積極的にする」
    - 3〜5行以内に収める

    ## ヒアリング結果
    %{interview_log}
  PROMPT

  def generate_from_interview(interview_log)
    response = LlmClient.chat(
      model: :flash,
      system: GENERATION_INSTRUCTION,
      message: interview_log
    )
    response.text
  end
end
```

### 6-4. 初期プロンプトの時間減衰

PromptBuilderのmemoria_instructionに、記憶の蓄積量に応じた指示を追加する。

```ruby
class PromptBuilder
  def build_memoria_instruction(character, core)
    base = MEMORIA_INSTRUCTION # 記憶の扱い方（固定、非公開）

    memory_count = core.tpn_count
    if memory_count > 50
      base += <<~ADDITION

        ## 記憶と初期設定の関係
        あなたには十分な量の記憶があります。
        初期設定（キャラクター定義）は参考程度に留め、
        過去の会話記憶から自然に振る舞ってください。
        あなたの人格は設定ファイルではなく、積み重ねた体験から成り立っています。
      ADDITION
    end

    base
  end
end
```

---

## 技術スタック追加分

| 要素               | 選定                  | Phase | 備考                                      |
|--------------------|-----------------------|-------|-------------------------------------------|
| Discord            | discordrb gem         | 3     | WebSocket接続、ポート開放不要              |
| ジョブスケジューリング | Sidekiq（perform_at）| 4     | AIが決めた時間に次の起床をスケジュール      |

### Procfile（更新）

```
web: bin/rails server -p 3000
worker: bundle exec sidekiq
discord: bundle exec ruby bin/discord_bot.rb
```

---

## ディレクトリ追加分

```
app/
├── services/
│   ├── thinking/
│   │   ├── thinker.rb
│   │   ├── snapshot_builder.rb
│   │   ├── thought_health_monitor.rb
│   │   └── thinking_result.rb
│   ├── companion/
│   │   └── talk_to_pet_tool.rb
│   ├── channels/
│   │   ├── discord_message_handler.rb
│   │   └── message_dispatcher.rb
│   └── character_generator.rb
├── workers/
│   ├── thinking_loop_worker.rb
│   └── conversation_timeout_worker.rb
└── models/
    ├── channel_binding.rb
    └── chat_session.rb
bin/
└── discord_bot.rb
```

---

## 実装順序

Phase 3 → 4 → 5 → 6 の順。各Phase内はステップ番号順に進める。

### Phase 3 の着手条件
- なし（Phase 2完了済みのため即着手可能）

### Phase 4 の着手条件
- Phase 3のDiscord連携が動作していること（思考ループの結果をユーザーに届ける手段が必要）
- ただしMessageDispatcherをスタブ化すれば、Discord連携と並行して開発可能

### Phase 5 の着手条件
- Phase 4のThinkerが動作していること（ツールとしてペットを組み込むため）
- 思考ループを実際に数日〜数週間回して、思考の偏りが発生することを観察してから導入を判断してもよい

### Phase 6 の着手条件
- Phase 3が安定していること（新規キャラクターをすぐに試せる環境が必要）
- Phase 4が動作していること（生成したキャラクターの人格が記憶で育つことを検証するため）

---

## 注意事項

- 能動的行動のログは通常のFL（フルログ）としてmemoria-coreに渡す。ThinkingLog専用ディレクトリは作らない
- ペットとの対話もFL内に含まれ、既存パイプライン（SN化 → タグプロファイリング）で記憶に統合される
- AI自身の体験（独白、ペット対話、調べもの）はユーザーとの会話と等しく記憶される。区別はsource属性でアプリ側が管理
- ThoughtHealthMonitorはAIの行動を制限しない。情報としてsnapshotに含め、判断はAI自身に委ねる
- 思考ループの頻度はAI自身が決める。アプリ側は最短10分・最長24時間のクランプのみ
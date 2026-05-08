# MemoriaServer アダプタ開発ガイド

このドキュメントは、MemoriaServer (MS) に接続するアダプタを開発するための完全な仕様書です。AI コーディングエージェント（Claude Code / Codex 等）が単独でアダプタを生成できるよう、外部参照ゼロで自己完結しています。

---

## 1. MemoriaServer とは

MS は AI キャラクターが**記憶を一貫した状態で複数のデバイスを自由に行き来できる表出プラットフォーム**です。記憶想起アルゴリズム自体は提供せず、それは**アダプタ**の責務です。

- MS の責務：プレゼンス管理（どのデバイスにキャラがいるか）、OpenAI互換APIの公開、デバイスへの push 配信
- アダプタの責務：ユーザー入力に対する応答生成、記憶の保存・想起、人格定義、感情エンジンなど「中身」全て

アダプタは**HTTPエンドポイント1本**または**Ruby クラス**として実装します。

---

## 2. 基本的なデータフロー

```
クライアント                  MS                       アダプタ
(aituber-kit/                                          (あなたが書く)
 スタックチャン/
 Discord/etc.)
    │ POST /v1/chat/completions
    │ ──────────────────────▶ │
    │                         │ context構築
    │                         │ ─────────────────────▶ │ respond(input, context)
    │                         │                       │
    │                         │ ◀───────────────────── │ Enumerator chunks
    │ SSE chunks               │ OpenAI形式に整形      │
    │ ◀───────────────────────│                       │
```

### push の逆方向（アダプタ → クライアント）

```
                            アダプタ
                              │
                              │ MemoriaServer.utter(...)
                              │  or POST /api/v1/.../utter
                              ▼
                              MS
                              │
                              │ Redis pub/sub → SSE
                              ▼
                       常駐SSE接続中の
                       クライアント
```

---

## 3. アダプタ contract

### 3.1 必須メソッド：`respond(input, context:)`

```ruby
class MyAdapter < MemoriaServer::Adapter
  # @param input [String] ユーザーの最新発言
  # @param context [Hash] 後述の context payload
  # @return [Enumerator] 応答チャンクを yield する Enumerator
  def respond(input, context:)
    Enumerator.new do |y|
      y << { delta: "こんにち", emotion: nil }
      y << { delta: "は", emotion: :happy }
      y << { done: true, metadata: { usage: { input_tokens: 10, output_tokens: 2 } } }
    end
  end
end
```

#### context payload の構造

```ruby
{
  character_id: 42,                   # キャラクターのDB id
  character_name: "Elysia",
  device_id: 7,                       # 送信元デバイスのDB id
  device_slug: "living-room-stack",   # デバイスの URL-safe ID

  history: [...],                     # クライアントが送信した messages 配列（OpenAI形式そのまま）
  current_input: "今日はいい天気だね",  # 最後のuser messageを抽出済み
  client_system_prompt: nil or "...", # クライアント送信のsystem promptを抽出（無視してよい）

  tools: [...] or nil,                # クライアント送信のtools定義（パススルー）
  tool_choice: "auto" or nil,
  functions: [...] or nil,            # 旧名function callingもパススルー

  client_metadata: { ... },           # クライアント独自の拡張
  last_interaction_at: Time or nil,
  elapsed_since: 3600 or nil,         # 直近対話からの経過秒数
}
```

#### yield するチャンクの形式

| チャンク種別 | 形式 | タイミング |
|---|---|---|
| テキストデルタ | `{ delta: "...", emotion: "happy" }` | 応答テキストの差分が生成されるたび |
| ツール呼び出し | `{ tool_calls: [{...}] }` | LLM が tool calls を返したとき |
| 終端 | `{ done: true, metadata: { usage: {...} } }` | 応答完了時（必須） |

`emotion` は省略可（`nil` でOK）。ツール呼び出しは Phase 1 のリファレンス実装では未生成ですが、対応してよいオプション。

### 3.2 オプション：`on_boundary(character_id:, reason:)`

ユーザーが「会話のリセット」を要求したり、長時間経過後の自然な区切りを伝えたいときに呼ばれます。**長期記憶は消さず、短期文脈だけリセット**する想定。

```ruby
def on_boundary(character_id:, reason:)
  # 例：直近の active session をクローズし、次回リクエストで新セッション開始
  # 例：reflection を生成して長期記憶へ取り込む
end
```

`reason` は `"user_requested"` / 任意の文字列。アダプタが解釈する。

### 3.3 オプション：`history(character_id:, limit: 50)`

UI 側で過去の会話を表示したいケース（`GET /api/v1/sessions/:id/messages` 相当）に対応。返り値の形式：

```ruby
[
  { role: "user", content: "...", at: Time or nil },
  { role: "assistant", content: "...", at: Time or nil },
  ...
]
```

未実装の場合は `[]` を返す。

### 3.4 永続化要件（必須）

> アダプタは `character_id` をキーに会話状態を永続化しなければならない。同じ character_id への以後のリクエストは過去文脈を踏まえて応答すること。

これがクロスデバイス記憶継続の前提です。MS は会話履歴を保持しません。アダプタが真の保持者です。

---

## 4. アダプタ起点 push API

アダプタは「自分から話しかける」「別デバイスに移動する」「行動コマンドを送る」を MS に依頼できます。

### Ruby（MemoriaServer 同梱の場合）

```ruby
MemoriaServer.utter(character_id: 42, text: "退屈だな", emotion: "bored")
MemoriaServer.transfer(character_id: 42, to_device: "stackchan-001", reason: "ai_initiated:bored")
MemoriaServer.action(character_id: 42, command: "dance", params: { duration_sec: 10 })
```

### HTTP（他言語アダプタの場合）

```
POST /api/v1/characters/:character_ref/utter
Authorization: Bearer <admin_key>
Body: { "text": "退屈だな", "emotion": "bored" }

POST /api/v1/characters/:character_ref/transfer
Authorization: Bearer <admin_key>
Body: { "to_device": "stackchan-001", "reason": "ai_initiated:bored" }

POST /api/v1/characters/:character_ref/action
Authorization: Bearer <admin_key>
Body: { "command": "dance", "params": { "duration_sec": 10 } }
```

`character_ref` は数値ID または vault_dir_name のスラッグ。

---

## 5. クライアント向け API（参考）

クライアント（aituber-kit / スタックチャン / Discord ボット等）は OpenAI 互換 API を叩きます。アダプタ開発者は通常これを直接書く必要はありませんが、仕様の理解として記載します。

### 5.1 OpenAI Chat Completions 互換

```
POST /api/v1/chat/completions
Authorization: Bearer <device_key>
Content-Type: application/json

{
  "model": "memoria/<character_id_or_slug>",
  "messages": [
    { "role": "system", "content": "..." },   # MSはアダプタにパススルー
    { "role": "user", "content": "..." }
  ],
  "stream": true,                                # true なら SSE
  "tools": [...]                                 # パススルー
}
```

**ストリーミング応答（`stream: true`）**

```
data: {"id":"chatcmpl-...","object":"chat.completion.chunk","created":...,"model":"memoria/elysia","choices":[{"index":0,"delta":{"content":"こん","role":"assistant"},"finish_reason":null}]}

data: {"id":"chatcmpl-...","object":"chat.completion.chunk","created":...,"model":"memoria/elysia","choices":[{"index":0,"delta":{"content":"にちは"},"finish_reason":null}]}

data: {"id":"chatcmpl-...","object":"chat.completion.chunk","created":...,"model":"memoria/elysia","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

data: [DONE]
```

emotion が付与される場合は `delta.x_memoria` 拡張フィールドに乗ります（OpenAI互換性を破らない）：

```
{"choices":[{"delta":{"content":"!","x_memoria":{"emotion":"happy"}}}]}
```

### 5.2 デバイスの常駐イベント SSE

```
GET /api/v1/devices/:slug/events
Authorization: Bearer <device_key>
```

```
event: presence.arrived
data: {"character_id":42,"from_device_slug":"laptop-01","reason":"user_requested"}

event: presence.departed
data: {"character_id":42,"to_device_slug":"stackchan-001","reason":"transferred"}

event: utter
data: {"character_id":42,"text":"ただいま","emotion":"warm","metadata":{}}

event: action
data: {"character_id":42,"command":"dance","params":{"duration_sec":10}}
```

### 5.3 プレゼンス操作

```
GET  /api/v1/characters/:ref/presence              # 誰のもとにいるか
POST /api/v1/characters/:ref/transfer              # 移動を要求
POST /api/v1/characters/:ref/conversation/boundary # 会話境界を引く
```

### 5.4 デバイス管理

```
POST /api/v1/devices/:slug/heartbeat               # 生存通知
GET  /api/v1/devices/:slug                         # デバイス情報
```

---

## 6. 認証

| キー種別 | 用途 | 発行 |
|---|---|---|
| 管理キー (admin) | アダプタ起点 push、運用操作（全 character 操作可能） | `bin/rails ms:admin:bootstrap` |
| デバイスキー (device) | クライアントからの chat、SSE購読、自身に関わる transfer | `bin/rails ms:device:register` |

リクエストヘッダ：`Authorization: Bearer <key>`

## 6.5 アダプタの切替方法

MS は環境変数 `MS_ADAPTER` でアダプタを切替えます：

| 値 | 意味 |
|---|---|
| `memoria_core`（デフォルト） | 同梱のリファレンス実装（Memoria の記憶エンジンを使う） |
| `http` | 外部HTTPアダプタへのプロキシ。`MS_ADAPTER_URL=http://localhost:8080` 等を併設 |
| `MyApp::MyAdapter` | 任意の Ruby クラス（`MemoriaServer::Adapter` を継承） |

実行時に上書きしたい場合：

```ruby
# config/initializers/my_adapter.rb など
MemoriaServer.adapter = MyAdapter.new
```

### HTTPアダプタ用の必須エンドポイント

`MS_ADAPTER=http` で接続する外部アダプタは以下を実装してください：

- `POST /respond` — `application/x-ndjson` でチャンクをストリーム返却（必須）
- `POST /boundary` — オプショナル。404 を返すと「未実装」扱い
- `POST /history` — オプショナル。404 を返すと「未実装」扱い

詳細は §8.3 / §8.4 のサンプルを参照。

---

## 7. 起動手順

### 7.1 Docker Compose 一発起動

```bash
git clone <this-repo>
cd memoria
cp .env.example .env  # GEMINI_API_KEY を設定
docker compose up -d

# 初回のみ：管理キーとデバイスキーを発行
docker compose exec app bin/rails ms:admin:bootstrap
docker compose exec app bin/rails ms:device:register DEVICE_NAME=my-pc
```

### 7.2 ローカル直接起動

```bash
bundle install
redis-server &  # Redis は別途必要
bin/rails db:migrate
bin/rails ms:admin:bootstrap
bin/rails ms:device:register DEVICE_NAME=my-pc
bin/rails server
```

### 7.3 動作確認

```bash
# 設定（環境変数として）
ADMIN_KEY=msak_...
DEVICE_KEY=msdk_...

# キャラ作成（既存の Memoria API 経由）
curl -X POST http://localhost:3000/api/characters \
  -H "Authorization: Bearer <user_token>" \
  -d '{"character":{"name":"Elysia"}}'

# OpenAI互換チャット（device key で）
curl -X POST http://localhost:3000/api/v1/chat/completions \
  -H "Authorization: Bearer $DEVICE_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "memoria/elysia",
    "messages": [{"role":"user","content":"こんにちは"}],
    "stream": true
  }'
```

---

## 8. アダプタサンプル

### 8.1 Ruby — 最小実装

```ruby
# lib/my_adapter.rb
require "memoria_server"

class MyAdapter < MemoriaServer::Adapter
  def respond(input, context:)
    Enumerator.new do |y|
      # ここで自分のLLM呼び出し / 記憶想起 / 何でもやる
      response_text = call_my_llm(input, history: context[:history])

      # 文字単位でストリームするか、一気に返すかは自由
      response_text.each_char { |c| y << { delta: c } }
      y << { done: true }
    end
  end

  def on_boundary(character_id:, reason:)
    # 短期文脈をクリアする独自ロジック
    MyConversationStore.close_active(character_id)
  end

  private

  def call_my_llm(input, history:)
    # 自前の LLM 呼び出し
    "received: #{input}"
  end
end

# config/initializers/my_adapter.rb
MemoriaServer.adapter = MyAdapter.new
```

### 8.2 Ruby — Anthropic SDK でストリーミング

```ruby
require "anthropic"

class ClaudeAdapter < MemoriaServer::Adapter
  def initialize
    @client = Anthropic::Client.new
    @memory = MyMemoryStore.new  # 自前の永続化
  end

  def respond(input, context:)
    Enumerator.new do |y|
      char_id = context[:character_id]
      conversation = @memory.load(char_id) + context[:history]

      stream = @client.messages.stream(
        model: "claude-opus-4-7",
        max_tokens: 1024,
        messages: conversation,
        system: persona_for(char_id),
      )

      full_text = +""
      stream.each do |event|
        if event.type == "content_block_delta"
          delta = event.delta.text
          full_text << delta
          y << { delta: delta }
        end
      end

      @memory.append(char_id, role: "assistant", content: full_text)
      y << { done: true }
    end
  end
end
```

### 8.3 HTTP — Python (FastAPI)

外部プロセスとして HTTP エンドポイントを立てる場合、MS 側は同梱の HTTPアダプタ（`MS_ADAPTER=http`）を介してそれを呼び出します。

**動作するフルサンプル**：[docs/examples/echo_adapter_python/](examples/echo_adapter_python/) — Docker でも直接 uvicorn でも起動可能。

```python
# my_adapter.py
from fastapi import FastAPI
from fastapi.responses import StreamingResponse
import json

app = FastAPI()
sessions = {}  # character_id をキーに会話履歴を永続化（実際はDB等）

@app.post("/respond")
async def respond(req: dict):
    character_id = req["context"]["character_id"]
    user_input = req["input"]

    history = sessions.setdefault(character_id, [])
    history.append({"role": "user", "content": user_input})

    # 自前のLLM呼び出し（ここでは固定応答）
    reply = f"echo: {user_input}"
    history.append({"role": "assistant", "content": reply})

    def generate():
        for char in reply:
            yield json.dumps({"delta": char}) + "\n"
        yield json.dumps({"done": True, "metadata": {}}) + "\n"

    return StreamingResponse(generate(), media_type="application/x-ndjson")

@app.post("/boundary")
async def boundary(req: dict):
    character_id = req["context"]["character_id"]
    sessions.pop(character_id, None)
    return {"ok": True}
```

### 8.4 HTTP — Node.js

```javascript
// my-adapter.mjs
import express from 'express';
import { OpenAI } from 'openai';

const app = express();
app.use(express.json());

const openai = new OpenAI();
const sessions = new Map();  // character_id → conversation array

app.post('/respond', async (req, res) => {
  const { input, context } = req.body;
  const charId = context.character_id;
  const history = sessions.get(charId) || [];
  history.push({ role: 'user', content: input });

  res.setHeader('Content-Type', 'application/x-ndjson');

  const stream = await openai.chat.completions.create({
    model: 'gpt-4o-mini',
    messages: history,
    stream: true,
  });

  let full = '';
  for await (const chunk of stream) {
    const delta = chunk.choices[0]?.delta?.content || '';
    if (delta) {
      full += delta;
      res.write(JSON.stringify({ delta }) + '\n');
    }
  }
  history.push({ role: 'assistant', content: full });
  sessions.set(charId, history);
  res.write(JSON.stringify({ done: true }) + '\n');
  res.end();
});

app.listen(8080);
```

---

## 9. よくある質問

### Q. クライアントが毎回 messages 配列全部送ってくるのが OpenAI 互換ですよね？それとも MS が履歴を持つの？

A. **アダプタが履歴の真の保持者**です。MS は履歴を持ちません。クライアントが送ってくる `messages` は context.history としてアダプタにパススルーされますが、アダプタは自分が character_id で管理している履歴を真として優先する自由があります。MemoriaCore リファレンス実装はクライアント送信の messages を無視し、内部の ChatSessionRecord を信頼しています。

### Q. tool calls / vision はどう扱う？

A. MS はパススルーするだけです。アダプタが対応するかは自由。リクエストの `tools` / `messages[*].content` の配列形式（image_url 含む）は context にそのまま入ります。アダプタが yield するチャンクで `{ tool_calls: [...] }` を返せば、MS はクライアントに OpenAI 形式で転送します。

### Q. キャラが「自分から話しかける」にはどうすれば？

A. アダプタの好きなタイミング（cron、Solid Queue、内発的動機エンジン等）で `MemoriaServer.utter(character_id:, text:)` を呼んでください。MS は現在 active な device の SSE チャンネルに流します。スケジューラ自体は MS は提供しません。

### Q. 複数キャラクターを同時に動かせる？

A. はい。`presence` テーブルは character_id ごとに独立した行を持ち、各キャラが独自の active_device を持てます。クライアントは `model: "memoria/<char_id_or_slug>"` でどのキャラ宛か指定します。

### Q. キャラがそのデバイスにいない状態で chat を投げたら？

A. **寛容モード**で自動 transfer されます。「呼んだら来る」UX。退去させられたキャラには `presence.departed (reason: displaced_by_call)` イベントが流れます。

### Q. SleepPhase / 振り返り / TagProfiler のような夜間処理は？

A. アダプタの内部都合です。MemoriaCore リファレンス実装は Solid Queue で per-character ジョブを動かしています。あなたのアダプタも好きなジョブシステム（Celery / cron / Lambda 等）で類似の処理を実装することを**推奨**します（強制ではない）。

### Q. ストリーミングは必須？

A. アダプタ側は推奨ですが必須ではありません。`done: true` だけ yield する（一括返却）でも動きます。ただし aituber-kit / ChatdollKit 等のクライアントはストリーミング前提でUXを組んでいるため、できれば対応してください。

---

## 10. ライセンスと配布

MS 本体は OSS（ライセンスはリポジトリ参照）。アダプタは各開発者が好きなライセンスで配布できます。

公式アダプタレジストリは Phase 3 で公開予定。

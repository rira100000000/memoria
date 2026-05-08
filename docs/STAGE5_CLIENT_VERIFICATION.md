# ステージ 5：クライアント接続検証 チェックリスト

実機・外部クライアントが必要なため自律実行不可。準備が整ったら順に実施。

## 5.1 サーバ起動

```bash
# 開発環境（ローカル直接）
redis-server &
bin/ms-setup                    # admin + main-pc 登録
bin/rails server                # http://localhost:3000

# または Docker Compose
docker compose up -d
docker compose exec app bin/ms-setup
```

控えること：
- `ADMIN_KEY` (msak_...)
- `DEVICE_KEY` (msdk_...)

## 5.1.5 ヘルパーツール

接続前に動作確認するためのツール群：

- `bin/ms-smoke` — 全 MS エンドポイントの疎通＋認可テスト（curl ベース）
- `docs/examples/sse_viewer.html` — ブラウザで SSE イベントを視覚確認
- `docs/examples/echo_adapter_python/` — HTTP アダプタの動作するサンプル実装

```bash
# 環境変数設定後に
bin/ms-smoke
```

詳細：[docs/AITUBER_KIT_INTEGRATION.md](AITUBER_KIT_INTEGRATION.md)

## 5.2 aituber-kit 接続検証

詳細手順は [docs/AITUBER_KIT_INTEGRATION.md](AITUBER_KIT_INTEGRATION.md) を参照。要点：

### 準備
1. https://github.com/tegnike/aituber-kit を clone
2. `npm install && npm run dev` で起動
3. ブラウザで設定画面を開く

### LLM 設定
- LLM サービス：OpenAI 互換
- ベース URL：`http://localhost:3000/api/v1`
- API Key：上記の `DEVICE_KEY`
- モデル：`memoria/<character_vault_dir_name>`（例：`memoria/elysia`）
- ストリーミング：有効

### 検証項目
- [ ] チャット送信 → SSE で文字が逐次表示される
- [ ] サーバログに `"POST /api/v1/chat/completions"` が現れる
- [ ] `presence` テーブルが自動更新される（`bin/rails console` で確認）
- [ ] 2回目以降のチャットで過去文脈を踏まえた応答が返る（記憶継続の確認）

### 想定される課題
- aituber-kit が `x_memoria.emotion` を読まない → 表情反映には独自フォーク or PR が必要
- `messages` を毎回送ってくる仕様 → MS は無視するがアダプタ次第

## 5.3 スタックチャン接続検証

### 機種選定
- M5Stack Core2 / Stack-chan の OpenAI 互換ファームを焼く
- 候補：[robo8080/M5Unified_StackChan_ChatGPT](https://github.com/robo8080/M5Unified_StackChan_ChatGPT)
- ファームの設定で API URL と API Key を変更可能か事前確認

### 設定
- API URL: `http://<dev_pc_ip>:3000/api/v1/chat/completions`
- API Key: `DEVICE_KEY`（スタックチャン用に別途発行：`bin/rails ms:device:register DEVICE_NAME=stackchan-living`）
- モデル：`memoria/<vault_dir_name>`

### 検証項目
- [ ] スタックチャンから音声入力 → MS 経由で応答が返る
- [ ] heartbeat エンドポイントを定期 POST する実装を追加（5秒間隔等）
- [ ] presence の active_device が動く

### 想定される課題
- スタックチャンファームが SSE をサポートしていない場合 → `stream: false` で非ストリーミング応答を使う
- WiFi 経由のレイテンシ
- TLS 必須なファームが多い → ngrok / cloudflared 等で HTTPS 終端

## 5.4 PC ↔ 別デバイス 移動デモ（サーバ側検証 ✅ 2026-05-08）

aituber-kit / Stack-chan が SSE 購読を実装する前段として、サーバ側の transfer / utter / action / presence event の挙動を curl + SSE listener で検証済み。

### 検証手順（再現方法）

```bash
# 2 デバイス登録
DEVICE_NAME=main-pc bundle exec rails ms:device:register
DEVICE_NAME=phone-rira bundle exec rails ms:device:register

# 別シェル 1：main-pc 用 SSE 購読
curl -N -H "Authorization: Bearer $MAIN_PC_KEY" \
  http://localhost:3001/api/v1/devices/main-pc/events

# 別シェル 2：phone-rira 用 SSE 購読
curl -N -H "Authorization: Bearer $PHONE_KEY" \
  http://localhost:3001/api/v1/devices/phone-rira/events

# transfer / utter / action を順に叩く
curl -X POST -H "Authorization: Bearer $ADMIN_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"to_device":"phone-rira","reason":"user_called"}' \
  http://localhost:3001/api/v1/characters/<id>/transfer

curl -X POST -H "Authorization: Bearer $ADMIN_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"text":"hi","emotion":"warm"}' \
  http://localhost:3001/api/v1/characters/<id>/utter

curl -X POST -H "Authorization: Bearer $ADMIN_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"command":"dance","params":{"duration_sec":10}}' \
  http://localhost:3001/api/v1/characters/<id>/action
```

### 検証結果

- transfer 時、旧デバイスに `presence.departed`、新デバイスに `presence.arrived` が**正しい from/to slug 付き**で配信
- utter / action は active な device にだけ届く（非 active の SSE には流れない）
- DB の unique 制約 + atomic lock により presence は常に1行（「キャラはどこか一箇所」原則を担保）
- Transfer ログテーブルに移動履歴が完全に蓄積

### 残タスク（クライアント側）

サーバ側挙動は完璧だが、以下のクライアント UI 反映が未実装：

- aituber-kit に SSE 購読部を追加（`presence.departed` で「お出かけ中」表示、`utter` で台詞ふきだし、`action` で動作トリガー）
- Stack-chan ファームに同等の購読を実装（5.3 の改造項目）

ブラウザでの視覚確認用に `docs/examples/sse_viewer.html` を提供。Stage 5.6（aituber-kit emotion + presence パッチ）と Stage 5.3 で各クライアントへ展開する。

---

## 5.6 emotion engine + aituber-kit パッチ（✅ 2026-05-08）

### 完了：サーバ側 capability negotiation

クライアントが `x_memoria.wants` で要求する capability に応じてバックエンドが LLM への出力指示を注入する仕組みを実装：

- リクエスト：`{"x_memoria":{"wants":["emotion"]}}`
- LLM が応答中に `<x_memoria>{"emotion":"happy"}</x_memoria>` 形式の sentinel タグを挿入
- MS の `StreamingMetadataExtractor` がストリーム中にタグを抽出し `delta.x_memoria.emotion` チャンクとして配信
- インライン挿入のため、応答中の表情変化と同期する

実 LLM（Gemini 2.5 Flash）で動作確認済み：応答冒頭に `delta.x_memoria.emotion=neutral` チャンクが出てから、テキスト本体のチャンク群が続くシーケンス。

### 完了：aituber-kit 翻訳パッチ

aituber-kit リポジトリの `src/lib/api-services/customApi.ts` のレスポンス変換ストリームに以下を追加：

```typescript
// MemoriaServer 互換: delta.x_memoria.emotion を `[emotion]` インラインタグに翻訳
const xMemEmotion = data.choices?.[0]?.delta?.x_memoria?.emotion
if (typeof xMemEmotion === 'string' && xMemEmotion.length > 0) {
  const synthetic = {
    type: 'text-delta',
    delta: `[${xMemEmotion}] `,
  }
  controller.enqueue(encoder.encode(`data: ${JSON.stringify(synthetic)}\n`))
  if (data.choices[0].delta.content === undefined) continue
}
```

aituber-kit には `[happy] こんにちは` 形式の inline emotion タグを VRoid 表情に変換する既存機構（`features/chat/handlers.ts` の `extractEmotion`）があるため、MS の `delta.x_memoria.emotion` を翻訳すれば下流ロジックは無改造で動く。

emotion 値域は MS 側（`neutral / happy / sad / angry / relaxed / surprised`）と aituber-kit `EMOTIONS` 定数が**完全一致**しているため、マッピング不要。

### スマホからの利用方法

aituber-kit Custom Body に以下を追加：
```json
{"model":"memoria/3","stream":true,"x_memoria":{"wants":["emotion"]}}
```

これでチャットを送るとキャラの表情が応答内容に応じて切替わる。

### 残タスク

- aituber-kit のフォークを公式に PR（パッチは小さい・後方互換）
- presence event 購読（SSE）も同様にパッチを当てて「お出かけ中」表示を実装（次フェーズ）

---

## 5.4 PC ↔ スタックチャン 移動デモ（実機検証）

### シナリオ
1. PC（aituber-kit）でキャラと会話開始（presence: aituber-kit）
2. アダプタ起点 or 管理者から `transfer` API 叩く → presence: stackchan
3. PC側 SSE で `presence.departed` 受信、UI で「お出かけ中」表示
4. スタックチャン側で `presence.arrived` 受信、挨拶
5. スタックチャン側で会話継続（前の話の続きが可能）
6. 戻りも同様

### 検証項目
- [ ] transfer 完了後、PC側 SSE に `presence.departed` イベントが届く
- [ ] スタックチャン側に `presence.arrived` が届く
- [ ] 移動後の会話で過去文脈（PC で話した内容）を引いてくる
- [ ] 5分以上のアイドル後の SSE が切れていない（keepalive 必要なら追加実装）

## 5.5 自発移動デモ

### 準備
- アダプタ側に「退屈タイマー」を実装：
  - Solid Queue で「最終発話から N 分後にチェック」ジョブを enqueue
  - 退屈条件成立 → `MemoriaServer.transfer(character_id:, to_device: "stackchan-...", reason: "ai_initiated:bored")` 呼び出し

### 検証項目
- [ ] アイドル中に自発的に transfer が走る
- [ ] 移動先のスタックチャンで `utter` で挨拶発話が届く（"スタックチャン来たよ" 等）

## 5.6 モバイル（スマホブラウザ）デモ

### 準備
- aituber-kit はNext.js なのでモバイルブラウザで動く
- 同一 LAN の PC IP に向ける（`http://192.168.x.x:3000/api/v1`）
- スマホ用にも `bin/rails ms:device:register DEVICE_NAME=phone-rira` で別キー発行

### 検証項目
- [ ] スマホで開いてチャット可能
- [ ] PC ↔ スマホ ↔ スタックチャン 3点間の transfer が動く

## 5.7 展示会前のリハーサル

- [ ] 5分の長時間ループデモが安定する（メモリリーク・SSE切断なし）
- [ ] ネットワーク切断 → 再接続シナリオの動作確認
- [ ] 複数観客が同時アクセスしてもクラッシュしない（observability 視点）
- [ ] `bin/rails ms:admin:list` / `ms:device:list` で常に状態確認できる
- [ ] バックアップ手順（admin キー紛失時の再 bootstrap 等）を文書化

## 課題があったら

- 設計に立ち返る：`plan/MemoriaServer(MS)設計ドキュメント.md`
- アダプタ contract：`docs/ADAPTER_README.md`
- API 仕様：`config/routes.rb` で全エンドポイント一覧

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

## 5.2 aituber-kit 接続検証

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

## 5.4 PC ↔ スタックチャン 移動デモ

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

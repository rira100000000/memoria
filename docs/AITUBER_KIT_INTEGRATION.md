# aituber-kit 連携ガイド

[aituber-kit](https://github.com/tegnike/aituber-kit) は AI VTuber 配信用クライアント（Next.js 製）。MemoriaServer (MS) を OpenAI 互換バックエンドとして接続することで、Memoria の長期記憶を保ったままブラウザ・モバイルでキャラと会話できる。

## 構成

```
ユーザー ──→ aituber-kit (Next.js / ブラウザ) ──→ MS (Rails) ──→ MemoriaCore アダプタ
                       │                                          │
                       │ OpenAI 互換                              │ Gemini API
                       ▼                                          ▼
                                                              長期記憶
```

## 初回セットアップ

### 1. MS 側

```bash
cd memoria
bin/ms-setup DEVICE_NAME=aituber-kit-pc
```

控える：
- `ADMIN KEY`（msak_...）
- `DEVICE KEY`（msdk_...）
- 発話させたいキャラの `vault_dir_name`（例：`hal`、`elysia`）

### 2. aituber-kit 側

```bash
git clone https://github.com/tegnike/aituber-kit
cd aituber-kit
npm install
npm run dev
```

ブラウザで http://localhost:3000 を開いて設定画面へ。

#### LLM 設定

| 項目 | 値 |
|---|---|
| LLMサービス | **OpenAI** |
| モデル | `memoria/<vault_dir_name>` 例：`memoria/hal` |
| API Key | `<DEVICE_KEY>` |
| Custom URL | `http://localhost:3000/api/v1` |
| ストリーミング | **有効** |

> **ポート競合注意**: aituber-kit と MS は両方 3000 を使うので、片方をずらす：
> - MS を別ポート：`bin/rails server -p 3001` ＋ aituber-kit Custom URL を `http://localhost:3001/api/v1`
> - aituber-kit を別ポート：`PORT=3001 npm run dev`

#### 動作確認

設定保存 → メイン画面で発話 → MS のサーバログに `POST /api/v1/chat/completions` が出れば接続成功。応答が逐次表示されればストリーミングOK。

### 3. 検証

```bash
export MS_BASE_URL=http://localhost:3001
export MS_ADMIN_KEY=msak_...
export MS_DEVICE_KEY=msdk_...
export MS_CHARACTER_REF=hal
bin/ms-smoke
```

全項目 ✅ なら基盤は健全。

## 既知の制限と対処

### emotion (`x_memoria.emotion`) が反映されない

aituber-kit は OpenAI 標準レスポンスしか読まないため、MS が乗せている `delta.x_memoria.emotion` は無視される。表情同期には軽量パッチが必要。

#### 必要な変更（実装案）

aituber-kit 側のレスポンスチャンク処理（おそらく `src/features/chat/handlers/openai.ts` 周辺）に以下を追加：

```typescript
// チャンク受信時
const xMemoria = chunk.choices[0]?.delta?.x_memoria;
if (xMemoria?.emotion) {
  // 既存の表情切替APIを呼ぶ
  setEmotion(xMemoria.emotion);
}
```

emotion の値（`happy` / `sad` / `angry` / `surprised` / `neutral` 等）と aituber-kit の表情プリセット名のマッピング表が必要。

### messages 配列を毎回送ってくる

OpenAI 仕様上、aituber-kit は履歴を含む `messages` 配列を毎回送る。MS は context にパススルーするが、**MemoriaCore アダプタはクライアント送信の messages を無視**して自前の ChatSessionRecord を真とする。これにより：

- aituber-kit 側で履歴をリセット → MS 側の文脈は保持される（意図したクロスデバイス継続）
- aituber-kit を別デバイスで開いても、同じ character の文脈で続けられる

会話のリセットが必要な場合は明示的に：

```bash
curl -X POST -H "Authorization: Bearer $ADMIN_KEY" \
  http://localhost:3001/api/v1/characters/$CHAR/conversation/boundary \
  -d '{"reason":"user_requested"}'
```

または aituber-kit 側に「リセットボタン」を追加して上記APIを叩く実装。

### tools / function calling

Phase 1 の MemoriaCore アダプタは内蔵の `semantic_search` ツールしか提供しない。aituber-kit が独自の tools を送ってきても無視される。MemoriaCore の Function Calling フローを拡張するか、HTTP アダプタ経由で外部 LLM を使う必要がある。

## モバイルブラウザ対応

aituber-kit は Next.js なのでスマホブラウザでも動く：

1. PC とスマホを同一 LAN に接続
2. PC の IP を確認（例：`192.168.1.10`）
3. aituber-kit を `npm run dev -- --host 0.0.0.0` で起動
4. スマホで `http://192.168.1.10:3000` にアクセス
5. 設定画面で Custom URL を `http://192.168.1.10:3001/api/v1` に変更（PC のホスト IP）

スマホ用に別の DEVICE_KEY を発行する：

```bash
bin/rails ms:device:register DEVICE_NAME=phone-rira
```

## クロスデバイス移動デモ

PC → スマホ移動：

```bash
# PC で会話中... 別ターミナルから
curl -X POST -H "Authorization: Bearer $ADMIN_KEY" \
  -H "Content-Type: application/json" \
  -d '{"to_device":"phone-rira","reason":"user_requested"}' \
  http://localhost:3001/api/v1/characters/hal/transfer
```

PC 側の SSE に `presence.departed` が届く。スマホ側に `presence.arrived` が届く（aituber-kit が SSE 購読部を実装している場合）。

> **注意**: aituber-kit には SSE 常駐イベント受信の実装はない。`presence.arrived/departed` を表示するには `/api/v1/devices/:slug/events` を購読する追加実装が必要。

## トラブルシュート

### 401 Unauthorized

DEVICE_KEY が誤っている。`bin/rails ms:device:list` で発行済みキーを確認、必要なら `bin/rails ms:device:rotate_key` で再発行。

### 404 character not found

`model: "memoria/<vault_dir_name>"` の値が間違っている。`bin/rails runner 'Character.pluck(:name, :vault_dir_name)'` で正しい slug を確認。

### Streaming が機能しない（応答がまとめて来る）

aituber-kit の設定で「ストリーミングを有効」になっていない可能性。または Rails 開発環境のリバースプロキシ設定。`bin/rails server` 直接起動なら問題ないはず。

### CORS エラー

MS は `origins "*"` で全許可しているので通常起きない。発生したら `config/initializers/cors.rb` を確認。

# Stack-chan ファーム選定調査 — MemoriaServer 接続のための比較

調査日: 2026-05-07
目的: 9月の生成AI展示会で「PC（aituber-kit）⇄ スマホ ⇄ Stack-chan」の3点間で AI キャラ（presence）が移動する展示を行う。MemoriaServer (MS) は OpenAI Chat Completions 互換 API を提供するため、**カスタム base URL 指定**と **`Authorization: Bearer <device_key>` ヘッダ送出**が必須要件。

---

## 1. 候補ファーム比較表

| 候補 | 最終更新の目安 | 対応HW | カスタムURL | カスタムBearer | ストリーミング | Function Calling | 設定方式 | MS連携の親和性 |
|---|---|---|---|---|---|---|---|---|
| **robo8080 / AI_StackChan2** | 2023〜（メンテ静か） | Core2 中心 / CoreS3 不安定 | ✗ ハードコード | ✗ | ✗ | ✗ | SD `apikey.txt` + Web UI `/apikey` | 改造必要（中） |
| **robo8080 / M5Unified_StackChan_ChatGPT** (+ _Global) | 2023〜 | Core2 / Basic | ✗ | ✗ | ✗ | ✗ | SD `wifi.txt` + `apikey.txt` / Web UI | 改造必要（中） |
| **robo8080 / M5Unified_AI_StackChan_Lite** | 2023〜 | Core2 軽量 | ✗ | ✗ | ✗ | ✗ | SD + Web | 改造必要（軽） |
| **yh1224 / AIStackchan-hrs** | 比較的活発 | Core2 / CoreS3 / Basic / Fire | ✗ デフォルト（ただし `settings.json` を **HTTP POST で動的更新**できる構造） | ✗（既定なし、追加容易） | `chat.openai.stream` キーあり | ✗ | SD `settings.json` + `POST /settings` | **改造容易（推奨1）** |
| **ronron-gh / AI_StackChan_Ex** | 2026/02 indexed、活発 | Core2 / CoreS3 | ✗ | ✗ | ◯（Realtime mode 1〜2s） | **◯ Function Calling 対応** | YAML 3層 (`SC_SecConfig` / `SC_BasicConfig` / `SC_ExConfig`) | **改造容易（推奨2）** |
| **ronron-gh / AI_StackChan2_FuncCall** | やや古め | Core2 | ✗ | ✗ | ✗ | ◯ | SD | 改造必要（中） |
| **rudyll / stackchan_ha_addons** | 2026 活発（80+ commits） | M5公式 Stack-chan (CoreS3) | サーバ側 add-on で吸収可（HA 経由） | 同左 | ◯（streaming PCM） | ◯（HA device control） | Web UI（HA 設定タブ） | **間接連携向け（推奨2.5）** |
| **stack-chan/stack-chan 公式** | dev/v1.0 メイン、コミット多数 / 直近やや停滞 | Core2 / Basic 等 | ✗（mods 次第） | ✗ | △ | ✗ | Moddable JS（mc.config.json） | **JS 製のため改造容易（推奨2）** |
| **m5stack/StackChan 公式** | 2026 活発 | M5公式 Stack-chan kit (CoreS3) | ✗ Xiaozhi cloud 既定 | ✗ | ◯ Realtime | △ | M5Burner | 改造困難 |

> どのファームも `https://api.openai.com/v1/chat/completions` をハードコードしているのが現状。**MS 連携のためにファーム側を 1 行〜数行レベルで改造する前提が現実的**。改造容易性で順位付け。

---

## 2. 推奨機種: 第一候補 **yh1224 / AIStackchan-hrs**

### 推奨理由
- `settings.json` がフラット構造で、`chat.openai` セクションを丸ごと書き換えやすい。
- `POST /settings` で**動的に config 上書き可能** → 焼き直し不要で展示当日に MS の URL/Key を差し替えられる。
- `chat.openai.stream` キーが既に存在し、SSE 受信ロジックを足しやすい。
- 複数機種（Core2 / CoreS3 / Basic / Fire）にピンマッピング対応済み。
- C++ 99% で構造が単純 → `OpenAI host = "api.openai.com"` 相当の定数を `settings.openai.baseUrl` に置換し、`Authorization` ヘッダ生成に MS の `device_key` を流す改造が 1 ファイル内で済む見込み。

### 改造ポイント（推奨1）
1. `chat.openai.baseUrl`（例: `https://memoria.local/api/v1/openai`）と `chat.openai.deviceKey` を `settings.json` に追加。
2. HTTPS クライアント生成箇所で `host`/`url` を base URL に差し替え、`Authorization: Bearer ${deviceKey}` を送出。
3. `model` は `memoria/<id>` 形式の文字列をそのまま `settings.json` に入れて流用。
4. Presence 移動の SSE 購読は別タスク（FreeRTOS task）で `ESPAsyncWebServer` 系の HTTP クライアントを使い `/api/v1/devices/:slug/events` を `text/event-stream` で受信。受信時に顔表情と目線を切り替える。

## 第二候補 **ronron-gh / AI_StackChan_Ex**

- Function Calling 対応・Realtime mode（1-2s）・YAML 3層（運用 / セキュア値分離）が秀逸。
- 2026 年2月時点でも更新されており Core2 / CoreS3 両対応。
- 改造コストは hrs より高い（ファイル分割が深い）が、**presence 表現に function calling を活かせる**ため拡張性が最も高い。
- スマホ ⇄ Stack-chan 間で MS から `set_presence_state(idle/listening/speaking/thinking)` をツール呼び出しで制御するなどの応用に向く。

---

## 3. 想定購入リスト（展示用 1 体構成 / 税込 / 2026-05 時点）

| 用途 | 品名 | 入手先 | 単価 | 数量 | 小計 |
|---|---|---|---:|---:|---:|
| 本体MCU | M5Stack Core2 v1.3 | スイッチサイエンス #11050 | ¥8,030 | 1 | ¥8,030 |
| 制御ボード | Stack-chan_TakaoBase_SCS0009（基板のみ） | スイッチサイエンス #9288 | ¥700 | 1 | ¥700 |
| サーボ | Feetech SCS0009 シリアルサーボ | 千石電商 / スイッチサイエンス | ~¥1,500 | 2 | ~¥3,000 |
| 筐体 | mongonta 版 M5GoBottom 組立キット または mongonta.booth.pm の3Dプリントキット | BOOTH / mongonta | ~¥3,000 | 1 | ~¥3,000 |
| ケーブル類 | USB-C 給電ケーブル / Grove | 既存流用可 | — | — | — |
| **小計** | | | | | **約 ¥14,700** |

> 代替（簡素・サーボ無し版）: M5Stack CoreS3 SE ¥7,062 単体でも顔表示のみは可能。展示インパクトが弱いので非推奨。
> 代替（手間ゼロの上位版）: M5公式「ｽﾀｯｸﾁｬﾝ AIデスクトップロボット」¥22,990 だが**現在売り切れ**。9月までに再入荷確認が必要。サーボ込み完成品。

**展示3点間移動を想定するなら最低2体（1体は予備）+ aituber-kit を回す PC 1台 + スマホ 1台**。Stack-chan 2体ぶんで ~¥30,000、CoreS3版へ揃えるなら +¥10,000。

---

## 4. セットアップ手順の概略（推奨1: AIStackchan-hrs フォーク前提）

1. **環境準備**: VSCode + PlatformIO 拡張 / M5Stack Core2 / micro SD カード（FAT32）/ USB-C ケーブル。
2. **リポジトリ取得**: `git clone https://github.com/yh1224/AIStackchan-hrs && git checkout -b memoria-fork`
3. **`platformio.ini` 確認**: `board = m5stack-core2` を確認、必要なら `m5stack-cores3` などに変更。
4. **コード改造（最小）**:
   - `src/lib/...` 配下の OpenAI HTTP クライアントで `https://api.openai.com` を `settings.chat.openai.baseUrl` に置換。
   - `Authorization: Bearer <apiKey>` 部分はそのまま、ただし `apiKey` には MS の `device_key` を入れる運用に。
5. **ビルド & 書き込み**: `pio run -t upload`。シリアル `pio device monitor` で IP を確認。
6. **SD カード初期設定**（焼き直し不要）: ルートに `settings.json` を置く、もしくは Wi-Fi 接続後に curl で動的設定:
   ```bash
   curl -X POST http://<stackchan-ip>/settings \
     -H "Content-Type: application/json" \
     -d '{
       "wifi": {"ssid":"...","password":"..."},
       "chat": {"openai": {
         "baseUrl":"https://memoria.example.com/v1",
         "apiKey":"sk-device-xxxxxxx",
         "model":"memoria/hal-default",
         "stream": true,
         "maxHistory": 10
       }},
       "speech": {"voicevox": {"endpoint":"http://<pc-ip>:50021"}}
     }'
   ```
7. **VOICEVOX 起動**: 同 LAN の PC で VOICEVOX エンジンを `0.0.0.0:50021` で listen させ、Stack-chan の TTS 先に指定。
8. **Presence SSE 購読**（追加実装）: ファーム起動時に `EventSource` 相当のループで `GET /api/v1/devices/<slug>/events` を `Accept: text/event-stream` で開き、`presence:enter` / `presence:leave` を表情・サーボ動作に紐付け。
9. **動作検証**: 物理ボタン押下→マイク録音→STT（Whisper or Google）→ MS の `/v1/chat/completions` へ POST → 返答 → VOICEVOX → 再生、の一連を確認。
10. **展示当日**: Wi-Fi SSID/PW のみ会場用に上書き（POST /settings）、device_key は事前に焼き込み済み。

---

## 5. MS 連携の懸念点と対策

| 懸念 | 評価 | 対策 |
|---|---|---|
| `Authorization: Bearer <device_key>` 送出 | **既存の OpenAI ヘッダと同形式**なので apiKey フィールドに入れるだけで通る | コード変更ほぼ不要 |
| `model: "memoria/<id>"` 指定 | 任意文字列が通る実装が多い（OpenAI SDK 側のバリデーションは MS にはない） | `settings.json` の model に文字列をそのまま指定 |
| ストリーミング | hrs は `stream` フラグありだが SSE パースが完全か要確認。Ex の Realtime mode は WebSocket 系で別経路 | 初手は `stream: false` で動かし、UX 改善時に SSE パース実装 |
| Presence SSE 購読 | ESP32 で `text/event-stream` を読む実装は ESPAsyncWebServer / WiFiClientSecure で可能 | FreeRTOS task で常駐ループ、再接続ロジック必須 |
| 焼き直し頻度 | hrs は HTTP POST で動的更新可 → 当日変更しても再フラッシュ不要 | OK |
| 複数台同期 | MS 側で device_key ごとに presence を発火させれば自然に成立 | MS の SSE が複数同時購読を許す前提を確認 |

---

## 6. 結論と次アクション

- **第一候補: yh1224/AIStackchan-hrs を fork して `baseUrl` フィールドを追加**。実装コスト最小・展示当日の差し替えに強い。
- **第二候補（拡張性重視）: ronron-gh/AI_StackChan_Ex** を採用し Function Calling 経由で presence を制御。Realtime mode 採用時の UX 優位。
- 9月までの工程: ①ハード調達（5月中、CoreS3 完成品の再入荷待ち含む）→ ②ファーム fork & MS 互換改造（6月）→ ③SSE presence 統合（7月）→ ④3点間デモ統合リハーサル（8月）。
- 公式 M5 kit（¥22,990）は再入荷タイミングを週次でウォッチ推奨。間に合わない場合は Core2 + TakaoBase 自作構成に確定させる。

## Sources

- [robo8080/M5Unified_StackChan_ChatGPT (GitHub)](https://github.com/robo8080/M5Unified_StackChan_ChatGPT)
- [robo8080/M5Unified_StackChan_ChatGPT_Global (GitHub)](https://github.com/robo8080/M5Unified_StackChan_ChatGPT_Global)
- [robo8080/AI_StackChan2 (GitHub)](https://github.com/robo8080/AI_StackChan2)
- [robo8080/AI_StackChan2_README (GitHub)](https://github.com/robo8080/AI_StackChan2_README)
- [yh1224/AIStackchan-hrs (GitHub)](https://github.com/yh1224/AIStackchan-hrs)
- [ronron-gh/AI_StackChan_Ex (GitHub)](https://github.com/ronron-gh/AI_StackChan_Ex)
- [ronron-gh/AI_StackChan2_FuncCall (GitHub)](https://github.com/ronron-gh/AI_StackChan2_FuncCall)
- [rudyll/stackchan_ha_addons (GitHub)](https://github.com/rudyll/stackchan_ha_addons)
- [stack-chan/stack-chan official (GitHub)](https://github.com/stack-chan/stack-chan)
- [m5stack/StackChan official (GitHub)](https://github.com/m5stack/StackChan)
- [M5Stack Core2 v1.3 — スイッチサイエンス](https://www.switch-science.com/products/11050)
- [M5Stack CoreS3 SE — スイッチサイエンス](https://www.switch-science.com/products/9690)
- [Stack-chan_TakaoBase_SCS0009（完成品） — スイッチサイエンス](https://www.switch-science.com/products/9288)
- [M5 ｽﾀｯｸﾁｬﾝ AIデスクトップロボット — スイッチサイエンス](https://www.switch-science.com/products/11131)
- [mongonta booth (Stack-chan kits)](https://raspberrypi.mongonta.com/about-products-stackchan-m5gobottom-version/)
- [How to install AI Stackchan-2 — Jun OKAMURA (Medium)](https://jun1okamura.medium.com/how-to-install-ai-stackchan-2-with-google-stt-openai-and-voicevox-services-afb9bb1010b)
- [Stack-chan firmware docs (stack-chan.github.io)](https://stack-chan.github.io/stack-chan/firmware/)
- [ESP32 Server-Sent Events (SSE) — Random Nerd Tutorials](https://randomnerdtutorials.com/esp32-web-server-sent-events-sse/)
- [StackChan CONNECT — yh1224 notes](https://notes.yh1224.com/stackchan-connect/)
- [DeepWiki: ronron-gh/AI_StackChan_Ex](https://deepwiki.com/ronron-gh/AI_StackChan_Ex)
- [DeepWiki: robo8080/M5Unified_StackChan_ChatGPT](https://deepwiki.com/robo8080/M5Unified_StackChan_ChatGPT/1-overview)

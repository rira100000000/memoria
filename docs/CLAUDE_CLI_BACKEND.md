# claude -p バックエンド

キャラクターの会話と思考ループを、Gemini API の代わりに `claude -p`（Claude Code のヘッドレス実行）で動かす選択肢です。既定は Gemini で、設定したときだけ使われます。

## 何が claude -p で動くか

| 処理 | 使うもの |
| --- | --- |
| 会話（`ChatSession#send_message`。Discord bot、`/api/chats`） | claude -p |
| 思考ループと予定の実行（`Thinking::Thinker`） | claude -p |
| 埋め込み、Web検索、振り返り（SN）、タグ付け、睡眠フェーズ、ペット・読書伴走者の返答、音声の書き起こし | Gemini のまま |
| ストリーミングの会話（OpenAI互換API。デバイスからの会話） | Gemini のまま |

ツールを使うループだけを claude -p に任せます。軽い処理と埋め込みは Gemini のままなので、`GEMINI_API_KEY` は引き続き必要です。

## 設定

```bash
MEMORIA_AGENT_BACKEND=claude_cli
CLAUDE_CLI_MODEL=sonnet         # 普段のモデル（既定: sonnet）
CLAUDE_CLI_DEEP_MODEL=opus      # 込み入った会話で切り替えるモデル（既定: opus）
# CLAUDE_CLI_COMMAND=claude     # claude コマンドのパス
# CLAUDE_CLI_TIMEOUT=600        # 1回の実行の上限（秒）
# CLAUDE_CLI_MAX_TURNS=20       # 1回の実行でのツール呼び出しの往復の上限
```

`claude` はインストール済みで、ログイン済み（または API キーを設定済み）である必要があります。memoria は認証情報を読みません。

## 仕組み

1. memoria はシステムプロンプト（`PromptBuilder` の出力）とプロンプトを渡して `claude -p` を起動します。会話のときは、これまでの会話を書き起こしてプロンプトに入れます
2. ツールは MCP サーバ `bin/memoria_mcp`（stdio）として渡します。Gemini のときと同じツール（記憶検索、予定、プラグインのツールなど）が同じ処理で実行されます
3. Claude Code の組み込みツール（Bash・Edit など）、設定ファイル、CLAUDE.md は使いません（`--tools ""`、`--setting-sources ""`、空の作業ディレクトリ）
4. MCP サーバは実行したツールを一時ファイルに記録し、memoria はそれを会話ログ（FL）に反映します

### 強いモデルへの切り替え

会話では `use_deep_model` ツールが使えます。開発の相談や設計の壁打ちのような込み入った会話になったとキャラクターが判断すると、このツールを呼びます。その返答から `CLAUDE_CLI_DEEP_MODEL` で作り直し、会話が終わる（セッションが閉じる）まで強いモデルのまま続きます。

### 使えなかったとき

claude -p が失敗したとき（異常終了、タイムアウト、利用枠切れなど）は Gemini で動きます。

- 会話: Gemini の返答の末尾に「⚠️ memoria: claude -p が使えなかったので Gemini で動きました（理由）」を添えます（会話の履歴には残しません）
- 思考ループ: 同じ文を連絡手段（Discord など）に送ります。続けて失敗しても1時間に1回まで

## 規約について

claude -p をサブスクリプション（Claude Pro / Max など）で使う場合は、Anthropic の規約に従ってください。要点:

- 自分のマシンで、自分のサブスクリプションで、自分のために使うこと。他の人にサブスクリプションの利用枠を使わせる形（共有のサーバとして公開するなど）は認められていません
- 他の人に使わせるなら API キー（`ANTHROPIC_API_KEY`）で使ってください

詳しくは [Claude Code の Legal and compliance](https://code.claude.com/docs/en/legal-and-compliance) を参照してください。規約の順守は利用者の責任です。

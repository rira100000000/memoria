# Echo Adapter (Python / FastAPI)

MemoriaServer の HTTP アダプタ contract の最小サンプル実装。ユーザー入力をそのまま echo するだけだが、永続化・ストリーミング・境界・履歴フェッチを正しく実装している。

## 何を学ぶためのサンプルか

- [docs/ADAPTER_README.md](../../ADAPTER_README.md) で定義した HTTP アダプタ仕様（`/respond` / `/boundary` / `/history`）
- ndjson ストリーム応答の組み立て方
- character_id をキーにした会話履歴の永続化（contract 必須要件）

## 使い方

### ローカル起動

```bash
cd docs/examples/echo_adapter_python
pip install -r requirements.txt
uvicorn app:app --port 8080
```

### Docker

```bash
docker build -t memoria-echo-adapter .
docker run -p 8080:8080 memoria-echo-adapter
```

### MS から繋ぐ

`.env` に以下を追加してから MS を起動：

```env
MS_ADAPTER=http
MS_ADAPTER_URL=http://localhost:8080
```

```bash
bin/rails server
```

これで MS の OpenAI 互換チャットがこの echo アダプタへ流れる。

```bash
curl -N -X POST http://localhost:3000/api/v1/chat/completions \
  -H "Authorization: Bearer <DEVICE_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"model":"memoria/<character>","messages":[{"role":"user","content":"hello"}],"stream":true}'
```

応答：`[Echo echo] hello` が一文字ずつ流れてくる。

## 実 LLM に繋げる

`app.py` の `generate_reply()` を差し替える。Anthropic / OpenAI / Gemini どれでも：

```python
from anthropic import Anthropic
client = Anthropic()

def generate_reply(user_input, history, character_name):
    msgs = [{"role": m["role"], "content": m["content"]}
            for m in history if m["role"] != "system"]
    resp = client.messages.create(
        model="claude-opus-4-7",
        max_tokens=1024,
        messages=msgs,
        system=f"You are {character_name}.",
    )
    return resp.content[0].text
```

ストリーミングしたければ `stream_chunks()` も書き換える：

```python
async def stream_chunks(stream):
    full = ""
    for event in stream.text_stream:
        full += event
        yield (json.dumps({"delta": event}) + "\n").encode("utf-8")
    yield (json.dumps({"done": True, "metadata": {}}) + "\n").encode("utf-8")
```

## 永続化について

このサンプルはプロセスメモリ（`SESSIONS` dict）に履歴を持っているため、再起動で消える。本番アダプタは：

- DB（PostgreSQL / SQLite）
- Redis
- ファイルシステム
- 既存の記憶エンジン（LangChain / LlamaIndex / 自作）

のいずれかに永続化すること。`character_id` をキーにすれば、クロスデバイス記憶継続が成立する。

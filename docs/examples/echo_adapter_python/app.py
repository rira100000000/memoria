"""
MemoriaServer 用サンプル HTTP アダプタ（Python / FastAPI）。

仕様：docs/ADAPTER_README.md に従う最小実装。
- POST /respond  : ndjson でチャンクをストリーム返却（必須）
- POST /boundary : 短期文脈境界の通知（オプショナル）
- POST /history  : UI 用の過去履歴フェッチ（オプショナル）

このサンプルは「ユーザー入力をそのまま echo」する単純な動作。
character_id をキーに会話履歴を永続化（メモリ内・本番なら DB 等を使う）。

実LLMに繋げる場合は generate_reply() を差し替える：
    OpenAI/Anthropic/Gemini の SDK でストリーミング呼び出しを実装し、
    各 chunk を yield で返すだけ。
"""

import asyncio
import json
import time
from collections import defaultdict
from typing import AsyncIterator

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse

app = FastAPI(title="MemoriaServer Echo Adapter")

# character_id をキーに会話履歴を保持（プロセスメモリ内 — デモ用）
# 本番アダプタは DB / Redis / ファイル等で永続化すること（contract 必須要件）
SESSIONS: dict[int, list[dict]] = defaultdict(list)


@app.post("/respond")
async def respond(req: Request):
    body = await req.json()
    user_input: str = body.get("input") or ""
    context: dict = body.get("context") or {}
    character_id = context.get("character_id")
    character_name = context.get("character_name") or "Echo"

    # 過去履歴の取得（クライアントが送ってきた messages は無視し、自前を真とする）
    history = SESSIONS[character_id]
    history.append({"role": "user", "content": user_input, "at": time.time()})

    # 応答生成（ここを差し替えれば実LLMに）
    reply = generate_reply(user_input, history, character_name=character_name)

    # 履歴に保存（応答完了後にまとめる）
    history.append({"role": "assistant", "content": reply, "at": time.time()})

    return StreamingResponse(stream_chunks(reply), media_type="application/x-ndjson")


@app.post("/boundary")
async def boundary(req: Request):
    body = await req.json()
    character_id = body.get("character_id")
    reason = body.get("reason", "user_requested")
    had = character_id in SESSIONS and len(SESSIONS[character_id]) > 0
    # 短期文脈リセット：最新10件だけ残して切る等、自由に解釈する
    # ここでは「boundary 以前は context に入れない」マーカーだけ追加
    if character_id in SESSIONS:
        SESSIONS[character_id].append(
            {"role": "system", "content": f"[boundary: {reason}]", "at": time.time()}
        )
    return JSONResponse({"ok": True, "reason": reason, "had_active_session": had})


@app.post("/history")
async def history(req: Request):
    body = await req.json()
    character_id = body.get("character_id")
    limit = int(body.get("limit", 50))
    msgs = SESSIONS.get(character_id, [])[-limit:]
    return JSONResponse({"messages": msgs})


# --- ロジック本体（差し替えポイント）-----------------------------------

def generate_reply(user_input: str, history: list[dict], character_name: str) -> str:
    """
    実LLMに繋げる場合はここを差し替える。
    例（Anthropic SDK）：
        from anthropic import Anthropic
        client = Anthropic()
        msgs = [{"role": m["role"], "content": m["content"]} for m in history if m["role"] != "system"]
        resp = client.messages.create(
            model="claude-opus-4-7",
            max_tokens=512,
            messages=msgs,
            system=f"You are {character_name}.",
        )
        return resp.content[0].text
    """
    return f"[{character_name} echo] {user_input}"


async def stream_chunks(reply: str) -> AsyncIterator[bytes]:
    """応答テキストを文字単位で ndjson ストリーム化する。"""
    for ch in reply:
        yield (json.dumps({"delta": ch}, ensure_ascii=False) + "\n").encode("utf-8")
        await asyncio.sleep(0.01)  # 演出として少し間を置く（実LLMストリームでは不要）
    yield (json.dumps({"done": True, "metadata": {}}) + "\n").encode("utf-8")


# --- 動作確認用 ----------------------------------------------------------

@app.get("/")
def root():
    return {
        "name": "MemoriaServer Echo Adapter",
        "endpoints": ["/respond", "/boundary", "/history"],
        "active_characters": list(SESSIONS.keys()),
    }

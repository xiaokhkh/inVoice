import asyncio
import base64
import hashlib
import json
import os
import threading
import time
import uuid
from pathlib import Path

import numpy as np
from fastapi import FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect
from pydantic import BaseModel
import uvicorn

import sherpa_onnx
from stream_protocol import (
    FinishReplyCache,
    PROTOCOL_VERSION,
    parse_audio_frame,
    session_expired,
    validate_finish,
    validate_start_message,
)

ROOT_DIR = Path(__file__).resolve().parents[2]
MODEL_DIR = os.getenv("FAST_ASR_MODEL_DIR", str(ROOT_DIR / "models" / "zipformer"))
SAMPLE_RATE = int(os.getenv("FAST_ASR_SAMPLE_RATE", "16000"))
FEATURE_DIM = int(os.getenv("FAST_ASR_FEATURE_DIM", "80"))
NUM_THREADS = int(os.getenv("FAST_ASR_NUM_THREADS", "4"))
MODELING_UNIT = os.getenv("FAST_ASR_MODELING_UNIT", "bpe")
BPE_VOCAB = os.getenv("FAST_ASR_BPE_VOCAB", str(Path(MODEL_DIR) / "bpe.model"))
LOCAL_TOKEN = os.getenv("VOICEOPS_LOCAL_TOKEN", "")
SESSION_TTL_SECONDS = int(os.getenv("FAST_ASR_SESSION_TTL_SECONDS", "120"))
SERVICE_NAME = "voiceops-fast-asr"
MODEL_ID = Path(MODEL_DIR).name


def _model_sha256() -> str:
    digest = hashlib.sha256()
    for filename in ("encoder.onnx", "decoder.onnx", "joiner.onnx", "tokens.txt", "bpe.model"):
        path = Path(MODEL_DIR) / filename
        if not path.exists():
            continue
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
    return digest.hexdigest()


MODEL_SHA256 = _model_sha256()

print(f"[fast_asr] loading model from: {MODEL_DIR}")
recognizer = sherpa_onnx.OnlineRecognizer.from_transducer(
    encoder=f"{MODEL_DIR}/encoder.onnx",
    decoder=f"{MODEL_DIR}/decoder.onnx",
    joiner=f"{MODEL_DIR}/joiner.onnx",
    tokens=f"{MODEL_DIR}/tokens.txt",
    num_threads=NUM_THREADS,
    sample_rate=SAMPLE_RATE,
    feature_dim=FEATURE_DIM,
    modeling_unit=MODELING_UNIT,
    bpe_vocab=BPE_VOCAB,
)
print("[fast_asr] model ready")

app = FastAPI(title="Fast ASR Sidecar (sherpa-onnx)")
lock = threading.Lock()
sessions_lock = threading.Lock()
sessions = {}


@app.middleware("http")
async def authorize_http(request: Request, call_next):
    if LOCAL_TOKEN and request.headers.get("authorization") != f"Bearer {LOCAL_TOKEN}":
        from fastapi.responses import JSONResponse

        return JSONResponse(status_code=401, content={"detail": "invalid local token"})
    return await call_next(request)


class StartResp(BaseModel):
    session_id: str


class PushReq(BaseModel):
    session_id: str
    samples_b64: str
    sample_rate: int = SAMPLE_RATE


class PushResp(BaseModel):
    text: str
    latency_ms: int


class EndReq(BaseModel):
    session_id: str


class EndResp(BaseModel):
    text: str


@app.get("/health")
def health():
    return {
        "status": "ok",
        "service": SERVICE_NAME,
        "protocol_version": PROTOCOL_VERSION,
        "model_id": MODEL_ID,
        "model_sha256": MODEL_SHA256,
        "runtime_version": getattr(sherpa_onnx, "__version__", "unknown"),
    }


def _extract_text(result) -> str:
    if isinstance(result, str):
        return result
    return getattr(result, "text", "") or ""


def _cleanup_expired_sessions() -> None:
    now = time.monotonic()
    with sessions_lock:
        expired = [
            session_id
            for session_id, value in sessions.items()
            if session_expired(value[1], now, SESSION_TTL_SECONDS)
        ]
        for session_id in expired:
            sessions.pop(session_id, None)


def _create_stream():
    with lock:
        return recognizer.create_stream()


def _decode_chunk(stream, sample_rate: int, samples: np.ndarray) -> str:
    with lock:
        stream.accept_waveform(sample_rate, samples)
        while recognizer.is_ready(stream):
            recognizer.decode_stream(stream)
        return _extract_text(recognizer.get_result(stream))


def _finish_stream(stream) -> str:
    with lock:
        stream.input_finished()
        while recognizer.is_ready(stream):
            recognizer.decode_stream(stream)
        return _extract_text(recognizer.get_result(stream))


@app.post("/v1/fast_asr/start", response_model=StartResp)
def start_session():
    _cleanup_expired_sessions()
    session_id = uuid.uuid4().hex
    stream = _create_stream()
    with sessions_lock:
        sessions[session_id] = (stream, time.monotonic())
    return StartResp(session_id=session_id)


@app.post("/v1/fast_asr/push", response_model=PushResp)
def push_audio(req: PushReq):
    _cleanup_expired_sessions()
    with sessions_lock:
        session = sessions.get(req.session_id)
    if session is None:
        raise HTTPException(status_code=404, detail="session not found")
    stream = session[0]
    with sessions_lock:
        sessions[req.session_id] = (stream, time.monotonic())

    if not req.samples_b64:
        return PushResp(text="", latency_ms=0)

    try:
        data = base64.b64decode(req.samples_b64)
    except Exception as exc:
        raise HTTPException(status_code=400, detail=f"invalid base64: {exc}") from exc

    if not data:
        return PushResp(text="", latency_ms=0)

    samples = np.frombuffer(data, dtype=np.float32)
    if samples.size == 0:
        return PushResp(text="", latency_ms=0)

    started = time.time()
    text = _decode_chunk(stream, req.sample_rate, samples)
    latency_ms = int((time.time() - started) * 1000)
    return PushResp(text=text, latency_ms=latency_ms)


@app.post("/v1/fast_asr/end", response_model=EndResp)
def end_session(req: EndReq):
    with sessions_lock:
        session = sessions.pop(req.session_id, None)
    if session is None:
        raise HTTPException(status_code=404, detail="session not found")
    return EndResp(text=_finish_stream(session[0]))


@app.websocket("/v1/fast_asr/ws")
async def stream_audio(websocket: WebSocket):
    if LOCAL_TOKEN and websocket.headers.get("authorization") != f"Bearer {LOCAL_TOKEN}":
        await websocket.close(code=4401, reason="invalid local token")
        return

    await websocket.accept()
    stream = None
    session_id = None
    expected_sequence = 0
    received_frames = 0
    last_received_sequence = None
    latest_text = ""
    revision = 0
    stable_revision_count = 0
    last_text_change = time.monotonic()
    dirty_reason = None
    finish_cache = FinishReplyCache()

    try:
        first = await asyncio.wait_for(websocket.receive(), timeout=10)
        if first.get("type") == "websocket.disconnect":
            return
        if first.get("text") is None:
            await websocket.close(code=4400, reason="start message required")
            return
        start = json.loads(first["text"])
        try:
            validate_start_message(start, SAMPLE_RATE)
        except ValueError as exc:
            await websocket.close(code=4400, reason=str(exc))
            return

        session_id = str(start.get("session_id") or uuid.uuid4())
        stream = await asyncio.to_thread(_create_stream)
        await websocket.send_json(
            {
                "type": "started",
                "session_id": session_id,
                "protocol_version": PROTOCOL_VERSION,
                "model_id": MODEL_ID,
                "model_sha256": MODEL_SHA256,
            }
        )

        while True:
            message = await asyncio.wait_for(websocket.receive(), timeout=SESSION_TTL_SECONDS)
            if message.get("type") == "websocket.disconnect":
                return
            if message.get("bytes") is not None:
                if finish_cache.payload is not None:
                    dirty_reason = dirty_reason or "audio_after_finish"
                    continue
                payload = message["bytes"]
                try:
                    parsed = parse_audio_frame(payload, expected_sequence)
                except ValueError as exc:
                    dirty_reason = dirty_reason or str(exc)
                    await websocket.send_json({"type": "warning", "reason": str(exc)})
                    continue

                expected_sequence += 1
                last_received_sequence = parsed.sequence
                received_frames += parsed.frames
                samples = np.frombuffer(parsed.pcm, dtype="<f4")
                decode_started = time.perf_counter()
                text = await asyncio.to_thread(_decode_chunk, stream, SAMPLE_RATE, samples)
                latency_ms = int((time.perf_counter() - decode_started) * 1000)
                revision += 1
                now = time.monotonic()
                if text and text == latest_text:
                    stable_revision_count += 1
                else:
                    latest_text = text
                    stable_revision_count = 1 if text else 0
                    last_text_change = now
                await websocket.send_json(
                    {
                        "type": "partial",
                        "session_id": session_id,
                        "revision": revision,
                        "text": text,
                        "received_frames": received_frames,
                        "latency_ms": latency_ms,
                    }
                )
                continue

            if message.get("text") is None:
                continue
            control = json.loads(message["text"])
            if control.get("type") == "abort":
                await websocket.close(code=1000)
                return
            if control.get("type") != "finish":
                dirty_reason = dirty_reason or "unknown_control_message"
                continue
            if finish_cache.payload is not None:
                await websocket.send_json(finish_cache.payload)
                continue

            expected_frames = int(control.get("total_frames", -1))
            expected_last_sequence = control.get("last_sequence")
            if expected_last_sequence is not None:
                expected_last_sequence = int(expected_last_sequence)
            final_text = await asyncio.to_thread(_finish_stream, stream)
            integrity = validate_finish(
                received_frames=received_frames,
                expected_frames=expected_frames,
                last_received_sequence=last_received_sequence,
                expected_last_sequence=expected_last_sequence,
                dirty_reason=dirty_reason,
            )
            stable_duration_ms = int((time.monotonic() - last_text_change) * 1000)
            await websocket.send_json(
                {
                    "type": "final_segment",
                    "session_id": session_id,
                    "segment_id": 0,
                    "text": final_text,
                    "received_frames": received_frames,
                }
            )
            finished_payload = finish_cache.store({
                "type": "done",
                "session_id": session_id,
                "text": final_text,
                "received_frames": received_frames,
                "expected_frames": expected_frames,
                "last_sequence": last_received_sequence,
                "clean": integrity.clean,
                "truncated": integrity.truncated,
                "reason": integrity.reason,
                "stable_revision_count": stable_revision_count,
                "stable_duration_ms": stable_duration_ms,
                "model_id": MODEL_ID,
                "model_sha256": MODEL_SHA256,
                "protocol_version": PROTOCOL_VERSION,
            })
            await websocket.send_json(finished_payload)
    except (asyncio.TimeoutError, WebSocketDisconnect):
        return
    except (ValueError, json.JSONDecodeError) as exc:
        try:
            await websocket.send_json({"type": "error", "reason": str(exc)})
            await websocket.close(code=4400)
        except RuntimeError:
            pass


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=8790)

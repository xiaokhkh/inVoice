import asyncio
import hashlib
import importlib.metadata
import os
import sys
import tempfile
import time
from pathlib import Path

from fastapi import FastAPI, File, HTTPException, Request, UploadFile
from pydantic import BaseModel
import uvicorn
import numpy as np
import soundfile as sf

from inference_queue import SingleFlightInference

MODEL_ID = os.getenv("ASR_MODEL_ID", "mlx-community/GLM-ASR-Nano-2512-8bit")
LOCAL_TOKEN = os.getenv("VOICEOPS_LOCAL_TOKEN", "")
SERVICE_NAME = "voiceops-asr-mlx"
PROTOCOL_VERSION = 1
os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")


def _ensure_py39_compat() -> None:
    if sys.version_info >= (3, 10):
        return

    try:
        import site

        candidates = []
        if hasattr(site, "getsitepackages"):
            candidates.extend(site.getsitepackages())
        candidates.append(site.getusersitepackages())

        for base in candidates:
            if not base:
                continue
            dsp_path = Path(base) / "mlx_audio" / "dsp.py"
            if not dsp_path.exists():
                continue
            text = dsp_path.read_text(encoding="utf-8")
            if "from __future__ import annotations" in text:
                return
            parts = text.splitlines()
            if parts and parts[0].startswith('"""'):
                end = 1
                while end < len(parts) and not parts[end].startswith('"""'):
                    end += 1
                end = min(end + 1, len(parts))
                parts.insert(end, "")
                parts.insert(end + 1, "from __future__ import annotations")
            else:
                parts.insert(0, "from __future__ import annotations")
            dsp_path.write_text("\n".join(parts) + "\n", encoding="utf-8")
            return
    except Exception:
        pass


def _ensure_glmasr_no_torch_compat() -> None:
    """Remove mlx-audio's torch-only type annotation dependency.

    mlx-audio 0.2.x imports ``torch.nn`` in its STT generate helper solely for
    two ``nn.Module`` annotations. GLM-ASR imports the helper for ``wired_limit``
    and otherwise has no PyTorch runtime dependency.
    """
    try:
        import site

        candidates = []
        if hasattr(site, "getsitepackages"):
            candidates.extend(site.getsitepackages())
        candidates.append(site.getusersitepackages())

        for base in candidates:
            if not base:
                continue
            generate_path = Path(base) / "mlx_audio" / "stt" / "generate.py"
            if not generate_path.exists():
                continue
            text = generate_path.read_text(encoding="utf-8")
            if "import torch.nn as nn" not in text:
                return
            text = text.replace("import torch.nn as nn\n", "")
            text = text.replace(
                "from typing import List, Optional, Union",
                "from typing import Any, List, Optional, Union",
            )
            text = text.replace("nn.Module", "Any")
            generate_path.write_text(text, encoding="utf-8")
            return
    except Exception:
        pass


_ensure_py39_compat()
_ensure_glmasr_no_torch_compat()

from mlx_audio.stt.utils import load_model

app = FastAPI(title="ASR MLX Sidecar")
inference_queue = SingleFlightInference()


def _model_hash() -> str:
    explicit = os.getenv("ASR_MODEL_HASH", "").strip()
    if explicit:
        return explicit
    cache_root = Path(
        os.getenv("HF_HUB_CACHE")
        or (Path(os.getenv("HF_HOME", Path.home() / ".cache" / "huggingface")) / "hub")
    )
    cache_name = "models--" + MODEL_ID.replace("/", "--")
    revision_ref = cache_root / cache_name / "refs" / "main"
    if revision_ref.exists():
        try:
            return revision_ref.read_text(encoding="utf-8").strip()
        except OSError:
            pass
    return hashlib.sha256(MODEL_ID.encode("utf-8")).hexdigest()


MODEL_HASH = _model_hash()
try:
    RUNTIME_VERSION = importlib.metadata.version("mlx-audio")
except importlib.metadata.PackageNotFoundError:
    RUNTIME_VERSION = "unknown"

print(f"[asr] loading model: {MODEL_ID}")
_model = inference_queue.run(lambda: load_model(MODEL_ID)).value
print("[asr] model ready")


def _warm_up_model() -> None:
    try:
        sr = 16_000
        samples = np.zeros(sr, dtype="float32")
        with tempfile.NamedTemporaryFile(delete=False, suffix=".wav") as fp:
            path = fp.name
        sf.write(path, samples, sr)
        try:
            _model.generate(path, verbose=False)
        except Exception:
            pass
        try:
            os.remove(path)
        except Exception:
            pass
    except Exception:
        pass


inference_queue.run(_warm_up_model)


class TranscribeResp(BaseModel):
    text: str
    queue_ms: int
    infer_ms: int
    total_ms: int
    model_id: str = MODEL_ID
    model_hash: str = MODEL_HASH


def _authorize(request: Request) -> None:
    if LOCAL_TOKEN and request.headers.get("authorization") != f"Bearer {LOCAL_TOKEN}":
        raise HTTPException(status_code=401, detail="invalid local token")


@app.get("/health")
def health(request: Request):
    _authorize(request)
    return {
        "status": "ok",
        "service": SERVICE_NAME,
        "protocol_version": PROTOCOL_VERSION,
        "model_id": MODEL_ID,
        "model_hash": MODEL_HASH,
        "runtime_version": RUNTIME_VERSION,
    }


def _trim_silence(path: str, top_db: float = 40.0) -> int:
    try:
        audio, sr = sf.read(path, dtype="float32")
    except Exception:
        return -1

    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    if audio.size == 0:
        return 0

    frame = 1024
    hop = 256
    if audio.size < frame:
        return int(audio.size)

    rms = []
    for i in range(0, audio.size - frame + 1, hop):
        chunk = audio[i : i + frame]
        rms.append(np.sqrt(np.mean(chunk * chunk)))

    if not rms:
        return 0
    rms = np.array(rms)
    max_rms = float(rms.max())
    if max_rms <= 0:
        return 0

    threshold = max_rms * (10 ** (-top_db / 20))
    idx = np.where(rms > threshold)[0]
    if idx.size == 0:
        return 0

    pad = int(sr * 0.05)
    start = max(0, int(idx[0] * hop - pad))
    end = min(audio.size, int(idx[-1] * hop + frame + pad))
    trimmed = audio[start:end]
    if trimmed.size == 0:
        return 0

    if trimmed.size != audio.size:
        sf.write(path, trimmed, sr)
    return int(trimmed.size)


def _generate_text(path: str) -> str:
    try:
        result = _model.generate(path, verbose=False)
    except ValueError as exc:
        if "Input is too short" in str(exc):
            return ""
        raise

    if isinstance(result, dict):
        text = (result.get("text", "") or "").strip()
        segments = result.get("segments")
    else:
        text = (getattr(result, "text", "") or "").strip()
        segments = getattr(result, "segments", None)
    if not text and segments:
        try:
            text = " ".join(segment.get("text", "").strip() for segment in segments).strip()
        except Exception:
            return ""
    return text


async def _transcribe_path(tmp_path: str, byte_len: int, recv_ms: int, write_ms: int) -> TranscribeResp:
    total_started = time.perf_counter()
    trim_started = time.perf_counter()
    trimmed_len = await asyncio.to_thread(_trim_silence, tmp_path)
    trim_ms = int((time.perf_counter() - trim_started) * 1000)

    if 0 <= trimmed_len < 400:
        timing_queue_ms = 0
        timing_infer_ms = 0
        text = ""
    else:
        timing = await inference_queue.run_async(lambda: _generate_text(tmp_path))
        timing_queue_ms = timing.queue_ms
        timing_infer_ms = timing.infer_ms
        text = timing.value

    total_ms = int((time.perf_counter() - total_started) * 1000) + recv_ms + write_ms
    print(
        f"[asr_perf] bytes={byte_len} recv_ms={recv_ms} write_ms={write_ms} "
        f"trim_ms={trim_ms} queue_ms={timing_queue_ms} infer_ms={timing_infer_ms} "
        f"total_ms={total_ms} trimmed={trimmed_len}"
    )
    return TranscribeResp(
        text=text,
        queue_ms=timing_queue_ms,
        infer_ms=timing_infer_ms,
        total_ms=total_ms,
    )


@app.post("/v1/asr/transcribe", response_model=TranscribeResp)
async def transcribe(request: Request, file: UploadFile = File(...)):
    _authorize(request)
    receive_started = time.perf_counter()
    data = await file.read()
    recv_ms = int((time.perf_counter() - receive_started) * 1000)
    write_started = time.perf_counter()
    with tempfile.NamedTemporaryFile(delete=False, suffix=".wav") as fp:
        fp.write(data)
        tmp_path = fp.name
    write_ms = int((time.perf_counter() - write_started) * 1000)
    try:
        return await _transcribe_path(tmp_path, len(data), recv_ms, write_ms)
    finally:
        try:
            os.remove(tmp_path)
        except OSError:
            pass


@app.post("/v1/asr/transcribe-wav", response_model=TranscribeResp)
async def transcribe_wav(request: Request):
    _authorize(request)
    receive_started = time.perf_counter()
    byte_len = 0
    with tempfile.NamedTemporaryFile(delete=False, suffix=".wav") as fp:
        tmp_path = fp.name
        async for chunk in request.stream():
            byte_len += len(chunk)
            fp.write(chunk)
    recv_ms = int((time.perf_counter() - receive_started) * 1000)
    try:
        return await _transcribe_path(tmp_path, byte_len, recv_ms, 0)
    finally:
        try:
            os.remove(tmp_path)
        except OSError:
            pass


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=8765)

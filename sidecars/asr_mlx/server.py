import os
import sys
import tempfile
import time
from pathlib import Path

from fastapi import FastAPI, UploadFile, File
from pydantic import BaseModel
import uvicorn
import numpy as np
import soundfile as sf

MODEL_ID = os.getenv("ASR_MODEL_ID", "mlx-community/GLM-ASR-Nano-2512-8bit")
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

print(f"[asr] loading model: {MODEL_ID}")
_model = load_model(MODEL_ID)
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


_warm_up_model()


class TranscribeResp(BaseModel):
    text: str


@app.get("/health")
def health():
    return {"status": "ok", "model": MODEL_ID}


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


@app.post("/v1/asr/transcribe", response_model=TranscribeResp)
async def transcribe(file: UploadFile = File(...)):
    t0 = time.perf_counter()
    suffix = ".wav" if file.filename.endswith(".wav") else ".wav"
    data = await file.read()
    t1 = time.perf_counter()
    byte_len = len(data)
    with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as fp:
        fp.write(data)
        tmp_path = fp.name
    t2 = time.perf_counter()

    try:
        trimmed_len = _trim_silence(tmp_path)
        t3 = time.perf_counter()
        if 0 <= trimmed_len < 400:
            total_ms = int((time.perf_counter() - t0) * 1000)
            recv_ms = int((t1 - t0) * 1000)
            write_ms = int((t2 - t1) * 1000)
            trim_ms = int((t3 - t2) * 1000)
            print(
                f"[asr_perf] bytes={byte_len} recv_ms={recv_ms} write_ms={write_ms} "
                f"trim_ms={trim_ms} infer_ms=0 total_ms={total_ms} trimmed={trimmed_len}"
            )
            return TranscribeResp(text="")

        try:
            t4 = time.perf_counter()
            res = _model.generate(tmp_path, verbose=False)
            t5 = time.perf_counter()
        except ValueError as exc:
            if "Input is too short" in str(exc):
                total_ms = int((time.perf_counter() - t0) * 1000)
                recv_ms = int((t1 - t0) * 1000)
                write_ms = int((t2 - t1) * 1000)
                trim_ms = int((t3 - t2) * 1000)
                print(
                    f"[asr_perf] bytes={byte_len} recv_ms={recv_ms} write_ms={write_ms} "
                    f"trim_ms={trim_ms} infer_ms=0 total_ms={total_ms} trimmed={trimmed_len}"
                )
                return TranscribeResp(text="")
            raise
        if isinstance(res, dict):
            text = (res.get("text", "") or "").strip()
            segments = res.get("segments")
        else:
            text = (getattr(res, "text", "") or "").strip()
            segments = getattr(res, "segments", None)
        if not text and segments:
            try:
                text = " ".join(seg.get("text", "").strip() for seg in segments).strip()
            except Exception:
                text = ""
        total_ms = int((time.perf_counter() - t0) * 1000)
        recv_ms = int((t1 - t0) * 1000)
        write_ms = int((t2 - t1) * 1000)
        trim_ms = int((t3 - t2) * 1000)
        infer_ms = int((t5 - t4) * 1000)
        print(
            f"[asr_perf] bytes={byte_len} recv_ms={recv_ms} write_ms={write_ms} "
            f"trim_ms={trim_ms} infer_ms={infer_ms} total_ms={total_ms} trimmed={trimmed_len}"
        )
        return TranscribeResp(text=text)
    finally:
        try:
            os.remove(tmp_path)
        except Exception:
            pass


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=8765)

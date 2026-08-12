# ASR MLX Sidecar

FastAPI wrapper around mlx-audio.

Start:

```
../../scripts/install.sh
./.venv/bin/python server.py
```

The installer deliberately installs `mlx-audio==0.2.10` with `--no-deps`, then
uses `requirements.txt` for the minimal ASR dependency set. Installing the
upstream package normally also resolves unrelated TTS and WebRTC extras.

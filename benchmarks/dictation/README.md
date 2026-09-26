# Dictation model gate

`manifest.jsonl` is intentionally not committed: it contains reference and
human-corrected speech text. Keep the audio and manifest in a controlled local
directory. Each JSONL row has this shape:

```json
{"id":"zh-001","category":"zh","reference":"参考文本","human_revision":"人工修订文本","terms":["MLX"],"audio":"audio/zh-001.wav","outputs":{"glm":{"text":"...","stop_to_final_ms":431},"zipformer":{"text":"...","stop_to_final_ms":180},"paraformer":{"text":"...","stop_to_final_ms":210}}}
```

Required fixed-corpus composition is 80 `zh`, 40 `en`, 60 `mixed`, and 20
`terms` rows. Do not enable streaming finals from an incomplete or changing
corpus.

Evaluate one or more candidates against GLM:

```bash
python3 scripts/evaluate_dictation_corpus.py benchmarks/dictation/manifest.jsonl \
  --candidate zipformer --candidate paraformer
```

The command exits non-zero unless corpus counts are complete, every result is
present, CER/WER and term-retention gates pass, and candidate stop-to-final p95
is at most 250 ms. It never downloads a model or sends corpus content.

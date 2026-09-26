import struct
from dataclasses import dataclass
from typing import Any, Dict, Optional


PROTOCOL_VERSION = 1
PCM_FORMAT = "f32le"


@dataclass(frozen=True)
class ParsedAudioFrame:
    sequence: int
    pcm: bytes
    frames: int


@dataclass(frozen=True)
class IntegrityResult:
    clean: bool
    truncated: bool
    reason: Optional[str]


class FinishReplyCache:
    """Stores the first done reply so repeated finish is side-effect free."""

    def __init__(self) -> None:
        self.payload: Optional[Dict[str, Any]] = None

    def store(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        if self.payload is None:
            self.payload = payload
        return self.payload


def validate_start_message(payload: Dict[str, Any], sample_rate: int) -> None:
    if payload.get("type") != "start":
        raise ValueError("start_message_required")
    if payload.get("protocol_version") != PROTOCOL_VERSION:
        raise ValueError("protocol_mismatch")
    if (
        payload.get("sample_rate") != sample_rate
        or payload.get("channels") != 1
        or payload.get("format") != PCM_FORMAT
    ):
        raise ValueError("unsupported_audio_format")


def session_expired(last_seen: float, now: float, ttl_seconds: float) -> bool:
    return now - last_seen >= ttl_seconds


def parse_audio_frame(payload: bytes, expected_sequence: int) -> ParsedAudioFrame:
    if len(payload) < 8:
        raise ValueError("binary_frame_too_short")
    sequence = struct.unpack("<Q", payload[:8])[0]
    if sequence != expected_sequence:
        raise ValueError("sequence_gap")
    pcm = payload[8:]
    if not pcm or len(pcm) % 4 != 0:
        raise ValueError("invalid_pcm_length")
    return ParsedAudioFrame(sequence=sequence, pcm=pcm, frames=len(pcm) // 4)


def validate_finish(
    *,
    received_frames: int,
    expected_frames: int,
    last_received_sequence: Optional[int],
    expected_last_sequence: Optional[int],
    dirty_reason: Optional[str] = None,
) -> IntegrityResult:
    reason = dirty_reason
    if reason is None and received_frames != expected_frames:
        reason = "frame_count_mismatch"
    if reason is None and last_received_sequence != expected_last_sequence:
        reason = "last_sequence_mismatch"
    return IntegrityResult(clean=reason is None, truncated=reason is not None, reason=reason)

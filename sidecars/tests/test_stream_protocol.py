import struct
import unittest

from sidecars.fast_asr.stream_protocol import (
    FinishReplyCache,
    parse_audio_frame,
    session_expired,
    validate_finish,
    validate_start_message,
)


class StreamProtocolTests(unittest.TestCase):
    def test_parses_sequence_header_and_float32_payload(self):
        parsed = parse_audio_frame(struct.pack("<Qff", 4, 0.25, -0.5), expected_sequence=4)
        self.assertEqual(parsed.sequence, 4)
        self.assertEqual(parsed.frames, 2)

    def test_rejects_sequence_gap(self):
        with self.assertRaisesRegex(ValueError, "sequence_gap"):
            parse_audio_frame(struct.pack("<Qf", 6, 0.25), expected_sequence=5)

    def test_finish_requires_matching_frame_and_sequence_counts(self):
        clean = validate_finish(
            received_frames=1600,
            expected_frames=1600,
            last_received_sequence=3,
            expected_last_sequence=3,
        )
        self.assertTrue(clean.clean)

        dirty = validate_finish(
            received_frames=1200,
            expected_frames=1600,
            last_received_sequence=3,
            expected_last_sequence=3,
        )
        self.assertEqual(dirty.reason, "frame_count_mismatch")

    def test_handshake_rejects_protocol_or_format_mismatch(self):
        valid = {
            "type": "start",
            "protocol_version": 1,
            "sample_rate": 16000,
            "channels": 1,
            "format": "f32le",
        }
        validate_start_message(valid, 16000)
        with self.assertRaisesRegex(ValueError, "protocol_mismatch"):
            validate_start_message({**valid, "protocol_version": 2}, 16000)
        with self.assertRaisesRegex(ValueError, "unsupported_audio_format"):
            validate_start_message({**valid, "format": "s16le"}, 16000)

    def test_ttl_and_duplicate_finish_are_deterministic(self):
        self.assertFalse(session_expired(last_seen=10, now=129.9, ttl_seconds=120))
        self.assertTrue(session_expired(last_seen=10, now=130, ttl_seconds=120))
        cache = FinishReplyCache()
        first = cache.store({"type": "done", "text": "first"})
        second = cache.store({"type": "done", "text": "second"})
        self.assertIs(first, second)
        self.assertEqual(second["text"], "first")

    def test_500_simulated_sessions_preserve_order_frames_and_tail(self):
        for session_index in range(500):
            chunk_frames = [1600, 1600, 137 + (session_index % 11)]
            received_frames = 0
            last_sequence = None
            for sequence, frames in enumerate(chunk_frames):
                payload = struct.pack("<Q", sequence) + (b"\0\0\0\0" * frames)
                parsed = parse_audio_frame(payload, expected_sequence=sequence)
                received_frames += parsed.frames
                last_sequence = parsed.sequence
            integrity = validate_finish(
                received_frames=received_frames,
                expected_frames=sum(chunk_frames),
                last_received_sequence=last_sequence,
                expected_last_sequence=len(chunk_frames) - 1,
            )
            self.assertTrue(integrity.clean)


if __name__ == "__main__":
    unittest.main()

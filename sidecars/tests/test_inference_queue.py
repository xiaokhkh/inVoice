import asyncio
import threading
import time
import unittest

from sidecars.asr_mlx.inference_queue import SingleFlightInference


class SingleFlightInferenceTests(unittest.TestCase):
    def test_sync_load_and_async_inference_share_one_worker_thread(self):
        queue = SingleFlightInference()
        load_thread = queue.run(threading.get_ident).value

        async def infer_thread():
            return (await queue.run_async(threading.get_ident)).value

        self.assertEqual(asyncio.run(infer_thread()), load_thread)

    def test_serializes_concurrent_work_and_reports_queue_time(self):
        queue = SingleFlightInference()
        active = 0
        maximum_active = 0
        state_lock = threading.Lock()

        def operation():
            nonlocal active, maximum_active
            with state_lock:
                active += 1
                maximum_active = max(maximum_active, active)
            time.sleep(0.03)
            with state_lock:
                active -= 1
            return "ok"

        async def run_pair():
            return await asyncio.gather(queue.run_async(operation), queue.run_async(operation))

        results = asyncio.run(run_pair())
        self.assertEqual(maximum_active, 1)
        self.assertEqual([result.value for result in results], ["ok", "ok"])
        self.assertGreaterEqual(max(result.queue_ms for result in results), 20)


if __name__ == "__main__":
    unittest.main()

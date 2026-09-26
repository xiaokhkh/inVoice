import asyncio
import concurrent.futures
import functools
import time
from dataclasses import dataclass
from typing import Callable, Generic, TypeVar


T = TypeVar("T")


@dataclass(frozen=True)
class InferenceTiming(Generic[T]):
    value: T
    queue_ms: int
    infer_ms: int


class SingleFlightInference:
    """Runs every ML operation on one stable worker thread.

    MLX keeps GPU stream state per thread. A generic ``asyncio.to_thread`` pool
    can load or warm the model on one thread and execute it on another, which
    makes Metal reject the cached stream. A dedicated single-worker executor
    preserves both serialization and thread affinity.
    """

    def __init__(self) -> None:
        self._executor = concurrent.futures.ThreadPoolExecutor(
            max_workers=1,
            thread_name_prefix="voiceops-glm-asr",
        )

    def run(self, operation: Callable[[], T]) -> InferenceTiming[T]:
        queued_at = time.perf_counter()
        return self._executor.submit(self._execute, queued_at, operation).result()

    def _execute(self, queued_at: float, operation: Callable[[], T]) -> InferenceTiming[T]:
        started_at = time.perf_counter()
        value = operation()
        finished_at = time.perf_counter()
        return InferenceTiming(
            value=value,
            queue_ms=int((started_at - queued_at) * 1000),
            infer_ms=int((finished_at - started_at) * 1000),
        )

    async def run_async(self, operation: Callable[[], T]) -> InferenceTiming[T]:
        queued_at = time.perf_counter()
        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(
            self._executor,
            functools.partial(self._execute, queued_at, operation),
        )

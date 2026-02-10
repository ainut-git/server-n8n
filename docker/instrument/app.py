import asyncio
import logging
import time
from fastapi import FastAPI
from pydantic import BaseModel, Field

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("instrument")

app = FastAPI(title="Instrument Service")

MAX_OUTPUT_BYTES = 10 * 1024 * 1024  # 10 MB


class RunRequest(BaseModel):
    command: str
    timeout: int = Field(default=300, ge=1, le=3600)


class RunResponse(BaseModel):
    stdout: str
    stderr: str
    exit_code: int
    timed_out: bool
    truncated: bool = False


def truncate_output(data: bytes, limit: int = MAX_OUTPUT_BYTES) -> tuple[str, bool]:
    if len(data) > limit:
        return data[:limit].decode(errors="replace") + "\n... [truncated]", True
    return data.decode(errors="replace"), False


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.post("/run", response_model=RunResponse)
async def run_command(req: RunRequest):
    logger.info("Command: %s (timeout=%ds)", req.command[:200], req.timeout)
    start = time.monotonic()
    timed_out = False
    truncated = False
    try:
        proc = await asyncio.create_subprocess_shell(
            req.command,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd="/data",
        )
        try:
            stdout, stderr = await asyncio.wait_for(
                proc.communicate(), timeout=req.timeout
            )
        except asyncio.TimeoutError:
            proc.kill()
            stdout, stderr = await proc.communicate()
            timed_out = True

        stdout_str, t1 = truncate_output(stdout)
        stderr_str, t2 = truncate_output(stderr)
        truncated = t1 or t2
        exit_code = proc.returncode if proc.returncode is not None else -1

        elapsed = time.monotonic() - start
        logger.info("Done: exit=%d time=%.1fs timed_out=%s truncated=%s", exit_code, elapsed, timed_out, truncated)

        return RunResponse(
            stdout=stdout_str,
            stderr=stderr_str,
            exit_code=exit_code,
            timed_out=timed_out,
            truncated=truncated,
        )
    except Exception as e:
        elapsed = time.monotonic() - start
        logger.error("Failed: %s time=%.1fs", str(e), elapsed)
        return RunResponse(
            stdout="",
            stderr=str(e),
            exit_code=-1,
            timed_out=False,
            truncated=False,
        )

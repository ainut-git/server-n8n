import asyncio
from fastapi import FastAPI
from pydantic import BaseModel, Field

app = FastAPI(title="Instrument Service")


class RunRequest(BaseModel):
    command: str
    timeout: int = Field(default=300, ge=1, le=3600)


class RunResponse(BaseModel):
    stdout: str
    stderr: str
    exit_code: int
    timed_out: bool


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.post("/run", response_model=RunResponse)
async def run_command(req: RunRequest):
    timed_out = False
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

        return RunResponse(
            stdout=stdout.decode(errors="replace"),
            stderr=stderr.decode(errors="replace"),
            exit_code=proc.returncode if proc.returncode is not None else -1,
            timed_out=timed_out,
        )
    except Exception as e:
        return RunResponse(
            stdout="",
            stderr=str(e),
            exit_code=-1,
            timed_out=False,
        )

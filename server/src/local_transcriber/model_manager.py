from __future__ import annotations

import asyncio
import json
import shutil
import sys
from contextlib import suppress
from dataclasses import asdict
from pathlib import Path

from .config import Settings
from .database import SessionLocal
from .model_catalog import MODEL_CATALOG, ModelDefinition
from .models import ModelJobRecord, utc_now


class ModelManagerError(RuntimeError):
    pass


class ModelManager:
    def __init__(self, config: Settings) -> None:
        self.config = config
        self._tasks: dict[str, asyncio.Task[None]] = {}
        self._processes: dict[str, asyncio.subprocess.Process] = {}
        self._lock = asyncio.Lock()

    def model_path(self, definition: ModelDefinition) -> Path:
        return self.config.models_dir / definition.directory_name

    def list_models(self) -> list[dict]:
        latest_by_model: dict[str, ModelJobRecord] = {}
        with SessionLocal() as db:
            jobs = (
                db.query(ModelJobRecord)
                .order_by(ModelJobRecord.created_at.desc())
                .all()
            )
            for job in jobs:
                latest_by_model.setdefault(job.model_id, job)
        results = []
        for definition in MODEL_CATALOG.values():
            job = latest_by_model.get(definition.id)
            results.append(
                {
                    **asdict(definition),
                    "installed": self.model_path(definition).exists(),
                    "job_id": job.id if job else None,
                    "job_state": job.state if job else None,
                    "job_phase": job.phase if job else None,
                }
            )
        return results

    def get_job(self, job_id: str) -> ModelJobRecord | None:
        with SessionLocal() as db:
            return db.get(ModelJobRecord, job_id)

    async def start_download(self, model_id: str, token: str | None) -> ModelJobRecord:
        definition = MODEL_CATALOG.get(model_id)
        if definition is None:
            raise ModelManagerError("指定されたモデルはありません。")
        if self.model_path(definition).exists():
            raise ModelManagerError("モデルは既に導入されています。")
        if definition.requires_token and not token:
            raise ModelManagerError("このモデルの取得にはHugging Face Tokenが必要です。")
        if definition.approximate_size_bytes is not None:
            available = shutil.disk_usage(self.config.models_dir).free
            required = int(definition.approximate_size_bytes * 1.5)
            if available < required:
                raise ModelManagerError(
                    "モデルを取得する空き容量が不足しています。"
                    f"少なくとも約{required // 1_000_000} MB必要です。"
                )
        async with self._lock:
            if any(not task.done() for task in self._tasks.values()):
                raise ModelManagerError("別のモデルをダウンロードしています。")
            with SessionLocal() as db:
                job = ModelJobRecord(model_id=model_id)
                db.add(job)
                db.commit()
                db.refresh(job)
                job_id = job.id
            self._tasks[job_id] = asyncio.create_task(
                self._run_download(job_id, definition, token)
            )
            return self.get_job(job_id)  # type: ignore[return-value]

    async def _run_download(
        self, job_id: str, definition: ModelDefinition, token: str | None
    ) -> None:
        staging = self.config.models_dir / ".staging" / definition.id
        cache = self.config.data_dir / "cache" / "huggingface"
        final = self.model_path(definition)
        with SessionLocal() as db:
            job = db.get(ModelJobRecord, job_id)
            if job:
                job.state = "running"
                job.phase = "starting"
                db.commit()
        process: asyncio.subprocess.Process | None = None
        try:
            worker_prefix = (
                [sys.executable, "_model_download_worker"]
                if getattr(sys, "frozen", False)
                else [
                    sys.executable,
                    "-m",
                    "local_transcriber.model_download_worker",
                ]
            )
            process = await asyncio.create_subprocess_exec(
                *worker_prefix,
                definition.id,
                definition.repo_id,
                definition.revision,
                str(staging),
                str(final),
                str(cache),
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            self._processes[job_id] = process
            assert process.stdin is not None
            process.stdin.write(
                json.dumps({"hfToken": token}).encode()
            )
            await process.stdin.drain()
            process.stdin.close()
            assert process.stdout is not None
            assert process.stderr is not None
            stderr_task = asyncio.create_task(process.stderr.read())
            async for line in process.stdout:
                try:
                    payload = json.loads(line)
                except (json.JSONDecodeError, UnicodeDecodeError):
                    continue
                with SessionLocal() as db:
                    job = db.get(ModelJobRecord, job_id)
                    if job:
                        job.phase = str(payload.get("phase") or job.phase)
                        db.commit()
            return_code = await process.wait()
            stderr = await stderr_task
            if return_code:
                detail = stderr.decode(errors="replace").strip()
                if token:
                    detail = detail.replace(token, "[redacted]")
                raise ModelManagerError(detail or "モデルの取得に失敗しました。")
            with SessionLocal() as db:
                job = db.get(ModelJobRecord, job_id)
                if job:
                    job.state = "completed"
                    job.phase = "completed"
                    job.progress = 1.0
                    job.completed_at = utc_now()
                    db.commit()
        except asyncio.CancelledError:
            if process and process.returncode is None:
                process.terminate()
                await process.wait()
            self._finish_cancelled(job_id)
            raise
        except Exception as exc:
            detail = str(exc)
            if token:
                detail = detail.replace(token, "[redacted]")
            with SessionLocal() as db:
                job = db.get(ModelJobRecord, job_id)
                if job:
                    job.state = "error"
                    job.phase = "error"
                    job.error_code = "download_failed"
                    job.error_message = detail
                    job.completed_at = utc_now()
                    db.commit()
        finally:
            self._processes.pop(job_id, None)

    def _finish_cancelled(self, job_id: str) -> None:
        with SessionLocal() as db:
            job = db.get(ModelJobRecord, job_id)
            if job:
                job.state = "cancelled"
                job.phase = "cancelled"
                job.completed_at = utc_now()
                db.commit()

    async def cancel(self, job_id: str) -> ModelJobRecord:
        task = self._tasks.get(job_id)
        job = self.get_job(job_id)
        if job is None:
            raise ModelManagerError("ダウンロードジョブが見つかりません。")
        if job.state not in {"queued", "running"}:
            raise ModelManagerError("このジョブは停止できません。")
        if task and not task.done():
            task.cancel()
            with suppress(asyncio.CancelledError):
                await task
        else:
            self._finish_cancelled(job_id)
        return self.get_job(job_id)  # type: ignore[return-value]

    def recover_interrupted_jobs(self) -> None:
        with SessionLocal() as db:
            jobs = (
                db.query(ModelJobRecord)
                .filter(ModelJobRecord.state.in_(["queued", "running"]))
                .all()
            )
            for job in jobs:
                job.state = "error"
                job.phase = "interrupted"
                job.error_code = "server_restarted"
                job.error_message = "サーバー再起動によりダウンロードが中断されました。"
                job.completed_at = utc_now()
            db.commit()

    async def shutdown(self) -> None:
        tasks = [task for task in self._tasks.values() if not task.done()]
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)


model_manager: ModelManager | None = None


def get_model_manager(config: Settings) -> ModelManager:
    global model_manager
    if model_manager is None or model_manager.config is not config:
        model_manager = ModelManager(config)
    return model_manager

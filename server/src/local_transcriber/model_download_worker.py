from __future__ import annotations

import json
import os
import sys
from pathlib import Path


def emit(phase: str) -> None:
    print(json.dumps({"phase": phase}), flush=True)


def validate_model(model_id: str, path: Path) -> None:
    required = (
        ("config.json", "model.bin")
        if model_id == "whisper-small"
        else ("config.yaml",)
    )
    missing = [name for name in required if not (path / name).exists()]
    if missing:
        raise RuntimeError(f"必須ファイルがありません: {', '.join(missing)}")


def main() -> None:
    if len(sys.argv) != 7:
        raise SystemExit(
            "usage: model_download_worker MODEL_ID REPO REVISION STAGING FINAL CACHE"
        )
    model_id, repo_id, revision = sys.argv[1:4]
    staging_path = Path(sys.argv[4])
    final_path = Path(sys.argv[5])
    cache_path = Path(sys.argv[6])
    secret = json.loads(sys.stdin.read() or "{}")
    token = secret.get("hfToken")

    os.environ["HF_HUB_OFFLINE"] = "0"
    os.environ["TRANSFORMERS_OFFLINE"] = "0"
    os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
    from huggingface_hub import snapshot_download

    staging_path.mkdir(parents=True, exist_ok=True)
    cache_path.mkdir(parents=True, exist_ok=True)
    emit("resolving")
    emit("downloading")
    snapshot_download(
        repo_id,
        revision=revision,
        local_dir=staging_path,
        cache_dir=cache_path,
        token=token,
    )
    emit("verifying")
    validate_model(model_id, staging_path)
    if final_path.exists():
        raise RuntimeError("モデルは既に導入されています。")
    staging_path.replace(final_path)
    emit("completed")


if __name__ == "__main__":
    main()

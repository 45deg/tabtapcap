from __future__ import annotations

import argparse
import os
import sys

from .config import settings


def serve(args: argparse.Namespace) -> None:
    import uvicorn

    application: object | str
    if args.reload:
        application = "local_transcriber.api:app"
    else:
        from .api import app

        application = app
    uvicorn.run(
        application,
        host=settings.host,
        port=settings.port,
        reload=args.reload,
    )


def model_status(_args: argparse.Namespace) -> None:
    from .transcription import TranscriptionEngine

    for name, ready in TranscriptionEngine(settings).model_status().items():
        print(f"{name}: {'ready' if ready else 'missing'}")


def download_models(args: argparse.Namespace) -> None:
    try:
        from huggingface_hub import snapshot_download
    except ImportError:
        sys.exit("uv sync --project server --extra transcriptionを先に実行してください。")
    settings.ensure_directories()
    token = os.environ.get("HF_TOKEN")
    print("Whisper smallモデルを取得しています…")
    snapshot_download(
        "Systran/faster-whisper-small",
        local_dir=settings.models_dir / "faster-whisper-small",
    )
    if not args.diarization:
        print("Whisperモデルの取得が完了しました。")
        return
    if not token:
        sys.exit(
            "Whisperは取得しました。--diarizationには利用条件への同意と"
            "HF_TOKENが必要です。"
        )
    print("pyannote community-1モデルを取得しています…")
    snapshot_download(
        "pyannote/speaker-diarization-community-1",
        local_dir=settings.models_dir / "speaker-diarization-community-1",
        token=token,
    )
    print("モデルの取得が完了しました。")


def allow_extension(args: argparse.Namespace) -> None:
    config = settings.load_local_config()
    if args.extension_id not in config.allowed_extension_ids:
        config.allowed_extension_ids.append(args.extension_id)
    settings.save_local_config(config)
    print(f"許可しました: {args.extension_id}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="local-transcriber")
    subcommands = parser.add_subparsers(required=True)

    serve_parser = subcommands.add_parser("serve")
    serve_parser.add_argument("--reload", action="store_true")
    serve_parser.set_defaults(handler=serve)

    models_parser = subcommands.add_parser("models")
    model_subcommands = models_parser.add_subparsers(required=True)
    status_parser = model_subcommands.add_parser("status")
    status_parser.set_defaults(handler=model_status)
    download_parser = model_subcommands.add_parser("download")
    download_parser.add_argument(
        "--diarization",
        action="store_true",
        help="利用条件への同意が必要なpyannote話者分離モデルも取得します",
    )
    download_parser.set_defaults(handler=download_models)

    config_parser = subcommands.add_parser("config")
    config_subcommands = config_parser.add_subparsers(required=True)
    allow_parser = config_subcommands.add_parser("allow-extension")
    allow_parser.add_argument("extension_id")
    allow_parser.set_defaults(handler=allow_extension)
    return parser


def main() -> None:
    args = build_parser().parse_args()
    args.handler(args)


if __name__ == "__main__":
    main()

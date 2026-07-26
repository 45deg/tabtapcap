from __future__ import annotations

import sys


def main() -> None:
    if len(sys.argv) > 1 and sys.argv[1] == "_model_download_worker":
        from local_transcriber.model_download_worker import main as worker_main

        sys.argv = ["model_download_worker", *sys.argv[2:]]
        worker_main()
        return
    if len(sys.argv) > 1 and sys.argv[1] == "_diarization_worker":
        from local_transcriber.diarization_worker import main as worker_main

        sys.argv = ["diarization_worker", *sys.argv[2:]]
        worker_main()
        return
    from local_transcriber.cli import main as cli_main

    cli_main()


if __name__ == "__main__":
    main()

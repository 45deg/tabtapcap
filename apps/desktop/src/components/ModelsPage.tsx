import { useCallback, useEffect, useState } from "react";
import { api } from "../api";
import type { ModelInfo, ModelJob } from "../types";

const phaseLabels: Record<string, string> = {
  queued: "待機中",
  starting: "開始しています",
  resolving: "ファイルを確認しています",
  downloading: "ダウンロードしています",
  verifying: "検証しています",
  completed: "導入済み",
  cancelled: "キャンセルしました",
  interrupted: "中断されました",
  error: "エラー"
};

function formatBytes(bytes: number | null): string | null {
  if (bytes === null) return null;
  return `${Math.round(bytes / 1_000_000)} MB`;
}

export function ModelsPage({ onError }: { onError: (message: string) => void }) {
  const [models, setModels] = useState<ModelInfo[]>([]);
  const [jobs, setJobs] = useState<Record<string, ModelJob>>({});
  const [loading, setLoading] = useState(true);

  const refresh = useCallback(async () => {
    const next = (await api.models()).filter((model) => model.id !== "pyannote-community-1");
    setModels(next);
    const activeJobs = next.filter((model) => model.job_id).map(async (model) => {
      const job = await api.modelJob(model.job_id!);
      return [model.id, job] as const;
    });
    setJobs(Object.fromEntries(await Promise.all(activeJobs)));
    setLoading(false);
  }, []);

  useEffect(() => {
    void refresh().catch((reason: Error) => onError(reason.message));
  }, [onError, refresh]);

  useEffect(() => {
    if (!Object.values(jobs).some((job) => ["queued", "running"].includes(job.state))) return;
    const timer = window.setInterval(() => {
      void refresh().catch(() => undefined);
    }, 1_000);
    return () => window.clearInterval(timer);
  }, [jobs, refresh]);

  async function startDownload(model: ModelInfo): Promise<void> {
    try {
      const job = await api.downloadModel(model.id);
      setJobs((current) => ({ ...current, [model.id]: job }));
      await refresh();
    } catch (reason) {
      onError(reason instanceof Error ? reason.message : String(reason));
    }
  }

  return (
    <section className="management-page" aria-labelledby="models-title">
      <header className="management-header">
        <div>
          <h2 id="models-title">モデル</h2>
          <p>文字起こしと発話区間検出に使うモデルを、このMacへ保存します。</p>
        </div>
      </header>
      {loading ? (
        <p className="empty-transcript">モデルを確認しています…</p>
      ) : (
        <div className="model-grid">
          {models.map((model) => {
            const job = jobs[model.id];
            const active = job && ["queued", "running"].includes(job.state);
            return (
              <article className="model-card" key={model.id}>
                <div className="model-card-heading">
                  <div>
                    <h3>{model.name}</h3>
                    <p>{model.purpose}</p>
                  </div>
                  <span className={model.installed ? "model-state ready" : "model-state"}>
                    {model.installed ? "導入済み" : "未導入"}
                  </span>
                </div>
                {formatBytes(model.approximate_size_bytes) && (
                  <p className="model-meta">目安 {formatBytes(model.approximate_size_bytes)}</p>
                )}
                {job && (
                  <div className={`job-status ${job.state === "error" ? "error" : ""}`}>
                    <span>{phaseLabels[job.phase] ?? job.phase}</span>
                    {active && <progress aria-label="モデルのダウンロード進行中" />}
                    {job.error_message && <p>{job.error_message}</p>}
                  </div>
                )}
                {!model.installed && (
                  <div className="model-actions">
                    <button
                      type="button"
                      className="button primary"
                      disabled={Boolean(active)}
                      onClick={() => void startDownload(model)}
                    >
                      {active ? "取得中…" : "ダウンロード"}
                    </button>
                    {active && job && (
                      <button
                        type="button"
                        className="button secondary"
                        onClick={async () => {
                          await api.cancelModelJob(job.id);
                          await refresh();
                        }}
                      >
                        キャンセル
                      </button>
                    )}
                  </div>
                )}
              </article>
            );
          })}
        </div>
      )}
    </section>
  );
}

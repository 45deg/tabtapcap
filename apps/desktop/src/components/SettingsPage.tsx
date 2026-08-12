import { useEffect, useState } from "react";
import { api } from "../api";
import type { AppSettings, ModelInfo } from "../types";

export function SettingsPage({
  onError,
  onDataDeleted
}: {
  onError: (message: string) => void;
  onDataDeleted: () => Promise<void>;
}) {
  const [settings, setSettings] = useState<AppSettings | null>(null);
  const [models, setModels] = useState<ModelInfo[]>([]);
  const [saved, setSaved] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [deleted, setDeleted] = useState(false);
  const [exportingExtension, setExportingExtension] = useState(false);
  const [extensionPath, setExtensionPath] = useState<string | null>(null);

  useEffect(() => {
    void Promise.all([api.settings(), api.models()])
      .then(([nextSettings, nextModels]) => {
        setSettings(nextSettings);
        setModels(nextModels.filter((model) => model.engine !== "utility"));
      })
      .catch((reason: Error) => onError(reason.message));
  }, [onError]);

  if (!settings) return <p className="empty-transcript">設定を読み込んでいます…</p>;

  const selectedModel = models.find(
    (model) => model.id === settings.transcription.model_id
  );
  const fixedJapanese =
    settings.transcription.model_id.startsWith("parakeet-") ||
    settings.transcription.model_id === "apple-speech";

  const updateFormatting = (
    key: keyof AppSettings["formatting"],
    value: number
  ): void => {
    setSaved(false);
    setSettings({
      ...settings,
      formatting: { ...settings.formatting, [key]: value }
    });
  };

  return (
    <section className="management-page" aria-labelledby="settings-title">
      <header className="management-header">
        <div>
          <h2 id="settings-title">設定</h2>
          <p>ここで変更した値は、次に開始する録音から使用されます。</p>
        </div>
      </header>
      <form
        className="settings-form"
        onSubmit={async (event) => {
          event.preventDefault();
          try {
            setSettings(await api.updateSettings(settings));
            setSaved(true);
          } catch (reason) {
            onError(reason instanceof Error ? reason.message : String(reason));
          }
        }}
      >
        <fieldset>
          <legend>文字起こし</legend>
          <label className="setting-row">
            <span>
              言語
              <small>
                {fixedJapanese
                  ? settings.transcription.model_id === "apple-speech"
                    ? "Apple Speechは日本語（ja-JP）固定です。"
                    : "Parakeet Japaneseは日本語固定です。"
                  : "日本語固定、または音声から自動判定します。"}
              </small>
            </span>
            <select
              value={settings.transcription.language}
              disabled={fixedJapanese}
              onChange={(event) => {
                setSaved(false);
                setSettings({
                  ...settings,
                  transcription: {
                    ...settings.transcription,
                    language: event.target.value as "ja" | "auto"
                  }
                });
              }}
            >
              <option value="ja">日本語</option>
              <option value="auto">自動判定</option>
            </select>
          </label>
          <label className="setting-row">
            <span>
              認識モデル
              <small>
                {selectedModel?.availability_message ??
                  (selectedModel?.managed_by_system
                    ? "Appleのモデルを初回利用時に取得し、macOSが管理します。"
                    : "録音開始時に選んだモデルで処理します。")}
              </small>
            </span>
            <select
              value={settings.transcription.model_id}
              onChange={(event) => {
                setSaved(false);
                const modelId =
                  event.target.value as AppSettings["transcription"]["model_id"];
                const requiresJapanese =
                  modelId.startsWith("parakeet-") || modelId === "apple-speech";
                setSettings({
                  ...settings,
                  transcription: {
                    ...settings.transcription,
                    model_id: modelId,
                    language: requiresJapanese ? "ja" : settings.transcription.language
                  }
                });
              }}
            >
              {models.map((model) => (
                <option key={model.id} value={model.id} disabled={!model.available}>
                  {model.name}
                  {!model.available
                    ? "（利用不可）"
                    : model.managed_by_system
                      ? model.installed
                        ? "（OSに導入済み）"
                        : "（初回利用時に取得）"
                      : model.installed
                        ? ""
                        : "（未導入）"}
                </option>
              ))}
            </select>
          </label>
        </fieldset>
        <details>
          <summary>文章整形の詳細設定</summary>
          <div className="detail-settings">
            {(
              [
                ["comma_pause_ms", "読点候補の無音", "ms", 200, 1_000],
                ["sentence_pause_ms", "文を区切る無音", "ms", 500, 3_000],
                ["paragraph_pause_ms", "段落を区切る無音", "ms", 500, 10_000],
                ["max_paragraph_chars", "段落の最大文字数", "文字", 80, 1_000]
              ] as const
            ).map(([key, label, unit, min, max]) => (
              <label className="setting-row" key={key}>
                <span>{label}</span>
                <span className="number-control">
                  <input
                    type="number"
                    min={min}
                    max={max}
                    step={key === "max_paragraph_chars" ? 10 : 100}
                    value={settings.formatting[key]}
                    onChange={(event) => updateFormatting(key, Number(event.target.value))}
                  />
                  {unit}
                </span>
              </label>
            ))}
          </div>
        </details>
        <div className="settings-actions">
          <button type="submit" className="button primary">
            設定を保存
          </button>
          {saved && <span role="status">保存しました</span>}
        </div>
      </form>
      <section className="utility-card" aria-labelledby="extension-export-title">
        <div>
          <h3 id="extension-export-title">Chrome拡張機能</h3>
          <p>
            このアプリと同じバージョンの拡張機能をZIPでダウンロードフォルダーへ出力します。
            ZIPを展開し、Chromeの拡張機能画面で「パッケージ化されていない拡張機能」として読み込んでください。
          </p>
        </div>
        <div className="utility-card-actions">
          <button
            type="button"
            className="button primary"
            disabled={exportingExtension}
            onClick={async () => {
              setExportingExtension(true);
              setExtensionPath(null);
              try {
                setExtensionPath(await api.exportExtensionBundle());
              } catch (reason) {
                onError(reason instanceof Error ? reason.message : String(reason));
              } finally {
                setExportingExtension(false);
              }
            }}
          >
            {exportingExtension ? "出力しています…" : "拡張機能を出力"}
          </button>
          {extensionPath && (
            <span role="status" title={extensionPath}>
              ダウンロードフォルダーへ保存しました
            </span>
          )}
        </div>
      </section>
      <section className="data-deletion" aria-labelledby="data-deletion-title">
        <div>
          <h3 id="data-deletion-title">データの削除</h3>
          <p>
            録音、文字起こし、設定、アプリがダウンロードしたモデルをこのMacから削除します。
            macOSが管理するApple Speechモデルは削除されません。この操作は元に戻せません。
          </p>
        </div>
        <div className="data-deletion-actions">
          <button
            type="button"
            className="button danger"
            disabled={deleting}
            onClick={async () => {
              if (
                !confirm(
                  "すべての録音、文字起こし、設定、アプリがダウンロードしたモデルを削除しますか？\n\nmacOSが管理するApple Speechモデルは削除されません。この操作は元に戻せません。"
                )
              ) {
                return;
              }
              setDeleting(true);
              setDeleted(false);
              try {
                await api.deleteAllData();
                setSettings(await api.settings());
                setSaved(false);
                setDeleted(true);
                await onDataDeleted();
              } catch (reason) {
                onError(reason instanceof Error ? reason.message : String(reason));
              } finally {
                setDeleting(false);
              }
            }}
          >
            {deleting ? "削除しています…" : "すべてのデータを削除"}
          </button>
          {deleted && <span role="status">データを削除しました</span>}
        </div>
      </section>
    </section>
  );
}

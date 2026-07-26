import { useEffect, useState } from "react";
import { api } from "../api";
import type { AppSettings } from "../types";

export function SettingsPage({ onError }: { onError: (message: string) => void }) {
  const [settings, setSettings] = useState<AppSettings | null>(null);
  const [saved, setSaved] = useState(false);

  useEffect(() => {
    void api
      .settings()
      .then(setSettings)
      .catch((reason: Error) => onError(reason.message));
  }, [onError]);

  if (!settings) return <p className="empty-transcript">設定を読み込んでいます…</p>;

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
              <small>日本語固定、または音声から自動判定します。</small>
            </span>
            <select
              value={settings.transcription.language}
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
          <p className="setting-note">話者分析は現在無効です。</p>
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
    </section>
  );
}

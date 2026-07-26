import { defineManifest } from "@crxjs/vite-plugin";

export default defineManifest({
  manifest_version: 3,
  name: "Local Tab Transcriber",
  description: "現在のタブ音声をMac上だけで文字起こしします。",
  version: "0.1.0",
  minimum_chrome_version: "116",
  permissions: ["activeTab", "tabCapture", "offscreen", "storage"],
  host_permissions: ["http://127.0.0.1/*", "ws://127.0.0.1/*"],
  background: {
    service_worker: "src/service-worker.ts",
    type: "module"
  },
  action: {
    default_popup: "src/popup.html",
    default_title: "Local Tab Transcriber"
  },
  content_security_policy: {
    extension_pages:
      "script-src 'self'; object-src 'self'; connect-src http://127.0.0.1:8765 ws://127.0.0.1:8765"
  },
  icons: {
    "16": "icons/icon-16.png",
    "48": "icons/icon-48.png",
    "128": "icons/icon-128.png"
  }
});


import { defineManifest } from "@crxjs/vite-plugin";

const version = process.env.npm_package_version;
if (!version) {
  throw new Error("npm_package_version is required to build the extension manifest");
}

export default defineManifest({
  manifest_version: 3,
  name: "TabTapCap",
  description: "現在のタブ音声をMac上だけで文字起こしします。",
  version,
  minimum_chrome_version: "116",
  permissions: ["activeTab", "tabCapture", "offscreen", "storage"],
  host_permissions: ["http://127.0.0.1/*", "ws://127.0.0.1/*"],
  background: {
    service_worker: "src/service-worker.ts",
    type: "module"
  },
  action: {
    default_popup: "src/popup.html",
    default_title: "TabTapCap"
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

import { crx } from "@crxjs/vite-plugin";
import { defineConfig } from "vite";
import { resolve } from "node:path";
import manifest from "./manifest.config";

export default defineConfig({
  plugins: [crx({ manifest })],
  build: {
    outDir: "dist",
    emptyOutDir: true,
    sourcemap: true,
    rollupOptions: {
      input: {
        offscreen: resolve(__dirname, "src/offscreen.html")
      }
    }
  }
});

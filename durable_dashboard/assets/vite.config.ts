import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import path from "path";

export default defineConfig(({ command }) => ({
  plugins: [react(), tailwindcss()],
  // Use relative URLs in built CSS so @font-face / image references resolve
  // relative to the CSS file itself. The dashboard is forwarded at an
  // arbitrary host-app prefix (e.g. /dashboard, /admin/durable), and
  // Plug.Static serves assets at "<prefix>/__assets__/...". With base="./"
  // a CSS url("./jetbrains-mono.woff2") resolves to
  // "<prefix>/__assets__/jetbrains-mono.woff2" instead of the root path,
  // which 404s.
  base: "./",
  build: {
    outDir: "../priv/static/durable_dashboard",
    emptyOutDir: true,
    rollupOptions: {
      input: {
        // LiveView-first stack: LiveSocket + ReactFlow island only
        app: path.resolve(__dirname, "src/main.ts"),
      },
      output: {
        entryFileNames: "[name].js",
        chunkFileNames: "[name]-[hash].js",
        assetFileNames: "[name][extname]",
        manualChunks: {
          "vendor-xyflow": ["@xyflow/react", "@dagrejs/dagre"],
        },
      },
    },
    sourcemap: command === "serve",
  },
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "src"),
    },
  },
  server: {
    port: 5173,
    strictPort: true,
  },
}));

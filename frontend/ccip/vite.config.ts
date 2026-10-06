import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import path from "path";

export default defineConfig({
  // Base public path. "/" for local dev and custom domains; set BASE_PATH
  // (e.g. "/cross-chain-vault-adapters/") when serving from a sub-path such as a
  // GitHub Pages project site.
  base: process.env.BASE_PATH || "/",
  plugins: [react()],
  resolve: {
    alias: {
      "@": path.resolve(import.meta.dirname, "client", "src"),
    },
  },
  optimizeDeps: {
    // Pre-bundle the CCIP SDK (and its CommonJS dependencies) for the dev server.
    include: ["@chainlink/ccip-sdk"],
  },
  root: path.resolve(import.meta.dirname, "client"),
  envDir: import.meta.dirname,
  build: {
    outDir: path.resolve(import.meta.dirname, "dist"),
    emptyOutDir: true,
    commonjsOptions: {
      include: [/node_modules/],
      transformMixedEsModules: true,
    },
  },
  server: {
    fs: {
      strict: true,
      deny: ["**/.*"],
    },
  },
});

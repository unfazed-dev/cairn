import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vite';

export default defineConfig({
  plugins: [sveltekit()],
  server: {
    // Proxy /v1 to the local cairn-cloud binary in dev so the admin can call
    // the real API without CORS gymnastics. `npm run dev` (5173) → cairn-cloud (9090).
    proxy: {
      '/v1': {
        target: process.env.CAIRN_CLOUD_URL ?? 'http://localhost:9090',
        changeOrigin: true
      }
    }
  }
});

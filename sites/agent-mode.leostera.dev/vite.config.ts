import { cloudflare } from '@cloudflare/vite-plugin';
import { defineConfig } from 'vite';

export default defineConfig({
  plugins: [cloudflare({ inspectorPort: Number(process.env.INSPECTOR_PORT ?? 9295) })],
  build: { sourcemap: true },
  server: { port: Number(process.env.PORT ?? 8795), strictPort: true },
});

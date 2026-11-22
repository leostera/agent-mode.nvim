import { bindings, defineConfig } from 'cf/config';

import * as entrypoint from './src/worker.ts' with { type: 'cf-worker' };

/** The agent-mode.nvim website on agent-mode.leostera.dev: the page, /llms.txt, and assets. */
export default defineConfig(({ mode }) => {
  const local = mode === 'development';
  return {
    accountId: '0f436d2aabf1f872be90b8dd9d5715e6',
    worker: {
      name: 'agent-mode-site',
      compatibilityDate: '2026-11-01',
      entrypoint,
      assets: { notFoundHandling: 'none', runWorkerFirst: ['/', '/llms.txt'] },
      domains: local ? [] : ['agent-mode.leostera.dev'],
      workersDev: false,
      previewUrls: false,
      env: { ASSETS: bindings.assets() },
      observability: { enabled: true, logs: { enabled: true, invocationLogs: true, persist: true } },
    },
  };
});

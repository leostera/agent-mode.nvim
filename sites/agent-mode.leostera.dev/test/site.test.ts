import { expect, test } from 'bun:test';
import { handle } from '../src/worker.ts';

test('the page shows the demo, every agent, and onboards from llms.txt', async () => {
  const page = await handle(new Request('https://x/'))!.text();
  expect(page).toContain('<h1 id="title">agent mode');
  expect(page).toContain('src="/demo.mp4"');
  for (const agent of ['pi', 'claude', 'codex', 'opencode']) expect(page).toContain(`/logos/${agent}.svg`);
  expect(page).toContain('https://agent-mode.leostera.dev/llms.txt');
});

test('llms.txt tells an agent how to check, install and verify', async () => {
  const text = await handle(new Request('https://x/llms.txt'))!.text();
  for (const step of ['## Check', '## Install', '## Verify', 'leostera/agent-mode.nvim']) expect(text).toContain(step);
});

test('only GET and HEAD reach the pages, and assets fall through', () => {
  expect(handle(new Request('https://x/', { method: 'POST' }))!.status).toBe(405);
  expect(handle(new Request('https://x/demo.mp4'))).toBeNull();
});

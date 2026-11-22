/** agent-mode.leostera.dev: the page and /llms.txt from here, the rest from static assets. */
import { landing } from './landing.ts';
import { onboarding } from './onboarding.ts';

const HTML = {
  'content-type': 'text/html; charset=utf-8',
  'cache-control': 'public, max-age=300',
  'content-security-policy':
    "default-src 'none'; style-src 'self'; script-src 'self'; img-src 'self'; media-src 'self'; font-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
  'x-content-type-options': 'nosniff',
  'referrer-policy': 'strict-origin-when-cross-origin',
};
const TEXT = {
  'content-type': 'text/plain; charset=utf-8',
  'cache-control': 'public, max-age=300',
  'x-content-type-options': 'nosniff',
};

/** The pages; null for what the static assets serve. */
export function handle(request: Request): Response | null {
  const { pathname } = new URL(request.url);
  const page = pathname === '/' ? { body: landing, headers: HTML } : pathname === '/llms.txt' ? { body: onboarding, headers: TEXT } : null;
  if (!page) return null;
  if (request.method !== 'GET' && request.method !== 'HEAD')
    return new Response('Method not allowed', { status: 405, headers: { allow: 'GET, HEAD' } });
  return new Response(request.method === 'HEAD' ? null : page.body, { headers: page.headers });
}

export default {
  async fetch(request, env): Promise<Response> {
    return handle(request) ?? env.ASSETS.fetch(request);
  },
} satisfies ExportedHandler<Env>;

/** The page: what agent-mode is, the demo, onboarding an agent, and how it compares. */
import { esc } from './html.ts';
import { onboardPrompt, REPO } from './onboarding.ts';

const AGENTS = ['claude', 'codex', 'opencode', 'pi'];

const POINTS: { title: string; text: string }[] = [
  {
    title: 'Ask where you are',
    text: 'Cursor on a line, <kbd>&lt;leader&gt;a</kbd>, type. The agent sees the file, the cursor, the selection, the diagnostics and what your language server can do there.',
  },
  {
    title: 'Read it in context',
    text: 'Answers render as Markdown right under the line and move with the code. The file is never touched.',
  },
  {
    title: 'Change code in place',
    text: '“rename to presenter”, “extract this into a function”. Renames go through your language server; edits land as one undo step.',
  },
  {
    title: 'Keep the thread',
    text: 'Every request goes to the same conversation, so “do the same for the second caller” just works. Each shows a live status by its line, and lands there even as lines move.',
  },
];

const OTHERS: { name: string; url: string; how: string }[] = [
  { name: 'codecompanion.nvim', url: 'https://github.com/olimorris/codecompanion.nvim', how: 'a chat buffer, and diffs to accept' },
  { name: 'avante.nvim', url: 'https://github.com/avante-corp/avante.nvim', how: 'a sidebar, and diffs to apply' },
  { name: 'sidekick.nvim', url: 'https://github.com/folke/sidekick.nvim', how: 'the agent’s terminal in a split' },
  { name: 'claudecode.nvim', url: 'https://github.com/coder/claudecode.nvim', how: 'Claude Code’s terminal, and diffs' },
  { name: 'opencode.nvim', url: 'https://github.com/nickjvandyke/opencode.nvim', how: 'OpenCode’s interface' },
];

const SPEC = `{
  "leostera/agent-mode.nvim",
  keys = { { "<leader>a", "<Plug>(AgentMode)", mode = { "n", "x" } } },
  opts = { agent = "claude" }, -- "codex", "opencode", "pi"
}`;

export const landing = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="theme-color" content="#f7f7f4">
<meta name="description" content="Ask your coding agent about the code under your cursor, or tell it what to change, without leaving Neovim. Works with Claude Code, Codex, OpenCode and pi.">
<meta property="og:title" content="agent mode: your coding agent at the cursor, in Neovim">
<meta property="og:description" content="Answers under the line you asked about. Edits straight into the buffer.">
<link rel="icon" type="image/svg+xml" href="/favicon.svg">
<link rel="stylesheet" href="/site.css">
<script src="/site.js" defer></script>
<title>agent mode: your coding agent at the cursor, in Neovim</title>
</head>
<body>
<div class="page">
<main>
  <section class="hero" aria-labelledby="title">
    <h1 id="title">agent mode<span class="cursor" aria-hidden="true"></span></h1>
    <p class="tagline">your coding agent, at the cursor, in Neovim</p>
    <p class="description">Ask about the line you are on, or tell it what to change. Answers show up right under the line; edits land in the buffer as one undo step. With the agent you already use.</p>
    <div class="actions">
      <div class="onboard-action">
        <button class="onboard" type="button" data-copy="${esc(onboardPrompt)}">
          <span>Set it up with your agent</span><span class="marks">${AGENTS.map((a) => `<img src="/logos/${a}.svg" width="22" height="22" alt="">`).join('')}</span>
        </button>
        <p class="copy-toast" role="status" hidden></p>
      </div>
      <p class="small"><a href="${REPO}">github.com/leostera/agent-mode.nvim</a> · Free · Neovim 0.12+</p>
    </div>
  </section>
  <figure class="demo">
    <video src="/demo.mp4" poster="/demo.webp" width="1280" height="880" autoplay muted loop playsinline aria-label="Two questions answered under their lines, then a block extracted into a function"></video>
    <figcaption>Sped up: the waits for the agent are cut.</figcaption>
  </figure>
  <ul class="points">
${POINTS.map((p) => `    <li><h2>${p.title}</h2><p>${p.text}</p></li>`).join('\n')}
  </ul>
  <section class="install" aria-labelledby="install">
    <h2 id="install">Install</h2>
    <p>With <a href="https://github.com/folke/lazy.nvim">lazy.nvim</a>, with an agent CLI installed and logged in:</p>
    <pre><code>${esc(SPEC)}</code></pre>
    <p>Your agent’s own login, models and billing are used as they are. It uses its own tools on your project; the buffer you are in changes only through its reply, as one undo step.</p>
  </section>
  <section class="compare" aria-labelledby="compare">
    <h2 id="compare">Why not a chat plugin?</h2>
    <p>Use one when you want a long conversation about a codebase. They talk to you through</p>
    <ul>
${OTHERS.map((o) => `      <li><a href="${o.url}">${o.name}</a>: ${o.how}</li>`).join('\n')}
    </ul>
    <p>agent-mode is for the quick answer or change at the line you are on, without leaving it. <a href="${REPO}#how-it-compares">The full comparison</a>.</p>
  </section>
</main>
<footer>made with &lt;3 by <a href="https://github.com/leostera">@leostera</a></footer>
</div>
</body>
</html>`;

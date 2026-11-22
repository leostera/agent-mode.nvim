/** What an agent reads to set agent-mode up in someone's Neovim. */
export const SITE = 'https://agent-mode.leostera.dev';
export const REPO = 'https://github.com/leostera/agent-mode.nvim';

export const onboardPrompt = `Read ${SITE}/llms.txt and set up agent-mode.nvim in my Neovim config.`;

export const onboarding = `# agent-mode.nvim

> Ask your coding agent about the code under the cursor, or tell it what to change, without leaving Neovim. Answers render under the line; edits land in the buffer as one undo step.

Source and full docs: ${REPO}

You are setting this plugin up in the user's Neovim config. Make the smallest change that fits how their config is already organized.

## Check

- Neovim 0.12 or newer: \`nvim --version\`.
- At least one agent CLI installed and logged in: \`claude\`, \`codex\`, \`opencode\` or \`pi\`. Prefer the one the user already uses; if you are one of these, use yourself.
- Find the config: \`nvim --headless +'lua io.write(vim.fn.stdpath("config"))' +q\`, and see which plugin manager it uses.

## Install

With lazy.nvim, add a spec next to their other plugins:

\`\`\`lua
{
  "leostera/agent-mode.nvim",
  keys = {
    { "<leader>a", "<Plug>(AgentMode)", mode = { "n", "x" }, desc = "Ask the agent" },
  },
  opts = {
    agent = "claude", -- "claude", "codex", "opencode", or "pi"
  },
}
\`\`\`

With another manager, install \`leostera/agent-mode.nvim\` and add \`vim.keymap.set({ "n", "x" }, "<leader>a", "<Plug>(AgentMode)")\` and \`vim.g.agent_mode = { agent = "claude" }\`. No \`setup()\` call is needed.

The plugin maps no keys itself. Pick a key for \`<Plug>(AgentMode)\` that does not clash with an existing mapping.

Settings worth knowing:

- \`cmd\`: the full path to the agent CLI when it is not on Neovim's PATH, common when Neovim starts from a GUI. For Claude Code installed locally: \`vim.fn.expand("~/.local/bin/claude")\`.
- \`model\` and \`thinking\`: in the format the agent expects.

## Verify

Run \`nvim --headless +'checkhealth agent_mode' +'w! /dev/stdout' +qa\` and fix any errors it reports. Then tell the user: put the cursor on a line, press the key, and type a question or an instruction. \`:AgentMode log\` shows the last prompt and reply if something looks off, and \`:h agent-mode\` has the docs.
`;

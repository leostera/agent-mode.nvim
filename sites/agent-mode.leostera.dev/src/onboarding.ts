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
  opts = {
    agent = "claude", -- "claude", "codex", "opencode", or "pi"
  },
}
\`\`\`

With another manager, install \`leostera/agent-mode.nvim\` and call \`require("agent_mode").setup({ agent = "claude" })\`.

Options worth knowing:

- \`keymap\` (default \`"<leader>a"\`): pick another if it clashes with an existing mapping.
- \`cmd\`: the full path to the agent CLI when it is not on Neovim's PATH, common when Neovim starts from a GUI. For Claude Code installed locally: \`vim.fn.expand("~/.local/bin/claude")\`.
- \`model\` and \`thinking\`: in the format the agent expects.

## Verify

Run \`nvim --headless +'lua require("agent_mode")' +q\` and check it exits without errors. Then tell the user: put the cursor on a line, press the keymap, and type a question or an instruction. \`:AgentModeLog\` shows the last prompt and reply if something looks off.
`;

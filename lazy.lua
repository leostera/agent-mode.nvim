-- lazy.nvim adds the specs returned here when it installs the plugin.
--   nui.nvim draws the session split.
--   snacks.nvim draws the settings menu and pickers (:AgentMode config);
--   without it they fall back to vim.ui.select and vim.ui.input.
return {
  { "MunifTanjim/nui.nvim" },
  { "folke/snacks.nvim" },
}

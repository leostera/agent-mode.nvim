# Records docs/demo.gif with VHS (https://github.com/charmbracelet/vhs):
#   vhs docs/demo.tape
# It drives your own Neovim config with agent-mode on pi and assumes the
# prompt is mapped to ,,a (leader ","). Waits for the agent are cut out.

Output docs/demo.gif

Set Shell zsh
Set FontFamily "Menlo"
Set FontSize 16
Set LineHeight 1.2
Set Width 1280
Set Height 880
Set Theme "Catppuccin Mocha"
Set WindowBar Colorful
Set Padding 16
Set Framerate 20
Set TypingSpeed 40ms

Hide
Type "clear && env -u AXO_SESSION_ID nvim lua/agent_mode/edits.lua" Enter
Sleep 2.5s
Type ":8" Enter
Type "zt"
Type ":12" Enter
Type "^"
Sleep 300ms
Show

# Two questions, one after the other; both run at once.
Sleep 800ms
Type ",,a"
Sleep 400ms
Type "why sort these bottom-up? briefly"
Sleep 600ms
Enter
Sleep 800ms
Type ":19" Enter
Type "^w"
Sleep 300ms
Type ",,a"
Sleep 400ms
Type "what does floor track? one sentence"
Sleep 600ms
Enter
Sleep 3s
Hide
Wait+Screen@120s /pi: what does floor track/
Wait+Screen@120s /pi: why sort these/
Sleep 500ms
Type ":8" Enter
Type "zt"
Type ":19" Enter
Show
Sleep 6s

# Clear them and refactor a block.
Type ":AgentModeDismiss!" Enter
Sleep 800ms
Type ":21" Enter
Type "V8j"
Sleep 800ms
Type ",,a"
Sleep 400ms
Type "extract this bounds check into a local function"
Sleep 600ms
Enter
Sleep 3s
Hide
Wait+Screen@120s /agent-mode: /
Sleep 500ms
Type ":10" Enter
Type "zt"
Sleep 300ms
Show
Sleep 6s

Hide
Type ":e!" Enter
Type ":qa!" Enter

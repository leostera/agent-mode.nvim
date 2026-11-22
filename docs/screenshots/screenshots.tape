# Regenerates the README screenshots with VHS (https://github.com/charmbracelet/vhs):
#   cd docs/screenshots && vhs screenshots.tape
# It drives your own Neovim config with agent-mode on pi, and assumes the
# prompt is mapped to ,,a (leader ","). Answers differ from run to run.


Set Shell zsh
Set FontFamily "Menlo"
Set FontSize 16
Set LineHeight 1.25
Set Width 1360
Set Height 800
Set Theme "Catppuccin Mocha"
Set WindowBar Colorful
Set Padding 18
Set TypingSpeed 35ms

Hide
Type "cd ../.. && clear && env -u AXO_SESSION_ID nvim lua/agent_mode/edits.lua"
Enter
Sleep 2.5s
Type ":8" Enter
Type "zt"
Type ":12" Enter
Type "^"
Sleep 300ms
Show

# A clarification question about the bottom-up sort.
Sleep 600ms
Type ",,a"
Sleep 300ms
Type "why sort the edits bottom-up?"
Sleep 500ms
Screenshot ask.png
Enter
Sleep 4.5s
Screenshot working.png
Wait+Screen@90s /│ pi: why sort/
Sleep 1s
Screenshot answer.png
Sleep 1.5s

# Open the answer in place and select from it.
Enter
Sleep 600ms
Type "jjV"
Sleep 600ms
# Screenshot select.png
Sleep 1s
Escape
Type "q"
Sleep 300ms
Type ":AgentModeDismiss!" Enter
Sleep 600ms

# Rename a variable.
Type ":19" Enter
Type "^w"
Sleep 300ms
Type ",,a"
Sleep 300ms
Type "rename to claimed_from"
Sleep 500ms
# Screenshot rename-ask.png
Enter
Sleep 4s
# Screenshot rename-working.png
Wait+Screen@90s /local claimed_from/
Sleep 1.5s
Screenshot renamed.png
Sleep 1.5s

Hide
Type ":e!" Enter
Type ":qa!" Enter

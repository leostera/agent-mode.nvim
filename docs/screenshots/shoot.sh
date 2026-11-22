#!/bin/zsh
# Takes the README screenshots on macOS: a Ghostty window running your Neovim
# config with agent-mode on pi, asking about and renaming code in this repo.
# Needs an unlocked screen, Screen Recording permission for the terminal that
# runs it, and the prompt mapped to ,,a (leader ","). Answers vary per run.
#   docs/screenshots/shoot.sh
set -e
REPO=${0:A:h:h:h}
OUT=$REPO/docs/screenshots
WORK=$(mktemp -d)
SOCK=/tmp/am-shot.sock
mkdir -p $OUT

# The window: Neovim on edits.lua, listening on $SOCK so we can drive it.
cat > $WORK/nvim.sh <<SCRIPT
#!/bin/zsh
cd $REPO
rm -f $SOCK
exec env -u AXO_SESSION_ID nvim --listen $SOCK lua/agent_mode/edits.lua
SCRIPT
chmod +x $WORK/nvim.sh
cat > $WORK/winid.swift <<'SWIFT'
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
var best: (Int, Double) = (0, 0)
for w in list where (w["kCGWindowOwnerName"] as? String) == "Ghostty" {
  let b = w["kCGWindowBounds"] as! [String: Double]
  let area = (b["Width"] ?? 0) * (b["Height"] ?? 0)
  if area > best.1 { best = (w["kCGWindowNumber"] as! Int, area) }
}
print(best.0)
SWIFT

nv() { nvim --server $SOCK --remote-send "$1"; }
nvx() { nvim --server $SOCK --remote-expr "$1"; }

window_id() {
  # The frontmost Ghostty window: the one this script just opened.
  swift $WORK/winid.swift 2>/dev/null
}

shot() {
  sleep 0.4
  screencapture -x -o -l "$WID" "$OUT/$1.png"
  echo "saved $OUT/$1.png"
}

wait_idle() {
  # Wait until no agent-mode request is running.
  for i in {1..240}; do
    [ "$(nvx 'luaeval("#require(\"agent_mode\").requests()")')" = "0" ] && return 0
    sleep 0.25
  done
  echo "timed out waiting for the agent" >&2
  return 1
}

open -na /Applications/Ghostty.app --args --command=$WORK/nvim.sh --title=agent-mode.nvim \
  --background-opacity=1 --window-width=104 --window-height=32 --font-size=15 \
  --custom-shader-animation=false --window-save-state=never --quit-after-last-window-closed=true
for i in {1..40}; do [ -S $SOCK ] && break; sleep 0.25; done
sleep 1.5
WID=$(window_id)
[ -n "$WID" ] || { echo "no Ghostty window found" >&2; exit 1; }
echo "window $WID"
nvx 'luaeval("require(\"agent_mode\").configure({ agent = \"pi\" })")' >/dev/null

# 1. A clarification question about the bottom-up sort in edits.plan.
nv '<Esc>:12<CR>zt:normal! 4k<CR>'
nv ':12<CR>^'
nv ',,a'
sleep 0.4
nv 'why sort the edits bottom-up?'
shot ask
nv '<CR>'
sleep 4.5
shot working
wait_idle
nv ':normal! 4kzt<CR>:12<CR>'
shot answer

# 2. Open the answer in place to select from it.
nv '<CR>'
sleep 0.5
nv 'jjV'
nv '<Esc>q'
nv ':AgentModeDismiss!<CR>'

# 3. Rename a variable.
nv ':19<CR>zz:19<CR>^w'
nv ',,a'
sleep 0.4
nv 'rename to claimed_from'
nv '<CR>'
sleep 4
wait_idle
sleep 0.5
shot renamed

# Leave the source file as it was.
nv ':e!<CR>'
nv ':qa!<CR>'
echo done

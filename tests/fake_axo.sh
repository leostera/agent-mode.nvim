#!/bin/sh
# Stands in for the axo CLI in tests.
#   axo --json session show --sid S     prints a session whose transcript is
#                                       $AGENT_MODE_FAKE_TRANSCRIPT
#   axo --json session prompt ... -     records the prompt in
#                                       $AGENT_MODE_FAKE_STDIN, then, in the
#                                       background, plays a turn into the
#                                       transcript: the prompt, a tool call,
#                                       an edit of $AGENT_MODE_FAKE_EDIT_FILE
#                                       to $AGENT_MODE_FAKE_EDIT_CONTENT, and
#                                       the final reply $AGENT_MODE_FAKE_REPLY.
set -e
case "$*" in
  *"session show"*)
    printf '{"id":"fake","piSessionFile":"%s"}\n' "$AGENT_MODE_FAKE_TRANSCRIPT"
    ;;
  *"session prompt"*)
    cat > "$AGENT_MODE_FAKE_STDIN"
    nonce=$(sed -n 's/^\[agent-mode request \([0-9a-f]*\),.*/\1/p' "$AGENT_MODE_FAKE_STDIN")
    t="$AGENT_MODE_FAKE_TRANSCRIPT"
    (
      sleep 0.2
      printf '{"type":"message","message":{"role":"user","content":"unrelated"}}\n' >> "$t"
      printf '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"not ours"}],"stopReason":"stop"}}\n' >> "$t"
      printf '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"[agent-mode request %s, from Neovim]"}]}}\n' "$nonce" >> "$t"
      printf '{"type":"message","message":{"role":"assistant","content":[],"stopReason":"toolUse"}}\n' >> "$t"
      if [ -n "$AGENT_MODE_FAKE_EDIT_FILE" ]; then
        printf '%s\n' "$AGENT_MODE_FAKE_EDIT_CONTENT" > "$AGENT_MODE_FAKE_EDIT_FILE"
      fi
      sleep 0.2
      # Write the final line in two pieces to exercise partial reads.
      printf '{"type":"message","message":{"role":"assistant",' >> "$t"
      sleep 0.3
      printf '"content":[{"type":"text","text":"%s"}],"stopReason":"%s"}}\n' \
        "$AGENT_MODE_FAKE_REPLY" "${AGENT_MODE_FAKE_STOP:-stop}" >> "$t"
    ) > /dev/null 2>&1 &
    printf '{"accepted":true,"queued":false}\n'
    ;;
  *)
    echo "fake axo: unexpected arguments: $*" >&2
    exit 2
    ;;
esac

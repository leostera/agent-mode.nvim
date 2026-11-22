#!/bin/sh
# Stands in for the agent in tests: records the prompt it was sent on stdin,
# waits, then prints the reply. The reply and delay come from the arguments
# ($1, $2) or else from AGENT_MODE_FAKE_REPLY and AGENT_MODE_FAKE_DELAY.
# With AGENT_MODE_FAKE_LINES set, the reply is printed one line at a time,
# AGENT_MODE_FAKE_LINES seconds apart, to imitate a streaming agent.
cat > "${AGENT_MODE_FAKE_STDIN:-/dev/null}"
reply="${1-$AGENT_MODE_FAKE_REPLY}"
sleep "${2-${AGENT_MODE_FAKE_DELAY:-0}}"
if [ -n "$AGENT_MODE_FAKE_LINES" ]; then
  printf '%s\n' "$reply" | while IFS= read -r line; do
    printf '%s\n' "$line"
    sleep "$AGENT_MODE_FAKE_LINES"
  done
else
  printf '%s' "$reply"
fi
exit "${AGENT_MODE_FAKE_EXIT:-0}"

/**
 * agent-mode for pi: registers agent-mode's MCP server, so pi can work in
 * the user's Neovim (its buffers, cursor, language servers, inline answers)
 * and take the requests the user makes at their cursor.
 *
 * Install it once with `pi install <this file>` (pi loads it from here, so
 * it finds bin/ next to it), or load it for one run with `pi -e <this file>`.
 * agent-mode loads it itself for the agents it starts.
 */

import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
	const bridge = join(dirname(fileURLToPath(import.meta.url)), "..", "bin", "agent-mode-mcp");
	const server = process.env.AGENT_MODE_SERVER;
	try {
		pi.registerMcpServer("agent-mode", {
			command: bridge,
			args: server ? ["--server", server] : [],
			exposure: "direct",
			description: "Work in the user's Neovim: buffers, cursor, language servers, inline answers.",
		});
	} catch {
		// Registered already, by an installed copy of this extension.
	}
}

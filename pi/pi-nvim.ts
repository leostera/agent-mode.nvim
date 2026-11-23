/**
 * pi-nvim: pair this pi session with a Neovim running agent-mode.
 *
 * Run /nvim and pick a Neovim. From then on, each request made at the cursor
 * in that Neovim arrives here as a message and starts a turn (or waits for
 * the current one), and pi works on it with the nvim-mcp tools: edits to the
 * buffer, language server renames, answers under the line. When the turn
 * settles the request finishes in Neovim, and if pi only replied in words,
 * that reply is shown under the line. /nvim off unpairs; quitting pi does too.
 *
 * It also registers the nvim-mcp server, so pi has the tools with or without
 * pairing. Install it once with `pi install <this file>` (pi loads it from
 * here, so it finds bin/ next to it), or load it for one run with
 * `pi -e <this file>`. agent-mode loads it itself for the agents it starts.
 */

import { type ChildProcess, spawn } from "node:child_process";
import { readdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const bridgePath = join(dirname(fileURLToPath(import.meta.url)), "..", "bin", "nvim-mcp");

/** A Neovim running agent-mode, as it registers itself for nvim-mcp. */
type Neovim = { address: string; cwd: string; pid: number; used_at?: number; file?: string };

function registry(): string {
	const state = process.env.XDG_STATE_HOME ?? join(homedir(), ".local", "state");
	return join(state, process.env.NVIM_APPNAME ?? "nvim", "nvim-mcp", "servers");
}

function alive(pid: number): boolean {
	try {
		process.kill(pid, 0);
		return true;
	} catch {
		return false;
	}
}

/** Running Neovims: the ones in this project first, then the latest used. */
function neovims(cwd: string): Neovim[] {
	let names: string[] = [];
	try {
		names = readdirSync(registry());
	} catch {
		return [];
	}
	const found: Neovim[] = [];
	for (const name of names) {
		try {
			const info = JSON.parse(readFileSync(join(registry(), name), "utf8")) as Neovim;
			if (info.address && info.pid && alive(info.pid)) found.push(info);
		} catch {
			// a file being written, or not one of ours
		}
	}
	const inProject = (n: Neovim) => {
		const rel = relative(resolve(n.cwd), resolve(cwd));
		return !rel.startsWith("..") ? 1 : 0;
	};
	return found.sort((a, b) => inProject(b) - inProject(a) || (b.used_at ?? 0) - (a.used_at ?? 0));
}

function tilde(path: string): string {
	const home = homedir();
	return path === home || path.startsWith(`${home}/`) ? `~${path.slice(home.length)}` : path;
}

function describe(n: Neovim): string {
	return `${tilde(n.cwd)} · ${n.file ? basename(n.file) : "[no file]"} (pid ${n.pid})`;
}

/** nvim-mcp, spoken to directly: one bridge process per pairing. */
class Bridge {
	private child: ChildProcess;
	private pending = new Map<number, (message: any) => void>();
	private nextId = 1;
	private buffer = "";

	constructor(address: string, onExit: () => void) {
		this.child = spawn(bridgePath, ["--server", address], { stdio: ["pipe", "pipe", "ignore"] });
		this.child.stdout?.setEncoding("utf8");
		this.child.stdout?.on("data", (chunk: string) => {
			this.buffer += chunk;
			let newline = this.buffer.indexOf("\n");
			while (newline >= 0) {
				const line = this.buffer.slice(0, newline);
				this.buffer = this.buffer.slice(newline + 1);
				try {
					const message = JSON.parse(line);
					this.pending.get(message.id)?.(message);
					this.pending.delete(message.id);
				} catch {
					// not JSON-RPC
				}
				newline = this.buffer.indexOf("\n");
			}
		});
		this.child.on("exit", () => {
			for (const settle of this.pending.values()) settle({ error: { message: "nvim-mcp exited" } });
			this.pending.clear();
			onExit();
		});
	}

	private request(method: string, params: unknown): Promise<any> {
		const id = this.nextId++;
		return new Promise((settle) => {
			this.pending.set(id, settle);
			this.child.stdin?.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
		});
	}

	async start(): Promise<void> {
		await this.request("initialize", {
			protocolVersion: "2025-06-18",
			capabilities: {},
			clientInfo: { name: "pi-nvim", version: "0.1.0" },
		});
	}

	/** Call a tool; its text, and whether it failed. */
	async call(name: string, args: Record<string, unknown>): Promise<{ text: string; error: boolean }> {
		const message = await this.request("tools/call", { name, arguments: args });
		if (message.error) return { text: String(message.error.message), error: true };
		return { text: message.result?.content?.[0]?.text ?? "", error: message.result?.isError === true };
	}

	close(): void {
		this.child.kill();
	}
}

const guidance = [
	"The user asked this from Neovim, which is paired with this session (pi-nvim).",
	"Do it with the nvim-mcp tools and the context_id below: edit for their buffer (never your file tools",
	"for it: it may have unsaved changes), lsp_rename or code_action when listed, show_answer or just",
	"your reply for answers (your reply is shown under their line when you use neither), and run_lua",
	"for what only Neovim has. Keep answers short. The request finishes when your turn ends; do not call",
	"wait_for_request or finish.",
].join(" ");

export default function (pi: ExtensionAPI) {
	const registerTools = (server?: string) => {
		try {
			pi.registerMcpServer("nvim-mcp", {
				command: bridgePath,
				args: server ? ["--server", server] : [],
				exposure: "direct",
				description: "Work in the user's Neovim: buffers, cursor, language servers, inline answers.",
			});
		} catch {
			// Registered already, by another copy of this extension.
		}
	};
	registerTools(process.env.NVIM_MCP_SERVER);

	type Link = { bridge: Bridge; neovim: Neovim };
	let link: Link | null = null;
	let busy = false; // a run is going (agent_start .. agent_settled)
	let reply = ""; // the assistant's last words in the current run
	let turnDone: (() => void) | null = null;
	let setStatus: (text: string | undefined) => void = () => {};
	let say: (text: string, level?: "info" | "warning" | "error") => void = () => {};

	const unlink = (why?: string) => {
		if (!link) return;
		const old = link;
		link = null;
		old.bridge.close();
		registerTools(process.env.NVIM_MCP_SERVER);
		setStatus(undefined);
		turnDone?.();
		if (why) say(why, "warning");
	};

	/** Take requests from the paired Neovim until unpaired. */
	const listen = async (mine: Link) => {
		while (link === mine) {
			const result = await mine.bridge.call("wait_for_request", { timeout_seconds: 3600 });
			if (link !== mine) return;
			const id = result.text.match(/context_id: (\w+)/)?.[1];
			if (result.error && /^(Lost Neovim|No Neovim|nvim-mcp exited)/.test(result.text)) {
				return unlink("Neovim went away; unpaired.");
			}
			if (/unpaired you/.test(result.text)) return unlink("Neovim unpaired this session.");
			if (!id || result.error) continue; // no request yet
			reply = "";
			const done = new Promise<void>((settle) => {
				turnDone = settle;
			});
			const message = `${guidance}\n\n${result.text}`;
			if (busy) pi.sendUserMessage(message, { deliverAs: "followUp" });
			else pi.sendUserMessage(message);
			await done;
			turnDone = null;
			if (link !== mine) return;
			await mine.bridge.call("finish", { context_id: id, reply });
		}
	};

	const pair = async (neovim: Neovim, cwd: string) => {
		unlink();
		let mine: Link | null = null;
		const bridge = new Bridge(neovim.address, () => {
			if (mine && link === mine) unlink("Neovim went away; unpaired.");
		});
		await bridge.start();
		const result = await bridge.call("pair", { agent: `pi (${basename(cwd)})` });
		if (result.error) {
			bridge.close();
			return say(`Could not pair: ${result.text}`, "error");
		}
		mine = { bridge, neovim };
		link = mine;
		registerTools(neovim.address); // the tools act on this Neovim too
		setStatus(`nvim: ${tilde(neovim.cwd)}`);
		say(`Paired with Neovim in ${tilde(neovim.cwd)}. Ask away at your cursor.`);
		void listen(mine);
	};

	pi.on("session_start", (_event, ctx) => {
		setStatus = (text) => ctx.ui.setStatus("nvim", text);
		say = (text, level = "info") => ctx.ui.notify(text, level);
	});
	pi.on("agent_start", () => {
		busy = true;
	});
	pi.on("agent_end", (event) => {
		const messages = (event as { messages?: any[] }).messages ?? [];
		for (let i = messages.length - 1; i >= 0; i--) {
			const m = messages[i];
			if (m?.role !== "assistant") continue;
			const text = (Array.isArray(m.content) ? m.content : [])
				.filter((block: any) => block?.type === "text")
				.map((block: any) => block.text)
				.join("");
			reply = text;
			break;
		}
	});
	pi.on("agent_settled", () => {
		busy = false;
		turnDone?.();
	});
	pi.on("session_shutdown", () => unlink());

	pi.registerCommand("nvim", {
		description: "Pair this session with a Neovim running agent-mode (/nvim off to unpair)",
		handler: async (args, ctx) => {
			setStatus = (text) => ctx.ui.setStatus("nvim", text);
			say = (text, level = "info") => ctx.ui.notify(text, level);
			const arg = args.trim();
			if (arg === "off" || arg === "unpair") {
				if (!link) return say("Not paired with a Neovim.");
				// The paired bridge is busy waiting for a request; tell Neovim on another.
				const once = new Bridge(link.neovim.address, () => {});
				await once.start();
				await once.call("unpair", {});
				once.close();
				return unlink("Unpaired from Neovim.");
			}
			const list = neovims(ctx.cwd);
			if (list.length === 0) {
				return say("No Neovim with agent-mode is running. Start one, then /nvim again.", "warning");
			}
			let choice = list[0];
			if (list.length > 1) {
				const labels = list.map(describe);
				const picked = await ctx.ui.select("Pair with which Neovim?", labels);
				if (!picked) return;
				choice = list[labels.indexOf(picked)];
			}
			await pair(choice, ctx.cwd);
		},
	});
}

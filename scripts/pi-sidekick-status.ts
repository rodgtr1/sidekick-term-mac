// Sidekick agent-status extension for the Pi coding agent.
//
// Reports Pi's lifecycle to Sidekick's agents panel using the same OSC 666
// termprop sequence that sidekick-agent-status emits for Claude Code/Codex
// hooks. Installed to ~/.pi/agent/extensions/ by install-agent-status-hooks.
//
// Mapping:
//   session_start            -> done   (registers the tab in the agents panel on open)
//   agent_start              -> busy   (working on a prompt)
//   tool_call                -> busy   (resets from ready once tools start running)
//   project_trust            -> ready  (Pi needs user to approve project trust)
//   agent_end                -> done   (back at the input prompt)
//   session_shutdown(quit)   -> idle   (removed from the agents panel)
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { closeSync, openSync, writeSync } from "node:fs";

const TERMPROP = "vte.ext.sidekick.agent";

function report(status: "busy" | "ready" | "done" | "idle"): void {
  try {
    const fd = openSync("/dev/tty", "w");
    try {
      writeSync(fd, `\x1b]666;${TERMPROP}=${status}\x1b\\`);
    } finally {
      closeSync(fd);
    }
  } catch {
    // No controlling terminal (print/RPC mode) — nothing to report to.
  }
}

export default function (pi: ExtensionAPI) {
  // Register the tab in the agents panel as soon as the session opens.
  pi.on("session_start", async () => report("done"));

  pi.on("agent_start", async () => report("busy"));

  // Flip back to busy as soon as a tool starts executing — covers the case
  // where a project_trust dialog was just resolved and the pending tool runs.
  pi.on("tool_call", async () => report("busy"));

  // Pi needs the user to approve running code in this directory.
  // Report ready so Sidekick highlights it, then return undecided so Pi
  // handles the actual trust UI itself.
  pi.on("project_trust", async () => {
    report("ready");
    return { trusted: "undecided" as const };
  });

  pi.on("agent_end", async () => report("done"));

  pi.on("session_shutdown", async (event) => {
    if (event.reason === "quit") {
      report("idle");
    }
  });
}

import { install } from "./commands/install.js";
import { update } from "./commands/update.js";
import { uninstall } from "./commands/uninstall.js";
import { status } from "./commands/status.js";

const HELP = `dry-eyes — semantic duplicate-code scans for Claude Code

Usage:
  npx dry-eyes install [--project]     Install (global by default)
  npx dry-eyes update [--project]      Re-copy the latest version
  npx dry-eyes uninstall [--project]   Remove what was installed
  npx dry-eyes status                  Show what's installed, and where

Flags:
  --project   Install/update/uninstall to this repo's .claude/skills/dry-eyes
              instead of the global ~/.claude/skills/user/dry-eyes.

After installing, open Claude Code in any repository and run:
  /dry-eyes init   configure (exclude patterns, output location, scopes, probes)
  /dry-eyes scan   sweep the whole repo, cluster candidates, verify, compare every variant

DRY Eyes is Claude Code only for v1 — no --target flag (see README for why).

Docs: https://github.com/kigiela/dry-eyes
`;

export async function run(argv) {
  const [cmd, ...rest] = argv;
  const project = rest.includes("--project");

  switch (cmd) {
    case "install":
      return install({ project });
    case "update":
      return update({ project });
    case "uninstall":
      return uninstall({ project });
    case "status":
      return status();
    case "--help":
    case "-h":
    case undefined:
      console.log(HELP);
      return;
    default:
      console.error(`Unknown command: ${cmd}\n`);
      console.log(HELP);
      process.exitCode = 1;
  }
}

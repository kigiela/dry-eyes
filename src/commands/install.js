import { copySkill } from "../lib/installCore.js";

export async function install({ project = false } = {}) {
  const { targetDir, fileCount, version, alreadyInstalled } = copySkill({ project });

  if (alreadyInstalled) {
    console.log(`dry-eyes ${version} refreshed at ${targetDir} (${fileCount} files).`);
  } else {
    console.log(`dry-eyes ${version} installed at ${targetDir} (${fileCount} files).`);
  }
  console.log("");
  console.log("Next: open Claude Code in a repository and run:");
  console.log("  /dry-eyes init   configure (exclude patterns, output location, scopes, duplication probes)");
  console.log("  /dry-eyes scan   sweep the whole repo, cluster candidates, verify, compare every variant");
  console.log("");
  console.log(
    "A brand-new Claude Code session may be needed to discover the skill (skills are read at session start).",
  );
  if (!project) {
    console.log("");
    console.log("(Installed globally. Use --project to install into this repo's .claude/skills/ instead.)");
  }
}

import fs from "node:fs";
import { installTargetDir } from "../lib/paths.js";
import { removeDirRecursive } from "../lib/copy.js";

// Removes ONLY the installed skill files. Never touches a target repository's
// own `.dry-eyes/` directory (config, probes, generated reports) — that has
// a separate lifecycle and belongs to whichever repo `/dry-eyes init` ran
// in, not to this install.
export async function uninstall({ project = false } = {}) {
  const targetDir = installTargetDir({ project });

  if (!fs.existsSync(targetDir)) {
    console.log(`Nothing installed at ${targetDir} — nothing to do.`);
    return;
  }

  removeDirRecursive(targetDir);
  console.log(`Removed dry-eyes from ${targetDir}.`);
  console.log(
    "(Any .dry-eyes/ config or DRY_EYES_SCAN_*.md/.json reports in repos where you ran /dry-eyes are untouched — those belong to that repo, not to this install.)",
  );
}

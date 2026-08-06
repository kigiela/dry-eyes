import fs from "node:fs";
import { installTargetDir, installMetaPath, readJsonSafe } from "../lib/paths.js";

export async function status() {
  const globalDir = installTargetDir({ project: false });
  const projectDir = installTargetDir({ project: true });

  const globalMeta = readJsonSafe(installMetaPath(globalDir));
  const projectMeta = readJsonSafe(installMetaPath(projectDir));

  console.log("dry-eyes install status:");
  console.log("");
  console.log(`  Global   (${globalDir}):`);
  console.log(globalMeta ? `    installed, version ${globalMeta.version}` : "    not installed");
  console.log("");
  console.log(`  Project  (${projectDir}, relative to cwd):`);
  console.log(projectMeta ? `    installed, version ${projectMeta.version}` : "    not installed");

  if (fs.existsSync(".dry-eyes/config.json")) {
    console.log("");
    console.log("  This repo has a .dry-eyes/config.json — /dry-eyes init has been run here.");
    console.log(
      fs.existsSync(".dry-eyes/probes.json")
        ? "  .dry-eyes/probes.json is present — /dry-eyes scan will reuse it."
        : "  .dry-eyes/probes.json is missing — /dry-eyes scan will auto-bootstrap it non-interactively.",
    );
  }

  if (!globalMeta && !projectMeta) {
    console.log("");
    console.log("Run `npx dry-eyes install` to get started.");
  }
}

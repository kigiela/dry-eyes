import fs from "node:fs";
import path from "node:path";
import { SKILL_SOURCE_DIR, installTargetDir, installMetaPath } from "./paths.js";
import { copyDirRecursive, listFilesRecursive } from "./copy.js";

function packageVersion() {
  const pkgPath = path.join(SKILL_SOURCE_DIR, "..", "..", "package.json");
  const pkg = JSON.parse(fs.readFileSync(pkgPath, "utf8"));
  return pkg.version;
}

/**
 * Copies skills/dry-eyes/** into the target dir and writes .install-meta.json.
 * Always overwrites (no diff/hash-aware update in v1).
 * Returns { targetDir, fileCount, version, alreadyInstalled }.
 */
export function copySkill({ project = false } = {}) {
  const targetDir = installTargetDir({ project });
  const alreadyInstalled = fs.existsSync(installMetaPath(targetDir));
  const version = packageVersion();

  copyDirRecursive(SKILL_SOURCE_DIR, targetDir);

  const fileCount = listFilesRecursive(SKILL_SOURCE_DIR).length;
  fs.writeFileSync(
    installMetaPath(targetDir),
    JSON.stringify(
      {
        package: "dry-eyes",
        version,
        installedAt: new Date().toISOString(),
        project,
      },
      null,
      2,
    ) + "\n",
  );

  return { targetDir, fileCount, version, alreadyInstalled };
}

import { copySkill } from "../lib/installCore.js";
import { installTargetDir, installMetaPath, readJsonSafe } from "../lib/paths.js";

export async function update({ project = false } = {}) {
  const targetDir = installTargetDir({ project });
  const previousVersion = readJsonSafe(installMetaPath(targetDir))?.version ?? null;

  const { fileCount, version } = copySkill({ project });

  if (!previousVersion) {
    console.log(`No existing install found at ${targetDir} — installed dry-eyes ${version} fresh (${fileCount} files).`);
  } else if (previousVersion === version) {
    console.log(`dry-eyes ${version} was already up to date at ${targetDir} (re-copied ${fileCount} files anyway).`);
  } else {
    console.log(`Updated dry-eyes ${previousVersion} → ${version} at ${targetDir} (${fileCount} files).`);
  }
}

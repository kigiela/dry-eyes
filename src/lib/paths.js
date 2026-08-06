import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const SKILL_NAME = "dry-eyes";

// Resolves to the package root (the directory containing package.json),
// regardless of whether this is running from a local checkout or a
// downloaded npm tarball.
const THIS_FILE = fileURLToPath(import.meta.url);
export const PACKAGE_ROOT = path.resolve(path.dirname(THIS_FILE), "..", "..");

export const SKILL_SOURCE_DIR = path.join(PACKAGE_ROOT, "skills", SKILL_NAME);

export function installTargetDir({ project = false } = {}) {
  return project
    ? path.join(process.cwd(), ".claude", "skills", SKILL_NAME)
    : path.join(os.homedir(), ".claude", "skills", "user", SKILL_NAME);
}

export function installMetaPath(targetDir) {
  return path.join(targetDir, ".install-meta.json");
}

// Shared by status.js (which needs the whole object) and update.js (which
// only needs .version) — a single "corrupted/missing file means not
// installed" reading, not two independent ones. Deliberately swallows any
// read/parse error the same way: a genuinely corrupted .install-meta.json
// and a missing one are both just "treat as not installed" here, since
// there's no user-facing distinction worth making between them at this
// layer (a corrupted meta file gets fixed by re-running install anyway).
export function readJsonSafe(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8"));
  } catch {
    return null;
  }
}

// No --target / TOOL_INTEGRATIONS here, unlike 16-eyes. DRY Eyes v1 is Claude
// Code only — this pipeline leans much harder on real deterministic code
// (bucketing, Jaccard merging, the path-hallucination guard) than a security
// audit does, and a prompted-JSON port to a tool without the Workflow API
// would degrade far worse. See the plan's "Deliberately dropped" section.

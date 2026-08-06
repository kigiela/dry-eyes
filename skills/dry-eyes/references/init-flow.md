# `/dry-eyes init` — configure

Two ways this runs: **standard** (the user typed `/dry-eyes init` directly —
detect → inventory → interview → confirm → write) and **auto-bootstrap**
(invoked internally by `/dry-eyes scan` because `.dry-eyes/probes.json`
doesn't exist yet — no interview, sane defaults, safe to run with no human
present). Both end the same way: `.dry-eyes/probes.json` gets written — the
persisted repo profile + duplication-probe set that `scan` loads from,
instead of profiling the repo and designing probes fresh on every run.

A **probe** here is the deliberate counterpart to a security-audit skill's
**lens**: a lens is an expensive LLM investigation area; a probe configures a
cheap deterministic signal (grep/awk-based — see
`../assets/collect-signals.sh`) plus, in `thorough` mode, an optional
supplementary LLM inventory sweep for whatever the signals can't see.

## Standard mode (user-invoked)

Five phases, strictly in order. Do **not** write `.dry-eyes/config.json` or
`.dry-eyes/probes.json` before Phase 5.

### Phase 1 — Detect existing config

Check whether `.dry-eyes/config.json` already exists in the repo root.

- **Exists:** read it, tell the user what it currently has, and ask whether
  they want to update it (re-run the interview, keeping current values as
  defaults) or leave it as is. If leaving it as is, ask separately whether
  they'd also like the probes regenerated (useful after the repo has changed
  shape significantly) — if not, stop here.
- **Doesn't exist:** continue to Phase 2 as a fresh setup.

### Phase 2 — Inventory

Explore the repo (don't ask the user yet):

- **Package/workspace layout.** Find every package manifest
  (`package.json`, `pyproject.toml`, `go.mod`, `Gemfile`, `Cargo.toml`, ...)
  and note its path, language, and an inferred role (web app / api / shared
  lib / worker / ...). A monorepo with `apps/`, `packages/`, or workspace
  entries needs one entry per package, not one for the whole repo. This
  becomes `profile.packages` and seeds `config.json`'s `scopes[]`.
- **Existing clone tooling.** Check for `.jscpd.json`, a `jscpd`/`cpd` config
  block in `package.json`, a PMD ruleset, or similar. If found, note it —
  category design should deprioritize categories whose duplication would be
  plain textual copy-paste, since that tool already finds those.
- **Output location.** Does a `docs/` directory exist? That's the default
  report location; otherwise the repo root.
- **`.gitignore` contents** — context for the exclude-patterns question next.

### Phase 3 — Interview

Ask briefly (grouped questions, not a long form):

1. **Exclude patterns** — propose this default set, adjusted for anything
   seen in `.gitignore`:
   ```
   node_modules/**  dist/**  build/**  vendor/**  **/*.min.js
   **/*.test.*  **/*.spec.*  **/__tests__/**  **/test/**  **/tests/**
   **/generated/**  **/*.gen.*  **/*.pb.go  **/*_pb2.py  **/*.g.dart
   **/migrations/**  **/__snapshots__/**  **/fixtures/**  **/*.lock
   ```
   Tests and migrations are excluded **by design, not just convenience**:
   duplication inside tests is usually a feature (explicitness over DRY, and
   a test asserting the same shape as a sibling test is not a maintenance
   burden), and migrations are append-only by construction — every migration
   repeats similar DDL and none of it is a DRY violation. Both are the
   single biggest noise sources in a naive duplication scan. Mention this
   reasoning and offer to put either back in if the user wants them scanned.
2. **Output location** — confirm the `docs/`-or-root default, or let the
   user pick a different directory.
3. **Default depth** — "quick" (signals only — no LLM category sweep, 1
   comparison vote per divergent cluster, ~6-10 categories designed below)
   vs "thorough" (the default — adds the supplementary LLM sweep that
   catches duplication sharing no surface signal, 3 rotated comparison
   votes, as many categories as the repo's surface area warrants).
4. **Gitignore the reports?** — ask explicitly, default **no** if unsure.
   This is the opposite of a security-audit tool's usual default: a
   duplication report is a refactoring backlog most teams want in git
   history, not a write-up of exploit steps that's risky to commit. Present
   it as a real choice regardless.
5. **Report language** — default `en`; ask if they'd prefer `pt` or `es`.
6. **Model** — which model every subagent call in the scan pipeline
   (category sweep, triage, verification, comparison, reconciliation,
   synthesis) should use:
   - **Sonnet** (recommended, the default) — pinned regardless of the
     invoking session's own model, so a thorough scan's ~150-200 subagent
     calls stay cost-predictable.
   - **Claude Code's own default** — inherit whatever model the invoking
     session itself is on.
   - **A specific model** other than Sonnet — Opus or Haiku. Ask which if
     picked.
7. **Cross-package scope** — if Phase 2 found more than one package sharing
   a language: "compare across packages that share a language (e.g. a
   monorepo's `apps/web` and `packages/ui`), or keep every package strictly
   isolated?" Default **same-language** — the former is usually the
   highest-value finding in a monorepo (one app split across packages);
   the latter never lets a candidate cluster span two packages at all. Skip
   this question if Phase 2 found only one package — there's nothing to
   cross. Either way, a package Phase 2 flagged as its own independently
   deployed service is never merged into another package's candidate pool,
   regardless of this answer — two decoupled services duplicating something
   is a different, and much lower-confidence, kind of finding than one app's
   own internal duplication.

No CI question — DRY Eyes has no CI template in v1 (see `SKILL.md`'s "What
this does not do").

### Phase 4 — Confirm

Show the user the exact `.dry-eyes/config.json` about to be written, and
tell them you're about to profile the repo and design its duplication
probes (a handful of agent calls, well under a minute) — get one go-ahead
before doing either.

### Phase 5 — Design probes & write

1. **Call the `Workflow` tool** with `script` set to the exact contents of
   "The profile/probe-design workflow script" below, and
   `args: { excludePatterns, depth, model, crossPackage }` from the Phase 3
   answers. The user invoking `/dry-eyes init` is the opt-in to multi-agent
   orchestration — don't ask again.
2. **Derive `config.json`'s `scopes[]` from the workflow's `profile.packages`**:
   group packages by language (or keep one scope per package if the user
   chose `crossPackage: "never"`), each getting an `id` (a slug from the
   package path or language), a `root`, the `language`, and `include` globs
   inferred from the package's own language/manifest (e.g. `**/*.rb` for a
   Ruby package, `**/*.ts,**/*.tsx` for a TypeScript one).
3. **Write `.dry-eyes/config.json`**, matching this shape (documented
   formally in `../assets/config.schema.json`):

   ```json
   {
     "$schema": "../../.claude/skills/dry-eyes/assets/config.schema.json",
     "version": 1,
     "depth": "thorough",
     "language": "en",
     "model": "sonnet",
     "excludePatterns": [
       "node_modules/**", "dist/**", "build/**", "vendor/**", "**/*.min.js",
       "**/*.test.*", "**/*.spec.*", "**/__tests__/**", "**/test/**", "**/tests/**",
       "**/generated/**", "**/*.gen.*", "**/migrations/**",
       "**/__snapshots__/**", "**/fixtures/**", "**/*.lock"
     ],
     "scopes": [
       { "id": "ruby-app", "root": ".", "language": "ruby", "include": ["app/**/*.rb", "lib/**/*.rb"] }
     ],
     "output": {
       "dir": "docs",
       "markdownPattern": "DRY_EYES_SCAN_{date}.md",
       "jsonPattern": "DRY_EYES_SCAN_{date}.json",
       "gitignoreReports": false
     },
     "probesPointer": ".dry-eyes/probes.json",
     "lastRunPointer": ".dry-eyes/last-run.json",
     "scan": {
       "crossPackage": "same-language",
       "maxOccurrencesPerBucket": 25,
       "minClusterSize": 2,
       "maxBuckets": 40
     },
     "comparison": { "votesPerCluster": 3, "rotateVariantOrder": true },
     "signals": {
       "literalCooccurrence": { "enabled": true, "minFiles": 3, "maxFiles": 12, "minLength": 14, "maxLength": 110, "topN": 300 },
       "pathMirror": { "enabled": true, "nonTerminalWildcardOnly": true, "minVariants": 2, "topN": 200 },
       "lineOverlap": { "enabled": true, "minSharedLines": 8, "minLineLength": 25, "minOccurrences": 3, "maxOccurrences": 12, "topN": 400 },
       "nameFamily": { "enabled": true, "requireDomainWord": true, "minVariants": 2, "topN": 200 },
       "concernMechanism": { "enabled": true },
       "externalCloneTool": { "enabled": false, "command": null }
     },
     "suppress": []
   }
   ```

   Omit a scope's `include` globs you couldn't infer confidently (fall back
   to the package's whole directory). If the user chose `depth: "quick"`,
   set `comparison.votesPerCluster` to `1` instead of `3`. If they opted to
   gitignore reports, add the configured report filename pattern to the
   repo's `.gitignore` (create it if it doesn't exist, append if it does —
   never overwrite). Set `scan.crossPackage` from question 7 (default
   `"same-language"` if the question was skipped for having only one
   package). Set `model` from question 6.
4. **Write `.dry-eyes/probes.json`**:
   ```json
   {
     "version": 1,
     "generatedAt": "<ISO timestamp from your own context>",
     "gitRev": "<git rev-parse HEAD, via Bash>",
     "profile": "<the workflow's `profile` return value, verbatim, with `categories` merged in as `conceptCategories`>"
   }
   ```
5. Tell the user it's done: how many categories were designed and a
   one-line sense of what they cover (from `profile.domainSummary`), how
   many scopes were detected, and that `/dry-eyes scan` will pick all of
   this up automatically from here on. Mention that both files are plain,
   editable JSON — the cheapest lever on recall if a category or scope
   turns out to be missing or mis-scoped, and that re-running `/dry-eyes
   init` regenerates the probes from scratch.

## Auto-bootstrap mode (invoked internally by `scan`)

Triggered the moment `/dry-eyes scan` looks for `.dry-eyes/probes.json` (per
`config.probesPointer`) and doesn't find it. **Never interview, never wait
for confirmation.**

1. **If `.dry-eyes/config.json` already exists**, read it and reuse its
   `excludePatterns`/`depth`/`model`/`scan.crossPackage` as-is — don't touch
   or ask about anything else in it. If `probesPointer` is missing from it
   (an older config), add the default (`.dry-eyes/probes.json`) when writing
   it back out. If `scopes` is missing or empty, run Phase 2's
   package-detection now to fill it in.
2. **If `.dry-eyes/config.json` doesn't exist**, run Phase 2's inventory
   automatically and write `.dry-eyes/config.json` with every documented
   default verbatim from the Phase 5 shape above (including
   `output.gitignoreReports: false`, `scan.crossPackage: "same-language"`,
   `model: "sonnet"`) — no interview, no confirmation step. **Also read
   `.gitignore` (if present) and append its own top-level patterns to
   `excludePatterns`**, on top of the hardcoded default set — this needs no
   human judgment call (a repo's own `.gitignore` is already a statement of
   "not part of the real codebase," safe to fold in automatically), unlike
   the interactive Phase 3 exclude question, which additionally asks the
   user to confirm/adjust the *proposed* list. Skipping this step would mean
   auto-bootstrap silently sweeps whatever a project-specific ignored
   directory happens to be (a build-output name that doesn't match any
   hardcoded pattern, a local dev-only scratch folder, etc.) that the
   interactive path would have caught via the same `.gitignore` read.
3. **Call the same `Workflow` script** as Standard mode Phase 5 step 1, with
   whatever `excludePatterns`/`depth`/`model`/`crossPackage` resulted from
   step 1 or 2 above.
4. **Derive `scopes[]` and write both files** exactly as in Standard mode
   Phase 5 steps 2-4.
5. **Return control** to `scan` and continue its flow immediately. `scan`'s
   own final summary must mention that config/probes were bootstrapped just
   now with defaults, and that `/dry-eyes init` can be run anytime
   afterward to customize any of it (it will detect the bootstrapped config
   and offer to update it, per Phase 1).

## The profile/probe-design workflow script

```js
export const meta = {
  name: 'dry-eyes-probe-design',
  description: 'Profile a repo and design a tailored set of duplication-prone categories, persisted for /dry-eyes scan to reuse.',
  phases: [{ title: 'Profile' }, { title: 'Category design' }],
}

const PROFILE_SCHEMA = {
  type: 'object',
  properties: {
    languages: { type: 'array', items: { type: 'string' } },
    frameworks: { type: 'array', items: { type: 'string' } },
    domainSummary: { type: 'string' },
    architectureSummary: { type: 'string' },
    packages: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          path: { type: 'string' },
          language: { type: 'string' },
          role: { type: 'string' },
          independentlyDeployed: { type: 'boolean' },
        },
        required: ['path', 'language', 'role'],
      },
    },
    sharedModulePaths: { type: 'array', items: { type: 'string' } },
    duplicationHypotheses: { type: 'array', items: { type: 'string' } },
    existingCloneTooling: { type: 'array', items: { type: 'string' } },
  },
  required: ['languages', 'domainSummary', 'architectureSummary', 'packages', 'duplicationHypotheses'],
}

const CATEGORIES_SCHEMA = {
  type: 'object',
  properties: {
    categories: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          id: { type: 'string' },
          label: { type: 'string' },
          focus: { type: 'string' },
          conceptExamples: { type: 'array', items: { type: 'string' } },
          scope: {
            type: 'object',
            properties: {
              language: { type: 'string' },
              packages: { type: 'array', items: { type: 'string' } },
            },
            required: ['language'],
          },
          domainWords: { type: 'array', items: { type: 'string' } },
          mechanisms: {
            type: 'array',
            items: {
              type: 'object',
              properties: { label: { type: 'string' }, pattern: { type: 'string' } },
              required: ['label', 'pattern'],
            },
          },
          expectedSharedHome: { type: 'string' },
          inventoryPrompt: { type: 'string' },
          priority: { type: 'string', enum: ['high', 'medium', 'low'] },
        },
        required: ['id', 'label', 'scope', 'priority'],
      },
    },
  },
  required: ['categories'],
}

const excludePatterns = (args && Array.isArray(args.excludePatterns) && args.excludePatterns) || []
const depth = args && args.depth === 'quick' ? 'quick' : 'thorough'
const modelPolicy = args && typeof args.model === 'string' ? args.model : 'sonnet'
const modelOpt = modelPolicy !== 'default' ? { model: modelPolicy } : {}
const crossPackage = args && args.crossPackage === 'never' ? 'never' : 'same-language'

const excludeNote = excludePatterns.length
  ? `\n\nDo not consider anything under these excluded paths (vendored/generated/test/fixture, already out of scope): ${excludePatterns.join(', ')}.`
  : ''
const depthNote =
  depth === 'quick'
    ? '\n\nDepth requested: QUICK — design only the 6-10 highest-value categories; skip lower-priority ones entirely rather than covering everything shallowly.'
    : ''

log('Profiling the repository (stack, packages, domain, architecture)...')
phase('Profile')
const profile = await agent(
  `Profile this repository for a duplicate-code-detection planning step. Explore its structure (package manifests, lockfiles, workspace/monorepo config, top-level directories, README). Identify:
- languages and frameworks in use
- domainSummary: what this application/service actually does, for whom
- architectureSummary: monolith vs services, frontend/backend split, monorepo layout
- packages: every distinct package/workspace found — path, language, role ("web app"/"api"/"shared lib"/"worker"/...), and independentlyDeployed (true only if it's genuinely its own deployable service, not just a folder)
- sharedModulePaths: existing shared/common module locations, if any (used later to suggest where a consolidated implementation should live)
- duplicationHypotheses: concrete, repo-shape observations about WHERE duplication is likely — e.g. "app/connectors/* looks like one adapter per external vendor, expect shared error-handling/list-fetch logic reimplemented per vendor", "these two directories look like mirrored product lines". Ground each in something you actually saw (a directory name, a manifest, a README line), not speculation.
- existingCloneTooling: any jscpd/PMD-CPD/similar textual-clone-detector config already present in the repo, if any.${excludeNote}`,
  { schema: PROFILE_SCHEMA, phase: 'Profile', label: 'profile', ...modelOpt },
)
log(
  `Profile: ${(profile?.languages || []).join(', ')} · ${(profile?.packages || []).length} package(s) · ${(profile?.duplicationHypotheses || []).length} duplication hypothesis(es)`,
)

phase('Category design')
const categoryDesign = await agent(
  `You are designing the standing duplication-detection plan for a repository (every /dry-eyes scan will reuse this same plan), given this profile:

Languages: ${(profile?.languages || []).join(', ')}
Frameworks: ${(profile?.frameworks || []).join(', ')}
Domain: ${profile?.domainSummary}
Architecture: ${profile?.architectureSummary}
Packages: ${(profile?.packages || []).map((p) => `${p.path} (${p.language}, ${p.role}${p.independentlyDeployed ? ', independently deployed' : ''})`).join('; ')}
Shared module locations: ${(profile?.sharedModulePaths || []).join(', ') || 'none found'}
Duplication hypotheses: ${(profile?.duplicationHypotheses || []).join('; ')}
Existing clone tooling: ${(profile?.existingCloneTooling || []).join(', ') || 'none'}

Produce a list of duplication-prone CATEGORIES — each a specific, repo-relevant concept area where the SAME business rule, calculation, validation, or UI/UX pattern is plausibly implemented more than once. This is NOT about textual copy-paste (a separate deterministic pass already handles that) — it's about the same MEANING implemented independently, possibly with different code, possibly with different behavior. Consider (include what applies, SKIP what doesn't, ADD repo-specific ones):
- validation rules, per entity/field
- monetary or quantitative calculation (pricing, discount, tax, fees, proration, totals)
- formatting & display (currency, dates, numbers, names, addresses)
- user-facing feedback (error messages, toasts, banners, modals, empty/loading states) — this is the category most likely to need a "mechanisms" list (see below)
- permission & entitlement checks
- data access / query construction patterns
- retry, timeout, and error-handling policy
- status/state-machine transitions
- mapping & serialization (DTO <-> domain <-> persistence)
- config & feature-flag reads
- date/timezone arithmetic
- idempotency & deduplication keys
- naming/structural duplication signals (sibling files or functions that look like independent rewrites — *V2/*New/*Old/*Copy suffixes, or synonym pairs like fetch/get/load, validate/verify/check, format/render/display) — always include ONE category like this even if nothing else applies, as a recall backstop that doesn't depend on having guessed the right domain area
- any business-logic-specific risk unique to this repo's actual domain

Hard constraints, because these enforce real product rules mechanically downstream:
- Every category's "scope.language" is exactly ONE language — never mix. If the same concept exists in more than one language, that's out of scope for this version and should not be merged into one category.
- "scope.packages", if given, obeys: ${crossPackage === 'never' ? 'packages are NEVER grouped together — one category per package if the concept repeats across packages.' : 'packages sharing a language MAY be grouped, EXCEPT never group two packages that are both independently deployed services — those are supposed to stay decoupled, and duplication between them is a different, lower-confidence kind of finding.'}
- If existingCloneTooling is non-empty, deprioritize (or omit) categories whose duplication would mostly be plain textual copy-paste — that tool already finds those cheaply.

For each category: "id" (slug), "label", "focus" (one line), "conceptExamples" (2-4 concrete examples of what would count), "scope" ({language, packages}), "domainWords" (lowercase words that would appear in a function/variable name implementing this concept — needed for the deterministic name-matching signal; without these, that signal is dominated by generic framework-convention names, so be specific and generous, include synonyms in different languages the domain might use e.g. Portuguese and English terms if this repo's domain is Brazilian), "mechanisms" (ONLY for a category about a "concern with multiple possible implementations", like user-facing feedback — a list of {label, pattern}, where pattern is a grep-style regex, NO backreferences, matching one plausible implementation mechanism; e.g. for error display: {label:"toast", pattern:"\\\\btoast\\\\b"}, {label:"inline-error", pattern:"\\\\bsetError\\\\b"} — omit "mechanisms" entirely for categories this doesn't apply to), "expectedSharedHome" (if this concept were factored out once, where should it live in THIS repo, based on sharedModulePaths — be concrete, e.g. "packages/pricing/src/discount.ts"), "inventoryPrompt" (used only in thorough mode: a COMPLETE standalone brief for an independent subagent to sweep this category across its scope and return an INVENTORY of every occurrence it finds — file:line, symbol, and a 1-3 sentence behavior summary each — explicitly telling it NOT to claim any two occurrences are duplicates yet, that's a later step's job; and to reconcile its coverage against however many files the category's scope actually has), and "priority" (high/medium/low).

Aim for as many categories as the repo's actual surface area warrants (6-10 for a small single-purpose service, more for a large multi-domain codebase).${depthNote}`,
  { schema: CATEGORIES_SCHEMA, phase: 'Category design', label: 'category-design', ...modelOpt },
)
const categories = (categoryDesign?.categories || []).filter((c) => c && c.id && c.label && c.scope)
log(`${categories.length} categor(ies) designed: ${categories.map((c) => c.id).join(', ')}`)

return { profile: { ...profile, conceptCategories: categories } }
```

## Design notes (for maintainers)

- **Why category design lives here, not in `scan-flow.md`:** profiling a repo
  and naming its duplication-prone categories is repo-shape work, done once,
  not per-run work — same rationale as 16-eyes' lens design.
- **Why `scope.language`/`scope.packages` are structured fields on the
  category, not prose inside a prompt:** the v1 same-language/same-package
  rule needs to be enforced *mechanically* by `scan-flow.md`'s bucketing
  logic (which can check a plain field), not left to a prompt an agent
  might drift from over a long category-design call.
- **Why `domainWords`/`mechanisms` are structured data, not embedded in
  `inventoryPrompt`'s prose:** `collect-signals.sh`'s deterministic
  `nameFamily` and `concernMechanism` signals consume them directly as CLI
  arguments — they need to be parseable data, not something `scan-flow.md`
  would have to extract from free text.
- **Why one naming/structural category is always requested:** it's the one
  category that doesn't depend on category design having correctly guessed
  the repo's domain — a cheap recall backstop for exactly the failure mode
  where init didn't think to name the right area.
- **Auto-bootstrap exists specifically for unattended runs** (a scripted
  `claude -p "/dry-eyes scan"` with no human present would otherwise hang on
  Phase 3/4's interview).

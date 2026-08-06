# `/dry-eyes scan` — sweep the whole repo

Turns cheap deterministic duplication signals into verified duplicate-code
clusters, then compares every cluster's variants against each other — and
against what a correct implementation would need — to answer the question
this tool exists for: not just "is this duplicated" but "which variant (if
any) is actually right, or does none of them handle everything."

Full-repo only — there is no diff/PR-scoped mode (see `SKILL.md`'s "What
this does not do"; duplicate detection is inherently whole-corpus, unlike a
security lens that reasons locally about one changed hunk).

## When invoked

Steps 1-8 and 10-11 happen in **this session** (`Bash`/`Read`/`Write` — the
`Workflow` script itself has none of these).

1. Determine `today` (`YYYY-MM-DD`) and `gitRev` (`git rev-parse HEAD`) from
   the repo — reports are commit-scoped, and a report read a week later has
   drifted line numbers, so this gets stamped and disclosed. **If the
   command fails** (no `.git` at all — not just uncommitted, genuinely not a
   git repository), pass `gitRev: null` and continue; don't treat it as
   fatal. Note that signal collection itself (`collect-signals.sh`) still
   requires a git work tree per-scope regardless — a non-git repo will get
   an `"error"` back from every scope's signal collection (handled in step
   5), so in practice this case surfaces there, not here.
2. Determine optional `focus` from the user's invocation (narrows which
   persisted categories/scopes run — never redesigns them) and whether the
   user asked for signals-only mode (e.g. "just show me the candidates" /
   `/dry-eyes scan --signals-only`) — zero agent calls, see step 8.
3. Read `.dry-eyes/config.json` (defaults apply to every field if absent):
   `depth` (default `thorough`), `language` (default `en`), `model`
   (default `sonnet`), `excludePatterns`, `scopes`, `output.*`,
   `probesPointer` (default `.dry-eyes/probes.json`), `scan.*`,
   `comparison.*`, `signals.*`, `suppress`.
4. Read the probes file. **If missing, run `init-flow.md`'s auto-bootstrap
   now**, then re-read both files and continue. Never invent a profile or
   categories yourself — `scan` always runs against a persisted,
   previously-designed set, exactly like a lens-based audit tool would.
5. **For each scope in `config.scopes`**, gather this scope's signals:
   a. From `probes.profile.conceptCategories`, collect every category whose
      `scope.language` matches this scope's language (and, if the category
      names specific `scope.packages`, whose packages overlap this scope's
      root).
   b. Build this scope's **domain-words** list: the union of every matching
      category's `domainWords`, deduped, comma-joined.
   c. Build this scope's **concerns file**: a TSV, one line per matching
      category's `mechanisms[]` entry — `<category.id>\t<mechanism.label>\t<mechanism.pattern>`
      — written with `Write` to a temp path (e.g.
      `.dry-eyes/.tmp-concerns-<scope.id>.tsv`, removed after step 5d).
   d. Run the collector:
      ```bash
      sh <skill-install-dir>/assets/collect-signals.sh \
        --root <repo-root> --scope-id <scope.id> \
        --include "<scope.include, comma-joined>" \
        --exclude "<config.excludePatterns, comma-joined>" \
        --domain-words "<this scope's domain words>" \
        --concerns-file <this scope's concerns TSV path> \
        --lit-min-files <signals.literalCooccurrence.minFiles> [... every threshold from config.signals, mapped 1:1 to the matching --lit-*/--line-*/--top-n-* flag]
      ```
      Parse its JSON stdout. If it returns an `"error"` field, log it and
      treat that scope as contributing zero signals rather than failing the
      whole scan. If `toolsAvailable.jq` is `false`, note in the eventual
      report's coverage section that `nameFamily`/`concernMechanism` were
      skipped for that scope (the collector says so itself in
      `signalsSkipped`) — install `jq` to get full signal coverage.
6. **Merge every scope's signal JSON** into one `signalsByScope` object
   keyed by scope id, and compute `knownPaths` — the union of every file
   path mentioned anywhere across every scope's signal output. This is the
   real-path universe the path-hallucination guard (below) checks every
   agent-named file against for signal-derived candidates (the supplementary
   inventory sweep's own discoveries get added to this universe as they
   come in — see the script's design notes on why that guard can't apply
   to sweep output the same way it does to signal output).
7. Clean up the temp concerns-file(s) from step 5c.
8. **If signals-only mode**: skip `Workflow` entirely. Render the bucket
   list straight from `signalsByScope` (no clustering/verification/
   comparison — this is the free, zero-agent-call preview) and stop here.
   Tell the user this is the raw candidate list before any judgment has been
   applied, and that a full `/dry-eyes scan` spends agent calls narrowing
   and comparing these.
9. **Call `Workflow`** with the script below and
   `args: { today, gitRev, focus, profile: probes.profile, signalsByScope,
   knownPaths, depth, language, model, thresholds: config.scan,
   comparison: config.comparison, suppress: config.suppress }`. Invoking the
   named skill is the user's opt-in to multi-agent orchestration — don't ask
   again.
10. Take `{ reportMarkdown, reportJson, stats }` and write both files with
    `Write`: `<outputDir>/DRY_EYES_SCAN_<today>.md` and `.json` (same-day
    collision → append `-2`, `-3`, never overwrite). Then write/overwrite
    `.dry-eyes/last-run.json` = `{ markdown, json, generatedAt, stats }`.
11. Report a short summary: buckets found, clusters confirmed vs dismissed,
    how many got the multi-vote comparison panel vs a single pass, **any
    coverage gaps** (dropped by a cap, a scope whose signal collection
    errored, `jq`/`rg` unavailability) — never imply exhaustiveness — both
    file paths, and whether step 4 auto-bootstrapped. State plainly: this
    only produces the report, it touches no code, and there is **no `fix`
    command in v1** — the JSON is the handoff artifact for whenever one
    exists.

## The scan workflow script

Everything below — schemas, the `T` i18n table, helpers, prompts, and the
script body — is ONE continuous script passed as `Workflow`'s `script`
parameter (matching 16-eyes' own convention: `export const meta` at the top,
followed by everything else, ending in the `return { reportMarkdown,
reportJson, stats }` at the bottom).

```js
export const meta = {
  name: 'dry-eyes-scan',
  description: "Turn cheap deterministic duplication signals into verified duplicate-code clusters, then compare each cluster's variants against each other and against what a correct implementation would need.",
  phases: [
    { title: 'Category selection' },
    { title: 'Bucketing' },
    { title: 'Inventory sweep' },
    { title: 'Triage' },
    { title: 'Verification' },
    { title: 'Comparison' },
    { title: 'Reconciliation' },
    { title: 'Synthesis' },
  ],
}

// ── Schemas ──────────────────────────────────────────────────────────────

const CATEGORY_SELECTION_SCHEMA = {
  type: 'object',
  properties: { selectedCategoryIds: { type: 'array', items: { type: 'string' } } },
  required: ['selectedCategoryIds'],
}

const INVENTORY_SCHEMA = {
  type: 'object',
  properties: {
    occurrences: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          label: { type: 'string' },
          conceptKey: { type: 'string', description: 'lowercase dotted slug; reuse the SAME key for occurrences believed to be the same concept' },
          file: { type: 'string' },
          startLine: { type: 'number' },
          symbol: { type: 'string' },
          behaviorSummary: { type: 'string' },
        },
        required: ['label', 'conceptKey', 'file', 'behaviorSummary'],
      },
    },
    truncated: { type: 'boolean' },
    coverageNotes: { type: 'string' },
  },
  required: ['occurrences', 'truncated'],
}

const TRIAGE_SCHEMA = {
  type: 'object',
  properties: {
    clusters: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          concept: { type: 'string' },
          conceptDescription: { type: 'string' },
          kind: { type: 'string', enum: ['business-rule', 'calculation', 'validation', 'ux-pattern', 'data-mapping', 'infrastructure-boilerplate', 'other'] },
          variantFiles: { type: 'array', items: { type: 'string' } },
          whySameConcept: { type: 'string' },
          confidence: { type: 'string', enum: ['high', 'medium', 'low'] },
        },
        required: ['concept', 'kind', 'variantFiles', 'whySameConcept', 'confidence'],
      },
    },
    discarded: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          reasonCode: { type: 'string', enum: ['already-shared', 'coincidental-signal', 'different-concept', 'framework-interface', 'intentional-decoupling', 'generated-code', 'test-fixture'] },
          explanation: { type: 'string' },
        },
        required: ['reasonCode', 'explanation'],
      },
    },
  },
  required: ['clusters', 'discarded'],
}

const VERDICT_SCHEMA = {
  type: 'object',
  properties: {
    isRealDuplication: { type: 'boolean' },
    confirmedVariantFiles: { type: 'array', items: { type: 'string' } },
    falsePositiveReason: { type: 'string', enum: ['already-shared', 'different-concept', 'framework-interface', 'generated-code', 'test-fixture', 'intentional-decoupling', 'trivially-small', 'other', 'none'] },
    duplicationType: { type: 'string', enum: ['semantic', 'textual', 'mixed'] },
    divergenceRisk: { type: 'string', enum: ['behaves-differently-today', 'could-drift', 'cosmetic-only', 'none'] },
    severity: { type: 'string', enum: ['high', 'medium', 'low'] },
    consolidationType: { type: 'string', enum: ['safe', 'risky'] },
    why: { type: 'string' },
  },
  required: ['isRealDuplication', 'confirmedVariantFiles', 'falsePositiveReason', 'duplicationType', 'divergenceRisk', 'severity', 'consolidationType', 'why'],
}

const COMPARISON_SCHEMA = {
  type: 'object',
  properties: {
    requiredBehavior: { type: 'array', items: { type: 'string' }, description: 'What a CORRECT implementation of this concept must do — write this FIRST, before judging any variant, derived from the domain/callers/union of what any variant handles.' },
    variants: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          file: { type: 'string' },
          behavior: { type: 'string' },
          edgeCasesHandled: { type: 'array', items: { type: 'string' } },
          edgeCasesMissed: { type: 'array', items: { type: 'string' } },
          correctness: { type: 'string', enum: ['correct', 'partially-correct', 'incorrect', 'cannot-determine'] },
        },
        required: ['file', 'behavior', 'correctness'],
      },
    },
    divergences: {
      type: 'array',
      items: {
        type: 'object',
        properties: { dimension: { type: 'string' }, detail: { type: 'string' }, consequence: { type: 'string' } },
        required: ['dimension', 'detail'],
      },
    },
    gapsInAllVariants: { type: 'array', items: { type: 'string' }, description: 'Behaviors NO variant handles. It is a common, expected outcome that this is non-empty — do not force one variant to look complete when it is not.' },
    verdictKind: { type: 'string', enum: ['one_variant_correct', 'none_fully_correct', 'context_dependent', 'equivalent'] },
    bestVariantFile: { type: 'string' },
    proposedCanonical: { type: 'string' },
    canonicalHome: { type: 'string' },
    recommendation: { type: 'string' },
    confidence: { type: 'string', enum: ['high', 'medium', 'low'] },
  },
  required: ['requiredBehavior', 'variants', 'divergences', 'gapsInAllVariants', 'verdictKind', 'proposedCanonical', 'recommendation', 'confidence'],
}

const RECONCILE_SCHEMA = {
  type: 'object',
  properties: {
    verdictKind: { type: 'string', enum: ['one_variant_correct', 'none_fully_correct', 'context_dependent', 'equivalent'] },
    bestVariantFile: { type: 'string' },
    agreement: { type: 'string', enum: ['unanimous', 'majority', 'split'] },
    dissentSummary: { type: 'string' },
    gapsInAllVariants: { type: 'array', items: { type: 'string' } },
    rebuttedGaps: { type: 'array', items: { type: 'string' }, description: 'Gap claims examined and found wrong, with why — every gap claim from every vote must end up in EITHER gapsInAllVariants OR here.' },
    proposedCanonical: { type: 'string' },
    canonicalHome: { type: 'string' },
    recommendation: { type: 'string' },
    confidence: { type: 'string', enum: ['high', 'medium', 'low'] },
  },
  required: ['verdictKind', 'agreement', 'gapsInAllVariants', 'proposedCanonical', 'recommendation', 'confidence'],
}

const EXEC_SUMMARY_SCHEMA = { type: 'object', properties: { summary: { type: 'string' } }, required: ['summary'] }

// ── i18n ─────────────────────────────────────────────────────────────────

const LANGUAGE_NAMES = { en: 'English', pt: 'Portuguese', es: 'Spanish' }

const T = {
  en: {
    intro: 'Semantic duplicate-code scan — the same business rule, calculation, or UI/UX pattern implemented independently more than once, often with different behavior each time. Not a token-matching clone detector: the comparison, not the detection, is the point.',
    coverageHeading: 'Coverage and method',
    scopesScanned: 'Scopes scanned',
    signalsUsed: 'Signals used',
    notCheckedHeading: 'Known gaps in this run',
    notCheckedNoSignal: 'This tool is high-precision, medium-recall by design: duplication sharing no repeated literal, no shared name, no similar line shape, and no mirrored path is invisible to these signals, and the supplementary sweep only catches it if a category happened to be designed for that area. A different-language implementation of the same rule is out of scope for this version entirely.',
    suppressedBy: 'Suppressed by config',
    scannedAtCommit: 'Scanned at commit',
    mapHeading: 'Duplication map',
    divergentHeading: 'Clusters that need a decision — variants behave differently',
    sameHeading: 'Plain duplication — variants behave the same',
    variantsHeading: 'Variants',
    divergenceHeading: 'Where they diverge',
    notHandled: 'Not handled by any existing variant',
    targetSketch: 'Proposed canonical implementation',
    recommendationLabel: 'Recommendation',
    appendixHeading: 'Appendix',
    discardedHeading: 'Not duplication',
    corruptedHeading: 'Analysis failed — needs manual review',
  },
  pt: {
    intro: 'Varredura de duplicação semântica de código — a mesma regra de negócio, cálculo ou padrão de UI/UX implementado de forma independente mais de uma vez, muitas vezes com comportamento diferente em cada versão. Não é um detector de clones por comparação literal: o ponto é a comparação, não a detecção.',
    coverageHeading: 'Cobertura e método',
    scopesScanned: 'Escopos varridos',
    signalsUsed: 'Sinais usados',
    notCheckedHeading: 'Lacunas conhecidas nesta execução',
    notCheckedNoSignal: 'Esta ferramenta é, por design, de alta precisão e recall médio: duplicações sem literal repetido, sem nome compartilhado, sem forma de linha semelhante e sem caminho espelhado são invisíveis a estes sinais, e a varredura complementar só as encontra se alguma categoria tiver sido desenhada para aquela área. Uma implementação da mesma regra em outra linguagem está totalmente fora do escopo desta versão.',
    suppressedBy: 'Suprimido pela configuração',
    scannedAtCommit: 'Varredura feita no commit',
    mapHeading: 'Mapa de duplicações',
    divergentHeading: 'Clusters que exigem uma decisão — as variantes se comportam de forma diferente',
    sameHeading: 'Duplicação simples — as variantes se comportam igual',
    variantsHeading: 'Variantes',
    divergenceHeading: 'Onde divergem',
    notHandled: 'Não tratado por nenhuma variante existente',
    targetSketch: 'Implementação canônica proposta',
    recommendationLabel: 'Recomendação',
    appendixHeading: 'Apêndice',
    discardedHeading: 'Não é duplicação',
    corruptedHeading: 'Análise falhou — precisa de revisão manual',
  },
  es: {
    intro: 'Escaneo de duplicación semántica de código — la misma regla de negocio, cálculo o patrón de UI/UX implementado de forma independiente más de una vez, a menudo con comportamiento diferente en cada versión. No es un detector de clones por coincidencia literal: el punto es la comparación, no la detección.',
    coverageHeading: 'Cobertura y método',
    scopesScanned: 'Ámbitos escaneados',
    signalsUsed: 'Señales usadas',
    notCheckedHeading: 'Brechas conocidas en esta ejecución',
    notCheckedNoSignal: 'Esta herramienta es, por diseño, de alta precisión y recall medio: las duplicaciones sin literal repetido, sin nombre compartido, sin forma de línea similar y sin ruta reflejada son invisibles para estas señales, y el barrido complementario solo las detecta si alguna categoría fue diseñada para esa área. Una implementación de la misma regla en otro lenguaje está totalmente fuera del alcance de esta versión.',
    suppressedBy: 'Suprimido por configuración',
    scannedAtCommit: 'Escaneado en el commit',
    mapHeading: 'Mapa de duplicación',
    divergentHeading: 'Clusters que necesitan una decisión — las variantes se comportan diferente',
    sameHeading: 'Duplicación simple — las variantes se comportan igual',
    variantsHeading: 'Variantes',
    divergenceHeading: 'Dónde divergen',
    notHandled: 'No manejado por ninguna variante existente',
    targetSketch: 'Implementación canónica propuesta',
    recommendationLabel: 'Recomendación',
    appendixHeading: 'Apéndice',
    discardedHeading: 'No es duplicación',
    corruptedHeading: 'El análisis falló — necesita revisión manual',
  },
}

// ── Helpers (pure JS — no imports available) ──────────────────────────────

// Ported VERBATIM from 16-eyes' audit-flow.md — same tool, same real
// observed failure: a schema-valid object where every string field is
// literally "test" (stale cache / crossed fixture). Never trust it blindly.
function looksCorrupted(obj) {
  if (!obj || typeof obj !== 'object') return false
  const strings = Object.values(obj).filter((v) => typeof v === 'string' && v.length > 0)
  return strings.length > 0 && strings.every((v) => v.trim().toLowerCase() === 'test')
}

function fnv1a(s) {
  let h = 0x811c9dc5
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i)
    h = (h + (h << 1) + (h << 4) + (h << 7) + (h << 8) + (h << 24)) >>> 0
  }
  return h.toString(16).padStart(8, '0')
}

function slug(s) {
  return String(s || '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 48) || 'cluster'
}

function clusterId(categoryOrScopeId, concept, variantFiles) {
  const key = [...variantFiles].map((f) => String(f).replace(/^\.\//, '')).sort().join('|')
  return `dup-${slug(categoryOrScopeId)}-${slug(concept)}-${fnv1a(key)}`
}

// Every signal-derived candidate file originates from collect-signals.sh's
// deterministic output, so the real-path universe for THOSE is knowable in
// advance — this is the one guard 16-eyes cannot have (its lens findings may
// legitimately point anywhere in the repo). The returned function also
// exposes `.add()` so the inventory sweep (which legitimately finds files no
// signal mentioned — that's its entire purpose) can extend the known-path
// universe with what it finds, rather than having its own discoveries
// wrongly rejected by the very guard meant to catch hallucination.
function makePathGuard(knownPaths) {
  const known = new Set((knownPaths || []).map((p) => String(p).replace(/^\.\//, '')))
  const check = (p) => known.has(String(p || '').replace(/^\.\//, ''))
  check.add = (p) => known.add(String(p || '').replace(/^\.\//, ''))
  return check
}

function isSuppressed(file, suppressList) {
  return (suppressList || []).some((s) => {
    const re = new RegExp('^' + String(s.pathGlob).replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*\*/g, '@@DS@@').replace(/\*/g, '[^/]*').replace(/@@DS@@/g, '.*') + '$')
    return re.test(file)
  })
}

function jaccard(a, b) {
  const A = new Set(a), B = new Set(b)
  let inter = 0
  for (const x of A) if (B.has(x)) inter++
  const union = A.size + B.size - inter
  return union === 0 ? 0 : inter / union
}

function scoreBucket(b) {
  return b.signals.length * 3 + Math.min(b.files.length, 6)
}

// Turns collect-signals.sh's per-scope, per-signal output into a unified
// candidate-bucket list, merging across signals within the same scope when
// their file sets substantially overlap (cross-signal agreement becomes a
// free confidence boost instead of a 3x cost) — plain JS, zero agent calls.
function normalizeSignalsToBuckets(signalsByScope, suppress) {
  const buckets = []
  for (const [scopeId, s] of Object.entries(signalsByScope || {})) {
    const sig = (s && s.signals) || {}
    for (const b of (sig.literalCooccurrence && sig.literalCooccurrence.buckets) || [])
      buckets.push({ scopeId, signal: 'literalCooccurrence', files: b.files, evidence: { literals: b.literals } })
    for (const f of (sig.pathMirror && sig.pathMirror.families) || [])
      buckets.push({ scopeId, signal: 'pathMirror', files: f.files, evidence: { pattern: f.pattern } })
    for (const p of (sig.lineOverlap && sig.lineOverlap.pairs) || [])
      buckets.push({ scopeId, signal: 'lineOverlap', files: [p.fileA, p.fileB], evidence: { sharedLines: p.sharedLines, scaffoldLines: p.scaffoldLines } })
    for (const n of (sig.nameFamily && sig.nameFamily.families) || [])
      buckets.push({ scopeId, signal: 'nameFamily', files: n.files, evidence: { name: n.name } })
    for (const c of (sig.concernMechanism && sig.concernMechanism.concerns) || []) {
      const allFiles = [...new Set(c.multiMechanismFiles || [])]
      if (allFiles.length >= 2)
        buckets.push({ scopeId, signal: 'concernMechanism', files: allFiles, evidence: { concernId: c.concernId, mechanisms: c.mechanisms } })
    }
  }
  const kept = buckets.filter((b) => !(b.files || []).every((f) => isSuppressed(f, suppress)))
  const merged = []
  for (const b of kept) {
    const target = merged.find((m) => m.scopeId === b.scopeId && jaccard(m.files, b.files) >= 0.5)
    if (target) {
      target.files = [...new Set([...target.files, ...b.files])]
      target.signals.push(b.signal)
      target.evidence.push({ signal: b.signal, ...b.evidence })
    } else {
      merged.push({ scopeId: b.scopeId, files: [...b.files], signals: [b.signal], evidence: [{ signal: b.signal, ...b.evidence }] })
    }
  }
  return merged
}

// ── Prompts ──────────────────────────────────────────────────────────────

function inventoryPrompt(category, languageName) {
  return `${category.inventoryPrompt}

Return an INVENTORY only — list every occurrence you find with file, startLine, symbol, and a 1-3 sentence behaviorSummary each. Do NOT claim any two occurrences are duplicates yet — that is a later step's job. Include things that look unique, not just things that look repeated. If you could not cover every candidate location, set truncated:true and say why in coverageNotes.

Write "label" and "behaviorSummary" in ${languageName}.`
}

function triagePrompt(bucket, profile, languageName) {
  return `The following files were flagged as POSSIBLY related by a cheap automated signal (${bucket.signals.join(', ')}) during a duplicate-code scan of this repository (${profile.domainSummary}). This is a candidate list, not a confirmed duplication claim.

Files: ${bucket.files.join(', ')}
Evidence: ${JSON.stringify(bucket.evidence)}

Read the actual code in each file yourself. Group them into CLUSTERS of 2+ files that implement the SAME CONCEPT (not merely the same general category — "validates an email" and "validates a CPF" are a different concept each, even if both are "validation"). A single file is never a cluster on its own. For anything you decide is NOT a genuine duplication candidate, put it in "discarded" with a reasonCode and why (already-shared via a common function/import, coincidental-signal match, different-concept, framework-interface conformance, intentional-decoupling between independently-deployed services, generated-code, test-fixture).

Write "concept", "conceptDescription", "whySameConcept", and every discarded "explanation" in ${languageName}.`
}

function verifyPrompt(cluster, languageName) {
  return `A candidate duplicate-code cluster was proposed: "${cluster.concept}" (${cluster.conceptDescription || ''}), kind: ${cluster.kind}.
Files: ${cluster.variantFiles.join(', ')}

Read the ACTUAL code in each file yourself — do not trust the description above. Decide:
- isRealDuplication: is this a genuine independent reimplementation of the same concept (not already shared via a common function/import, not superficially similar but conceptually different, not two files that are SUPPOSED to stay decoupled)?
- confirmedVariantFiles: the subset of the files above that really do belong in this cluster (drop any that don't; a cluster that shrinks to fewer than 2 is not real).
- duplicationType: semantic (different code, same meaning) / textual (near copy-paste) / mixed.
- divergenceRisk: behaves-differently-today (you can already see a real behavioral difference) / could-drift (identical today, but nothing stops it diverging) / cosmetic-only (only naming/formatting differs) / none (you don't yet know — the comparison step will determine this).
- severity, consolidationType (safe = purely mechanical to unify with no behavior change for any caller today; risky = touches money/auth or needs a product decision).
- why: your reasoning, referencing the real code you read.

Be skeptical — a coincidental signal match that isn't really the same concept is NOT real duplication, say so via falsePositiveReason.

Write "why" in ${languageName}.`
}

function comparePrompt(cluster, variantOrder, languageName) {
  const files = variantOrder.join(', ')
  return `${cluster.variantFiles.length} implementations of the same concept were found in this repository: "${cluster.concept}" — ${cluster.conceptDescription || ''}. Variants, in the order to consider them: ${files}.

Read the actual code of EVERY variant yourself — do not trust any summary.

1. First, before assessing any variant, write requiredBehavior: what a CORRECT implementation of this concept must do in this domain. Derive it from the domain, the callers, and the union of everything any variant handles — NOT from whichever variant you read first.
2. Then, for each variant, describe its actual behavior, edge cases handled, edge cases missed, and a correctness verdict.
3. Then list divergences: every dimension the variants actually behave differently on, and the real consequence. Ignore purely cosmetic differences (naming, formatting) unless they change behavior.
4. Do NOT assume one of the existing variants is correct. It is a common, expected outcome that none of them handles everything — if so, set verdictKind:"none_fully_correct" and list everything no variant handles in gapsInAllVariants. Use "context_dependent" when each variant is genuinely right for its own caller and the fix is to parameterize, not pick a winner. Use "equivalent" only when they truly behave identically. Use "one_variant_correct" ONLY when one variant fully satisfies your requiredBehavior list, and name it in bestVariantFile.
5. proposedCanonical: describe (in prose) the implementation that would be correct — which may be none of the existing ones. canonicalHome: where it should live in this repo${cluster.expectedSharedHome ? ` (this concept's expected home: ${cluster.expectedSharedHome})` : ''}.

Write every prose field in ${languageName}.`
}

function reconcilePrompt(cluster, votes, languageName) {
  const kinds = votes.map((v) => v.verdictKind)
  const gapClaims = [...new Set(votes.flatMap((v) => v.gapsInAllVariants || []))]
  const requiredUnion = [...new Set(votes.flatMap((v) => v.requiredBehavior || []))]
  return `${votes.length} independent analysts examined this duplicate-code cluster ("${cluster.concept}"). Their verdicts: ${kinds.join(', ')}.

Union of every required behavior any analyst identified (union, not majority — a requirement only one analyst thought of is still a real requirement): ${requiredUnion.join('; ') || 'none listed'}

Gap claims you must address individually — behaviors an analyst says NO variant handles: ${gapClaims.join('; ') || 'none'}. For each one, either carry it into gapsInAllVariants, or put it in rebuttedGaps WITH the reason it's wrong, having checked the real code yourself. You may not silently drop one.

Read the variants' real code yourself where the analysts disagree. Produce the final conclusion. If they split, set agreement:"split" and summarize the minority position in dissentSummary — it goes in the report either way, even if you side with the majority. Landing on "one_variant_correct" is allowed even when someone claimed a gap, but only after you have explicitly rebutted that gap in rebuttedGaps.

Write every prose field in ${languageName}.`
}

// ── Report rendering ───────────────────────────────────────────────────────

function renderCluster(c, n, L, compact) {
  const lines = []
  lines.push(`### ${n}. ${c.concept}  \`${c.id}\``)
  lines.push(`- **Severity:** ${(c.verdict && c.verdict.severity) || '?'} · **Confidence:** ${(c.conclusion && c.conclusion.confidence) || '?'} · **Agreement:** ${c.agreement}${c.reconcileFailed ? ' (reconcile failed — showing first analysis)' : ''}`)
  lines.push('')
  lines.push(`**${L.variantsHeading}**`)
  for (const v of (c.conclusion && c.conclusion.variants) || (c.variantFiles || []).map((f) => ({ file: f })))
    lines.push(`- \`${v.file}\`${v.behavior ? ` — ${v.behavior}` : ''}`)
  lines.push('')
  if (!compact && c.conclusion) {
    if ((c.conclusion.divergences || []).length) {
      lines.push(`**${L.divergenceHeading}**`)
      for (const d of c.conclusion.divergences) lines.push(`- ${d.dimension}: ${d.detail}${d.consequence ? ` — ${d.consequence}` : ''}`)
      lines.push('')
    }
    if ((c.conclusion.gapsInAllVariants || []).length) {
      lines.push(`**${L.notHandled}:**`)
      for (const g of c.conclusion.gapsInAllVariants) lines.push(`- ${g}`)
      lines.push('')
    }
    lines.push(`**Verdict:** ${c.conclusion.verdictKind}`)
    if (c.conclusion.proposedCanonical) lines.push(`**${L.targetSketch}:** ${c.conclusion.proposedCanonical}${c.conclusion.canonicalHome ? ` — ${c.conclusion.canonicalHome}` : ''}`)
    if (c.conclusion.recommendation) lines.push(`**${L.recommendationLabel}:** ${c.conclusion.recommendation}`)
    if (c.conclusion.dissentSummary) lines.push(`**Dissent:** ${c.conclusion.dissentSummary}`)
  }
  lines.push('')
  lines.push('---')
  lines.push('')
  return lines.join('\n')
}

function renderReport(ctx) {
  const { today, gitRev, L, execSummary, coverage, stats, divergent, equivalent, discarded, corrupted, failedComparison, notAnalyzed, unknownPathHits, depth } = ctx
  const md = []
  md.push(`# DRY Eyes — ${today}`)
  md.push('')
  md.push(`> ${L.intro}`)
  md.push('')
  if (execSummary) { md.push(execSummary); md.push('') }

  md.push(`## ${L.coverageHeading}`)
  md.push(`- ${L.scopesScanned}: ${coverage.signalsUsed.join(', ') || 'none'}`)
  md.push(`- ${L.signalsUsed}: literal co-occurrence, path mirroring, normalized-line overlap, name-family (domain-gated), concern/mechanism inventory${depth === 'thorough' ? ', supplementary LLM category sweep' : ' (quick mode: no LLM sweep)'}`)
  if (coverage.notChecked.length) {
    md.push(`- **${L.notCheckedHeading}:**`)
    for (const n of coverage.notChecked) md.push(`  - ${n}`)
  }
  md.push(`- ${L.notCheckedNoSignal}`)
  if (coverage.suppressed && coverage.suppressed.length) {
    for (const s of coverage.suppressed) md.push(`- ${L.suppressedBy}: \`${s.pathGlob}\` — ${s.reason}`)
  }
  if (coverage.caps.bucketsDropped) md.push(`- ${coverage.caps.bucketsDropped} candidate bucket(s) dropped by the bucket cap — never analyzed.`)
  if (notAnalyzed && notAnalyzed.length) md.push(`- ${notAnalyzed.length} confirmed cluster(s) dropped by the analysis cap — never compared.`)
  if (unknownPathHits && unknownPathHits.length) md.push(`- ${unknownPathHits.length} file reference(s) from agent output didn't match any known signal-derived path and were dropped (hallucination guard).`)
  if (gitRev) md.push(`- ${L.scannedAtCommit}: \`${gitRev}\``)
  md.push('')

  md.push(`## ${L.mapHeading}`)
  md.push('| Kind | Count |')
  md.push('|---|---|')
  md.push(`| ${L.divergentHeading} | ${divergent.length} |`)
  md.push(`| ${L.sameHeading} | ${equivalent.length} |`)
  md.push('')

  md.push(`## ${L.divergentHeading} (${divergent.length})`)
  md.push('')
  divergent.forEach((c, i) => md.push(renderCluster(c, i + 1, L)))

  md.push(`## ${L.sameHeading} (${equivalent.length})`)
  md.push('')
  equivalent.forEach((c, i) => md.push(renderCluster(c, i + 1, L, true)))

  md.push(`## ${L.appendixHeading}`)
  if (discarded.length) {
    md.push(`### ${L.discardedHeading} (${discarded.length})`)
    for (const d of discarded) md.push(`- ${d.concept || '(unnamed)'} — ${d.verdict ? d.verdict.falsePositiveReason : '?'}: ${d.verdict ? d.verdict.why : ''}`)
  }
  if (corrupted.length || failedComparison.length) {
    md.push(`### ${L.corruptedHeading} (${corrupted.length + failedComparison.length})`)
    for (const c of corrupted) md.push(`- ${c.concept || '(unnamed)'} — verification response looked corrupted`)
    for (const c of failedComparison) md.push(`- ${c.concept || '(unnamed)'} — every comparison vote failed/looked corrupted`)
  }

  const clusterJson = (c) => ({
    id: c.id, concept: c.concept, kind: c.kind, scopeId: c.scopeId, signals: c.signals,
    severity: c.verdict && c.verdict.severity, duplicationType: c.verdict && c.verdict.duplicationType,
    consolidationType: c.verdict && c.verdict.consolidationType,
    variants: (c.conclusion && c.conclusion.variants) || (c.variantFiles || []).map((f) => ({ file: f })),
    divergences: c.conclusion && c.conclusion.divergences,
    requiredBehavior: c.conclusion && (c.conclusion.requiredBehavior || []),
    gapsInAllVariants: c.conclusion && (c.conclusion.gapsInAllVariants || []),
    verdictKind: c.conclusion && c.conclusion.verdictKind,
    bestVariantFile: c.conclusion && c.conclusion.bestVariantFile,
    proposedCanonical: c.conclusion && c.conclusion.proposedCanonical,
    canonicalHome: c.conclusion && c.conclusion.canonicalHome,
    recommendation: c.conclusion && c.conclusion.recommendation,
    confidence: c.conclusion && c.conclusion.confidence,
    agreement: c.agreement, reconcileFailed: Boolean(c.reconcileFailed),
  })

  const reportJson = JSON.stringify({
    schemaVersion: 1, date: today, gitRev, coverage, stats,
    clusters: { divergent: divergent.map(clusterJson), equivalent: equivalent.map(clusterJson) },
    appendix: {
      discarded: discarded.map((d) => ({ concept: d.concept, reason: d.verdict && d.verdict.falsePositiveReason, why: d.verdict && d.verdict.why, files: d.variantFiles })),
      corrupted: corrupted.map((c) => ({ concept: c.concept, files: c.variantFiles })),
      analysisFailed: failedComparison.map((c) => ({ id: c.id, concept: c.concept, files: c.variantFiles })),
    },
  }, null, 2)

  return { reportMarkdown: md.join('\n'), reportJson }
}

// ── Script body ────────────────────────────────────────────────────────────

const today = (args && args.today) || 'unknown-date'
const gitRev = (args && args.gitRev) || null
const focus = args && args.focus ? String(args.focus) : null
const profile = (args && args.profile) || {}
const signalsByScope = (args && args.signalsByScope) || {}
const knownPaths = (args && args.knownPaths) || []
const depth = args && args.depth === 'quick' ? 'quick' : 'thorough'
const language = args && T[args.language] ? args.language : 'en'
const L = T[language]
const languageName = LANGUAGE_NAMES[language]
const modelPolicy = args && typeof args.model === 'string' ? args.model : 'sonnet'
const modelOpt = modelPolicy !== 'default' ? { model: modelPolicy } : {}
// Fallback defaults here MUST match assets/config.schema.json (the source of
// truth) — these only apply when config.json omits a field entirely.
const thresholds = { maxBuckets: 40, minClusterSize: 2, ...(args && args.thresholds) }
const comparisonCfg = { votesPerCluster: depth === 'quick' ? 1 : 3, rotateVariantOrder: true, ...(args && args.comparison) }
const suppress = (args && args.suppress) || []
const isKnownPath = makePathGuard(knownPaths)
const coverage = { signalsUsed: Object.keys(signalsByScope), notChecked: [], caps: {}, suppressed: suppress, scopesErrored: [] }

for (const [scopeId, s] of Object.entries(signalsByScope)) {
  if (s && s.error) coverage.scopesErrored.push({ scopeId, error: s.error })
  if (s && s.toolsAvailable && s.toolsAvailable.jq === false) coverage.notChecked.push(`${scopeId}: nameFamily/concernMechanism skipped (jq unavailable)`)
}

const allCategories = ((profile && Array.isArray(profile.conceptCategories) && profile.conceptCategories) || [])
  .filter((c) => c && c.id)

// ── Bucketing (plain JS, zero agent calls) ────────────────────────────────
phase('Bucketing')
let buckets = normalizeSignalsToBuckets(signalsByScope, suppress).map((b) => ({ ...b, score: scoreBucket(b) }))
buckets.sort((a, b) => b.score - a.score)
const droppedByCap = buckets.slice(thresholds.maxBuckets)
buckets = buckets.slice(0, thresholds.maxBuckets)
coverage.caps.bucketsDropped = droppedByCap.length
log(`${buckets.length} candidate bucket(s) from deterministic signals (${droppedByCap.length} dropped by cap)`)

if (buckets.length === 0 && allCategories.length === 0) {
  return {
    reportMarkdown: `# DRY Eyes — ${today}\n\n${L.notCheckedNoSignal}`,
    reportJson: JSON.stringify({ schemaVersion: 1, date: today, gitRev, coverage, clusters: { divergent: [], equivalent: [] } }, null, 2),
    stats: null,
  }
}

// ── Optional category/focus selection (categories are fixed — designed
// once by /dry-eyes init — a per-invocation focus narrows which ones feed
// the thorough-mode sweep this time; it never redesigns any) ─────────────
let categories = allCategories
if (focus && allCategories.length > 0) {
  phase('Category selection')
  const selection = await agent(
    `Given this focus area for a duplicate-code scan: "${focus}", and this list of available categories (id — label — focus), select every category plausibly relevant. Be inclusive when in doubt.\n\n${allCategories.map((c) => `- ${c.id} — ${c.label} — ${c.focus || ''}`).join('\n')}`,
    { schema: CATEGORY_SELECTION_SCHEMA, phase: 'Category selection', label: 'category-selection', ...modelOpt },
  )
  const selectedIds = new Set((selection && selection.selectedCategoryIds) || [])
  const filtered = allCategories.filter((c) => selectedIds.has(c.id))
  categories = filtered.length > 0 ? filtered : allCategories
}

// ── Inventory sweep (thorough only) — the supplementary layer that catches
// duplication sharing NO surface signal at all. A barrier here is fine: it
// must finish before buckets are considered final, and it's at most a
// couple dozen parallel calls, never the long pole. Files this sweep finds
// are ADDED to the known-path universe (isKnownPath.add) rather than
// checked against it — they're new discoveries by construction, not
// candidates the path-hallucination guard has any pre-existing list for. ──
if (depth === 'thorough' && categories.length > 0) {
  phase('Inventory sweep')
  log(`Supplementary LLM sweep over ${categories.length} categor(ies) — catches duplicates sharing no surface signal`)
  const swept = await parallel(
    categories.map((cat) => () =>
      agent(inventoryPrompt(cat, languageName), { schema: INVENTORY_SCHEMA, phase: 'Inventory sweep', label: `sweep:${cat.id}`, ...modelOpt })
        .then((r) => ({ cat, r })),
    ),
  )
  for (const { cat, r } of swept.filter(Boolean)) {
    if (!r || looksCorrupted(r)) continue
    const valid = (r.occurrences || []).filter((o) => o && o.file && o.behaviorSummary)
    const byKey = new Map()
    for (const o of valid) {
      isKnownPath.add(o.file)
      if (!o.conceptKey) continue
      if (!byKey.has(o.conceptKey)) byKey.set(o.conceptKey, [])
      byKey.get(o.conceptKey).push(o)
    }
    for (const [key, occs] of byKey) {
      if (occs.length < thresholds.minClusterSize) continue
      buckets.push({
        scopeId: (cat.scope && cat.scope.language) || 'unknown',
        files: [...new Set(occs.map((o) => o.file))],
        signals: ['llmSweep'],
        evidence: [{ signal: 'llmSweep', category: cat.id, conceptKey: key }],
        fromSweep: true,
      })
    }
    if (r.truncated) coverage.notChecked.push(`${cat.id}: inventory sweep truncated — ${r.coverageNotes || 'coverage incomplete'}`)
  }
}

// ── Triage -> Verification, streamed per bucket (pipeline, not
// parallel()+barrier: verification of bucket A's clusters starts the moment
// bucket A's triage returns, without waiting on the slowest bucket — same
// pattern as 16-eyes' audit-flow.md lenses->verify pipeline). ─────────────
phase('Triage')
const unknownPathHits = []
const perBucket = await pipeline(
  buckets,
  (bucket) => (bucket.fromSweep
    ? Promise.resolve({ clusters: [{ concept: bucket.evidence[0].conceptKey, kind: 'other', variantFiles: bucket.files, whySameConcept: 'from LLM inventory sweep', confidence: 'medium' }], discarded: [] })
    : agent(triagePrompt(bucket, profile, languageName), { schema: TRIAGE_SCHEMA, phase: 'Triage', label: `triage:${bucket.scopeId}`, ...modelOpt })),
  (raw, bucket) => {
    if (!raw || looksCorrupted(raw)) return []
    const clusters = (raw.clusters || [])
      .map((c) => {
        const kept = (c.variantFiles || []).filter((f) => {
          if (isKnownPath(f)) return true
          unknownPathHits.push({ bucket: bucket.scopeId, concept: c.concept, file: f })
          return false
        })
        return { ...c, variantFiles: kept, scopeId: bucket.scopeId, signals: bucket.signals, evidence: bucket.evidence }
      })
      .filter((c) => c.variantFiles.length >= thresholds.minClusterSize)
    return parallel(
      clusters.map((c) => () =>
        agent(verifyPrompt(c, languageName), { schema: VERDICT_SCHEMA, phase: 'Verification', label: `verify:${bucket.scopeId}`, ...modelOpt }).then((v) => {
          const corrupted = !v || looksCorrupted(v)
          const id = clusterId(c.scopeId, c.concept, c.variantFiles)
          return { ...c, id, verdict: corrupted ? null : v, verdictCorrupted: corrupted }
        }),
      ),
    )
  },
)
const allTriaged = perBucket.flat().filter(Boolean)
const corrupted = allTriaged.filter((c) => c.verdictCorrupted)
const judged = allTriaged.filter((c) => !c.verdictCorrupted && c.verdict)
const realBeforeDedup = judged.filter((c) => c.verdict.isRealDuplication && (c.verdict.confirmedVariantFiles || []).length >= thresholds.minClusterSize)
const discarded = judged.filter((c) => !c.verdict.isRealDuplication || (c.verdict.confirmedVariantFiles || []).length < thresholds.minClusterSize)

// Two DIFFERENT buckets (e.g. found by different signals whose raw files
// didn't overlap enough to merge pre-triage) can independently converge on
// the identical confirmed concept + file set — same `id` by construction
// (clusterId hashes the sorted confirmed file set). Without this, that
// cluster gets triaged/verified/compared/reconciled as many times as
// buckets proposed it: wasted agent calls, and the same finding repeated
// verbatim in the report. Merge by id, keeping every contributing bucket's
// signals (independent convergence is itself a confidence signal worth
// keeping, not discarding).
const byId = new Map()
for (const c of realBeforeDedup) {
  const existing = byId.get(c.id)
  if (!existing) { byId.set(c.id, c); continue }
  existing.signals = [...new Set([...(existing.signals || []), ...(c.signals || [])])]
  existing.evidence = [...(existing.evidence || []), ...(c.evidence || [])]
}
const realClusters = [...byId.values()]
log(`${allTriaged.length} candidate cluster(s) verified: ${realClusters.length} real (${realBeforeDedup.length - realClusters.length} deduplicated by id), ${discarded.length} discarded, ${corrupted.length} corrupted/failed verification`)

// ── Comparison: K independent, rotated, full re-derivations — NOT
// refutation. A refuter asked "can you disprove variant A is best?"
// inherits the same anchor on A that produced the original judgment.
// Independent full analyses, each seeing variants in a different order,
// attack the anchor directly (see design notes). Gate: only clusters whose
// divergenceRisk suggests something is actually worth adjudicating. ───────
phase('Comparison')
const SEV = { high: 3, medium: 2, low: 1 }
const prioritized = [...realClusters].sort((a, b) => (SEV[b.verdict.severity] || 0) - (SEV[a.verdict.severity] || 0))
const analyzed = prioritized.slice(0, thresholds.maxBuckets)
const notAnalyzed = prioritized.slice(thresholds.maxBuckets)
coverage.caps.clustersNotAnalyzed = notAnalyzed.length

const compared = await parallel(
  analyzed.map((c) => () => {
    const variantFiles = c.verdict.confirmedVariantFiles && c.verdict.confirmedVariantFiles.length ? c.verdict.confirmedVariantFiles : c.variantFiles
    const needsPanel = c.verdict.divergenceRisk === 'behaves-differently-today' || c.verdict.divergenceRisk === 'could-drift'
    const baseVotes = needsPanel ? comparisonCfg.votesPerCluster : 1
    const votes = budget.total && budget.remaining() < 250_000 ? 1 : baseVotes
    return parallel(
      Array.from({ length: votes }, (_, i) => {
        const offset = variantFiles.length > 0 ? i % variantFiles.length : 0
        const order = comparisonCfg.rotateVariantOrder
          ? [...variantFiles.slice(offset), ...variantFiles.slice(0, offset)]
          : variantFiles
        return () => agent(comparePrompt({ ...c, variantFiles }, order, languageName), { schema: COMPARISON_SCHEMA, phase: 'Comparison', label: `compare:${c.id}:${i}`, ...modelOpt })
      }),
    ).then((raw) => {
      const valid = raw.filter(Boolean).filter((v) => !looksCorrupted(v)).filter((v) => !v.bestVariantFile || isKnownPath(v.bestVariantFile))
      // ★ Direct analog of 16-eyes' "0 valid votes ≠ survived" guard.
      //   Zero valid votes must NEVER default to a winner — the consequence
      //   here is worse than a phantom finding: a fabricated "adopt variant
      //   A" is something a human refactors toward.
      if (valid.length === 0) return { ...c, variantFiles, comparisonFailed: true }
      let conclusion, agreement
      if (valid.length === 1) {
        conclusion = valid[0]
        agreement = 'unanimous'
      } else {
        const kinds = new Set(valid.map((v) => v.verdictKind))
        const bests = new Set(valid.map((v) => v.bestVariantFile || ''))
        agreement = kinds.size === 1 && bests.size === 1 ? 'unanimous' : 'split'
        // Escalate on ANY disagreement, including a single dissenting vote —
        // deliberately asymmetric, not majority-vote. "None fully correct"
        // is exactly the conclusion an anchored majority is likely to miss,
        // so a lone dissent gets adjudicated, never simply outvoted.
        conclusion = agreement === 'unanimous' ? valid[0] : null
      }
      return { ...c, variantFiles, comparisonVotes: valid, conclusion, agreement: agreement || 'split' }
    })
  }),
)

// ── Reconciliation (only where votes disagreed) ───────────────────────────
phase('Reconciliation')
const needsReconcile = compared.filter((c) => c && !c.comparisonFailed && !c.conclusion && c.comparisonVotes && c.comparisonVotes.length > 1)
if (needsReconcile.length) log(`${needsReconcile.length} cluster(s) had disagreeing analyses — reconciling`)
const reconciled = await parallel(
  needsReconcile.map((c) => () =>
    agent(reconcilePrompt(c, c.comparisonVotes, languageName), { schema: RECONCILE_SCHEMA, phase: 'Reconciliation', label: `reconcile:${c.id}`, ...modelOpt })
      .then((r) => (!r || looksCorrupted(r) || (r.bestVariantFile && !isKnownPath(r.bestVariantFile))
        ? { id: c.id, reconcileFailed: true }
        : { id: c.id, conclusion: r })),
  ),
)
const reconcileById = new Map(reconciled.filter(Boolean).map((r) => [r.id, r]))
const finalClusters = compared
  .filter(Boolean)
  .filter((c) => !c.comparisonFailed)
  .map((c) => {
    if (c.conclusion) return c
    const r = reconcileById.get(c.id)
    if (r && r.conclusion) return { ...c, conclusion: r.conclusion, agreement: r.conclusion.agreement || 'split' }
    // reconcile failed/corrupted: fall back to the first valid vote rather
    // than dropping the cluster, but never claim unanimity it didn't earn.
    return { ...c, conclusion: c.comparisonVotes && c.comparisonVotes[0], agreement: 'split', reconcileFailed: true }
  })
const failedComparison = compared.filter(Boolean).filter((c) => c.comparisonFailed)

const divergent = finalClusters.filter((c) => c.conclusion && c.conclusion.verdictKind !== 'equivalent')
const equivalent = finalClusters.filter((c) => c.conclusion && c.conclusion.verdictKind === 'equivalent')

// ── Synthesis ──────────────────────────────────────────────────────────────
phase('Synthesis')
const execSummaryOut = await agent(
  `Write a 3-6 sentence executive summary of a duplicate-code scan. Stats: ${buckets.length} candidate bucket(s) from signals, ${realClusters.length} confirmed real duplication cluster(s) (${divergent.length} where variants behave DIFFERENTLY — the ones needing a decision — and ${equivalent.length} where they're equivalent), ${discarded.length} discarded as false positives, ${failedComparison.length} where analysis failed. Do not list individual clusters by name. Write in ${languageName}.`,
  { schema: EXEC_SUMMARY_SCHEMA, phase: 'Synthesis', label: 'exec-summary', ...modelOpt },
)

const stats = {
  buckets: buckets.length, bucketsDroppedByCap: droppedByCap.length,
  triaged: allTriaged.length, real: realClusters.length, discarded: discarded.length, corrupted: corrupted.length,
  divergent: divergent.length, equivalent: equivalent.length, analysisFailed: failedComparison.length,
  clustersNotAnalyzed: notAnalyzed.length, unknownPathHits: unknownPathHits.length,
}

const { reportMarkdown, reportJson } = renderReport({
  today, gitRev, L, execSummary: execSummaryOut && execSummaryOut.summary,
  coverage, stats, divergent, equivalent, discarded, corrupted, failedComparison, notAnalyzed, unknownPathHits, depth,
})

return { reportMarkdown, reportJson, stats }
```

## Design notes (for maintainers)

- **Why signals are gathered outside the `Workflow` script.** Workflow
  scripts have no filesystem/Bash access (same constraint documented in
  16-eyes' `audit-flow.md`) — `collect-signals.sh` runs in the orchestrating
  session, once per scope, before `Workflow` is even called.
- **Why bucketing/merging is plain JS, not an agent call.** It's pure
  data transformation over already-deterministic output — spending an agent
  call to group JSON objects would be pure waste. Merging across signals
  BEFORE any agent call is what turns 3 signals independently finding the
  same cluster into a free confidence boost instead of a 3x cost.
- **Why `pipeline()` for triage→verify, not `parallel()`+barrier.**
  Verification of bucket A's clusters starts the moment bucket A's triage
  returns, without waiting on the slowest bucket. Identical rationale to
  16-eyes' lenses→verify pipeline.
- **Why the comparison pass is independent rotated re-derivation, not
  refutation.** 16-eyes' adversarial review answers a binary question ("is
  this finding real?") and a refuter inherits the ORIGINAL agent's reasoning
  as its starting point. Here the cluster is already confirmed real by
  verification — what's at risk is a subtly wrong VERDICT, because an agent
  anchored on whichever variant it read first. A refuter asked "can you
  disprove variant A is best" is still reasoning about A. Instead, each of K
  votes independently re-derives the full comparison from scratch, seeing
  the variants in a different order each time, and is required (by schema
  field order — `requiredBehavior` is the first property) to write what
  correct looks like before looking at any variant's correctness. Escalating
  to reconciliation on a SINGLE dissenting vote (not just a minority) is
  deliberate: "none of these variants is fully correct" — the user's own
  framing for why this tool exists — is precisely the conclusion a
  converged, anchored majority is likely to have missed.
- **Zero valid comparison votes must never default to a winner.** Direct
  analog of 16-eyes' "0 valid votes ≠ survived" guard — here the consequence
  is worse than a phantom finding, since a fabricated "adopt variant A" is
  something a human will actually refactor toward. Routes to
  `comparisonFailed` → the appendix, never silently promoted.
- **The path-hallucination guard is new and only possible here, and only
  for signal-derived candidates.** Every signal-derived candidate file
  originates from `collect-signals.sh`'s deterministic output, so that
  real-path universe is known in advance — an agent naming a file outside
  it (in triage, in a comparison's `bestVariantFile`, in a reconciliation)
  has mechanically hallucinated. 16-eyes cannot do this at all — a lens's
  findings may legitimately point anywhere in the repo. The inventory
  sweep's OWN discoveries are the one exception by design: they legitimately
  name files no signal mentioned (that is the sweep's entire purpose), so
  they extend the known-path universe (`isKnownPath.add`) instead of being
  checked against it — the real check on a sweep-hallucinated file is the
  verify step's "read the actual code yourself," which cannot confirm
  duplication in a file that doesn't exist.
- **Why `looksCorrupted()` is ported verbatim, not reimplemented.** Same
  tool, same real observed corruption mode (schema-valid object, every
  string literally `"test"`) — no reason to write a different guard for the
  same failure.
- **Why coverage disclosure sits above the findings, not only in an
  appendix.** Direct application of 16-eyes' `audit-diff-flow.md` principle:
  never silently claim full coverage. This tool's central honesty point is
  that it's high-precision, medium-recall — duplication sharing no literal,
  no name, no line shape, and no mirrored path is invisible to it, and the
  `thorough`-mode sweep only catches what init happened to name a category
  for. The report says so every time, not just in this file.
- **Why divergent clusters lead the report, ahead of equivalent ones** — the
  reverse of 16-eyes' safe-first ordering. Equivalent-behavior clusters are
  mechanically boring (a linter could find many); divergent-behavior
  clusters are latent bugs — the entire reason to build this tool instead
  of a textual clone detector.
- **No diff-scoped mode, and why a port doesn't make sense.** A security
  lens reasons locally about one changed hunk; duplicate detection is
  inherently whole-corpus — to know if a diff's new code duplicates
  something, the "something" is almost always OUTSIDE the diff. A faithful
  diff-scoped version would have to sweep the whole repo anyway to find the
  other variant, losing the cost saving that justifies a diff mode in the
  first place. Noted as a non-goal, not forgotten.

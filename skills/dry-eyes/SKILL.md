---
name: dry-eyes
description: >-
  Finds SEMANTIC duplicate code across a whole repository — the same
  business rule, calculation, or UI/UX pattern implemented independently
  more than once, often with DIFFERENT behavior each time (e.g. one screen
  shows an error toast, another doesn't, a third shows both a toast and an
  inline error). Two subcommands — `/dry-eyes init` (profile the repo, pick
  which cheap deterministic duplication signals fit it, design tailored
  categories for a supplementary LLM sweep — auto-runs non-interactively if
  skipped) and `/dry-eyes scan` (gather the signals, cluster the candidates,
  verify each cluster skeptically, then compare every variant against the
  others AND against what a correct implementation would need). Crucially,
  a cluster's verdict is never just "which one wins": it can and often does
  conclude that NONE of the existing variants is fully correct, and
  describes what a correct implementation would have to handle that none
  of them do. NOT a copy-paste/token clone detector — jscpd, PMD-CPD and
  similar tools already find literal clones cheaply and deterministically;
  this is for the duplication those tools cannot see, where two
  independently-written implementations mean the same thing but share no
  text at all. Read-only, full-repo only — never edits code, no diff/PR
  mode. Trigger on: find duplicate code, find duplicated business logic,
  duplicated validation or calculation, same rule implemented twice,
  inconsistent error handling or toasts across screens, DRY violations,
  code-duplication report, refactoring backlog for duplicated logic,
  "dry-eyes init/scan"; "código duplicado", "regra de negócio duplicada",
  "mesma validação implementada em dois lugares", "cálculo duplicado em
  vários lugares", "mensagens de erro inconsistentes entre telas", "toast em
  algumas telas e não em outras", "violação de DRY", "relatório de
  duplicação de código"; "código duplicado", "regla de negocio duplicada",
  "misma validación implementada en dos lugares", "cálculo duplicado en
  varios lugares", "mensajes de error inconsistentes entre pantallas",
  "violación de DRY", "informe de duplicación de código".
---

# DRY Eyes — semantic duplicate-code scans

Two implementations rarely look identical when someone reimplements the
same rule independently — different names, different shape, sometimes a
different language of variable names. This tool doesn't stop at "these two
things look similar": every candidate is read and compared for real, and
the comparison's job is to say what a *correct* implementation of the
concept actually requires — then check each variant against that bar. It's
common, not rare, for the answer to be "none of them." When duplicates
exist, the interesting finding usually isn't which one is right — it's that
neither is, and there's a third or fourth approach, not yet written
anywhere, that would be.

## Why this is not jscpd / PMD-CPD (and doesn't replace them)

Textual clone detectors compare tokens: they're fast, deterministic, and
very good at catching literal copy-paste. That's a solved problem this tool
doesn't reinvent — `/dry-eyes scan` runs its own cheap deterministic
signals first (repeated string literals, mirrored file paths, shared
normalized lines, domain-gated name families, inconsistent UI/UX
mechanisms for the same concern) for exactly the same reason those tools
exist: most duplication candidates can be found without spending an LLM
call. What a token-matching tool cannot do is judge *meaning* — two
functions with nothing textually in common that both compute the same
discount, or a screen that shows a toast next to three screens that don't,
are invisible to it. That's what the LLM layer here is for: verifying a
candidate is a genuine reimplementation (not already shared, not
coincidental), then comparing every variant's actual behavior against what
the concept requires. The two approaches are complementary, not
competing — see `config.signals.externalCloneTool` to fold an existing
clone tool's output in as one more candidate source.

## When the user runs `/dry-eyes init`

Read `references/init-flow.md` and follow it end to end. Detects the
repo's package/workspace layout and any existing clone-detection tooling,
interviews briefly about exclude patterns / output location / scan depth /
language / whether to gitignore reports / model / cross-package scope, then
**profiles the repo and designs its duplication-prone categories**,
persisting both to `.dry-eyes/config.json` and `.dry-eyes/probes.json`. If
skipped, `/dry-eyes scan` auto-bootstraps this non-interactively (sane
defaults, no questions asked) the first time it needs probes that don't
exist yet. Running it explicitly first just lets you customize things
before that happens — both files are also plain, editable JSON afterward,
the cheapest lever on recall if a category turns out to be missing.

## When the user runs `/dry-eyes scan`

Read-only — never edits code, full-repo only. Read `references/scan-flow.md`
and follow it end to end: gather this repo's deterministic duplication
signals (bootstrapping probes via `init` first if none exist), turn them
into candidate clusters, verify each one skeptically, then run an
independent multi-vote comparison on every cluster whose variants actually
diverge in behavior — each vote derives what correct behavior requires
*before* looking at any variant, and disagreement between votes is
adjudicated, never simply outvoted, since the conclusion a converged
majority is most likely to miss is exactly "none of these is right." Writes
a classified markdown + JSON report, leading with the clusters that need a
human decision.

## What this does not do (v1)

- **No `fix` command.** The JSON report has a stable id and a
  safe/risky-style classification per cluster specifically so a future
  `dry-eyes fix` can consume it later — applying a consolidation is a
  different, higher-stakes action than reporting one, and isn't built yet.
- **No diff/PR-scoped mode.** Not just deferred: duplicate detection is
  inherently a whole-repo comparison (to know if new code duplicates
  something, the "something" is almost always outside the diff), unlike a
  security lens that can reason about one changed hunk alone — a faithful
  diff-scoped version would have to sweep the whole repo anyway, losing the
  cost saving that justifies a diff mode in the first place.
- **No cross-language comparison.** Every scope is exactly one language;
  the same rule reimplemented in, say, a Go backend and a TypeScript
  frontend is out of scope for this version.
- **High-precision, medium-recall, and the report says so every time.**
  Duplication sharing no repeated literal, no shared name, no similar line
  shape, and no mirrored path is invisible to the deterministic signals,
  and the supplementary LLM sweep only catches it if a category happened to
  be designed for that area. This is stated in every report's coverage
  section, not just here.

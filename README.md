# DRY Eyes

![DRY Eyes](./assets/Background.png)

**Finds semantic duplicate code for [Claude Code](https://claude.com/claude-code) — the
same business rule, calculation, or UI/UX pattern implemented independently more than
once, often with different behavior each time.**

![Claude Code](https://img.shields.io/badge/Claude_Code-supported-0F6E56)

![How DRY Eyes works](./assets/how-it-works-en.png)

> Finds the same business rule, calculation, or UI/UX pattern implemented
> independently more than once — often with **different behavior each
> time** — then compares every variant against the others and against what
> a correct implementation would actually need. Not a copy-paste detector:
> jscpd and PMD-CPD already find literal clones cheaply. This is for the
> duplication those tools can't see.

*[Leia em português](./README.pt-BR.md) · [Lee en español](./README.es.md)*

## Why this exists

Two implementations of the same rule rarely look identical when someone
reimplements it independently — different names, different shape,
sometimes a different variable-naming convention entirely. A token-matching
clone detector is fast and deterministic at catching copy-paste, but it
can't tell you that a screen showing an error toast and three screens that
don't are all supposed to handle the same failure the same way, or that
three files compute "the same" discount with three different edge-case
bugs.

DRY Eyes runs cheap, deterministic candidate-generation signals first
(repeated string literals, mirrored file paths, shared normalized lines,
domain-gated name families, inconsistent UI mechanisms for the same
concern) — for the same reason those clone detectors exist: most candidates
don't need an LLM call to surface. What's different is what happens next:
every real candidate gets read and compared for actual behavior, not just
textual similarity. The comparison's own job is to figure out what a
*correct* implementation of the concept requires, independently of any one
variant, and then check each variant against that bar. It's common — not
rare — for the answer to be "none of them," with a description of what a
correct implementation would still need to handle.

## Install

```bash
npx dry-eyes install --project   # this repo's .claude/skills/dry-eyes
# or, omit --project to install globally at ~/.claude/skills/user/dry-eyes
```

A brand-new Claude Code session may be needed afterward to discover the
skill (skills are read at session start).

<details>
<summary>Installing from a local clone (for contributing to DRY Eyes itself)</summary>

```bash
git clone https://github.com/kigiela/dry-eyes.git
cd dry-eyes
node bin/cli.js install --project
```

</details>

## Use

```
/dry-eyes init   configure — exclude patterns, output location, scopes,
                 duplication probes; auto-runs non-interactively if skipped
/dry-eyes scan   sweep the whole repo, cluster candidates, verify each
                 skeptically, compare every variant's actual behavior
```

## How it works

1. **Profile once, persist it.** `/dry-eyes init` profiles the repo's
   packages and languages, then designs a tailored set of duplication-prone
   categories (validation, calculations, error-display mechanisms, ...) —
   done once, reused by every future scan, not redesigned per run.
2. **Cheap signals first.** `/dry-eyes scan` runs five deterministic
   signals — repeated literals, mirrored paths, shared line shapes,
   domain-gated name families, inconsistent mechanisms for the same concern
   — merging cross-signal agreement into single candidates before any LLM
   call happens.
3. **Skeptical verification.** Every candidate cluster gets read for real
   and checked: is this actually the same concept, independently
   reimplemented — or already shared, coincidental, or two things that are
   supposed to stay decoupled?
4. **Independent comparison, not a vote for the "winner."** For clusters
   whose variants actually diverge in behavior, several independent
   analyses each derive what *correct* behavior requires **before** looking
   at any variant — then check every variant against that bar. Disagreement
   between analyses is adjudicated, not outvoted: the conclusion a converged
   majority is most likely to miss is exactly "none of these is right."
5. **A report, not a fix.** Markdown + JSON, leading with the clusters that
   need a human decision. Read-only — v1 has no `fix` command.

## What v1 does not do

- **No `fix` command.** The JSON report carries a stable id and a
  safe/risky-style classification per cluster specifically so a future
  `dry-eyes fix` could consume it — applying a consolidation is a
  different, higher-stakes action than reporting one.
- **No diff/PR-scoped mode.** Duplicate detection is inherently a
  whole-repo comparison — to know if new code duplicates something, the
  "something" is almost always outside the diff. A faithful diff-scoped
  version would have to sweep the whole repo anyway, losing the cost saving
  that justifies a diff mode in the first place.
- **No cross-language comparison.** Every scope is exactly one language.
- **No CI wiring, no multi-tool adapters.** Claude Code only for v1 — this
  pipeline leans much more heavily on real deterministic code (bucketing,
  Jaccard merging, a path-hallucination guard) than a prompted-JSON port to
  another tool's subagents could reliably reproduce.
- **High-precision, medium-recall, on purpose — and every report says so.**
  Duplication sharing no repeated literal, no shared name, no similar line
  shape, and no mirrored path is invisible to the deterministic signals; the
  supplementary LLM sweep only catches it if a category happened to be
  designed for that area.

## License

MIT — see [LICENSE](LICENSE).

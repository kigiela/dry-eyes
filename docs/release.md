# Cutting a release (publishing to npm)

Publishing is **not** automatic on every push/merge — it's triggered by publishing a
GitHub Release, a deliberate action a maintainer takes. See
[`.github/workflows/publish-npm.yml`](../.github/workflows/publish-npm.yml) for the
workflow itself.

## One-time setup

Auth is [npm Trusted Publishing](https://docs.npmjs.com/trusted-publishers) — OIDC-based,
**no `NPM_TOKEN` secret at all**. Configure it on the package itself:

1. npmjs.com → the `dry-eyes` package → **Settings** → **Trusted Publisher** → select
   **GitHub Actions**.
2. Fill in: organization/user `kigiela`, repository `dry-eyes`, workflow filename
   `publish-npm.yml` (filename only, no path), allowed action **npm publish**.
   Leave "Environment name" blank (this workflow doesn't use a GitHub environment).
3. Save. That's it — no secret to create or rotate. The workflow's `id-token: write`
   permission is what lets GitHub mint the short-lived OIDC token npm trusts at publish
   time.

Requires npm CLI ≥ 11.5.1 and Node ≥ 22.14.0, which is why the workflow pins
`node-version: "22"` via `actions/setup-node`.

**The very first release is a chicken-and-egg problem**: Trusted Publishing is
configured on a package's own Settings page, which doesn't exist until the package
has been published at least once — there's no npm account-level "pre-register a
Trusted Publisher for a name that doesn't exist yet" flow (verified: none of npm's
own docs, the GitHub Actions changelog announcement, or third-party writeups
describe one; this may simply not exist as a feature).

So, **only for the first-ever release**, publish manually instead of via the
workflow:

```bash
npm login          # your own npm account — do this yourself, not via any AI tool
npm publish --access public
```

Once that succeeds, the `dry-eyes` package exists and its Settings → Trusted
Publisher page appears — set it up then (org/user `kigiela`, repo `dry-eyes`,
workflow `publish-npm.yml`, action `npm publish`, environment blank), and every
release **after** the first goes through `gh release create` + the workflow as
described below, with no further manual `npm publish` ever needed.

## Every release

1. Bump the version in [`package.json`](../package.json) (semver — patch for fixes,
   minor for new features like a new subcommand, major for breaking changes to the
   config schema or CLI flags).
2. Commit and merge that bump to `main`.
3. Create a GitHub Release with a tag matching the new version, prefixed with `v`
   (e.g. version `1.0.0` → tag `v1.0.0`):
   ```bash
   gh release create v1.0.0 --title "v1.0.0" --generate-notes
   ```
   (`--generate-notes` drafts release notes from merged PRs since the last tag — edit
   before publishing if you want a hand-written summary instead.)
4. Publishing the release triggers the workflow, which:
   - Verifies the tag matches `package.json`'s version (fails loudly if they've drifted
     — never publishes a mismatched version).
   - Runs a quick sanity check (JS syntax, JSON validity of every schema/plugin file,
     shell syntax of `collect-signals.sh`, `npm pack --dry-run`).
   - Publishes to npm via Trusted Publishing — npm mints provenance automatically as
     part of that OIDC flow, tying the published package back to this exact GitHub
     Actions run and commit.

Unlike [`16-eyes`'s release process](https://github.com/kigiela/16-eyes/blob/main/docs/release.md),
there's no major-version-tag-moving step — that exists there only because its
`action.yml`/CI templates tell consumers to pin `uses: kigiela/16-eyes@v1`. DRY Eyes
ships no GitHub Action or CI templates in v1, so there's no rolling tag to maintain yet.

## If it fails

The "tag matches package.json" check is the most common failure — it means someone
tagged/released without bumping `package.json` first (or bumped it but forgot to merge
before tagging). Fix `package.json`, merge, delete the mismatched tag/release, and
re-cut it.

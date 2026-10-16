#!/bin/sh
# collect-signals.sh — cheap, deterministic duplication-candidate signals for
# one scope (one language, one package). Called by the orchestrating Claude
# Code session BEFORE the Workflow tool runs (Workflow scripts have no
# filesystem/Bash access — see references/scan-flow.md's design notes).
#
# Outputs ONE JSON document on stdout: aggregated, capped, never a per-file
# blob. All heavy lifting (grep/rg passes, awk aggregation) happens here so
# the LLM side of the pipeline only ever sees pre-reduced candidates, never
# raw file contents at this stage.
#
# Usage:
#   sh collect-signals.sh --root <path> --scope-id <id> \
#     [--include "<glob>[,<glob>]"] [--exclude "<glob>[,<glob>]"] \
#     [--domain-words "<word>[,<word>]"] [--concerns-file <path>] \
#     [--lit-min-files N] [--lit-max-files N] [--lit-min-len N] [--lit-max-len N] \
#     [--line-min-shared N] [--line-min-len N] [--line-min-occ N] [--line-max-occ N] \
#     [--top-n-literals N] [--top-n-lines N] [--top-n-paths N] [--top-n-names N]
#
# Never relies on an exec bit — always invoked as `sh <path>`.
#
# --concerns-file format: TSV, one mechanism per line, no header:
#   <concern_id>\t<mechanism_label>\t<ERE_pattern>
# e.g.:
#   error-display\ttoast\t\\btoast\\b
#   error-display\tinline-error\t\\bsetError\\b
# Lines missing any of the three fields are skipped.
#
# Safety model — read-only toward the scanned repo, and every tracked path or
# file name in it is treated as untrusted input:
# - Only regular files that `git ls-files` lists UNDER --root are ever opened.
#   A listed path that climbs out of --root (via an include glob or pathspec
#   magic such as `:/`) is dropped, and so is every symlink: a repo can track
#   `creds -> ~/.aws/credentials`, and following it would copy that file's
#   string literals into the JSON handed to the LLM.
# - File names never reach a command as options: rg/grep get `--` before the
#   batched path list, and awk reads paths from a list file instead of taking
#   them as operands (a tracked file named `--pre=./x.sh` or `-fx.awk` would
#   otherwise run code).
# - Nothing from the repo or the concerns file is eval'd or used to build a
#   file path; numeric options must be plain integers; patterns go via `-e`.
# - The only writes go to a private `mktemp -d` directory, which a flat,
#   non-recursive cleanup removes on exit (see `cleanup`).
#
# Design notes (see references/scan-flow.md for the full rationale):
# - One rg/grep pass per signal, never a process per file — a naive per-file
#   loop was unusably slow in testing (~2000 files); one rg/grep pass over
#   the same files took well under a second.
# - No regex backreferences anywhere: ripgrep's engine doesn't support them
#   (by design — no backtracking, for guaranteed linear-time matching), so
#   quoted-string extraction uses two separate passes (one per quote
#   character) instead of one pattern whose closing quote must repeat the
#   opening one.
# - Multi-value fields (file lists, literal lists) are joined with the ASCII
#   unit separator (\x1f), not comma or pipe — a file path or a string
#   literal pulled from arbitrary source code could contain either.
set -eu
unset CDPATH

# Defaults below MUST match assets/config.schema.json's documented defaults —
# that file is the source of truth (see its top-level description). This
# script can't import JSON, so these are a necessary, manually-kept-in-sync
# second copy, not an independent design decision.
ROOT="."
SCOPE_ID="scope"
INCLUDE=""
EXCLUDE=""
DOMAIN_WORDS=""
CONCERNS_FILE=""
LIT_MIN_FILES=3
LIT_MAX_FILES=12
LIT_MIN_LEN=14
LIT_MAX_LEN=110
LINE_MIN_SHARED=8
LINE_MIN_LEN=25
LINE_MIN_OCC=3
LINE_MAX_OCC=12
TOP_N_LITERALS=300
TOP_N_LINES=400
TOP_N_PATHS=200
TOP_N_NAMES=200

usage_error() { echo "collect-signals.sh: $1" >&2; exit 1; }

while [ $# -gt 0 ]; do
  opt=$1; val=${2-}
  case "$opt" in
    --root) ROOT=$val ;;
    --scope-id) SCOPE_ID=$val ;;
    --include) INCLUDE=$val ;;
    --exclude) EXCLUDE=$val ;;
    --domain-words) DOMAIN_WORDS=$val ;;
    --concerns-file) CONCERNS_FILE=$val ;;
    --lit-min-files) LIT_MIN_FILES=$val ;;
    --lit-max-files) LIT_MAX_FILES=$val ;;
    --lit-min-len) LIT_MIN_LEN=$val ;;
    --lit-max-len) LIT_MAX_LEN=$val ;;
    --line-min-shared) LINE_MIN_SHARED=$val ;;
    --line-min-len) LINE_MIN_LEN=$val ;;
    --line-min-occ) LINE_MIN_OCC=$val ;;
    --line-max-occ) LINE_MAX_OCC=$val ;;
    --top-n-literals) TOP_N_LITERALS=$val ;;
    --top-n-lines) TOP_N_LINES=$val ;;
    --top-n-paths) TOP_N_PATHS=$val ;;
    --top-n-names) TOP_N_NAMES=$val ;;
    *) usage_error "unknown argument: $opt" ;;
  esac
  [ $# -ge 2 ] || usage_error "missing value for $opt"
  shift 2
done

HAVE_RG=0; command -v rg >/dev/null 2>&1 && HAVE_RG=1
HAVE_JQ=0; command -v jq >/dev/null 2>&1 && HAVE_JQ=1
US="$(printf '\37')"   # ASCII unit separator, for joining multi-value TSV fields
TAB="$(printf '\t')"

SELF_DIR="$(cd -P -- "$(dirname -- "$0")" && pwd)"
AWK_DIR="$SELF_DIR/collect-signals.awk.d"

json_str() { printf '%s' "$1" | awk -v MODE=str -f "$AWK_DIR/json.awk"; }

# Scope-level failure: report it as data (scan-flow.md logs it and counts the
# scope as zero signals) instead of failing the whole scan.
fail_json() {
  printf '{"tool":"collect-signals","scopeId":"%s","fileCount":0,"error":"%s"}\n' \
    "$(json_str "$SCOPE_ID")" "$(json_str "$1")"
  exit 0
}

for n in "$LIT_MIN_FILES" "$LIT_MAX_FILES" "$LIT_MIN_LEN" "$LIT_MAX_LEN" \
         "$LINE_MIN_SHARED" "$LINE_MIN_LEN" "$LINE_MIN_OCC" "$LINE_MAX_OCC" \
         "$TOP_N_LITERALS" "$TOP_N_LINES" "$TOP_N_PATHS" "$TOP_N_NAMES"; do
  case "$n" in
    ''|*[!0-9]*) fail_json "numeric options must be non-negative integers, got: $n" ;;
  esac
done

[ -d "$ROOT" ] || fail_json "--root is not a directory"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/dryeyes.XXXXXXXX")"
# Flat, non-recursive cleanup of the directory created just above: every temp
# file lives directly inside it, `rm -f` never descends, and `rmdir` refuses
# to remove anything that isn't empty by then.
cleanup() {
  set +f
  if [ -n "${WORKDIR:-}" ] && [ -d "$WORKDIR" ] && [ ! -L "$WORKDIR" ]; then
    rm -f -- "$WORKDIR"/* 2>/dev/null || :
    rmdir -- "$WORKDIR" 2>/dev/null || :
  fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

glob_to_regex() {
  # crude but sufficient glob->ERE converter for the patterns this tool ships
  printf '%s' "$1" \
    | sed -E 's/[.[\^$()+{}|]/\\&/g' \
    | sed 's/\*\*/@@DS@@/g' \
    | sed 's/\*/[^\/]*/g' \
    | sed 's/@@DS@@/.*/g'
}

# Hardened git: never runs a repo-configured fsmonitor hook, and prints UTF-8
# paths verbatim instead of C-quoting them.
git_q() { git -c core.fsmonitor= -c core.quotePath=false "$@"; }

# ── File universe for this scope ────────────────────────────────────────────
# git ls-files already respects .gitignore; include/exclude on top handle the
# categories tracking alone doesn't (tests, fixtures, migrations, committed
# generated code).
cd -P -- "$ROOT"
if ! git_q rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  fail_json "not inside a git work tree"
fi

list_tracked() {
  if [ -n "$INCLUDE" ]; then
    # set -f (noglob) is essential here: unquoted `$INCLUDE` splitting on IFS
    # ALSO undergoes pathname expansion, and dash has no globstar — `**` gets
    # silently mis-expanded against the filesystem (matching a fixed number of
    # path segments) before git ever sees the literal pattern, corrupting every
    # recursive include glob. Verified empirically: without `set -f`, a
    # `web/**/*.ts,src/**/*.ts`-style include silently returned half the
    # intended files. With it, `$g` stays the literal string git's own pathspec
    # engine (which DOES understand `**`) is supposed to receive.
    OLDIFS=$IFS; IFS=','; set -f
    for g in $INCLUDE; do git_q ls-files -- "$g" 2>/dev/null || :; done
    set +f; IFS=$OLDIFS
  else
    git_q ls-files
  fi
}

EXCLUDE_RE=""
if [ -n "$EXCLUDE" ]; then
  OLDIFS=$IFS; IFS=','; set -f
  for g in $EXCLUDE; do
    re=$(glob_to_regex "$g")
    EXCLUDE_RE="${EXCLUDE_RE:+$EXCLUDE_RE|}$re"
  done
  set +f; IFS=$OLDIFS
fi

# git prints paths relative to the current directory, so anything outside
# --root comes back with a parent-directory segment — drop those outright.
list_tracked \
  | awk -F/ '{ for (i = 1; i <= NF; i++) if ($i == "..") next } $1 != "" { print }' \
  | sort -u \
  | if [ -n "$EXCLUDE_RE" ]; then grep -v -E -e "$EXCLUDE_RE" || :; else cat; fi \
  > "$WORKDIR/files.listed.txt"

# Regular files only, never symlinks. Shell builtins only — no process per file.
while IFS= read -r f; do
  if [ -f "$f" ] && [ ! -L "$f" ]; then printf '%s\n' "$f"; fi
done < "$WORKDIR/files.listed.txt" > "$WORKDIR/files.txt"

FILE_COUNT=$(wc -l < "$WORKDIR/files.txt" | tr -d ' ')
if [ "$FILE_COUNT" -eq 0 ]; then
  fail_json "no files matched this scope's include/exclude patterns"
fi

# NUL-separated batch runner: avoids one-process-per-file, safe on any
# filename. Every caller ends its own arguments with `--`, so a path that
# starts with `-` is always read as a path, never parsed as an option.
run_batched() {
  tr '\n' '\0' < "$WORKDIR/files.txt" | xargs -0 "$@"
}

# ============================================================================
# Signal 1 — literal co-occurrence: repeated distinctive string literals
# ============================================================================
: > "$WORKDIR/lit_raw.txt"
# NOTE: ripgrep has no "search only within these listed files" flag — its own
# `-f`/`--file` takes a PATTERN file, not a path list. So file scoping for rg,
# same as for grep, goes through explicit args via the batched xargs runner
# (files given as positional args to rg override its own glob/ignore rules).
# --no-config keeps a user's ripgreprc (e.g. a --pre preprocessor) out of it.
if [ "$HAVE_RG" -eq 1 ]; then
  run_batched rg --no-config -H -N --no-heading -o -e "\"[^\"]{${LIT_MIN_LEN},${LIT_MAX_LEN}}\"" -- >> "$WORKDIR/lit_raw.txt" 2>/dev/null || true
  run_batched rg --no-config -H -N --no-heading -o -e "'[^']{${LIT_MIN_LEN},${LIT_MAX_LEN}}'" -- >> "$WORKDIR/lit_raw.txt" 2>/dev/null || true
else
  run_batched grep -H -o -E -e "\"[^\"]{${LIT_MIN_LEN},${LIT_MAX_LEN}}\"" -- >> "$WORKDIR/lit_raw.txt" 2>/dev/null || true
  run_batched grep -H -o -E -e "'[^']{${LIT_MIN_LEN},${LIT_MAX_LEN}}'" -- >> "$WORKDIR/lit_raw.txt" 2>/dev/null || true
fi
sed -E 's/^([^:]*):(.*)$/\1\t\2/' "$WORKDIR/lit_raw.txt" \
  | sed -E "s/\t[\"']/\t/; s/[\"']\$//" \
  | sort -u > "$WORKDIR/lit_pairs.tsv"

awk -v MINF="$LIT_MIN_FILES" -v MAXF="$LIT_MAX_FILES" -f "$AWK_DIR/agg-literals.awk" "$WORKDIR/lit_pairs.tsv" \
  | sort -t "$TAB" -k2,2 \
  | awk -f "$AWK_DIR/group-by-fileset.awk" \
  | sort -t "$TAB" -k1,1rn \
  > "$WORKDIR/lit_buckets.tsv"
LIT_TOTAL=$(wc -l < "$WORKDIR/lit_buckets.tsv" | tr -d ' ')
head -n "$TOP_N_LITERALS" "$WORKDIR/lit_buckets.tsv" > "$WORKDIR/lit_buckets.capped.tsv"

# ============================================================================
# Signal 2 — path mirroring: files that differ only at ONE non-terminal path
# segment (a terminal wildcard degenerates to "files in a directory" — noise)
# ============================================================================
awk -F/ -v US="$US" '{
    n = split($0, a, "/")
    for (i = 1; i < n; i++) {
      s = ""
      for (j = 1; j <= n; j++) s = s (j == i ? "*" : a[j]) (j < n ? "/" : "")
      print s "\t" $0
    }
  }' "$WORKDIR/files.txt" \
  | sort \
  | awk -F'\t' -v US="$US" '{
      if ($1 == prev) { c++; files = files US $2 }
      else { if (c >= 2) print c"\t"prev"\t"files; prev = $1; c = 1; files = $2 }
    } END { if (c >= 2) print c"\t"prev"\t"files }' \
  > "$WORKDIR/path_families_raw.tsv"
PATH_TOTAL=$(wc -l < "$WORKDIR/path_families_raw.tsv" | tr -d ' ')
sort -t "$TAB" -k1,1rn "$WORKDIR/path_families_raw.tsv" | head -n "$TOP_N_PATHS" > "$WORKDIR/path_families.tsv"

# ============================================================================
# Signal 3 — normalized-line overlap (inverted index, near-linear)
# ============================================================================
awk -v LIST="$WORKDIR/files.txt" -v MINLEN="$LINE_MIN_LEN" -v MINOCC="$LINE_MIN_OCC" \
    -v MAXOCC="$LINE_MAX_OCC" -v MINSHARED="$LINE_MIN_SHARED" \
    -f "$AWK_DIR/line-overlap.awk" < /dev/null \
  | sort -t "$TAB" -k1,1rn > "$WORKDIR/line_pairs.tsv"
LINE_TOTAL=$(wc -l < "$WORKDIR/line_pairs.tsv" | tr -d ' ')
head -n "$TOP_N_LINES" "$WORKDIR/line_pairs.tsv" > "$WORKDIR/line_pairs.capped.tsv"

# ============================================================================
# Signal 4 — name-family clustering: function/method names sharing a domain
# word. MUST be gated by domain words — ungated, this is ~90% framework
# conventions (call/initialize/perform/index/show); verified empirically.
# ============================================================================
: > "$WORKDIR/name_families.tsv"
NAME_TOTAL=0
if [ -n "$DOMAIN_WORDS" ]; then
  DOMAIN_RE=$(printf '%s' "$DOMAIN_WORDS" | sed 's/,/|/g')
  : > "$WORKDIR/names_raw.txt"
  if [ "$HAVE_RG" -eq 1 ]; then
    run_batched rg --no-config -H -N --no-heading -o -e '\b(def|function|func|fn) (self\.)?[A-Za-z_][A-Za-z0-9_]*' -- >> "$WORKDIR/names_raw.txt" 2>/dev/null || true
  else
    run_batched grep -H -o -E -e "(def|function|func|fn) (self\.)?[A-Za-z_][A-Za-z0-9_]*" -- >> "$WORKDIR/names_raw.txt" 2>/dev/null || true
  fi
  sed -E 's/^([^:]*):(.*)$/\1\t\2/' "$WORKDIR/names_raw.txt" \
    | awk -F'\t' '{ name=$2; sub(/^(def|function|func|fn) (self\.)?/, "", name); print tolower(name)"\t"$1 }' \
    | grep -i -E -e "$DOMAIN_RE" > "$WORKDIR/names.tsv" || : > "$WORKDIR/names.tsv"
  sort "$WORKDIR/names.tsv" \
    | awk -F'\t' -v US="$US" '{
        if ($1 == prevName) { c++; files = files US $2 }
        else { if (c >= 2) print c"\t"prevName"\t"files; prevName = $1; c = 1; files = $2 }
      } END { if (c >= 2) print c"\t"prevName"\t"files }' \
    > "$WORKDIR/name_families_raw.tsv"
  NAME_TOTAL=$(wc -l < "$WORKDIR/name_families_raw.tsv" | tr -d ' ')
  sort -t "$TAB" -k1,1rn "$WORKDIR/name_families_raw.tsv" | head -n "$TOP_N_NAMES" > "$WORKDIR/name_families.tsv"
fi

# ============================================================================
# Signal 5 — concern -> mechanism inventory: for a profile-identified concern
# (e.g. "how errors are shown"), count files per mechanism and flag files
# using more than one mechanism family within the same concern.
# Temp file names are numbered, never derived from concern ids or labels.
# ============================================================================
: > "$WORKDIR/mech_index.tsv"
if [ -n "$CONCERNS_FILE" ] && [ -f "$CONCERNS_FILE" ]; then
  i=0
  while IFS="$TAB" read -r concern label pattern; do
    # every field is required — this also keeps a file that isn't the
    # expected TSV from being echoed back line by line as "concern ids"
    [ -n "$concern" ] && [ -n "$label" ] && [ -n "$pattern" ] || continue
    i=$((i + 1))
    mech_file="$WORKDIR/mech_$i.txt"
    if [ "$HAVE_RG" -eq 1 ]; then
      run_batched rg --no-config -l -e "$pattern" -- 2>/dev/null | sort > "$mech_file" || : > "$mech_file"
    else
      run_batched grep -l -E -e "$pattern" -- 2>/dev/null | sort > "$mech_file" || : > "$mech_file"
    fi
    printf '%s\t%s\t%s\n' "$concern" "$label" "$mech_file" >> "$WORKDIR/mech_index.tsv"
  done < "$CONCERNS_FILE"
fi

# ============================================================================
# JSON assembly — one shot per signal via `jq -R -s`, not per-row spawning.
# ============================================================================
if [ "$HAVE_JQ" -eq 1 ]; then
  LIT_JSON=$(jq -R -s --arg US "$US" '
    split("\n") | map(select(length > 0)) | map(
      split("\t") | {
        fileCount: (.[0] | tonumber),
        literalCount: (.[1] | tonumber),
        files: (.[2] | split($US)),
        literals: (.[3] | split($US))
      })' "$WORKDIR/lit_buckets.capped.tsv")

  PATH_JSON=$(jq -R -s --arg US "$US" '
    split("\n") | map(select(length > 0)) | map(
      split("\t") | {
        fileCount: (.[0] | tonumber),
        pattern: .[1],
        files: (.[2] | split($US))
      })' "$WORKDIR/path_families.tsv")

  LINE_JSON=$(jq -R -s '
    split("\n") | map(select(length > 0)) | map(
      split("\t") | {
        sharedLines: (.[0] | tonumber),
        scaffoldLines: (.[1] | tonumber),
        fileA: .[2],
        fileB: .[3]
      })' "$WORKDIR/line_pairs.capped.tsv")

  NAME_JSON=$(jq -R -s --arg US "$US" '
    split("\n") | map(select(length > 0)) | map(
      split("\t") | {
        fileCount: (.[0] | tonumber),
        name: .[1],
        files: (.[2] | split($US))
      })' "$WORKDIR/name_families.tsv")

  CONCERN_JSON="[]"
  if [ -s "$WORKDIR/mech_index.tsv" ]; then
    CONCERN_JSON=$(
      k=0
      cut -f1 "$WORKDIR/mech_index.tsv" | sort -u | while IFS= read -r concern; do
        k=$((k + 1))
        mechs="[]"
        allfiles="$WORKDIR/concern_${k}_allfiles.txt"
        : > "$allfiles"
        while IFS="$TAB" read -r c label path; do
          [ "$c" = "$concern" ] || continue
          n=$(wc -l < "$path" | tr -d ' ')
          cat "$path" >> "$allfiles"
          mechs=$(printf '%s' "$mechs" | jq --arg label "$label" --argjson n "$n" '. + [{label:$label, fileCount:$n}]')
        done < "$WORKDIR/mech_index.tsv"
        multi=$(sort "$allfiles" | uniq -d)
        multi_json=$(printf '%s' "$multi" | jq -R -s 'split("\n") | map(select(length>0))')
        jq -n --arg concern "$concern" --argjson mechanisms "$mechs" --argjson multi "$multi_json" \
          '{concernId:$concern, mechanisms:$mechanisms, multiMechanismFiles:$multi}'
      done | jq -s .
    )
  fi

  jq -n \
    --arg scopeId "$SCOPE_ID" --arg root "$ROOT" --argjson fileCount "$FILE_COUNT" \
    --argjson haveRg "$([ "$HAVE_RG" -eq 1 ] && echo true || echo false)" \
    --argjson litBuckets "$LIT_JSON" --argjson litTotal "$LIT_TOTAL" \
    --argjson pathFamilies "$PATH_JSON" --argjson pathTotal "$PATH_TOTAL" \
    --argjson linePairs "$LINE_JSON" --argjson lineTotal "$LINE_TOTAL" \
    --argjson nameFamilies "$NAME_JSON" --argjson nameTotal "$NAME_TOTAL" \
    --argjson concerns "$CONCERN_JSON" \
    '{
      tool: "collect-signals", scopeId: $scopeId, root: $root, fileCount: $fileCount,
      toolsAvailable: { rg: $haveRg, jq: true },
      signals: {
        literalCooccurrence: { buckets: $litBuckets, totalBeforeCap: $litTotal, capped: ($litTotal > ($litBuckets|length)) },
        pathMirror: { families: $pathFamilies, totalBeforeCap: $pathTotal, capped: ($pathTotal > ($pathFamilies|length)) },
        lineOverlap: { pairs: $linePairs, totalBeforeCap: $lineTotal, capped: ($lineTotal > ($linePairs|length)) },
        nameFamily: { families: $nameFamilies, totalBeforeCap: $nameTotal, capped: ($nameTotal > ($nameFamilies|length)), ran: ($nameTotal > 0 or ($nameFamilies|length) >= 0) },
        concernMechanism: { concerns: $concerns }
      }
    }'
else
  # jq unavailable — degrade honestly rather than fail: literal/path/line
  # signals still run in full (they're gathered above regardless of jq), just
  # rendered through json.awk instead of jq. This still gives 3 of 5 signals;
  # name-family/concern-mechanism need per-item object construction this
  # fallback doesn't attempt, and are reported as skipped.
  LIT_JSON=$(awk -v MODE=lit -f "$AWK_DIR/json.awk" "$WORKDIR/lit_buckets.capped.tsv")
  PATH_JSON=$(awk -v MODE=path -f "$AWK_DIR/json.awk" "$WORKDIR/path_families.tsv")
  LINE_JSON=$(awk -v MODE=line -f "$AWK_DIR/json.awk" "$WORKDIR/line_pairs.capped.tsv")

  cat <<EOF
{"tool":"collect-signals","scopeId":"$(json_str "$SCOPE_ID")","root":"$(json_str "$ROOT")","fileCount":$FILE_COUNT,"toolsAvailable":{"rg":$([ "$HAVE_RG" -eq 1 ] && echo true || echo false),"jq":false},"signals":{"literalCooccurrence":{"buckets":$LIT_JSON,"totalBeforeCap":$LIT_TOTAL},"pathMirror":{"families":$PATH_JSON,"totalBeforeCap":$PATH_TOTAL},"lineOverlap":{"pairs":$LINE_JSON,"totalBeforeCap":$LINE_TOTAL},"nameFamily":{"families":[],"totalBeforeCap":0,"skipped":true},"concernMechanism":{"concerns":[],"skipped":true}},"signalsSkipped":["nameFamily","concernMechanism"],"note":"jq not found on PATH — those two signals need per-item JSON object construction this fallback doesn't attempt. Install jq for full signal coverage."}
EOF
fi

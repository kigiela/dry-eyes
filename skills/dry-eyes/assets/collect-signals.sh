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
#     [--include "glob,glob,..."] [--exclude "glob,glob,..."] \
#     [--domain-words "word,word,..."] [--concerns-file <path>] \
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
#
# Design notes (see references/scan-flow.md for the full rationale):
# - One rg/grep pass per signal, never a process per file — a naive per-file
#   loop was unusably slow in testing (~2000 files); one rg/grep pass over
#   the same files took well under a second.
# - No regex backreferences anywhere: ripgrep's engine doesn't support them
#   (by design — no backtracking, for guaranteed linear-time matching), so
#   quoted-string extraction uses two separate passes (one per quote
#   character) instead of a single `(["'])...\1`-style pattern.
# - Multi-value fields (file lists, literal lists) are joined with the ASCII
#   unit separator (\x1f), not comma or pipe — a file path or a string
#   literal pulled from arbitrary source code could contain either.
set -eu

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

while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="$2"; shift 2 ;;
    --scope-id) SCOPE_ID="$2"; shift 2 ;;
    --include) INCLUDE="$2"; shift 2 ;;
    --exclude) EXCLUDE="$2"; shift 2 ;;
    --domain-words) DOMAIN_WORDS="$2"; shift 2 ;;
    --concerns-file) CONCERNS_FILE="$2"; shift 2 ;;
    --lit-min-files) LIT_MIN_FILES="$2"; shift 2 ;;
    --lit-max-files) LIT_MAX_FILES="$2"; shift 2 ;;
    --lit-min-len) LIT_MIN_LEN="$2"; shift 2 ;;
    --lit-max-len) LIT_MAX_LEN="$2"; shift 2 ;;
    --line-min-shared) LINE_MIN_SHARED="$2"; shift 2 ;;
    --line-min-len) LINE_MIN_LEN="$2"; shift 2 ;;
    --line-min-occ) LINE_MIN_OCC="$2"; shift 2 ;;
    --line-max-occ) LINE_MAX_OCC="$2"; shift 2 ;;
    --top-n-literals) TOP_N_LITERALS="$2"; shift 2 ;;
    --top-n-lines) TOP_N_LINES="$2"; shift 2 ;;
    --top-n-paths) TOP_N_PATHS="$2"; shift 2 ;;
    --top-n-names) TOP_N_NAMES="$2"; shift 2 ;;
    *) echo "collect-signals.sh: unknown argument: $1" >&2; exit 1 ;;
  esac
done

HAVE_RG=0; command -v rg >/dev/null 2>&1 && HAVE_RG=1
HAVE_JQ=0; command -v jq >/dev/null 2>&1 && HAVE_JQ=1
US="$(printf '\37')"   # ASCII unit separator, for joining multi-value TSV fields

WORKDIR="$(mktemp -d 2>/dev/null || mktemp -d -t dryeyes)"
trap 'rm -rf "$WORKDIR"' EXIT
SELF_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
AWK_DIR="$SELF_DIR/collect-signals.awk.d"

glob_to_regex() {
  # crude but sufficient glob->ERE converter for the patterns this tool ships
  printf '%s' "$1" \
    | sed -E 's/[.[\^$()+{}|]/\\&/g' \
    | sed 's/\*\*/@@DS@@/g' \
    | sed 's/\*/[^\/]*/g' \
    | sed 's/@@DS@@/.*/g'
}

# ── File universe for this scope ────────────────────────────────────────────
# git ls-files already respects .gitignore; include/exclude on top handle the
# categories tracking alone doesn't (tests, fixtures, migrations, committed
# generated code).
cd "$ROOT"
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "{\"tool\":\"collect-signals\",\"scopeId\":\"$SCOPE_ID\",\"fileCount\":0,\"error\":\"not inside a git work tree\"}"
  exit 0
fi

: > "$WORKDIR/files.txt"
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
  for g in $INCLUDE; do git ls-files -- "$g" 2>/dev/null; done >> "$WORKDIR/files.txt"
  set +f; IFS=$OLDIFS
else
  git ls-files >> "$WORKDIR/files.txt"
fi
sort -u "$WORKDIR/files.txt" -o "$WORKDIR/files.txt"

if [ -n "$EXCLUDE" ]; then
  EXCLUDE_RE=""
  OLDIFS=$IFS; IFS=','; set -f
  for g in $EXCLUDE; do
    re=$(glob_to_regex "$g")
    EXCLUDE_RE="${EXCLUDE_RE:+$EXCLUDE_RE|}$re"
  done
  set +f; IFS=$OLDIFS
  if [ -n "$EXCLUDE_RE" ]; then
    grep -vE "$EXCLUDE_RE" "$WORKDIR/files.txt" > "$WORKDIR/files.filtered.txt" || : > "$WORKDIR/files.filtered.txt"
    mv "$WORKDIR/files.filtered.txt" "$WORKDIR/files.txt"
  fi
fi

FILE_COUNT=$(wc -l < "$WORKDIR/files.txt" | tr -d ' ')
if [ "$FILE_COUNT" -eq 0 ]; then
  echo "{\"tool\":\"collect-signals\",\"scopeId\":\"$SCOPE_ID\",\"fileCount\":0,\"error\":\"no files matched this scope's include/exclude patterns\"}"
  exit 0
fi

# NUL-separated batch runner: avoids one-process-per-file, safe on any filename.
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
if [ "$HAVE_RG" -eq 1 ]; then
  run_batched rg -N --no-heading -o -e "\"[^\"]{${LIT_MIN_LEN},${LIT_MAX_LEN}}\"" >> "$WORKDIR/lit_raw.txt" 2>/dev/null || true
  run_batched rg -N --no-heading -o -e "'[^']{${LIT_MIN_LEN},${LIT_MAX_LEN}}'" >> "$WORKDIR/lit_raw.txt" 2>/dev/null || true
else
  run_batched grep -H -o -E "\"[^\"]{${LIT_MIN_LEN},${LIT_MAX_LEN}}\"" >> "$WORKDIR/lit_raw.txt" 2>/dev/null || true
  run_batched grep -H -o -E "'[^']{${LIT_MIN_LEN},${LIT_MAX_LEN}}'" >> "$WORKDIR/lit_raw.txt" 2>/dev/null || true
fi
sed -E 's/^([^:]*):(.*)$/\1\t\2/' "$WORKDIR/lit_raw.txt" \
  | sed -E "s/\t[\"']/\t/; s/[\"']\$//" \
  | sort -u > "$WORKDIR/lit_pairs.tsv"

awk -v MINF="$LIT_MIN_FILES" -v MAXF="$LIT_MAX_FILES" -f "$AWK_DIR/agg-literals.awk" "$WORKDIR/lit_pairs.tsv" \
  | sort -t "$(printf '\t')" -k2,2 \
  | awk -f "$AWK_DIR/group-by-fileset.awk" \
  | sort -t "$(printf '\t')" -k1,1rn \
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
sort -t "$(printf '\t')" -k1,1rn "$WORKDIR/path_families_raw.tsv" | head -n "$TOP_N_PATHS" > "$WORKDIR/path_families.tsv"

# ============================================================================
# Signal 3 — normalized-line overlap (inverted index, near-linear)
# ============================================================================
awk -v MINLEN="$LINE_MIN_LEN" -v MINOCC="$LINE_MIN_OCC" -v MAXOCC="$LINE_MAX_OCC" \
    -v MINSHARED="$LINE_MIN_SHARED" -f "$AWK_DIR/line-overlap.awk" $(cat "$WORKDIR/files.txt") \
  | sort -t "$(printf '\t')" -k1,1rn > "$WORKDIR/line_pairs.tsv"
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
    run_batched rg -N --no-heading -o -e '\b(def|function|func|fn) (self\.)?[A-Za-z_][A-Za-z0-9_]*' >> "$WORKDIR/names_raw.txt" 2>/dev/null || true
  else
    run_batched grep -H -o -E "(def|function|func|fn) (self\.)?[A-Za-z_][A-Za-z0-9_]*" >> "$WORKDIR/names_raw.txt" 2>/dev/null || true
  fi
  sed -E 's/^([^:]*):(.*)$/\1\t\2/' "$WORKDIR/names_raw.txt" \
    | awk -F'\t' '{ name=$2; sub(/^(def|function|func|fn) (self\.)?/, "", name); print tolower(name)"\t"$1 }' \
    | grep -iE "$DOMAIN_RE" > "$WORKDIR/names.tsv" || : > "$WORKDIR/names.tsv"
  sort "$WORKDIR/names.tsv" \
    | awk -F'\t' -v US="$US" '{
        if ($1 == prevName) { c++; files = files US $2 }
        else { if (c >= 2) print c"\t"prevName"\t"files; prevName = $1; c = 1; files = $2 }
      } END { if (c >= 2) print c"\t"prevName"\t"files }' \
    > "$WORKDIR/name_families_raw.tsv"
  NAME_TOTAL=$(wc -l < "$WORKDIR/name_families_raw.tsv" | tr -d ' ')
  sort -t "$(printf '\t')" -k1,1rn "$WORKDIR/name_families_raw.tsv" | head -n "$TOP_N_NAMES" > "$WORKDIR/name_families.tsv"
fi

# ============================================================================
# Signal 5 — concern -> mechanism inventory: for a profile-identified concern
# (e.g. "how errors are shown"), count files per mechanism and flag files
# using more than one mechanism family within the same concern.
# ============================================================================
: > "$WORKDIR/mech_index.tsv"
if [ -n "$CONCERNS_FILE" ] && [ -f "$CONCERNS_FILE" ]; then
  i=0
  while IFS="$(printf '\t')" read -r concern label pattern; do
    [ -z "$concern" ] && continue
    i=$((i + 1))
    mech_file="$WORKDIR/mech_$i.txt"
    if [ "$HAVE_RG" -eq 1 ]; then
      run_batched rg -l -e "$pattern" 2>/dev/null | sort > "$mech_file" || : > "$mech_file"
    else
      run_batched grep -lE "$pattern" 2>/dev/null | sort > "$mech_file" || : > "$mech_file"
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
      cut -f1 "$WORKDIR/mech_index.tsv" | sort -u | while read -r concern; do
        mechs="[]"
        allfiles="$WORKDIR/concern_${concern}_allfiles.txt"
        : > "$allfiles"
        while IFS="$(printf '\t')" read -r c label path; do
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
  # rendered through a minimal hand-rolled escaper instead of jq's. This still
  # gives 3 of 5 signals; name-family/concern-mechanism need per-item object
  # construction this fallback doesn't attempt, and are reported as skipped.
  esc() { printf '%s' "$1" | awk '{ gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); printf "%s", $0 } END { print "" }' | tr -d '\n'; }
  tsv_to_json_array() { # $1=file $2=US-count(0..2, which fields are US-joined lists)
    awk -F'\t' -v US="$US" -v file="$1" '
      BEGIN {
        while ((getline line < file) > 0) {
          n = split(line, f, "\t")
          printf (NR_out++ ? "," : "") "{"
          for (i = 1; i <= n; i++) print_field(i, f[i])
          printf "}"
        }
        print ""
      }
      function print_field(i, v) { }
    ' 2>/dev/null
  }
  # Minimal literal/path/line arrays via a small dedicated awk (clearer than
  # the generic helper above, which is intentionally left unused/simple).
  LIT_JSON=$(awk -F'\t' -v US="$US" 'BEGIN{printf "["} {
      if (NR>1) printf ","
      nf=split($3,fs,US); nl=split($4,ls,US)
      printf "{\"fileCount\":%s,\"literalCount\":%s,\"files\":[",$1,$2
      for(i=1;i<=nf;i++){gsub(/\\/,"\\\\",fs[i]);gsub(/"/,"\\\"",fs[i]);printf "%s\"%s\"",(i>1?",":""),fs[i]}
      printf "],\"literals\":["
      for(i=1;i<=nl;i++){gsub(/\\/,"\\\\",ls[i]);gsub(/"/,"\\\"",ls[i]);printf "%s\"%s\"",(i>1?",":""),ls[i]}
      printf "]}"
    } END{print "]"}' "$WORKDIR/lit_buckets.capped.tsv")
  PATH_JSON=$(awk -F'\t' -v US="$US" 'BEGIN{printf "["} {
      if (NR>1) printf ","
      nf=split($3,fs,US); p=$2; gsub(/\\/,"\\\\",p); gsub(/"/,"\\\"",p)
      printf "{\"fileCount\":%s,\"pattern\":\"%s\",\"files\":[",$1,p
      for(i=1;i<=nf;i++){gsub(/\\/,"\\\\",fs[i]);gsub(/"/,"\\\"",fs[i]);printf "%s\"%s\"",(i>1?",":""),fs[i]}
      printf "]}"
    } END{print "]"}' "$WORKDIR/path_families.tsv")
  LINE_JSON=$(awk -F'\t' 'BEGIN{printf "["} {
      if (NR>1) printf ","
      a=$3; b=$4; gsub(/\\/,"\\\\",a); gsub(/"/,"\\\"",a); gsub(/\\/,"\\\\",b); gsub(/"/,"\\\"",b)
      printf "{\"sharedLines\":%s,\"scaffoldLines\":%s,\"fileA\":\"%s\",\"fileB\":\"%s\"}",$1,$2,a,b
    } END{print "]"}' "$WORKDIR/line_pairs.capped.tsv")

  cat <<EOF
{"tool":"collect-signals","scopeId":"$(esc "$SCOPE_ID")","root":"$(esc "$ROOT")","fileCount":$FILE_COUNT,"toolsAvailable":{"rg":$([ "$HAVE_RG" -eq 1 ] && echo true || echo false),"jq":false},"signals":{"literalCooccurrence":{"buckets":$LIT_JSON,"totalBeforeCap":$LIT_TOTAL},"pathMirror":{"families":$PATH_JSON,"totalBeforeCap":$PATH_TOTAL},"lineOverlap":{"pairs":$LINE_JSON,"totalBeforeCap":$LINE_TOTAL},"nameFamily":{"families":[],"totalBeforeCap":0,"skipped":true},"concernMechanism":{"concerns":[],"skipped":true}},"signalsSkipped":["nameFamily","concernMechanism"],"note":"jq not found on PATH — those two signals need per-item JSON object construction this fallback doesn't attempt. Install jq for full signal coverage."}
EOF
fi

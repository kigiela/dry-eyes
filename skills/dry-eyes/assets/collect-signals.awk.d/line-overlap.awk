# Normalized-line overlap signal — inverted index over comment/string/number-
# masked lines, near-linear (only file PAIRS that actually co-occur on some
# line are ever materialized; no O(n^2) full pairwise scan).
# Invoke as: awk -v LIST=<path-list-file> -v MINLEN=... -f line-overlap.awk
# LIST holds one repo-relative path per line. Paths are read from it and
# opened with getline instead of being passed as awk operands: awk parses its
# operands itself, so a tracked file named like an option (`-fx.awk` loads
# x.awk as program text) or an assignment (`MINSHARED=0`) would be executed
# or evaluated rather than read — and a long list would hit ARG_MAX.
# Output: sharedLines<TAB>scaffoldLines<TAB>fileA<TAB>fileB
BEGIN {
  while ((getline path < LIST) > 0) {
    if (path == "") continue
    src = "./" path   # never "-" (stdin) or an absolute /dev/* special name
    while ((getline raw < src) > 0) index_line(raw, path)
    close(src)
  }
  close(LIST)
  report()
}
function index_line(line, file,    isScaffold, key, c) {
  gsub(/#.*$/, "", line)               # naive line-comment strip (# and // styles)
  gsub(/\/\/.*$/, "", line)
  gsub(/"[^"]*"/, "S", line)           # mask double-quoted strings
  gsub(/\x27[^\x27]*\x27/, "S", line)  # mask single-quoted strings
  gsub(/[0-9]+/, "N", line)            # mask numeric literals
  gsub(/^[ \t]+|[ \t]+$/, "", line)
  gsub(/[ \t]+/, " ", line)
  if (length(line) < MINLEN) return
  # scaffolding-shaped lines are demoted (tracked separately), never rejected
  # outright: a pair whose shared lines are MOSTLY this gets a lower priority
  # downstream, but isn't silently dropped.
  isScaffold = (line ~ /^(class|module|def|end|require|import|from|attr_(reader|writer|accessor)|private|public|protected|@[A-Za-z]|#\[|export |package )/) ? 1 : 0

  key = file SUBSEP line
  if (key in seen) return
  seen[key] = 1
  c = ++occ[line]
  fileOf[line, c] = file
  scaffoldOf[line] = scaffoldOf[line] + isScaffold
}
function report(    line, c, scaffoldFrac, i, j, fi, fj, pairKey, p, shared, scaffold, parts) {
  for (line in occ) {
    c = occ[line]
    if (c < MINOCC || c > MAXOCC) continue
    scaffoldFrac = scaffoldOf[line] / c
    for (i = 1; i <= c; i++) {
      for (j = i + 1; j <= c; j++) {
        fi = fileOf[line, i]; fj = fileOf[line, j]
        pairKey = (fi < fj) ? fi SUBSEP fj : fj SUBSEP fi
        pairShared[pairKey]++
        if (scaffoldFrac >= 0.7) pairScaffold[pairKey]++
      }
    }
  }
  for (p in pairShared) {
    shared = pairShared[p]
    if (shared < MINSHARED) continue
    scaffold = pairScaffold[p] + 0
    split(p, parts, SUBSEP)
    print shared "\t" scaffold "\t" parts[1] "\t" parts[2]
  }
}

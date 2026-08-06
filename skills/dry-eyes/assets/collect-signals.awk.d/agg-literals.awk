# Stage A of the literal-co-occurrence signal.
# Input: file<TAB>literal  (one row per (file,literal) match, pre-deduped)
# Output: count<TAB>sortedFileSet(US-joined)<TAB>literal — one row per
# literal that survived the file-count band and the noise filters.
# US = ASCII unit separator (\x1f), never appears in real source text, so
# it's safe to split on downstream without escaping concerns a comma/pipe
# would carry (a literal or path could contain either).
BEGIN { FS = "\t"; US = sprintf("%c", 31) }
{
  file = $1
  lit = $2
  if (lit == "") next
  # noise filters (stop patterns) — rejected before counting at all
  if (lit ~ /^[a-z0-9-]+( [a-z0-9-]+)+$/) next          # CSS class list: "btn btn-primary"
  if (lit ~ /[a-z-]+:[^;]+;/) next                       # inline style fragment
  if (lit ~ /^[a-z]+\/[a-z0-9.+-]+(;.*)?$/) next         # MIME type
  if (lit ~ /^[A-Za-z_][A-Za-z0-9_]*(, *[A-Za-z_][A-Za-z0-9_]*)+$/) next  # bare column/identifier list
  key = lit SUBSEP file
  if (!(key in seen)) {
    seen[key] = 1
    n = ++count[lit]
    files[lit, n] = file
  }
}
END {
  for (lit in count) {
    c = count[lit]
    if (c < MINF || c > MAXF) continue
    for (i = 1; i <= c; i++) flist[i] = files[lit, i]
    for (i = 2; i <= c; i++) {           # insertion sort — c is small (<=MAXF) by construction
      v = flist[i]; j = i - 1
      while (j >= 1 && flist[j] > v) { flist[j+1] = flist[j]; j-- }
      flist[j+1] = v
    }
    sig = flist[1]
    for (i = 2; i <= c; i++) sig = sig US flist[i]
    print c "\t" sig "\t" lit
    delete flist
  }
}

# Stage B of the literal-co-occurrence signal.
# Input (sorted by field 2, the file-set signature): count<TAB>fileset<TAB>literal
# Output: one row per distinct fileset — fileCount<TAB>literalCount<TAB>fileset<TAB>US-joined-literals
# This is what collapses N near-identical literals that all happen to live in
# the exact same file set into ONE candidate bucket instead of N (the
# "25 BigQuery log strings, same 5 files -> 1 cluster, not 25" finding).
BEGIN { FS = "\t"; US = sprintf("%c", 31) }
{
  if ($2 != prevSig && prevSig != "") flush()
  prevSig = $2
  prevCount = $1
  n = ++lits
  litList[n] = $3
}
END { if (prevSig != "") flush() }
function flush() {
  out = litList[1]
  for (i = 2; i <= lits; i++) out = out US litList[i]
  print prevCount "\t" lits "\t" prevSig "\t" out
  lits = 0
  delete litList
}

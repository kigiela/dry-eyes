# JSON rendering for collect-signals.sh's no-jq fallback, plus the single
# string escaper every hand-built JSON line in that script shares.
#
# Escapes by concatenation, never through sub()/gsub() replacement strings:
# their backslash handling differs between awk implementations (BWK awk, gawk,
# mawk), and an under-escaped backslash in a string literal pulled from a
# scanned repo would let it close its JSON string early and inject fields of
# its own into the document handed to the LLM.
#
# MODE=str  — stdin is one raw string (may span lines); prints it escaped,
#             without surrounding quotes
# MODE=lit  — fileCount<TAB>literalCount<TAB>files<TAB>literals -> JSON array
# MODE=path — fileCount<TAB>pattern<TAB>files                   -> JSON array
# MODE=line — sharedLines<TAB>scaffoldLines<TAB>fileA<TAB>fileB -> JSON array
# (files/literals are US-joined lists, US = ASCII unit separator)
BEGIN {
  FS = "\t"; US = sprintf("%c", 31)
  # control characters JSON can't carry raw and that have no short escape
  for (i = 1; i < 32; i++) if (i != 9 && i != 10 && i != 13) CTRL = CTRL sprintf("%c", i)
  if (MODE != "str") printf "["
}
function jesc(s,    out, i, n, c) {
  out = ""; n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c == "\\") out = out "\\\\"
    else if (c == "\"") out = out "\\\""
    else if (c == "\t") out = out "\\t"
    else if (c == "\r") out = out "\\r"
    else if (c == "\n") out = out "\\n"
    else if (index(CTRL, c) == 0) out = out c
  }
  return out
}
function jlist(s,    parts, n, i, out) {
  n = split(s, parts, US)
  out = "["
  for (i = 1; i <= n; i++) out = out (i > 1 ? "," : "") "\"" jesc(parts[i]) "\""
  return out "]"
}
function jnum(s) { return (s ~ /^[0-9]+$/) ? s : 0 }
MODE == "str" { printf "%s%s", (NR > 1 ? "\\n" : ""), jesc($0); next }
MODE == "lit" {
  printf "%s{\"fileCount\":%s,\"literalCount\":%s,\"files\":%s,\"literals\":%s}",
    (NR > 1 ? "," : ""), jnum($1), jnum($2), jlist($3), jlist($4)
}
MODE == "path" {
  printf "%s{\"fileCount\":%s,\"pattern\":\"%s\",\"files\":%s}",
    (NR > 1 ? "," : ""), jnum($1), jesc($2), jlist($3)
}
MODE == "line" {
  printf "%s{\"sharedLines\":%s,\"scaffoldLines\":%s,\"fileA\":\"%s\",\"fileB\":\"%s\"}",
    (NR > 1 ? "," : ""), jnum($1), jnum($2), jesc($3), jesc($4)
}
END { if (MODE != "str") print "]" }

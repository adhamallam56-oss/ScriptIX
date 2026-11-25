# ScriptIX OVAL engine. Plain POSIX awk (AIX awk, mawk, gawk, busybox, BWK awk): evaluates one
# compiled check on this server. Read-only. An answer it can't give is never reported as a pass.
#   awk -v W=WORKDIR -v SYS=uname -f oval.awk CHECKFILE
# Exit: 0 pass, 1 fail, 250 not applicable, 251 not checked, 252 error, 253 unknown.

# ---------------------------------------------------------------- helpers
function unesc(s,   o, i, c) {
  if (index(s, "\\") == 0) return s
  o = ""
  while ((i = index(s, "\\")) > 0) {
    c = substr(s, i + 1, 1)
    if (c == "n") c = "\n"; else if (c == "t") c = "\t"; else if (c == "r") c = "\r"
    o = o substr(s, 1, i - 1) c
    s = substr(s, i + 2)
  }
  return o s
}
function sq(s,   o, i) {   # single quotes for sh
  o = "'"
  while ((i = index(s, "'")) > 0) { o = o substr(s, 1, i - 1) "'\\''"; s = substr(s, i + 1) }
  return o s "'"
}
function oneline(s) { gsub(/[\n\r\t]/, " ", s); return substr(s, 1, 110) }
function dirpart(p,   i) { i = lastslash(p); if (i <= 1) return "/"; return substr(p, 1, i - 1) }
function basepart(p) { return substr(p, lastslash(p) + 1) }
function lastslash(p,   i) { for (i = length(p); i > 0; i--) if (substr(p, i, 1) == "/") return i; return 0 }
function joinpath(d, f) { if (d == "/" || substr(d, length(d), 1) == "/") return d f; return d "/" f }
function num(s) { return s ~ /^[ \t]*[-+]?[0-9]+[ \t]*$/ }
function keyof(s,   o, i, c) {   # a safe file name for a cache key, "" when too long
  o = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c ~ /^[A-Za-z0-9]$/) o = o c; else o = o "_" ORD[c] "_"
  }
  if (length(o) > 180) return ""
  return o
}
# cached CMD : runs CMD once per script run, returns the file that holds its output
function cached(cmd,   k, f, x, r) {
  k = keyof(cmd)
  if (k == "") { f = W "/c/t" (++NTMP) "_" PIDTAG; system("{ " cmd " ; } > " sq(f) " 2>/dev/null < /dev/null"); return f }
  f = W "/c/" k
  r = (getline x < f); close(f)
  if (r < 0) { system("{ " cmd " ; } > " sq(f "_" PIDTAG) " 2>/dev/null < /dev/null; mv " sq(f "_" PIDTAG) " " sq(f)) }
  return f
}
function has(tool,   c, x, r) {
  if (tool in HAS) return HAS[tool]
  c = "for d in `echo \"$PATH\" | tr : ' '`; do if [ -f \"$d/" tool "\" ] && [ -x \"$d/" tool "\" ]; then echo y; break; fi; done"
  x = ""; c | getline x; close(c)
  HAS[tool] = (x == "y")
  return HAS[tool]
}

# ---------------------------------------------------------------- regex (PCRE subset), backtracking
function mk(t, l, r) { NN++; NT[NN] = t; NL[NN] = l; NR_[NN] = r; return NN }
# lists ("," and "|") are flat, children NK[n, 1..NC[n]]: deep nesting overflows the stack of some awks
function addkid(n, k) { NC[n]++; NK[n, NC[n]] = k }
function up(c,   i) { i = index("abcdefghijklmnopqrstuvwxyz", c); return i ? substr("ABCDEFGHIJKLMNOPQRSTUVWXYZ", i, 1) : c }
function setnode(s, neg) { NN++; NT[NN] = "K"; NS[NN] = s; NL[NN] = neg; return NN }
function charnode(c,   l, u) {
  if (RFI) { l = tolower(c); u = up(l); if (l != u) return setnode(l u, 0) }
  NN++; NT[NN] = "C"; NS[NN] = c
  return NN
}
function inverse(s,   o, i, c) {
  o = ""
  for (i = 1; i < 256; i++) { c = CHR[i]; if (index(s, c) == 0) o = o c }
  return o
}
# class for an escape letter, "" when it isn't one
function esc_set(c) {
  if (c == "d") return DIG
  if (c == "D") return inverse(DIG)
  if (c == "w") return WRD
  if (c == "W") return inverse(WRD)
  if (c == "s") return SPC
  if (c == "S") return inverse(SPC)
  if (c == "h") return " \t"
  if (c == "H") return inverse(" \t")
  if (c == "v") return "\n\013\f\r"
  if (c == "V") return inverse("\n\013\f\r")
  if (c == "N") return inverse("\n")
  return ""
}
function hexval(c) { return index("0123456789abcdef", tolower(c)) - 1 }
# literal for an escape; RI points at the escape letter on entry and at the last used char on exit
function esc_char(c,   h, v) {
  if (c == "n") return "\n"
  if (c == "t") return "\t"
  if (c == "r") return "\r"
  if (c == "f") return "\f"
  if (c == "a") return "\007"
  if (c == "e") return "\033"
  if (c == "x") {
    if (substr(RP, RI + 1, 1) == "{") {
      v = 0; RI++
      while (RI < RN && substr(RP, RI + 1, 1) != "}") { RI++; v = v * 16 + hexval(substr(RP, RI, 1)) }
      RI++
    } else {
      v = 0; h = hexval(substr(RP, RI + 1, 1))
      if (h >= 0) { v = h; RI++; h = hexval(substr(RP, RI + 1, 1)); if (h >= 0 && RI < RN) { v = v * 16 + h; RI++ } }
    }
    if (v > 0 && v < 256) return CHR[v]
    RERR = "unsupported character code"; return "x"
  }
  return c
}
function posix_set(nm) {
  if (nm == "alpha") return LOW UPP
  if (nm == "digit") return DIG
  if (nm == "alnum") return LOW UPP DIG
  if (nm == "upper") return UPP
  if (nm == "lower") return LOW
  if (nm == "space") return SPC
  if (nm == "blank") return " \t"
  if (nm == "punct") return PUN
  if (nm == "word") return WRD
  if (nm == "xdigit") return DIG "abcdefABCDEF"
  if (nm == "print") return LOW UPP DIG PUN " "
  if (nm == "graph") return LOW UPP DIG PUN
  if (nm == "cntrl") return substr(inverse(LOW UPP DIG PUN " "), 1, 31) "\177"
  RERR = "unknown class [:" nm ":]"
  return ""
}
function parse_class(   neg, s, c, first, i, e, lo, hi, j, t, isset) {
  neg = 0; s = ""; first = 1
  if (substr(RP, RI, 1) == "^") { neg = 1; RI++ }
  while (RI <= RN) {
    c = substr(RP, RI, 1)
    if (c == "]" && !first) { RI++; if (RFI) s = foldset(s); return setnode(s, neg) }
    first = 0; isset = 0
    if (c == "[" && substr(RP, RI + 1, 1) == ":") {
      e = index(substr(RP, RI + 2), ":]")
      if (e > 0) {
        t = substr(RP, RI + 2, e - 1)
        if (substr(t, 1, 1) == "^") s = s inverse(posix_set(substr(t, 2))); else s = s posix_set(t)
        RI = RI + e + 3
        continue
      }
    }
    if (c == "\\") {
      RI++; c = substr(RP, RI, 1); t = esc_set(c)
      if (t != "") { s = s t; isset = 1 }
      else if (c == "b") c = "\010"
      else if (c ~ /^[pPRX]$/) { RERR = "unsupported escape in a class"; return setnode(s, neg) }
      else c = esc_char(c)
    }
    RI++
    if (isset) continue
    if (substr(RP, RI, 1) == "-" && substr(RP, RI + 1, 1) != "]" && RI < RN) {
      lo = c; RI++; hi = substr(RP, RI, 1)
      if (hi == "\\") {
        RI++; hi = substr(RP, RI, 1)
        if (esc_set(hi) != "") { s = s lo "-" esc_set(hi); RI++; continue }
        hi = esc_char(hi)
      } else if (hi == "[" && substr(RP, RI + 1, 1) == ":") { s = s lo "-"; continue }
      RI++
      if (ORD[lo] > ORD[hi]) { RERR = "bad range in a class"; return setnode(s, neg) }
      for (j = ORD[lo]; j <= ORD[hi]; j++) s = s CHR[j]
    } else s = s c
  }
  RERR = "missing ]"
  return setnode(s, neg)
}
function foldset(s,   o, i, c, l) {
  o = s
  for (i = 1; i <= 26; i++) {
    l = substr(LOW, i, 1); c = substr(UPP, i, 1)
    if (index(s, l) && !index(s, c)) o = o c
    else if (index(s, c) && !index(s, l)) o = o l
  }
  return o
}
function parse_alt(   l, n) {
  l = parse_cat(); n = 0
  while (RI <= RN && substr(RP, RI, 1) == "|" && RERR == "") {
    if (!n) { n = mk("|", 0, 0); addkid(n, l) }
    RI++; l = parse_cat(); addkid(n, l)
  }
  return n ? n : l
}
function parse_cat(   l, a, c, n) {
  l = 0; n = 0
  while (RI <= RN && RERR == "") {
    c = substr(RP, RI, 1)
    if (c == "|" || c == ")") break
    a = parse_rep()
    if (!l) { l = a; continue }
    if (!n) { n = mk(",", 0, 0); addkid(n, l) }
    addkid(n, a)
  }
  if (n) return n
  if (!l) l = mk("E", 0, 0)
  return l
}
function parse_rep(   a, c, mn, mx, g, t, i, n) {
  a = parse_atom()
  while (RI <= RN && RERR == "") {
    c = substr(RP, RI, 1)
    if (RFX && (c == " " || c == "\t" || c == "\n")) { RI++; continue }
    if (c == "*") { mn = 0; mx = -1; RI++ }
    else if (c == "+") { mn = 1; mx = -1; RI++ }
    else if (c == "?") { mn = 0; mx = 1; RI++ }
    else if (c == "{") {
      i = index(substr(RP, RI), "}")
      t = i ? substr(RP, RI + 1, i - 2) : ""
      if (t ~ /^[0-9]+$/) { mn = t + 0; mx = mn }
      else if (t ~ /^[0-9]+,$/) { mn = t + 0; mx = -1 }
      else if (t ~ /^[0-9]+,[0-9]+$/) { n = index(t, ","); mn = substr(t, 1, n - 1) + 0; mx = substr(t, n + 1) + 0 }
      else break
      RI = RI + i
    } else break
    g = 1
    c = substr(RP, RI, 1)
    if (c == "?" && RI <= RN) { g = 0; RI++ } else if (c == "+" && RI <= RN) { g = 2; RI++ }
    if (mx == 0) { a = mk("E", 0, 0); continue }
    a = mk("*", a, 0); NMN[a] = mn; NMX[a] = mx; NG[a] = g
  }
  return a
}
function parse_atom(   c, n, k, t, fi, fm, fs, fx, on, body, neg) {
  c = substr(RP, RI, 1); RI++
  if (c == ".") { if (RFS) return setnode("", 1); return mk(".", 0, 0) }
  if (c == "^") return mk(RFM ? "^" : "A", 0, 0)
  if (c == "$") return mk(RFM ? "$" : "Z", 0, 0)
  if (c == "[") return parse_class()
  if (c == "(") {
    fi = RFI; fm = RFM; fs = RFS; fx = RFX
    if (substr(RP, RI, 1) == "?") {
      t = substr(RP, RI + 1, 1)
      if (t == ":") { RI += 2; n = parse_alt() }
      else if (t == "=" || t == "!") { RI += 2; body = parse_alt(); n = mk("=", body, (t == "!")) }
      else if (t == ">") { RI += 2; body = parse_alt(); n = mk(">", body, 0) }
      else if (t == "#") { while (RI <= RN && substr(RP, RI, 1) != ")") RI++; n = mk("E", 0, 0) }
      else if (t == "<" && (substr(RP, RI + 2, 1) == "=" || substr(RP, RI + 2, 1) == "!")) {
        neg = (substr(RP, RI + 2, 1) == "!"); RI += 3; body = parse_alt(); n = mk("<", body, neg)
      }
      else if (t == "P" || t == "<" || t == "'") {   # named group: counts like a normal one
        if (t == "P" && substr(RP, RI + 2, 1) != "<") { RERR = "unsupported group"; return mk("E", 0, 0) }
        while (RI <= RN && substr(RP, RI, 1) != ">" && !(t == "'" && substr(RP, RI, 1) == "'" && substr(RP, RI - 1, 1) != "?")) RI++
        RI++; k = ++RCAP; body = parse_alt(); n = mk("(", body, k)
      }
      else if (t ~ /^[imsxU-]$/ && t != "U") {
        on = 1; RI++
        while (RI <= RN) {
          t = substr(RP, RI, 1)
          if (t == "-") on = 0
          else if (t == "i") RFI = on
          else if (t == "m") RFM = on
          else if (t == "s") RFS = on
          else if (t == "x") RFX = on
          else break
          RI++
        }
        if (t == ")") { RI++; return mk("E", 0, 0) }   # flags hold until the enclosing group ends
        if (t != ":") { RERR = "unsupported group"; return mk("E", 0, 0) }
        RI++; n = parse_alt()
      }
      else { RERR = "unsupported group"; return mk("E", 0, 0) }
    } else { k = ++RCAP; body = parse_alt(); n = mk("(", body, k) }
    if (substr(RP, RI, 1) != ")") { if (RERR == "") RERR = "missing )"; return n }
    RI++
    RFI = fi; RFM = fm; RFS = fs; RFX = fx
    return n
  }
  if (c == "\\") {
    if (RI > RN) { RERR = "trailing backslash"; return mk("E", 0, 0) }
    c = substr(RP, RI, 1)
    t = esc_set(c)
    if (t != "") { RI++; return setnode(t, 0) }
    if (c == "b" || c == "B" || c == "A" || c == "Z" || c == "z") { RI++; return mk(c, 0, 0) }
    if (c == "R") { RI++; return setnode("\n\013\f\r", 0) }
    if (c == "Q") {
      RI++; n = mk(",", 0, 0); NC[n] = 0
      while (RI <= RN && substr(RP, RI, 2) != "\\E") { t = charnode(substr(RP, RI, 1)); RI++; addkid(n, t) }
      RI += 2
      return n
    }
    if (c == "E") { RI++; return mk("E", 0, 0) }
    if (c ~ /^[1-9]$/) { RI++; return mk("\\", c + 0, RFI) }
    if (c ~ /^[pPXGKCgku0]$/) { RERR = "unsupported escape \\" c; return mk("E", 0, 0) }
    c = esc_char(c); RI++
    return charnode(c)
  }
  if (RFX && (c == " " || c == "\t" || c == "\n")) return mk("E", 0, 0)
  if (RFX && c == "#") { while (RI <= RN && substr(RP, RI, 1) != "\n") RI++; return mk("E", 0, 0) }
  if (c == "*" || c == "+" || c == "?") { RERR = "nothing to repeat"; return mk("E", 0, 0) }
  return charnode(c)
}
function emit(op, a, b) {
  PC++
  if (PC > 6000) { RERR = "pattern too long"; PC = 6000 }
  OP[RID, PC] = op; PA[RID, PC] = a; PB[RID, PC] = b
  return PC
}
function simple(n) { return NT[n] == "C" || NT[n] == "K" || NT[n] == "." }
function emit1(n) {
  if (NT[n] == "C") return emit(1, NS[n], "")
  if (NT[n] == "K") return emit(2, NS[n], NL[n])
  return emit(3, "", "")
}
# point every instruction in the list " 3 9 12" at the next one (second target when SECOND)
function patch(l, second,   m, i) {
  m = split(l, PTL, " ")
  for (i = 1; i <= m; i++) if (second) PB[RID, PTL[i]] = PC + 1; else PA[RID, PTL[i]] = PC + 1
}
function gen(n,   t, a, b, i, k, x, first) {
  if (RERR != "") return
  t = NT[n]
  if (t == "E") return
  if (simple(n)) { emit1(n); return }
  if (t == ",") { for (i = 1; i <= NC[n]; i++) gen(NK[n, i]); return }
  if (t == "|") {
    b = ""
    for (i = 1; i <= NC[n]; i++) {
      if (i == NC[n]) { gen(NK[n, i]); break }
      a = emit(4, 0, 0); PA[RID, a] = PC + 1; gen(NK[n, i])
      b = b " " emit(5, 0, 0); PB[RID, a] = PC + 1
    }
    patch(b, 0)
    return
  }
  if (t == "(") { emit(6, NR_[n] * 2, ""); gen(NL[n]); emit(6, NR_[n] * 2 + 1, ""); return }
  if (t == "^") { emit(7, "", ""); return }
  if (t == "$") { emit(8, "", ""); return }
  if (t == "A") { emit(11, "", ""); return }
  if (t == "Z") { emit(12, "", ""); return }
  if (t == "z") { emit(13, "", ""); return }
  if (t == "b") { emit(14, 0, ""); return }
  if (t == "B") { emit(14, 1, ""); return }
  if (t == "\\") { emit(15, NL[n], NR_[n]); return }
  if (t == "=") { a = emit(16, NR_[n], 0); gen(NL[n]); emit(9, "", ""); PB[RID, a] = PC + 1; return }
  if (t == "<") { a = emit(17, NR_[n], 0); gen(NL[n]); emit(18, "", ""); emit(9, "", ""); PB[RID, a] = PC + 1; return }
  if (t == ">") { a = emit(19, "", 0); gen(NL[n]); emit(9, "", ""); PB[RID, a] = PC + 1; return }
  if (t == "*") {
    if (NG[n] == 2) { a = emit(19, "", 0); NG[n] = 1; gen(n); NG[n] = 2; emit(9, "", ""); PB[RID, a] = PC + 1; return }
    if (simple(NL[n])) { a = emit(10, NMN[n], NMX[n]); PX[RID, a] = NG[n]; emit1(NL[n]); return }
    for (i = 1; i <= NMN[n] && RERR == ""; i++) gen(NL[n])
    if (NMX[n] < 0) {
      k = ++RMARK
      a = emit(4, 0, 0); PM[RID, a] = NG[n]
      x = emit(20, k, ""); gen(NL[n]); emit(21, k, ""); emit(5, a, 0)
      if (NG[n]) { PA[RID, a] = x; PB[RID, a] = PC + 1 } else { PA[RID, a] = PC + 1; PB[RID, a] = x }
    } else if (NMX[n] > NMN[n]) {
      first = 0; b = ""
      for (i = NMN[n] + 1; i <= NMX[n] && RERR == ""; i++) {
        a = emit(4, 0, 0); b = b " " a
        if (NG[n]) PA[RID, a] = PC + 1; else PB[RID, a] = PC + 1
        gen(NL[n])
      }
      patch(b, NG[n])
    }
    return
  }
  RERR = "unsupported pattern"
}
# where can a match start? 1 = only at a line start, 2 = also where the search begins, 3 = only at the start of the text, 4 = only where the search begins
function anchor(n,   t, a, b) {
  t = NT[n]
  if (t == "^") return 1
  if (t == "A") return 3
  if (t == ",") {
    b = 0
    for (a = 1; a <= NC[n]; a++) {
      if (NT[NK[n, a]] == "=") { b = 1; continue }
      if (NT[NK[n, a]] == "E") continue
      a = anchor(NK[n, a])
      return (b && (a == 2 || a == 4)) ? 0 : a   # after a lookahead, .* does not have to start the line
    }
    return 0
  }
  if (t == "(" || t == ">") return anchor(NL[n])
  if (t == "|") { a = anchor(NK[n, 1]); for (b = 2; b <= NC[n]; b++) if (anchor(NK[n, b]) != a) return 0; return a }
  if (t == "*" && NMN[n] == 0 && NMX[n] < 0 && NG[n] == 1) {
    if (NT[NL[n]] == ".") return 2
    if (NT[NL[n]] == "K" && NS[NL[n]] == "" && NL[NL[n]] == 1) return 4
  }
  return 0
}
function litflush() { if (length(LCUR) > length(LBEST)) LBEST = LCUR; LCUR = "" }
function literal(n,   t, i) {   # longest text that every match must contain
  t = NT[n]
  if (t == "C") { LCUR = LCUR NS[n]; return }
  if (t == ",") { for (i = 1; i <= NC[n]; i++) literal(NK[n, i]); return }
  if (t == "(" || t == ">") { literal(NL[n]); return }
  if (t == "E") return
  litflush()
}
function firstchar(n,   t, i) {
  t = NT[n]
  if (t == "C") return NS[n]
  if (t == ",") { for (i = 1; i <= NC[n]; i++) if (NT[NK[n, i]] != "E") return firstchar(NK[n, i]); return "" }
  if (t == "(" || t == ">") return firstchar(NL[n])
  return ""
}
# re PATTERN FLAGS(i m s) : compiled program number, 0 when the pattern is not supported (RERR says why)
function re(pat, fl,   key, n) {
  key = fl SUBSEP pat
  if (key in REID) { RERR = REBAD[key]; return REID[key] }
  RERR = ""; RP = pat; RI = 1; RN = length(pat); RCAP = 0; RMARK = 0; PC = 0
  RFI = index(fl, "i") > 0; RFM = index(fl, "m") > 0; RFS = index(fl, "s") > 0; RFX = 0
  n = parse_alt()
  if (RERR == "" && RI <= RN) RERR = "unbalanced )"
  RID = ++NRE
  if (RERR == "") { gen(n); emit(9, "", "") }
  REBAD[key] = RERR
  if (RERR != "") { REID[key] = 0; return 0 }
  RCAPS[RID] = RCAP; RANCH[RID] = anchor(n); RTOP[RID] = n
  LCUR = ""; LBEST = ""; literal(n); litflush()
  RLIT[RID] = LBEST; RFC[RID] = firstchar(n)
  RALL[RID] = (pat == "^.*$" || pat == ".*" || pat == "^.*" || pat == ".*$")
  REID[key] = RID
  return RID
}
function one(p, pc, c,   o) {   # does the single-character instruction match c?
  if (c == "") return 0
  o = OP[p, pc]
  if (o == 2) return (index(PA[p, pc], c) > 0) != PB[p, pc]
  if (o == 1) return c == PA[p, pc]
  return c != "\n"
}
function wordat(i,   c) { if (i < 1 || i > BLEN) return 0; c = substr(BUF, i, 1); return index(WRD, c) > 0 }
function vm(p, pc, pos, tgt,   sp0, o, c, n, mx, t, ok, k, e) {
  sp0 = SP
  while (1) {
    if (++STEPS > MAXSTEPS) { RERR = "pattern needs too much work on this text"; SP = sp0; return 0 }
    o = OP[p, pc]; ok = 1
    if (o == 1) { if (pos <= BLEN && substr(BUF, pos, 1) == PA[p, pc]) { pos++; pc++ } else ok = 0 }
    else if (o == 10) {
      n = 0; mx = PB[p, pc]; k = pc + 1; t = OP[p, k]
      if (PX[p, pc] == 1) {
        if (t == 2) {
          while ((mx < 0 || n < mx) && pos + n <= BLEN && (index(PA[p, k], substr(BUF, pos + n, 1)) > 0) != PB[p, k]) n++
        } else if (t == 3) {
          while ((mx < 0 || n < mx) && pos + n <= BLEN && substr(BUF, pos + n, 1) != "\n") n++
        } else {
          while ((mx < 0 || n < mx) && pos + n <= BLEN && substr(BUF, pos + n, 1) == PA[p, k]) n++
        }
        STEPS += n / 4
        if (n < PA[p, pc]) ok = 0
        else {
          if (n > PA[p, pc]) { SP++; ST[SP] = 3; SA[SP] = pc + 2; SB[SP] = pos + PA[p, pc]; SC[SP] = pos + n }
          pos += n; pc += 2
        }
      } else {
        while (n < PA[p, pc] && pos + n <= BLEN && one(p, k, substr(BUF, pos + n, 1))) n++
        if (n < PA[p, pc]) ok = 0
        else {
          SP++; ST[SP] = 4; SA[SP] = pc; SB[SP] = (mx < 0 ? -1 : pos + mx); SC[SP] = pos + n
          pos += n; pc += 2
        }
      }
    }
    else if (o == 2) { if (pos <= BLEN && (index(PA[p, pc], substr(BUF, pos, 1)) > 0) != PB[p, pc]) { pos++; pc++ } else ok = 0 }
    else if (o == 3) { if (pos <= BLEN && substr(BUF, pos, 1) != "\n") { pos++; pc++ } else ok = 0 }
    else if (o == 4) { SP++; ST[SP] = 0; SA[SP] = PB[p, pc]; SB[SP] = pos; pc = PA[p, pc] }
    else if (o == 5) pc = PA[p, pc]
    else if (o == 6) { k = PA[p, pc]; SP++; ST[SP] = 1; SA[SP] = k; SB[SP] = CAP[k]; CAP[k] = pos; pc++ }
    else if (o == 7) { if (pos == 1 || (pos <= BLEN && substr(BUF, pos - 1, 1) == "\n")) pc++; else ok = 0 }
    else if (o == 8) { if (pos > BLEN || substr(BUF, pos, 1) == "\n") pc++; else ok = 0 }
    else if (o == 9) {   # matched: forget the choices, keep the capture history for the caller
      MEND = pos
      n = sp0
      for (k = sp0 + 1; k <= SP; k++) if (ST[k] == 1 || ST[k] == 2) { n++; ST[n] = ST[k]; SA[n] = SA[k]; SB[n] = SB[k] }
      SP = n
      return 1
    }
    else if (o == 11) { if (pos == 1) pc++; else ok = 0 }
    else if (o == 12) { if (pos > BLEN || (pos == BLEN && substr(BUF, pos, 1) == "\n")) pc++; else ok = 0 }
    else if (o == 13) { if (pos > BLEN) pc++; else ok = 0 }
    else if (o == 14) { if ((wordat(pos - 1) != wordat(pos)) != PA[p, pc]) pc++; else ok = 0 }
    else if (o == 15) {
      k = PA[p, pc]
      if (CAP[k * 2 + 1] == 0) ok = 0
      else {
        t = substr(BUF, CAP[k * 2], CAP[k * 2 + 1] - CAP[k * 2])
        e = substr(BUF, pos, length(t))
        if ((e "") == (t "") || (PB[p, pc] && tolower(e) == tolower(t))) { pos += length(t); pc++ } else ok = 0
      }
    }
    else if (o == 16) {
      n = SP; e = vm(p, pc + 1, pos, 0)
      if (PA[p, pc]) { while (SP > n) { if (ST[SP] == 1) CAP[SA[SP]] = SB[SP]; else if (ST[SP] == 2) MRK[SA[SP]] = SB[SP]; SP-- } e = !e }
      if (e && RERR == "") pc = PB[p, pc]; else ok = 0
    }
    else if (o == 17) {
      e = 0
      for (k = pos; k >= 1 && !e && RERR == ""; k--) {
        n = SP; e = vm(p, pc + 1, k, pos)
        if (PA[p, pc]) while (SP > n) { if (ST[SP] == 1) CAP[SA[SP]] = SB[SP]; else if (ST[SP] == 2) MRK[SA[SP]] = SB[SP]; SP-- }
      }
      if (e != PA[p, pc] && RERR == "") pc = PB[p, pc]; else ok = 0
    }
    else if (o == 18) { if (pos == tgt) pc++; else ok = 0 }
    else if (o == 19) { if (vm(p, pc + 1, pos, 0)) { pos = MEND; pc = PB[p, pc] } else ok = 0 }
    else if (o == 20) { k = PA[p, pc]; SP++; ST[SP] = 2; SA[SP] = k; SB[SP] = MRK[k]; MRK[k] = pos; pc++ }
    else if (o == 21) { if (MRK[PA[p, pc]] == pos) pc += 2; else pc++ }   # an empty pass ends the loop
    if (ok) continue
    if (RERR != "") { SP = sp0; return 0 }
    while (1) {   # backtrack
      if (SP <= sp0) return 0
      t = ST[SP]
      if (t == 0) { pc = SA[SP]; pos = SB[SP]; SP--; break }
      if (t == 3) {
        SC[SP]--; pos = SC[SP]; pc = SA[SP]
        if (pos <= SB[SP]) SP--
        break
      }
      if (t == 4) {
        k = SC[SP]
        if ((SB[SP] >= 0 && k >= SB[SP]) || k > BLEN || !one(p, SA[SP] + 1, substr(BUF, k, 1))) { SP--; continue }
        SC[SP]++; pos = k + 1; pc = SA[SP] + 2
        break
      }
      if (t == 1) CAP[SA[SP]] = SB[SP]; else MRK[SA[SP]] = SB[SP]
      SP--
    }
  }
}
# search BUF from position FROM: 1 and MBEG, MEND, CAP when found
function search(p, from,   i, a, fc, k, nx) {
  RERR = ""; STEPS = 0
  a = RANCH[p]; fc = RFC[p]
  if (RLIT[p] != "" && index(BUF, RLIT[p]) == 0) return 0
  for (i = from; i <= BLEN + 1; i++) {
    if (a == 1 || a == 2) {
      if (!(i == 1 || substr(BUF, i - 1, 1) == "\n" || (a == 2 && i == from))) {
        nx = index(substr(BUF, i), "\n")
        if (!nx) return 0
        i += nx
      }
    } else if (a == 3) { if (i > 1) return 0 }
    else if (a == 4) { if (i > from) return 0 }
    else if (fc != "" && substr(BUF, i, 1) != fc) {
      nx = index(substr(BUF, i), fc)
      if (!nx) return 0
      i += nx - 1
    }
    for (k = 0; k <= RCAPS[p] * 2 + 1; k++) CAP[k] = 0
    SP = 0
    if (vm(p, 1, i, 0)) { MBEG = i; return 1 }
    if (RERR != "") return 0
  }
  return 0
}
# "true", "false" or "error": does PAT match somewhere in S?
function rematch(pat, s, fl,   p) {
  p = re(pat, fl)
  if (!p) return "error"
  if (RALL[p] && index(s, "\n") == 0) return "true"
  BUF = s; BLEN = length(s)
  if (search(p, 1)) return "true"
  return RERR == "" ? "false" : "error"
}

# literal starts of a path pattern, so find does not have to walk the whole disk.
# entries end in \001 (something variable follows), \002 (that is the whole path) or nothing
function pf(n, set,   t, m, i, e, o, b, x) {
  t = NT[n]
  if (set == PFALL) return set
  if (t == "E" || t == "^" || t == "A" || t == "=") return set
  if (t == ",") { for (i = 1; i <= NC[n]; i++) set = pf(NK[n, i], set); return set }
  if (t == "(" || t == ">") return pf(NL[n], set)
  if (t == "|") {
    b = ""
    for (i = 1; i <= NC[n]; i++) { x = pf(NK[n, i], set); if (x == PFALL || length(b) + length(x) > 3000) return PFALL; b = b (i > 1 ? "\n" : "") x }
    return b
  }
  m = split(set, PFT, "\n"); o = ""
  if (m == 0) { m = 1; PFT[1] = "" }
  for (i = 1; i <= m; i++) PFC[i] = PFT[i]
  for (i = 1; i <= m; i++) {
    e = PFC[i]
    if (substr(e, length(e), 1) != "\001" && substr(e, length(e), 1) != "\002") {
      if (t == "C") e = e NS[n]
      else if (t == "$" || t == "Z" || t == "z") e = e "\002"
      else e = e "\001"
    }
    o = o (i > 1 ? "\n" : "") e
  }
  return o
}
# starts for a path regex: fills PS[1..n] (PE[i] = 1: an exact path), returns n
function starts(pat,   p, set, m, i, e, n, x, j, dup) {
  p = re(pat, "")
  if (!p) return -1
  n = 0
  if (RANCH[p] != 3) { PS[1] = "/"; PE[1] = 0; return 1 }
  set = pf(RTOP[p], "")
  if (set == PFALL) { PS[1] = "/"; PE[1] = 0; return 1 }
  m = split(set, PFT, "\n")
  for (i = 1; i <= m; i++) {
    e = PFT[i]; x = 0
    if (substr(e, length(e), 1) == "\002") { x = 1; e = substr(e, 1, length(e) - 1) }
    else {
      if (substr(e, length(e), 1) == "\001") e = substr(e, 1, length(e) - 1)
      e = substr(e, 1, lastslash(e))
      if (e == "") e = "/"
      if (length(e) > 1) e = substr(e, 1, length(e) - 1)
    }
    dup = 0
    for (j = 1; j <= n; j++) if (PS[j] == e && PE[j] == x) dup = 1
    if (!dup && e != "") { n++; PS[n] = e; PE[n] = x }
  }
  return n
}

# ---------------------------------------------------------------- comparing
function rpmcmp(a, b,   i, j, x, y, ca, cb, isn) {
  if (a == b) return 0
  i = 1; j = 1
  while (i <= length(a) || j <= length(b)) {
    while (i <= length(a) && substr(a, i, 1) !~ /^[A-Za-z0-9~^]$/) i++
    while (j <= length(b) && substr(b, j, 1) !~ /^[A-Za-z0-9~^]$/) j++
    ca = substr(a, i, 1); cb = substr(b, j, 1)
    if (ca == "~" || cb == "~") { if (ca != "~") return 1; if (cb != "~") return -1; i++; j++; continue }
    if (ca == "^" || cb == "^") {
      if (ca == "") return -1
      if (cb == "") return 1
      if (ca != "^") return 1
      if (cb != "^") return -1
      i++; j++; continue
    }
    if (ca == "" || cb == "") break
    isn = ca ~ /^[0-9]$/
    x = ""; y = ""
    if (isn) {
      while (substr(a, i, 1) ~ /^[0-9]$/) { x = x substr(a, i, 1); i++ }
      while (substr(b, j, 1) ~ /^[0-9]$/) { y = y substr(b, j, 1); j++ }
    } else {
      while (substr(a, i, 1) ~ /^[A-Za-z]$/) { x = x substr(a, i, 1); i++ }
      while (substr(b, j, 1) ~ /^[A-Za-z]$/) { y = y substr(b, j, 1); j++ }
    }
    if (y == "") return isn ? 1 : -1
    if (isn) {
      sub(/^0+/, "", x); sub(/^0+/, "", y)
      if (length(x) != length(y)) return length(x) > length(y) ? 1 : -1
    }
    if ((x "") > (y "")) return 1
    if ((x "") < (y "")) return -1
  }
  if (i > length(a) && j > length(b)) return 0
  return i > length(a) ? -1 : 1
}
function dord(c) { if (c == "~") return -1; if (c == "" || c ~ /^[0-9]$/) return 0; if (c ~ /^[A-Za-z]$/) return ORD[c]; return ORD[c] + 256 }
function dpkgcmp(a, b,   i, j, d, x, y) {
  i = 1; j = 1
  while (i <= length(a) || j <= length(b)) {
    while ((i <= length(a) && substr(a, i, 1) !~ /^[0-9]$/) || (j <= length(b) && substr(b, j, 1) !~ /^[0-9]$/)) {
      d = dord(substr(a, i, 1)) - dord(substr(b, j, 1))
      if (d) return d < 0 ? -1 : 1
      if (i <= length(a)) i++
      if (j <= length(b)) j++
    }
    x = ""; y = ""
    while (substr(a, i, 1) ~ /^[0-9]$/) { x = x substr(a, i, 1); i++ }
    while (substr(b, j, 1) ~ /^[0-9]$/) { y = y substr(b, j, 1); j++ }
    sub(/^0+/, "", x); sub(/^0+/, "", y)
    if (length(x) != length(y)) return length(x) > length(y) ? 1 : -1
    if ((x "") > (y "")) return 1
    if ((x "") < (y "")) return -1
  }
  return 0
}
function splitevr(s,   i) {   # sets EE, EV, ER
  i = index(s, ":")
  if (i) { EE = substr(s, 1, i - 1); s = substr(s, i + 1) } else EE = 0
  if (EE == "" || EE == "(none)") EE = 0
  i = 0
  while (match(substr(s, i + 1), /-/)) i += RSTART
  if (i) { EV = substr(s, 1, i - 1); ER = substr(s, i + 1) } else { EV = s; ER = "" }
}
function evrcmp(a, b, deb,   e1, v1, r1, d) {
  splitevr(a); e1 = EE; v1 = EV; r1 = ER; splitevr(b)
  if (e1 + 0 != EE + 0) return e1 + 0 > EE + 0 ? 1 : -1
  d = deb ? dpkgcmp(v1, EV) : rpmcmp(v1, EV)
  if (d) return d
  if (!deb && (r1 == "" || ER == "")) return 0
  return deb ? dpkgcmp(r1, ER) : rpmcmp(r1, ER)
}
function vercmp(a, b,   n, m, i, x, y) {   # 1.10.2 against 1.9
  n = split(a, VC1, /[^0-9]+/); m = split(b, VC2, /[^0-9]+/)
  for (i = 1; i <= n || i <= m; i++) {
    x = (i <= n ? VC1[i] + 0 : 0); y = (i <= m ? VC2[i] + 0 : 0)
    if (x != y) return x > y ? 1 : -1
  }
  return 0
}
function bitop(a, b, isand,   r, p, x, y) {
  r = 0; p = 1
  while (a > 0 || b > 0) {
    x = a % 2; y = b % 2
    if (isand ? (x && y) : (x || y)) r += p
    a = int(a / 2); b = int(b / 2); p *= 2
  }
  return r
}
function bool(s) { s = tolower(s); if (s == "1" || s == "true" || s == "yes") return "true"; if (s == "0" || s == "false" || s == "no") return "false"; return s }
function ord3(op, d) {   # d = -1, 0, 1
  if (op == "equals" || op == "case insensitive equals") return d == 0 ? "true" : "false"
  if (op == "not equal" || op == "case insensitive not equal") return d != 0 ? "true" : "false"
  if (op == "greater than") return d > 0 ? "true" : "false"
  if (op == "greater than or equal") return d >= 0 ? "true" : "false"
  if (op == "less than") return d < 0 ? "true" : "false"
  if (op == "less than or equal") return d <= 0 ? "true" : "false"
  return "error"
}
function ipnum(s,   n) {
  n = split(s, IPP, ".")
  if (n != 4 || s !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) return -1
  return ((IPP[1] * 256 + IPP[2]) * 256 + IPP[3]) * 256 + IPP[4]
}
function cmpval(op, dt, have, want,   a, b, i, m1, m2, s) {
  have = have ""; want = want ""
  if (op == "pattern match") return rematch(want, have, "")
  if (dt == "int") {
    if (!num(have) || !num(want)) return "error"
    a = have + 0; b = want + 0
    if (op == "bitwise and") return bitop(a, b, 1) == b ? "true" : "false"
    if (op == "bitwise or") return bitop(a, b, 0) == b ? "true" : "false"
    return ord3(op, a < b ? -1 : a > b ? 1 : 0)
  }
  if (dt == "float") { a = have + 0; b = want + 0; return ord3(op, a < b ? -1 : a > b ? 1 : 0) }
  if (dt == "boolean") { a = bool(have); b = bool(want); return ord3(op, a == b ? 0 : 1) }
  if (dt == "evr_string") return ord3(op, evrcmp(have, want, 0))
  if (dt == "debian_evr_string") return ord3(op, evrcmp(have, want, 1))
  if (dt == "version" || dt == "fileset_revision" || dt == "ios_version") return ord3(op, vercmp(have, want))
  if (dt == "ipv4_address") {
    m1 = 32; m2 = 32
    if ((i = index(have, "/")) > 0) { m1 = substr(have, i + 1) + 0; have = substr(have, 1, i - 1) }
    if ((i = index(want, "/")) > 0) { m2 = substr(want, i + 1) + 0; want = substr(want, 1, i - 1) }
    a = ipnum(have); b = ipnum(want)
    if (a < 0 || b < 0 || m1 > 32 || m2 > 32) return "error"
    s = 1; for (i = 1; i <= 32 - m2; i++) s *= 2
    if (op == "subset of") return (m1 >= m2 && int(a / s) == int(b / s)) ? "true" : "false"
    if (op == "equals" || op == "not equal") return ord3(op, (a == b && m1 == m2) ? 0 : 1)
    return ord3(op, a < b ? -1 : a > b ? 1 : 0)
  }
  if (dt != "" && dt != "string" && dt != "binary") return "error"
  if (op == "case insensitive equals" || op == "case insensitive not equal") { have = tolower(have); want = tolower(want) }
  return ord3(op, (have "") == (want "") ? 0 : (have "") < (want "") ? -1 : 1)
}
function tally(r) {
  if (r == "true") CT++; else if (r == "false") CF++; else if (r == "error") CE++
  else if (r == "unknown") CU++; else if (r == "not evaluated") CV++; else CA++
}
function bycheck(chk, t, f, e, u, v, a) {
  if (chk == "all") {
    if (f) return "false"
    if (e) return "error"
    if (u) return "unknown"
    if (v) return "not evaluated"
    if (t) return "true"
  } else if (chk == "at least one") {
    if (t) return "true"
    if (e) return "error"
    if (u) return "unknown"
    if (v) return "not evaluated"
    if (f) return "false"
  } else if (chk == "only one") {
    if (t > 1) return "false"
    if (e) return "error"
    if (u) return "unknown"
    if (v) return "not evaluated"
    if (t == 1) return "true"
    if (f) return "false"
  } else {   # none satisfy, none exist
    if (t) return "false"
    if (e) return "error"
    if (u) return "unknown"
    if (v) return "not evaluated"
    if (f) return "true"
  }
  return a ? "not applicable" : "unknown"
}
function byop(op, t, f, e, u, v, a) {
  if (op == "AND") return bycheck("all", t, f, e, u, v, a)
  if (op == "OR") return bycheck("at least one", t, f, e, u, v, a)
  if (op == "ONE") return bycheck("only one", t, f, e, u, v, a)
  if (e) return "error"   # XOR
  if (u) return "unknown"
  if (v) return "not evaluated"
  if (t + f == 0) return a ? "not applicable" : "unknown"
  return t % 2 ? "true" : "false"
}
function flip(r) { if (r == "true") return "false"; if (r == "false") return "true"; return r }

# ---------------------------------------------------------------- variables
# val VID : evaluates a variable once. VF[VID] = ok, none, error. VN[VID] values in VV[VID, i]
function val(v,   x, i, n) {
  if (v in VF) return VF[v]
  if (!(v in VK)) { VF[v] = "error"; VN[v] = 0; return "error" }
  if (VK[v] != "local") { VN[v] += 0; VF[v] = VN[v] ? "ok" : "none"; return VF[v] }
  VF[v] = "error"; VN[v] = 0   # guards against loops
  x = VX[v]; comp(x)
  n = XN[x]
  for (i = 1; i <= n; i++) VV[v, i] = XV[x, i]
  VN[v] = n
  VF[v] = XF[x] == "ok" ? (n ? "ok" : "none") : XF[x]
  return VF[v]
}
function xput(x, s) { XN[x]++; XV[x, XN[x]] = s "" }
function comp(x,   f, i, j, k, n, c, o, it, e, p, s, t, best) {
  if (x in XF) return
  XF[x] = "ok"; XN[x] = 0
  f = XK[x]
  if (f == "lit") { xput(x, XA[x, 1]); return }
  if (f == "bad") { XF[x] = "error"; return }
  if (f == "var") {
    XF[x] = val(XA[x, 1])
    for (i = 1; i <= VN[XA[x, 1]]; i++) xput(x, VV[XA[x, 1], i])
    return
  }
  if (f == "obj") {
    o = XA[x, 1]; collect(o)
    if (OF_[o] == "error" || OF_[o] == "nc") { XF[x] = "error"; return }
    if (OF_[o] == "na") { XF[x] = "error"; return }
    for (i = 1; i <= OIN[o]; i++) {
      n = split(getent(OI[o, i], XA[x, 2]), MV, SEP)
      if (!hasent(OI[o, i], XA[x, 2])) continue
      if (n == 0) xput(x, "")
      for (j = 1; j <= n; j++) xput(x, MV[j])
    }
    if (OIN[o] == 0) XF[x] = "none"
    return
  }
  n = XC[x]
  for (i = 1; i <= n; i++) {
    c = XA[x, i]
    if (f == "split" && i > 1 || f == "substring" && i > 1 || f == "regex_capture" && i > 1 || f == "begin" && i > 1 || f == "end" && i > 1 || f == "arithmetic" && i == 1 || f == "time_difference" && i < 3) continue
    comp(c)
    if (XF[c] == "error") XF[x] = "error"
    else if (XF[c] == "none" && f != "count" && f != "unique" && f != "merge" && XF[x] == "ok") XF[x] = "none"
  }
  if (XF[x] == "error") return
  if (f == "count") {
    k = 0; for (i = 1; i <= n; i++) k += XN[XA[x, i]]
    XF[x] = "ok"; xput(x, k); return
  }
  if (XF[x] == "none") return
  if (f == "unique" || f == "merge") {
    for (i = 1; i <= n; i++) for (j = 1; j <= XN[XA[x, i]]; j++) {
      s = XV[XA[x, i], j]
      if (f == "unique" && ((x, s) in XU)) continue
      XU[x, s] = 1; xput(x, s)
    }
    if (XN[x] == 0) XF[x] = "none"
    return
  }
  if (f == "concat") {
    XV[x, 1] = ""; XN[x] = 1
    for (i = 1; i <= n; i++) {
      c = XA[x, i]; k = XN[x]; t = 0
      for (j = 1; j <= k; j++) XT[j] = XV[x, j]
      for (j = 1; j <= k; j++) for (p = 1; p <= XN[c]; p++) { t++; XV[x, t] = XT[j] XV[c, p] }
      XN[x] = t
    }
    return
  }
  if (f == "arithmetic") {
    for (i = 2; i <= n; i++) {
      c = XA[x, i]
      for (j = 1; j <= XN[c]; j++) if (XV[c, j] !~ /^[ \t]*[-+]?[0-9.]+[ \t]*$/) { XF[x] = "error"; return }
      if (i == 2) { for (j = 1; j <= XN[c]; j++) xput(x, XV[c, j]); continue }
      k = XN[x]; t = 0
      for (j = 1; j <= k; j++) XT[j] = XV[x, j]
      for (j = 1; j <= k; j++) for (p = 1; p <= XN[c]; p++) {
        t++; s = XA[x, 1] == "multiply" ? XT[j] * XV[c, p] : XT[j] + XV[c, p]
        XV[x, t] = s == int(s) ? sprintf("%.0f", s) : s ""
      }
      XN[x] = t
    }
    return
  }
  c = XA[x, 1]
  if (f == "time_difference") {   # only seconds since 1970: now minus the value, or value 1 minus value 2
    if (XA[x, 2] != "seconds_since_epoch" || (n > 3 && XA[x, 1] != "seconds_since_epoch")) { XF[x] = "error"; return }
    c = XA[x, 3]
    for (j = 1; j <= XN[c]; j++) {
      if (!num(XV[c, j])) { XF[x] = "error"; return }
      if (n < 4) { xput(x, sprintf("%.0f", NOW - XV[c, j])); continue }
      for (k = 1; k <= XN[XA[x, 4]]; k++) { if (!num(XV[XA[x, 4], k])) { XF[x] = "error"; return } xput(x, sprintf("%.0f", XV[c, j] - XV[XA[x, 4], k])) }
    }
    return
  }
  for (j = 1; j <= XN[c]; j++) {
    s = XV[c, j]
    if (f == "split") {
      t = XA[x, 2]
      if (t == "") { xput(x, s); continue }
      while ((i = index(s, t)) > 0) { xput(x, substr(s, 1, i - 1)); s = substr(s, i + length(t)) }
      xput(x, s)
    } else if (f == "substring") {
      i = XA[x, 2] + 0; k = XA[x, 3] + 0
      if (i > length(s)) { XF[x] = "error"; return }
      if (i < 1) i = 1
      xput(x, k < 0 ? substr(s, i) : substr(s, i, k))
    } else if (f == "regex_capture") {
      p = re(XA[x, 2], "")
      if (!p) { XF[x] = "error"; return }
      BUF = s; BLEN = length(s)
      if (search(p, 1)) xput(x, CAP[3] ? substr(BUF, CAP[2], CAP[3] - CAP[2]) : "")
      else if (RERR != "") { XF[x] = "error"; return }
      else xput(x, "")
    } else if (f == "begin") xput(x, substr(s, 1, length(XA[x, 2])) == XA[x, 2] ? s : XA[x, 2] s)
    else if (f == "end") xput(x, substr(s, length(s) - length(XA[x, 2]) + 1) == XA[x, 2] ? s : s XA[x, 2])
    else if (f == "escape_regex") {
      t = ""
      for (i = 1; i <= length(s); i++) { k = substr(s, i, 1); t = t (index("^$\\.[](){}*+?|", k) ? "\\" k : k) }
      xput(x, t)
    } else if (f == "glob_to_regex") xput(x, globre(s))
    else { XF[x] = "error"; return }
  }
}
function globre(g,   o, i, c, n) {
  o = "^"
  for (i = 1; i <= length(g); i++) {
    c = substr(g, i, 1)
    if (c == "\\" && i < length(g)) { i++; o = o "\\" substr(g, i, 1) }
    else if (c == "*") o = o "[^/]*"
    else if (c == "?") o = o "[^/]"
    else if (c == "[") {
      n = index(substr(g, i + 2), "]")
      if (!n) { o = o "\\["; continue }
      c = substr(g, i + 1, n)
      if (substr(c, 1, 1) == "!") c = "^" substr(c, 2)
      o = o "[" c "]"; i += n + 1
    }
    else o = o (index("^$.](){}+|", c) ? "\\" c : c)
  }
  return o "$"
}

# ---------------------------------------------------------------- items
function newitem(kind) { NI++; IK[NI] = kind; return NI }
function put(it, e, v) { IV[it, e] = v "" }
function hasent(it, e) {
  if ((it, e) in IV) return 1
  if (IK[it] == "file") return (e in FPERM)
  if (IK[it] == "partition") return (e == "total_space" || e == "space_used" || e == "space_left")
  return 0
}
function getent(it, e,   m, r, k) {
  if ((it, e) in IV) return IV[it, e]
  if (IK[it] == "file" && (e in FPERM)) {
    m = IV[it, "mode"]
    k = FPERM[e]
    if (e == "suid" || e == "sgid") return substr(m, k, 1) ~ /^[sS]$/ ? "true" : "false"
    if (e == "sticky") return substr(m, k, 1) ~ /^[tT]$/ ? "true" : "false"
    if (e == "has_extended_acl") return substr(m, 11, 1) == "+" ? "true" : "false"
    if (e == "oexec") return substr(m, k, 1) ~ /^[xt]$/ ? "true" : "false"
    if (e == "uexec" || e == "gexec") return substr(m, k, 1) ~ /^[xs]$/ ? "true" : "false"
    return substr(m, k, 1) != "-" ? "true" : "false"
  }
  return ""
}
# what the item is, to compare members of sets
function ident(it,   s, i, n) {
  n = split("filepath text instance subexpression name arch evr value unit property dependency mount_point device username pid command_line protocol local_full_address canonical_path hash_type hash", IDE, " ")
  s = IK[it]
  for (i = 1; i <= n; i++) if ((it, IDE[i]) in IV) s = s SUBSEP IDE[i] "=" IV[it, IDE[i]]
  return s
}
function show(it,   s, i, n, v) {
  n = split("filepath name unit username mount_point property value canonical_path text subexpression evr dependency user_id group_id mode type os_name processor_type flstinst level state maintenance_level tunable vuid label service_name runlevel start protocol local_full_address command_line hash inet_addr", SHE, " ")
  s = ""
  if (IV[it, "filepath"] ~ /^\/etc\/(shadow|gshadow|security\/passwd)/) return IV[it, "filepath"] " (content hidden)"
  for (i = 1; i <= n; i++) if ((it, SHE[i]) in IV) {
    v = IV[it, SHE[i]]
    if (IK[it] == "password" && SHE[i] != "username" && SHE[i] != "user_id" && SHE[i] != "group_id") continue
    if (IK[it] == "shadow" && SHE[i] != "username") continue
    if (SHE[i] == "subexpression" && (it, "text") in IV && index(IV[it, "text"], v)) continue
    gsub(SEP, ",", v)
    s = s (s == "" ? "" : " | ") v
  }
  return oneline(s)
}

# ---------------------------------------------------------------- objects
function entn(o, e) { if (OEX[o, e] == "var") return VN[OEA[o, e]]; return 1 }
function entv(o, e, i) { if (OEX[o, e] == "var") return VV[OEA[o, e], i]; return OEA[o, e] }
function hasobj(o, e) { return (o, e) in OEX }
function prepstate(s,   i) { for (i = 1; i <= SEN[s]; i++) if (SEX[s, i] == "var") val(SEA[s, i]) }
# all variables an object needs. "" when fine, else the flag the object gets
function prep(o,   i, e, r) {
  for (i = 1; i <= OEN[o]; i++) {
    e = OEL[o, i]
    if (OEX[o, e] == "var") {
      r = val(OEA[o, e])
      if (r == "error") return "error"
      if (r == "none") return "none"
    }
  }
  # variables of the filters too: they may run probes, which must not happen in the middle of a listing
  for (i = 1; i <= OFN[o]; i++) prepstate(OFL[o, i])
  return ""
}
# does value v satisfy the object's entity e? true/false/error
function objent(o, e, v,   i, n, r) {
  if (!hasobj(o, e) || OEX[o, e] == "nil") return "true"
  if (OEX[o, e] != "var") return cmpval(OEP[o, e], OED[o, e], v, OEA[o, e])
  CT = CF = CE = CU = CV = CA = 0
  n = entn(o, e)
  for (i = 1; i <= n; i++) tally(cmpval(OEP[o, e], OED[o, e], v, entv(o, e, i)))
  return bycheck(OEV[o, e], CT, CF, CE, CU, CV, CA)
}
function objmatch(o, e, v,   r) { r = objent(o, e, v); if (r == "error") OBAD[o] = 1; return r == "true" }

# addto O IT : applies the object's filters, then keeps the item
function addto(o, it,   i, r) {
  for (i = 1; i <= OFN[o]; i++) {
    r = evalstate(OFL[o, i], it)
    if (r == "error") OBAD[o] = 1
    if (OFA[o, i] == "include" ? r != "true" : r == "true") return 0
  }
  OIN[o]++; OI[o, OIN[o]] = it
  return 1
}
function collect(o,   r, k) {
  if (o in OF_) return
  OF_[o] = "error"; OIN[o] = 0
  if (!(o in OKIND)) return
  if (o in SOP) { for (k = 1; k <= OFN[o]; k++) prepstate(OFL[o, k]); collectset(o); return }
  r = prep(o)
  if (r != "") { OF_[o] = r; return }
  k = OKIND[o]
  if (k == "textfilecontent54") r = p_text(o)
  else if (k == "file") r = p_file(o)
  else if (k == "dpkginfo") r = p_dpkg(o)
  else if (k == "rpminfo") r = p_rpm(o)
  else if (k == "partition") r = p_partition(o)
  else if (k == "sysctl") r = p_sysctl(o)
  else if (k == "systemdunitproperty") r = p_unitprop(o)
  else if (k == "systemdunitdependency") r = p_unitdep(o)
  else if (k == "family") r = p_family(o)
  else if (k == "uname") r = p_uname(o)
  else if (k == "password") r = p_password(o)
  else if (k == "shadow") r = p_shadow(o)
  else if (k == "environmentvariable58" || k == "environmentvariable") r = p_env(o)
  else if (k == "variable") r = p_variable(o)
  else if (k == "symlink") r = p_symlink(o)
  else if (k == "filehash58") r = p_hash(o)
  else if (k == "interface") r = p_interface(o)
  else if (k == "inetlisteningservers") r = p_listen(o)
  else if (k == "process58" || k == "process") r = p_process(o)
  else if (k == "runlevel") r = p_runlevel(o)
  else if (k == "selinuxboolean") r = p_sebool(o)
  else if (k == "selinuxsecuritycontext") r = p_secontext(o)
  else if (k == "fileset") r = p_fileset(o)
  else if (k == "oslevel") r = p_oslevel(o)
  else if (k == "no") r = p_no(o)
  else if (k == "interim_fix") r = p_ifix(o)
  else r = "nc"
  if (r == "ok") r = OBAD[o] ? "error" : OIN[o] ? "complete" : "none"
  OF_[o] = r
}
function collectset(o,   n, i, j, it, f, k, any, fl, id) {
  n = SNUM[o]; any = ""
  for (i = 1; i <= n; i++) {
    collect(SOB[o, i]); f = OF_[SOB[o, i]]
    if (f == "error") any = "error"
    else if ((f == "nc" || f == "na") && any == "") any = f
  }
  if (any != "") { OF_[o] = any; return }
  for (i = 1; i <= n; i++) for (j = 1; j <= OIN[SOB[o, i]]; j++) {
    it = OI[SOB[o, i], j]; id = ident(it)
    SEEN[o, i, id] = 1
  }
  for (i = 1; i <= n; i++) {
    if (i == 2 && SOP[o] != "UNION") break
    for (j = 1; j <= OIN[SOB[o, i]]; j++) {
      it = OI[SOB[o, i], j]; id = ident(it)
      if (SOP[o] == "UNION" && i == 2 && ((o, 1, id) in SEEN)) continue
      if (SOP[o] == "COMPLEMENT" && ((o, 2, id) in SEEN)) continue
      if (SOP[o] == "INTERSECTION" && n > 1 && !((o, 2, id) in SEEN)) continue
      addto(o, it)
    }
  }
  OF_[o] = OBAD[o] ? "error" : OIN[o] ? "complete" : "none"
}

# ---------------------------------------------------------------- files
function iswsl(  l) { if (WSL == "") { WSL = 0; if ((getline l < "/proc/version") > 0 && tolower(l) ~ /microsoft/) WSL = 1; close("/proc/version") } return WSL }
function fsprune(st, how,   s, n, i, t) {
  if (how == "defined") return "-xdev "
  if (st ~ /^\/(proc|sys)(\/|$)/) return ""
  if (SYS != "Linux") return (how == "local" && (SYS == "AIX" || SYS == "SunOS")) ? "-fstype nfs -prune -o " : ""
  s = "proc sysfs"
  if (how != "all") s = s " nfs nfs4 cifs smb3 smbfs 9p drvfs afs ncpfs autofs fuse.sshfs ceph glusterfs fuse.glusterfs"
  else if (iswsl()) s = s " 9p drvfs"   # the drives of the Windows PC are not part of this system
  n = split(s, FST, " "); t = ""
  for (i = 1; i <= n; i++) t = t (i > 1 ? " -o " : "") "-fstype " FST[i]
  return "\\( " t " \\) -prune -o "
}
function slashes(s) { gsub(/\/\/+/, "/", s); return s }
# every path under START (dirs: only directories). Returns the list file
function walk(st, how, types,   t) {
  t = types == "d" ? "-type d " : types == "f" ? "\\( -type f -o -type l \\) " : ""
  return cached("find " sq(st == "/" ? "/" : st "/") " " fsprune(st, how) t "-print")
}
function addpath(p) { p = slashes(p); if (length(p) > 1 && substr(p, length(p), 1) == "/") p = substr(p, 1, length(p) - 1); if ((FGEN, p) in FSEEN) return; FSEEN[FGEN, p] = 1; FLN++; FL[FLN] = p }
function adddir(p) { p = slashes(p); if (length(p) > 1 && substr(p, length(p), 1) == "/") p = substr(p, 1, length(p) - 1); if ((FGEN, "d", p) in FSEEN) return; FSEEN[FGEN, "d", p] = 1; DLN++; DL[DLN] = p }
function isthere(p, t,   c, x) { x = ""; c = "[ " t " " sq(p) " ] && echo y"; c | getline x; close(c); return x == "y" }
function depthof(p,   n) { return split(p, DPT, "/") }
# candidate paths of an object with filepath, or path + filename. 1 = fine, 0 = not supported
function listpaths(o, types,   i, j, n, m, v, f, l, how, rec, maxd, base, q, d, c, nm, np, fop, nd) {
  FLN = 0; FGEN++; DLN = 0
  how = (o, "recurse_file_system") in OB ? OB[o, "recurse_file_system"] : "all"
  if (hasobj(o, "filepath")) {
    n = entn(o, "filepath")
    for (i = 1; i <= n; i++) {
      v = entv(o, "filepath", i)
      if (OEP[o, "filepath"] == "equals") { if (v != "") addpath(v); continue }
      if (OEP[o, "filepath"] != "pattern match") return 0
      m = starts(v)
      if (m < 0) return 0
      for (j = 1; j <= m; j++) { Q1[j] = PS[j]; Q2[j] = PE[j] }
      for (j = 1; j <= m; j++) {
        if (Q2[j]) { addpath(Q1[j]); continue }
        f = walk(Q1[j], how, types)
        while ((getline l < f) > 0) { l = slashes(l); if (rematch(v, l, "") == "true") addpath(l) }
        close(f)
      }
    }
    if (n > 1 && OEV[o, "filepath"] == "all") for (i = 1; i <= FLN; i++) if (!objmatch(o, "filepath", FL[i])) FL[i] = ""
    return 1
  }
  if (!hasobj(o, "path")) return 0
  n = entn(o, "path")
  for (i = 1; i <= n; i++) {
    v = entv(o, "path", i)
    if (OEP[o, "path"] == "equals") { if (v != "") adddir(v); continue }
    if (OEP[o, "path"] != "pattern match") return 0
    m = starts(v)
    if (m < 0) return 0
    for (j = 1; j <= m; j++) { Q1[j] = PS[j]; Q2[j] = PE[j] }
    for (j = 1; j <= m; j++) {
      if (Q2[j]) { adddir(Q1[j]); continue }
      f = walk(Q1[j], how, "d")
      while ((getline l < f) > 0) { l = slashes(l); if (length(l) > 1 && substr(l, length(l), 1) == "/") l = substr(l, 1, length(l) - 1); if (rematch(v, l, "") == "true") adddir(l) }
      close(f)
    }
  }
  rec = OB[o, "recurse_direction"]; maxd = (o, "max_depth") in OB ? OB[o, "max_depth"] + 0 : -1
  if (rec == "up") return 0
  fop = hasobj(o, "filename") ? (OEX[o, "filename"] == "nil" ? "nil" : OEP[o, "filename"]) : "nil"
  nd = DLN
  for (i = 1; i <= nd; i++) {
    d = DL[i]
    if (rec == "down") {
      base = depthof(d == "/" ? "" : d)
      f = walk(d, how, fop == "nil" ? "d" : types)
      while ((getline l < f) > 0) {
        l = slashes(l)
        if (length(l) > 1 && substr(l, length(l), 1) == "/") l = substr(l, 1, length(l) - 1)
        if (fop == "nil") { if (maxd < 0 || depthof(l) - base <= maxd) addpath(l); continue }
        if (l == d) continue
        if (maxd >= 0 && depthof(l) - 1 - base > maxd) continue
        if (objmatch(o, "filename", basepart(l))) addpath(l)
      }
      close(f)
    } else if (fop == "nil") addpath(d)
    else if (fop == "equals") { np = entn(o, "filename"); for (j = 1; j <= np; j++) addpath(joinpath(d, entv(o, "filename", j))) }
    else {
      c = "ls -a " sq(d == "/" ? d : d "/") " 2>/dev/null"
      while ((c | getline l) > 0) if (l != "." && l != ".." && objmatch(o, "filename", l)) addpath(joinpath(d, l))
      close(c)
    }
  }
  return 1
}
# whole file into BUF (BLEN). 1 read, 0 can't be read, -1 is not there
function slurp(p,   l, n, b, m, r, i) {
  if (p == LASTF) { BUF = LASTB; BLEN = length(BUF); return LASTR }
  n = 0; m = 0; b = ""
  r = -1
  if (isthere(p, "-f")) {
    if (!isthere(p, "-r")) r = 0
    else {
      r = 1
      while ((getline l < p) > 0) {
        b = b l "\n"
        if (++n == 100) { SLB[++m] = b; b = ""; n = 0 }
      }
      close(p)
    }
  }
  BUF = ""
  if (m) {   # joined in pairs: much faster than one growing string
    SLB[++m] = b
    while (m > 1) { n = 0; for (i = 1; i <= m; i += 2) { n++; SLB[n] = SLB[i] (i < m ? SLB[i + 1] : "") } m = n }
    BUF = SLB[1]
  } else BUF = b
  LASTF = p; LASTB = BUF; LASTR = r; BLEN = length(BUF)
  return r
}
function p_text(o,   i, j, k, n, p, v, fl, r, f, from, inst, it, s, iop, stopat, np, got) {
  if (!listpaths(o, "f")) return "error"
  for (i = 1; i <= FLN; i++) TFL[o, i] = FL[i]
  n = FLN
  fl = (OB[o, "multiline"] == "false" ? "" : "m") (OB[o, "singleline"] == "true" ? "s" : "") (OB[o, "ignore_case"] == "true" ? "i" : "")
  np = entn(o, "pattern")
  if (OEP[o, "pattern"] != "pattern match") return "error"
  stopat = (hasobj(o, "instance") && OEX[o, "instance"] == "lit" && OEP[o, "instance"] == "equals") ? OEA[o, "instance"] + 0 : 0
  for (i = 1; i <= n; i++) {
    f = TFL[o, i]
    if (f == "") continue
    r = slurp(f)
    if (r < 0) continue
    if (r == 0) { OBAD[o] = 1; note("cannot read " f); continue }
    for (j = 1; j <= np; j++) {
      p = re(entv(o, "pattern", j), fl)
      if (!p) { note("pattern not supported (" RERR "): " oneline(entv(o, "pattern", j))); return "error" }
      from = 1; inst = 0
      slurp(f)
      while (from <= BLEN + 1 && search(p, from)) {
        inst++
        k = MEND > MBEG ? MEND : MEND + 1
        if (!hasobj(o, "instance") || objmatch(o, "instance", inst)) {
          it = newitem("textfilecontent54")
          put(it, "filepath", f); put(it, "path", dirpart(f)); put(it, "filename", basepart(f))
          put(it, "pattern", entv(o, "pattern", j)); put(it, "instance", inst)
          put(it, "text", substr(BUF, MBEG, MEND - MBEG))
          s = ""
          for (r = 1; r <= RCAPS[p]; r++) if (CAP[r * 2 + 1] > 0) s = s (s == "" && r == 1 ? "" : SEP) substr(BUF, CAP[r * 2], CAP[r * 2 + 1] - CAP[r * 2])
          if (RCAPS[p] > 0) put(it, "subexpression", s)
          from = k
          if (OFN[o]) { addto(o, it); slurp(f) } else addto(o, it)
        } else from = k
        if (stopat && inst >= stopat) break
      }
      if (RERR != "") { note(RERR ": " f); return "error" }
    }
  }
  return "ok"
}
# one "ls -ldn" line -> item NI+1 (kept only when the caller keeps it)
function lsitem(l, kind,   i, m, uid, gid, sz, rest, n, it, t, p) {
  rest = l
  for (n = 1; n <= 8; n++) {
    sub(/^[ \t]+/, "", rest); i = match(rest, /[ \t]/)
    if (!i) return 0
    t = substr(rest, 1, i - 1); rest = substr(rest, i)
    if (n == 1) m = t; else if (n == 3) uid = t; else if (n == 4) gid = t
    else if (n == 5) { sz = t; if (substr(t, length(t), 1) == ",") { sub(/^[ \t]+/, "", rest); i = match(rest, /[ \t]/); rest = substr(rest, i); sz = 0 } }
  }
  p = substr(rest, 2)
  t = substr(m, 1, 1)
  if (t == "l") { i = index(p, " -> "); if (i) p = substr(p, 1, i - 1) }
  if (substr(p, 1, 1) != "/") return 0
  p = slashes(p)
  it = NI + 1; IK[it] = kind
  put(it, "filepath", p); put(it, "path", dirpart(p)); put(it, "filename", basepart(p))
  put(it, "mode", m); put(it, "user_id", uid); put(it, "group_id", gid); put(it, "size", sz)
  put(it, "type", t == "-" ? "regular" : t == "d" ? "directory" : t == "l" ? "symbolic link" : t == "c" ? "character special" : t == "b" ? "block special" : t == "p" ? "fifo" : t == "s" ? "socket" : "unknown")
  if (t == "d" && OFILENIL) { put(it, "path", p); put(it, "filename", "") }
  return it
}
function p_file(o,   i, n, c, l, it, how, st, f, rec, maxd, base, r, b, batch) {
  OFILENIL = hasobj(o, "filename") && OEX[o, "filename"] == "nil"
  # a whole tree: let find run ls, instead of one ls per file
  if (hasobj(o, "path") && OEP[o, "path"] == "equals" && OB[o, "recurse_direction"] == "down") {
    how = (o, "recurse_file_system") in OB ? OB[o, "recurse_file_system"] : "all"
    maxd = (o, "max_depth") in OB ? OB[o, "max_depth"] + 0 : -1
    n = entn(o, "path")
    for (i = 1; i <= n; i++) {
      st = entv(o, "path", i)
      if (length(st) > 1 && substr(st, length(st), 1) == "/") st = substr(st, 1, length(st) - 1)
      if (st == "") continue
      base = depthof(st == "/" ? "" : st)
      f = cached("find " sq(st == "/" ? "/" : st "/") " " fsprune(st, how) (OFILENIL ? "-type d " : "") "-exec ls -ldn {} +")
      while ((getline l < f) > 0) {
        it = lsitem(l, "file")
        if (!it) continue
        l = IV[it, "filepath"]
        if (length(l) > 1 && substr(l, length(l), 1) == "/") { l = substr(l, 1, length(l) - 1); put(it, "filepath", l); put(it, "path", OFILENIL ? l : dirpart(l)); put(it, "filename", OFILENIL ? "" : basepart(l)) }
        if (OFILENIL) { if (maxd >= 0 && depthof(l) - base > maxd) continue }
        else {
          if (l == st) continue
          if (maxd >= 0 && depthof(l) - 1 - base > maxd) continue
          if (IV[it, "type"] == "directory" || !objmatch(o, "filename", basepart(l))) continue   # a file name never means a directory
        }
        if (addto(o, it)) NI = it
      }
      close(f)
    }
    return "ok"
  }
  if (!listpaths(o, "")) return "error"
  n = FLN; batch = ""
  for (i = 1; i <= n; i++) if (FL[i] != "") {
    batch = batch " " sq(FL[i])
    if (length(batch) > 6000) { lsbatch(o, batch); batch = "" }
  }
  if (batch != "") lsbatch(o, batch)
  return "ok"
}
function lsbatch(o, b,   c, l, it, n, i) {
  c = "ls -ldn" b " 2>/dev/null"; n = 0
  while ((c | getline l) > 0) { n++; LSL[n] = l }
  close(c)
  for (i = 1; i <= n; i++) { it = lsitem(LSL[i], "file"); if (it && (OFILENIL || IV[it, "type"] != "directory") && addto(o, it)) NI = it }
}
function p_symlink(o,   n, i, v, c, l, it) {
  n = entn(o, "filepath")
  for (i = 1; i <= n; i++) {
    v = entv(o, "filepath", i)
    if (!isthere(v, "-h")) continue
    l = ""
    if (has("readlink")) { c = "readlink -f " sq(v) " 2>/dev/null"; c | getline l; close(c) }
    if (l == "") return "error"
    it = newitem("symlink"); put(it, "filepath", v); put(it, "canonical_path", l); addto(o, it)
  }
  return "ok"
}
function p_hash(o,   n, i, m, j, t, c, l, it, cmd) {
  if (!listpaths(o, "f")) return "error"
  n = FLN
  for (i = 1; i <= n; i++) HFL[i] = FL[i]
  for (i = 1; i <= n; i++) {
    if (HFL[i] == "" || !isthere(HFL[i], "-f")) continue
    m = split("MD5 SHA-1 SHA-224 SHA-256 SHA-384 SHA-512", HTY, " ")
    for (j = 1; j <= m; j++) {
      t = HTY[j]
      if (!objmatch(o, "hash_type", t)) continue
      cmd = tolower(t); sub(/-/, "", cmd)
      if (has(cmd "sum")) c = cmd "sum " sq(HFL[i])
      else if (has("openssl")) c = "openssl dgst -" cmd " -r " sq(HFL[i])
      else return "error"
      l = ""; (c " 2>/dev/null") | getline l; close(c " 2>/dev/null")
      sub(/[ \t].*$/, "", l)
      if (l == "") { OBAD[o] = 1; continue }
      it = newitem("filehash58"); put(it, "filepath", HFL[i]); put(it, "path", dirpart(HFL[i])); put(it, "filename", basepart(HFL[i]))
      put(it, "hash_type", t); put(it, "hash", l); addto(o, it)
    }
  }
  return "ok"
}

# ---------------------------------------------------------------- packages
# a tool that fails must never look like "nothing installed": the last line proves it finished
function p_dpkg(o,   f, l, it, i, e, v, r, ok) {
  if (!has("dpkg-query")) return "na"
  f = cached("dpkg-query -W -f='${Package}\\t${Architecture}\\t${Version}\\t${Status}\\n' && echo __sx_ok__")
  ok = 0
  while ((getline l < f) > 0) {
    if (l == "__sx_ok__") { ok = 1; continue }
    if (split(l, DPK, "\t") < 4 || DPK[4] !~ / installed$/) continue
    if (!objmatch(o, "name", DPK[1])) continue
    it = newitem("dpkginfo"); v = DPK[3]
    put(it, "name", DPK[1]); put(it, "arch", DPK[2])
    i = index(v, ":"); e = 0
    if (i) { e = substr(v, 1, i - 1); v = substr(v, i + 1) }
    r = ""; i = 0
    while (match(substr(v, i + 1), /-/)) i += RSTART
    if (i) { r = substr(v, i + 1); v = substr(v, 1, i - 1) }
    put(it, "epoch", e); put(it, "version", v); put(it, "release", r)
    put(it, "evr", e ":" v "-" r)
    addto(o, it)
  }
  close(f)
  if (!ok) note("dpkg-query failed: the package database can not be read")
  return ok ? "ok" : "error"
}
function p_rpm(o,   f, l, it, n, e, k, ok) {
  if (!has("rpm")) return has("dpkg-query") ? "ok" : "na"
  f = cached("rpm -qa --qf '%{NAME}\\t%{ARCH}\\t%{EPOCH}\\t%{VERSION}\\t%{RELEASE}\\t%{SIGPGP:pgpsig} %{RSAHEADER:pgpsig}\\n' && echo __sx_ok__")
  ok = 0
  while ((getline l < f) > 0) {
    if (l == "__sx_ok__") { ok = 1; continue }
    n = split(l, RPK, "\t")
    if (n < 5 || !objmatch(o, "name", RPK[1])) continue
    it = newitem("rpminfo")
    put(it, "name", RPK[1]); put(it, "arch", RPK[2]); put(it, "epoch", RPK[3]); put(it, "version", RPK[4]); put(it, "release", RPK[5])
    e = RPK[3] == "(none)" ? "0" : RPK[3]
    put(it, "evr", e ":" RPK[4] "-" RPK[5])
    k = "0"
    if (match(RPK[6], /Key ID [0-9a-fA-F]+/)) { k = tolower(substr(RPK[6], RSTART + 7, RLENGTH - 7)); k = substr(k, length(k) - 15) }
    put(it, "signature_keyid", k)
    put(it, "extended_name", RPK[1] "-" e ":" RPK[4] "-" RPK[5] "." RPK[2])
    addto(o, it)
  }
  close(f)
  if (!ok) note("rpm failed: the package database can not be read")
  return ok ? "ok" : "error"
}

# ---------------------------------------------------------------- system
function p_family(o,   it) { it = newitem("family"); put(it, "family", "unix"); addto(o, it); return "ok" }
function cmd1(c,   l) { l = ""; (c " 2>/dev/null") | getline l; close(c " 2>/dev/null"); return l }
function p_uname(o,   it) {
  it = newitem("uname")
  put(it, "machine_class", cmd1("uname -m")); put(it, "node_name", cmd1("uname -n")); put(it, "os_name", cmd1("uname -s"))
  put(it, "os_release", cmd1("uname -r")); put(it, "os_version", cmd1("uname -v"))
  put(it, "processor_type", cmd1("uname -p"))
  if (IV[it, "processor_type"] == "unknown" || IV[it, "processor_type"] == "") put(it, "processor_type", cmd1("uname -m"))
  addto(o, it)
  return "ok"
}
function unoct(s,   o, i) {   # \040 in /proc/mounts
  o = ""
  while ((i = index(s, "\\")) > 0 && substr(s, i + 1, 3) ~ /^[0-7][0-7][0-7]$/) {
    o = o substr(s, 1, i - 1) CHR[substr(s, i + 1, 1) * 64 + substr(s, i + 2, 1) * 8 + substr(s, i + 3, 1)]
    s = substr(s, i + 4)
  }
  return o s
}
function p_partition(o,   f, l, n, it, mp, r) {
  if (SYS == "Linux") f = "/proc/mounts"
  else if (SYS == "AIX") f = cached("mount | awk 'NR > 2 { if (substr($0, 1, 1) == \" \") print $1, $2, $3, $NF; else print $1 \":\" $2, $3, $4, $NF }'")
  else return "error"
  r = 0
  while ((getline l < f) > 0) {
    r = 1
    n = split(l, MNT, " "); mp = unoct(MNT[2])
    if (n < 3 || MNT[1] == "rootfs" || MNT[3] == "autofs" || !objmatch(o, "mount_point", mp)) continue
    it = newitem("partition")
    put(it, "mount_point", mp); put(it, "device", unoct(MNT[1])); put(it, "fs_type", MNT[3])
    l = MNT[4]; gsub(/,/, SEP, l); put(it, "mount_options", l)
    addto(o, it)
  }
  close(f)
  return r ? "ok" : "error"
}
function p_sysctl(o,   f, l, i, n, it, nm, v, c) {
  if (!has("sysctl")) return "na"
  if (OEP[o, "name"] == "equals") {
    n = entn(o, "name")
    for (i = 1; i <= n; i++) {
      nm = entv(o, "name", i); v = ""; c = 0
      f = cached("sysctl -n " sq(nm) " && echo __sx_ok__")
      while ((getline l < f) > 0) { if (l == "__sx_ok__") { c = 1; break } v = v (v == "" ? "" : "\n") l }
      close(f)
      if (!c) continue
      gsub(/[ \t]+/, "\t", v)
      it = newitem("sysctl"); put(it, "name", nm); put(it, "value", v); addto(o, it)
    }
    return "ok"
  }
  f = cached("sysctl -a")
  while ((getline l < f) > 0) {
    i = index(l, "=")
    if (!i) continue
    nm = substr(l, 1, i - 1); v = substr(l, i + 1)
    gsub(/[ \t]/, "", nm); sub(/^[ \t]+/, "", v); gsub(/[ \t]+/, "\t", v)
    if (!objmatch(o, "name", nm)) continue
    it = newitem("sysctl"); put(it, "name", nm); put(it, "value", v); addto(o, it)
  }
  close(f)
  return "ok"
}
function units(   f, l) {
  if (UNITSOK) return
  UNITSOK = 1; UN = 0
  f = cached("{ systemctl list-unit-files --no-legend --no-pager; systemctl list-units --all --no-legend --no-pager --plain || echo SX-NO-SYSTEMD; } | awk '{ u = $1; if (u !~ /[A-Za-z0-9]/) u = $2; if (!(u in s)) { s[u] = 1; print u } }'")
  while ((getline l < f) > 0) { if (l == "SX-NO-SYSTEMD") UNBAD = 1; else { UN++; UNIT[UN] = l } }
  close(f)
}
function p_unitprop(o,   i, f, l, it, nm, v, k, m, j) {
  if (!has("systemctl")) return "na"
  units()
  if (UNBAD) { note("systemd is not running, or cannot be asked"); return "error" }
  if (UN == 0) { note("systemctl gave no units"); return "error" }
  for (i = 1; i <= UN; i++) {
    if (!objmatch(o, "unit", UNIT[i])) continue
    f = cached("systemctl show --no-pager " sq(UNIT[i])); m = 0
    while ((getline l < f) > 0) {
      m++; k = index(l, "="); nm = substr(l, 1, k - 1)
      if (!k || !objmatch(o, "property", nm)) continue
      v = substr(l, k + 1)
      if (v == "yes") v = "true"; else if (v == "no") v = "false"
      if (nm ~ /^(Names|Wants|Requires|Requisite|RequiredBy|WantedBy|Before|After|Conflicts|BindsTo|PartOf|ConsistsOf|TriggeredBy|Triggers|Documentation|DropInPaths)$/) gsub(/ /, SEP, v)
      it = newitem("systemdunitproperty")
      put(it, "unit", UNIT[i]); put(it, "property", nm); put(it, "value", v)
      addto(o, it)
    }
    close(f)
    if (!m) { note("systemctl show failed"); return "error" }
  }
  return "ok"
}
function p_unitdep(o,   i, f, l, it, d) {
  if (!has("systemctl")) return "na"
  units()
  if (UNBAD) { note("systemd is not running, or cannot be asked"); return "error" }
  if (UN == 0) { note("systemctl gave no units"); return "error" }
  for (i = 1; i <= UN; i++) {
    if (!objmatch(o, "unit", UNIT[i])) continue
    f = cached("systemctl list-dependencies --plain --no-pager " sq(UNIT[i]))
    d = ""
    while ((getline l < f) > 0) {
      gsub(/[^A-Za-z0-9_.@:\\-]/, "", l)
      if (l == "" || l == UNIT[i]) continue
      d = d (d == "" ? "" : SEP) l
    }
    close(f)
    it = newitem("systemdunitdependency"); put(it, "unit", UNIT[i]); put(it, "dependency", d); addto(o, it)
  }
  return "ok"
}
function p_password(o,   f, l, n, it) {
  f = has("getent") ? cached("getent passwd") : "/etc/passwd"
  while ((getline l < f) > 0) {
    n = split(l, PWD, ":")
    if (n < 7 || !objmatch(o, "username", PWD[1])) continue
    it = newitem("password")
    put(it, "username", PWD[1]); put(it, "password", PWD[2]); put(it, "user_id", PWD[3]); put(it, "group_id", PWD[4])
    put(it, "gcos", PWD[5]); put(it, "home_dir", PWD[6]); put(it, "login_shell", PWD[7])
    addto(o, it)
  }
  close(f)
  return "ok"
}
function p_shadow(o,   l, n, it, r, i, e) {
  if (!isthere("/etc/shadow", "-f")) return "na"
  if (!isthere("/etc/shadow", "-r")) { note("cannot read /etc/shadow (run as root)"); return "error" }
  while ((getline l < "/etc/shadow") > 0) {
    n = split(l, SHD, ":")
    if (n < 8 || !objmatch(o, "username", SHD[1])) continue
    it = newitem("shadow")
    put(it, "username", SHD[1]); put(it, "password", SHD[2]); put(it, "chg_lst", SHD[3]); put(it, "chg_allow", SHD[4]); put(it, "chg_req", SHD[5])
    put(it, "exp_warn", SHD[6]); put(it, "exp_inact", SHD[7]); put(it, "exp_date", SHD[8]); put(it, "flag", SHD[9])
    e = substr(SHD[2], 1, 3)
    put(it, "encrypt_method", e == "$1$" ? "MD5" : substr(e, 1, 2) == "$2" ? "Blowfish" : e == "$5$" ? "SHA-256" : e == "$6$" ? "SHA-512" : e == "$y$" ? "Yescrypt" : "DES")
    addto(o, it)
  }
  close("/etc/shadow")
  return "ok"
}
function p_env(o,   c, l, pid, i, it, any) {
  if (hasobj(o, "pid") && OEX[o, "pid"] != "nil") {
    if (!isthere("/proc/1", "-d") || SYS != "Linux") return "na"
    c = "for p in /proc/[0-9]*; do i=${p#/proc/}; if [ -r $p/environ ]; then tr '\\000\\012' '\\012 ' < $p/environ | sed \"s/^/$i /\"; else echo \"$i\"; fi; done 2>/dev/null"
    while ((c | getline l) > 0) {
      i = index(l, " "); pid = i ? substr(l, 1, i - 1) : l
      if (!i) { if (objmatch(o, "pid", pid)) OBAD[o] = 1; continue }
      if (!objmatch(o, "pid", pid)) continue
      l = substr(l, i + 1); i = index(l, "=")
      if (!i || !objmatch(o, "name", substr(l, 1, i - 1))) continue
      it = newitem("environmentvariable58"); put(it, "pid", pid); put(it, "name", substr(l, 1, i - 1)); put(it, "value", substr(l, i + 1)); addto(o, it)
    }
    close(c)
    return "ok"
  }
  for (l in ENVIRON) if (objmatch(o, "name", l)) { it = newitem("environmentvariable58"); put(it, "name", l); put(it, "value", ENVIRON[l]); addto(o, it) }
  return "ok"
}
function p_variable(o,   v, i, r, it, n) {
  v = OEA[o, "var_ref"]; r = val(v)
  if (r == "error") return "error"
  n = VN[v]
  for (i = 1; i <= n; i++) { it = newitem("variable"); put(it, "var_ref", v); put(it, "value", VV[v, i]); addto(o, it) }
  return "ok"
}
function p_interface(o,   c, l, n, it, i, fl, nm, a) {
  if (!has("ip")) return "na"
  if (cmd1("ip -o addr show >/dev/null && echo y") != "y") return "error"
  c = "ip -o addr show 2>/dev/null"
  while ((c | getline l) > 0) {
    n = split(l, IFX, " "); nm = IFX[2]; sub(/@.*$/, "", nm); sub(/:$/, "", nm)
    if (!objmatch(o, "name", nm)) continue
    it = newitem("interface"); put(it, "name", nm); a = IFX[4]; sub(/\/.*$/, "", a); put(it, "inet_addr", a)
    fl = cmd1("ip -o link show dev " sq(nm))
    put(it, "type", index(fl, "link/ether") ? "ARPHRD_ETHER" : index(fl, "link/loopback") ? "ARPHRD_LOOPBACK" : "")
    if (match(fl, /<[^>]*>/)) { fl = substr(fl, RSTART + 1, RLENGTH - 2); gsub(/,/, SEP, fl) } else fl = ""
    put(it, "flag", fl)
    addto(o, it)
  }
  close(c)
  return "ok"
}
function p_listen(o,   c, l, n, it, a, pr, ad, po, i) {
  if (!has("ss")) return "error"
  if (cmd1("ss -lnt >/dev/null && ss -lnu >/dev/null && echo y") != "y") return "error"
  c = "{ ss -lnt | sed -e 1d -e 's/^/tcp /'; ss -lnu | sed -e 1d -e 's/^/udp /'; } 2>/dev/null"
  while ((c | getline l) > 0) {
    n = split(l, SSX, " "); pr = SSX[1]; a = SSX[5]
    i = 0
    while (match(substr(a, i + 1), /:/)) i += RSTART
    ad = substr(a, 1, i - 1); po = substr(a, i + 1)
    sub(/%.*$/, "", ad); gsub(/[][]/, "", ad)
    if (ad == "*") ad = "::"
    if (!objmatch(o, "protocol", pr) || !objmatch(o, "local_address", ad) || !objmatch(o, "local_port", po)) continue
    it = newitem("inetlisteningservers"); put(it, "protocol", pr); put(it, "local_address", ad); put(it, "local_port", po); put(it, "local_full_address", ad ":" po)
    addto(o, it)
  }
  close(c)
  return "ok"
}
function p_process(o,   c, l, n, it, i, cl) {
  c = "ps -e -o pid= -o ppid= -o ruid= -o uid= -o args= 2>/dev/null"
  if (SYS != "Linux") return "error"
  while ((c | getline l) > 0) {
    n = split(l, PSX, " ")
    cl = l; for (i = 1; i <= 4; i++) sub(/^[ \t]*[^ \t]+[ \t]/, "", cl)
    if (hasobj(o, "command_line") && OEX[o, "command_line"] != "nil" && !objmatch(o, "command_line", cl)) continue
    if (hasobj(o, "pid") && OEX[o, "pid"] != "nil" && !objmatch(o, "pid", PSX[1])) continue
    it = newitem("process58"); put(it, "pid", PSX[1]); put(it, "ppid", PSX[2]); put(it, "ruid", PSX[3]); put(it, "user_id", PSX[4]); put(it, "command_line", cl)
    addto(o, it)
  }
  close(c)
  return "ok"
}
function p_runlevel(o,   c, l, n, it, s, rl, k) {
  c = "for d in /etc/rc[0-6].d /etc/rc.d/rc[0-6].d; do [ -d $d ] && ls $d | sed \"s|^|$d |\"; done 2>/dev/null"
  while ((c | getline l) > 0) {
    n = split(l, RLX, " ")
    if (RLX[2] !~ /^[SK][0-9][0-9]/) continue
    rl = RLX[1]; sub(/\.d$/, "", rl); rl = substr(rl, length(rl)); s = substr(RLX[2], 4); k = substr(RLX[2], 1, 1)
    if ((o, s, rl) in RLSEEN || !objmatch(o, "service_name", s) || !objmatch(o, "runlevel", rl)) continue
    RLSEEN[o, s, rl] = 1
    it = newitem("runlevel"); put(it, "service_name", s); put(it, "runlevel", rl); put(it, "start", k == "S" ? "true" : "false"); put(it, "kill", k == "K" ? "true" : "false")
    addto(o, it)
  }
  close(c)
  return "ok"
}
function p_sebool(o,   c, l, n, it) {
  if (!has("sestatus")) return "na"
  c = "sestatus -b 2>/dev/null | awk 'b { print $1, $2 } /booleans:/ { b = 1 }'"
  while ((c | getline l) > 0) {
    n = split(l, SEB, " ")
    if (n < 2 || !objmatch(o, "name", SEB[1])) continue
    it = newitem("selinuxboolean"); put(it, "name", SEB[1]); put(it, "current_status", SEB[2] == "on" ? "true" : "false")
    put(it, "pending_status", SEB[2] == "on" ? "true" : "false"); addto(o, it)
  }
  close(c)
  return "ok"
}
function p_secontext(o,   i, n, l, it, c) {
  if (!listpaths(o, "")) return "error"
  n = FLN
  for (i = 1; i <= n; i++) SCF[i] = FL[i]
  for (i = 1; i <= n; i++) {
    if (SCF[i] == "") continue
    l = cmd1("ls -dZ " sq(SCF[i]))
    if (l == "") continue
    if (!match(l, /[^ \t:]+:[^ \t:]+:[^ \t:]+(:[^ \t]+)?/)) return "na"
    split(substr(l, RSTART, RLENGTH), SCX, ":")
    it = newitem("selinuxsecuritycontext"); put(it, "filepath", SCF[i]); put(it, "path", dirpart(SCF[i])); put(it, "filename", basepart(SCF[i]))
    put(it, "user", SCX[1]); put(it, "role", SCX[2]); put(it, "type", SCX[3]); addto(o, it)
  }
  return "ok"
}

# ---------------------------------------------------------------- AIX
function p_fileset(o,   f, l, n, it, s, ok) {
  if (!has("lslpp")) return "na"
  f = cached("lslpp -Lcq all")
  ok = 0
  while ((getline l < f) > 0) {
    n = split(l, LPP, ":")
    if (n >= 6) ok = 1
    if (n < 6 || !objmatch(o, "flstinst", LPP[2])) continue
    it = newitem("fileset"); put(it, "flstinst", LPP[2]); put(it, "level", LPP[3]); put(it, "description", LPP[8])
    s = LPP[6]
    put(it, "state", s ~ /^A/ ? "APPLIED" : s ~ /^C/ ? "COMMITTED" : s ~ /^B/ ? "BROKEN" : s ~ /^E/ ? "LOCKED" : s ~ /^O/ ? "OBSOLETE" : s)
    addto(o, it)
  }
  close(f)
  return ok ? "ok" : "error"
}
function p_oslevel(o,   l, it) {
  if (!has("oslevel")) return "na"
  l = cmd1("oslevel"); if (l == "") return "error"
  it = newitem("oslevel"); put(it, "maintenance_level", l); addto(o, it)
  return "ok"
}
function p_no(o,   f, l, i, nm, v, it, ok) {
  if (SYS != "AIX") return "na"
  f = cached("no -a")
  while ((getline l < f) > 0) {
    i = index(l, "="); if (!i) continue
    ok = 1
    nm = substr(l, 1, i - 1); v = substr(l, i + 1); gsub(/[ \t]/, "", nm); sub(/^[ \t]+/, "", v)
    if (!objmatch(o, "tunable", nm)) continue
    it = newitem("no"); put(it, "tunable", nm); put(it, "value", v); addto(o, it)
  }
  close(f)
  return ok ? "ok" : "error"
}
function p_ifix(o,   f, l, n, it) {
  if (!has("emgr")) return "na"
  f = cached("emgr -l; echo __sx_rc__ $?")   # "no efix data" may come with any exit code, but says so
  while ((getline l < f) > 0) {
    n = split(l, EMG, " ")
    if (EMG[1] !~ /^[0-9]+$/ || n < 3 || !objmatch(o, "vuid", EMG[3])) continue
    it = newitem("interim_fix"); put(it, "state", EMG[2]); put(it, "label", EMG[3]); put(it, "vuid", EMG[3]); addto(o, it)
  }
  close(f)
  return "ok"
}

# ---------------------------------------------------------------- states, tests, definitions
function statent(s, i, v,   e, n, j, r, w, t) {   # one item value against one state entity
  if (SEX[s, i] != "var") return cmpval(SEP_[s, i], SED[s, i], v, SEA[s, i])
  w = SEA[s, i]; r = val(w)
  if (r != "ok") return r == "none" ? "unknown" : "error"
  # every variable value counts, joined by var_check
  n = VN[w]
  CT = CF = CE = CU = CV = CA = 0
  for (j = 1; j <= n; j++) tally(cmpval(SEP_[s, i], SED[s, i], v, VV[w, j]))
  return bycheck(SEV[s, i], CT, CF, CE, CU, CV, CA)
}
function evalstate(s, it,   i, j, n, e, r, t, f, er, u, v, a, t2, f2, e2, u2, v2, a2, vals) {
  t = f = er = u = v = a = 0
  if (!(s in SOPR)) return "error"
  for (i = 1; i <= SEN[s]; i++) {
    e = SEL[s, i]
    if (SEX[s, i] == "var") val(SEA[s, i])   # may run probes: do it before the loops below
    if (!hasent(it, e)) r = "false"
    else {
      vals = getent(it, e)
      n = 0
      if (index(vals, SEP)) {
        t2 = f2 = e2 = u2 = v2 = a2 = 0
        while (1) {
          j = index(vals, SEP)
          r = statent(s, i, j ? substr(vals, 1, j - 1) : vals)
          if (r == "true") t2++; else if (r == "false") f2++; else if (r == "error") e2++; else if (r == "unknown") u2++; else v2++
          if (!j) break
          vals = substr(vals, j + 1)
        }
        r = bycheck(SEC[s, i], t2, f2, e2, u2, v2, a2)
      } else {
        r = statent(s, i, vals)
        if (SEC[s, i] ~ /^none/) r = flip(r)
      }
    }
    if (r == "true") t++; else if (r == "false") f++; else if (r == "error") er++; else if (r == "unknown") u++; else if (r == "not evaluated") v++; else a++
  }
  if (SEN[s] == 0) return "true"
  return byop(SOPR[s], t, f, er, u, v, a)
}
function existence(ce, n) {
  if (ce == "none_exist") return n == 0
  if (ce == "only_one_exists") return n == 1
  if (ce == "any_exist") return 1
  return n > 0   # at_least_one_exists, all_exist
}
function evaltest(t,   o, f, r, i, j, n, st, sf, se, su, sv, sa, t1, f1, e1, u1, v1, a1) {
  if (t in TR) return TR[t]
  TR[t] = "error"
  if (TK[t] == "?") { TR[t] = "not evaluated"; trace(t, 0); return TR[t] }
  if (TK[t] == "unknown") { TR[t] = "unknown"; return TR[t] }
  o = TO[t]; collect(o); f = OF_[o]
  if (f == "error") r = "error"
  else if (f == "na") r = "not applicable"
  else if (f == "nc") r = "not evaluated"
  else if (f == "none") r = existence(TE[t], 0) ? "true" : "false"
  else {
    n = OIN[o]
    r = existence(TE[t], n) ? "true" : "false"
    if (r == "true" && TN[t] > 0 && n > 0) {
      t1 = f1 = e1 = u1 = v1 = a1 = 0
      for (i = 1; i <= n; i++) {
        st = sf = se = su = sv = sa = 0
        for (j = 1; j <= TN[t]; j++) {
          r = evalstate(TST[t, j], OI[o, i])
          if (r == "true") st++; else if (r == "false") sf++; else if (r == "error") se++; else if (r == "unknown") su++; else if (r == "not evaluated") sv++; else sa++
        }
        r = TN[t] == 1 ? r : byop(TSO[t], st, sf, se, su, sv, sa)
        if (r == "true") t1++; else if (r == "false") f1++; else if (r == "error") e1++; else if (r == "unknown") u1++; else if (r == "not evaluated") v1++; else a1++
      }
      r = bycheck(TC[t], t1, f1, e1, u1, v1, a1)
    }
  }
  TR[t] = r
  trace(t, f == "complete" ? OIN[o] : 0)
  return r
}
function trace(t, n,   i, o) {
  if (QUIET || NTR >= 14) return
  NTR++
  if (TK[t] == "?") { print "not evaluated: " TCM[t] " (" TO[t] ")"; return }
  print TR[t] ": " oneline(TCM[t]) " [" TK[t] ", " n " found]"
  o = TO[t]
  for (i = 1; i <= n && i <= 3; i++) print "   " show(OI[o, i])
}
function note(s) { if (!QUIET && NNOTE < 5) { NNOTE++; print "note: " s } }
function evaldef(d) {
  if (d in DRES) return DRES[d]
  DRES[d] = "error"
  if (!(d in DROOT)) return "error"
  if (DROOT[d] == "") { DRES[d] = "not evaluated"; return DRES[d] }
  DRES[d] = evalref(DROOT[d])
  return DRES[d]
}
function evalref(ref,   neg, k, id, r) {
  neg = 0
  if (substr(ref, 1, 1) == "!") { neg = 1; ref = substr(ref, 2) }
  k = substr(ref, 1, 1); id = substr(ref, 2)
  if (k == "T") r = evaltest(id)
  else if (k == "D") r = evaldef(id)
  else r = evalcrit(id)
  return neg ? flip(r) : r
}
function evalcrit(c,   i, r, t, f, e, u, v, a) {
  t = f = e = u = v = a = 0
  for (i = 1; i <= CN[c]; i++) {
    r = evalref(CC[c, i])
    if (r == "true") t++; else if (r == "false") f++; else if (r == "error") e++; else if (r == "unknown") u++; else if (r == "not evaluated") v++; else a++
  }
  r = byop(CO[c], t, f, e, u, v, a)
  return CG[c] == "1" ? flip(r) : r
}
# XCCDF result of a check reference: E<definition> or K<complex check>
function evalx(ref,   k, id, r, i, n, p) {
  k = substr(ref, 1, 1); id = substr(ref, 2)
  if (k == "E") {
    r = evaldef(id)
    if (DCL[id] == "vulnerability" || DCL[id] == "patch") r = flip(r)
    if (r == "true") return "pass"
    if (r == "false") return "fail"
    if (r == "not evaluated") return "notchecked"
    if (r == "not applicable") return "notapplicable"
    return r
  }
  if (k != "K") return "notchecked"
  for (i = 1; i <= CN[id]; i++) { r = evalx(CC[id, i]); XCNT[id, r]++ }
  if (CO[id] == "OR") p = "pass unknown error fail notchecked notapplicable"
  else p = "fail unknown error notchecked pass notapplicable"   # a part nobody checked is never a pass
  n = split(p, XPR, " "); r = "notchecked"
  for (i = 1; i <= n; i++) if (XCNT[id, XPR[i]] > 0) { r = XPR[i]; break }
  if (CG[id] == "1") { if (r == "pass") r = "fail"; else if (r == "fail") r = "pass" }
  return r
}

# ---------------------------------------------------------------- main
BEGIN {
  FS = "\t"
  srand(); NOW = srand()
  SEP = "\035"; PFALL = "\003"; MAXSTEPS = 3000000
  for (i = 1; i < 256; i++) { c = sprintf("%c", i); CHR[i] = c; ORD[c] = i }
  DIG = "0123456789"; LOW = "abcdefghijklmnopqrstuvwxyz"; UPP = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  WRD = LOW UPP DIG "_"; SPC = " \t\n\013\f\r"; PUN = "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"
  FPERM["uread"] = 2; FPERM["uwrite"] = 3; FPERM["uexec"] = 4; FPERM["suid"] = 4
  FPERM["gread"] = 5; FPERM["gwrite"] = 6; FPERM["gexec"] = 7; FPERM["sgid"] = 7
  FPERM["oread"] = 8; FPERM["owrite"] = 9; FPERM["oexec"] = 10; FPERM["sticky"] = 10; FPERM["has_extended_acl"] = 11
  NI = NN = NRE = NTR = NNOTE = NTMP = SP = 0; FGEN = 0; LASTF = ""
}
$1 == "R" { ROOT = $2; next }
$1 == "P" { PLAT = $2; next }
$1 == "C" || $1 == "K" { CO[$2] = $3; CG[$2] = $4; for (i = 5; i <= NF; i++) { CN[$2]++; CC[$2, CN[$2]] = $i } next }
$1 == "D" { DCL[$2] = $3; DROOT[$2] = $4; next }
$1 == "T" { TK[$2] = $3; TE[$2] = $4; TC[$2] = $5; TSO[$2] = $6; TO[$2] = $7; TCM[$2] = unesc($8); TN[$2] = 0; for (i = 9; i <= NF; i++) { TN[$2]++; TST[$2, TN[$2]] = $i } next }
$1 == "O" { OKIND[$2] = $3; OEN[$2] = 0; OFN[$2] = 0; OBAD[$2] = 0; next }
$1 == "OE" { OEN[$2]++; OEL[$2, OEN[$2]] = $3; OEP[$2, $3] = $4; OED[$2, $3] = $5; OEV[$2, $3] = $6; OEX[$2, $3] = $7; OEA[$2, $3] = unesc($8); next }
$1 == "OB" { OB[$2, $3] = $4; next }
$1 == "OS" { SOP[$2] = $3; SNUM[$2] = 0; for (i = 4; i <= NF; i++) { SNUM[$2]++; SOB[$2, SNUM[$2]] = $i } next }
$1 == "OF" { OFN[$2]++; OFA[$2, OFN[$2]] = $3; OFL[$2, OFN[$2]] = $4; next }
$1 == "S" { SOPR[$2] = $3; SEN[$2] = 0; next }
$1 == "SE" { SEN[$2]++; i = SEN[$2]; SEL[$2, i] = $3; SEP_[$2, i] = $4; SED[$2, i] = $5; SEC[$2, i] = $6; SEV[$2, i] = $7; SEX[$2, i] = $8; SEA[$2, i] = unesc($9); next }
$1 == "V" { VK[$2] = $3; VX[$2] = $4; VN[$2] = 0; next }
$1 == "VV" { VN[$2]++; VV[$2, VN[$2]] = unesc($3); next }
$1 == "X" { XK[$2] = $3; XC[$2] = NF - 3; for (i = 4; i <= NF; i++) XA[$2, i - 3] = unesc($i); next }
END {
  if (ROOT == "") exit 252
  if (PLAT != "") {
    QUIET = 1
    if (evalref(PLAT) != "true") { print "Not applicable on this server."; exit 250 }
    QUIET = 0
    for (t in TR) if (TR[t] == "error") delete TR[t]
  }
  r = evalx(ROOT)
  print "result: " r
  if (r == "pass") exit 0
  if (r == "fail") exit 1
  if (r == "notapplicable") exit 250
  if (r == "notchecked") exit 251
  if (r == "unknown") exit 253
  exit 252
}

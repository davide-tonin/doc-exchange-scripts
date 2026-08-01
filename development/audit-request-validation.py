#!/usr/bin/env python3
"""State-of-the-union validation audit for every request-side DTO.

Scans request records (including sealed-interface impls and PARTY member payloads),
extracts each component's bean-validation annotations WITH their arguments plus the
@Schema requiredMode / maxLength hints, and emits:

  1. A per-DTO table: field, type, nullability, size/len, numeric, pattern, temporal,
     element constraints, and heuristic hygiene gaps.
  2. Aggregated hygiene findings grouped by category (the fail-hard gaps).
  3. The @Size(max) literal spread, to guide unifying magic numbers into constants.
  4. Every temporal field and whether it carries a @Future check.

Heuristics are clearly tagged; the human decides. Run:  python3 scripts/audit_request_validation.py
"""
import re
import sys
from pathlib import Path

ROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(r"C:\Users\DavideTonin\IdeaProjects\doc-exchange-service")
SRC = ROOT / "src" / "main"
OUT = ROOT / "docs" / "checklists" / "request_validation_audit.md"

RECORD_RE = re.compile(r"public\s+record\s+(\w+)\s*\((.*?)\)\s*(?:implements[^{]+)?\{", re.S)

# Request-side payload records live in *Request*.java plus a few named payload types.
EXTRA_PAYLOADS = ["group/web/dto/PartyMember.java",
                  "group/web/dto/TenantPartyMember.java",
                  "group/web/dto/AliasPartyMember.java"]

NOT_NULLISH = {"NotNull", "NotBlank", "NotEmpty"}
TEMPORAL_CHECKS = {"Future", "FutureOrPresent", "Past", "PastOrPresent"}
PRIMITIVES = {"int", "long", "boolean", "double", "float", "short", "byte", "char"}
BOXED = {"Integer", "Long", "Boolean", "Double", "Float", "Short", "Byte", "Character"}
# json keys that denote an upper time bound / expiry -> candidates for @Future.
EXPIRY_RE = re.compile(r"(expires|expiry|_to$|to_datetime|valid_to|end_at)", re.I)


def find_matching(s, open_idx, opench, closech):
    depth, i = 0, open_idx
    while i < len(s):
        if s[i] == opench:
            depth += 1
        elif s[i] == closech:
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def extract_annotations(region):
    """Return [(name, args_or_None), ...] for @Anno or @Anno(...) in region."""
    out, i, n = [], 0, len(region)
    while i < n:
        if region[i] == "@":
            j = i + 1
            while j < n and (region[j].isalnum() or region[j] in "_."):
                j += 1
            name = region[i + 1:j].split(".")[-1]
            args = None
            if j < n and region[j] == "(":
                close = find_matching(region, j, "(", ")")
                args = region[j + 1:close]
                j = close + 1
            out.append((name, args))
            i = j
        else:
            i += 1
    return out


def split_components(body):
    parts, depth, cur = [], 0, ""
    for ch in body:
        if ch in "(<{":
            depth += 1
        elif ch in ")>}":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append(cur); cur = ""
        else:
            cur += ch
    if cur.strip():
        parts.append(cur)
    return parts


def strip_all_annotations(s):
    out, i, n = [], 0, len(s)
    while i < n:
        if s[i] == "@":
            j = i + 1
            while j < n and (s[j].isalnum() or s[j] in "_."):
                j += 1
            if j < n and s[j] == "(":
                j = find_matching(s, j, "(", ")") + 1
            i = j
        else:
            out.append(s[i]); i += 1
    return "".join(out)


def num_arg(args, *keys, positional=False):
    """Numeric value for @Min/@Max/@Size. positional=True allows @Min(1)."""
    if args is None:
        return None
    for k in keys:
        m = re.search(rf"\b{k}\s*=\s*(\d+)", args)
        if m:
            return int(m.group(1))
    if positional:
        m = re.search(r"(\d+)", args)  # positional value, e.g. @Min(1)
        return int(m.group(1)) if m else None
    return None


def size_bound(args, key):
    """Raw token (digit or constant like PasswordPolicy.MAX_LENGTH) for min=/max=, or None."""
    if args is None:
        return None
    m = re.search(rf"\b{key}\s*=\s*([A-Za-z0-9_.]+)", args)
    return m.group(1) if m else None


def pattern_arg(args):
    if args is None:
        return None
    m = re.search(r'regexp\s*=\s*"((?:[^"\\]|\\.)*)"', args)
    return m.group(1) if m else "?"


def parse_component(part):
    raw = part.strip()
    if not raw:
        return None
    # region split: element annotations live inside the outermost <...>.
    lt = raw.find("<")
    if lt != -1:
        gt = find_matching(raw, lt, "<", ">")
        element_region = raw[lt + 1:gt] if gt != -1 else ""
        field_region = raw[:lt] + (raw[gt + 1:] if gt != -1 else "")
    else:
        element_region, field_region = "", raw

    field_annos = extract_annotations(field_region)
    element_annos = extract_annotations(element_region)

    json_key = None
    schema_required = False
    schema_maxlen = None
    for name, args in field_annos:
        if name == "JsonProperty" and args:
            m = re.search(r'"([^"]+)"', args)
            if m:
                json_key = m.group(1)
        if name == "Schema" and args:
            if "RequiredMode.REQUIRED" in args:
                schema_required = True
            ml = re.search(r"maxLength\s*=\s*(\d+)", args)
            if ml:
                schema_maxlen = int(ml.group(1))

    tokens = strip_all_annotations(raw).split()
    if len(tokens) < 2:
        return None
    field_name = tokens[-1]
    field_type = " ".join(tokens[:-1]).replace("< ", "<").replace(" >", ">")
    if json_key is None:
        json_key = field_name

    constraints = [n for n, _ in field_annos if n not in ("JsonProperty", "Schema")]
    return {
        "json_key": json_key, "field": field_name, "type": field_type,
        "field_annos": field_annos, "element_annos": element_annos,
        "constraints": constraints, "schema_required": schema_required,
        "schema_maxlen": schema_maxlen,
    }


def base_kind(t):
    t = t.strip()
    if t in PRIMITIVES:
        return "primitive"
    if t in BOXED:
        return "boxed-num"
    if t == "String":
        return "string"
    if t == "UUID":
        return "uuid"
    if t in ("OffsetDateTime", "Instant", "LocalDate", "LocalDateTime", "ZonedDateTime"):
        return "temporal"
    if t in ("JsonNode", "ObjectNode", "ArrayNode"):
        return "json"
    if t == "byte[]":
        return "bytes"
    if re.match(r"(List|Set|Collection)<", t):
        return "collection"
    return "enum/complex"


def facet_summary(c):
    """Human-readable per-facet cells + list of gap tags."""
    annos = {n: a for n, a in c["field_annos"] if n not in ("JsonProperty", "Schema")}
    names = set(annos)
    kind = base_kind(c["type"])
    gaps = []

    required = bool(names & NOT_NULLISH)
    req_cell = "+".join(n for n in ("NotNull", "NotBlank", "NotEmpty") if n in names) or "—"
    if kind == "primitive":
        req_cell = (req_cell + " (primitive)").strip()

    # size / length (captures both digit literals and named constants)
    size_cell = "—"
    size_min = size_max = None
    if "Size" in annos:
        size_min = size_bound(annos["Size"], "min")
        size_max = size_bound(annos["Size"], "max")
        size_cell = f"min={size_min if size_min is not None else 0} max={size_max if size_max is not None else '∞'}"
    numeric = [f"@{n}({num_arg(a, positional=True) if a else ''})" for n, a in c["field_annos"]
               if n in ("Min", "Max", "Positive", "PositiveOrZero", "Negative", "DecimalMin", "DecimalMax")]
    num_cell = ", ".join(numeric) if numeric else "—"

    pat = []
    if "Pattern" in annos:
        pat.append(f"@Pattern(/{pattern_arg(annos['Pattern'])}/)")
    if "Email" in names:
        pat.append("@Email")
    if "ValidEmail" in names:
        pat.append("@ValidEmail")
    if "ValidVatId" in names:
        pat.append("@ValidVatId")
    if "ValidObfuscatedId" in names:
        pat.append("@ValidObfuscatedId")
    pat_cell = ", ".join(pat) if pat else "—"

    temporal = [f"@{n}" for n in names if n in TEMPORAL_CHECKS]
    temp_cell = ", ".join(temporal) if temporal else "—"

    elem = []
    for n, a in c["element_annos"]:
        if n == "Size" and a:
            mx = size_bound(a, "max")
            elem.append(f"@Size(max={mx})" if mx else "@Size")
        else:
            elem.append(f"@{n}")
    elem_cell = ", ".join(elem) if elem else ("—" if kind != "collection" else "(none)")
    # @Pattern bounds length; the custom resolver-backed validators hard-cap internally
    # (@ValidEmail → 254, @ValidVatId → 14), so they are not "unbounded".
    has_pattern = bool(names & {"Pattern", "Email", "ValidEmail", "ValidVatId"})

    # ---- gap heuristics ----
    if c["schema_required"] and not required and kind not in ("primitive",):
        gaps.append("REQUIRED-no-@NotNull")
    if kind == "string":
        if "Size" not in annos and not has_pattern:
            gaps.append("no-max-len")
        elif "Size" in annos and size_max is None:
            gaps.append("size-no-max")
    if kind == "collection":
        if "Size" not in annos:
            gaps.append("no-size-cap")
        if not c["element_annos"]:
            gaps.append("elem-unconstrained")
    if kind == "temporal" and EXPIRY_RE.search(c["json_key"]) and not (names & {"Future", "FutureOrPresent"}):
        gaps.append("no-@Future")
    if c["schema_maxlen"] is not None and size_max is not None:
        if str(c["schema_maxlen"]) != str(size_max):
            gaps.append(f"schema/size-maxlen-mismatch({c['schema_maxlen']}/{size_max})")
    if kind == "primitive" and c["type"] in ("boolean",):
        gaps.append("primitive-bool-absent=false")

    return {"req": req_cell, "size": size_cell, "num": num_cell, "pattern": pat_cell,
            "temporal": temp_cell, "element": elem_cell, "kind": kind, "gaps": gaps}


def main():
    files = sorted(set(SRC.rglob("*Request*.java")) | {SRC / "java" / "eu" / "davide" / "features" / p for p in EXTRA_PAYLOADS})
    records = []  # (class_name, rel, [ (component, facet) ])
    for f in files:
        if not f.exists():
            continue
        text = f.read_text(encoding="utf-8")
        m = RECORD_RE.search(text)
        if not m:
            continue  # sealed interface, no own components
        class_name, body = m.group(1), m.group(2)
        rel = f.relative_to(ROOT).as_posix()
        rows = []
        for part in split_components(body):
            c = parse_component(part)
            if c:
                rows.append((c, facet_summary(c)))
        records.append((class_name, rel, rows))

    lines = ["# Request Validation — State of the Union\n"]
    lines.append("Auto-generated by `scripts/audit_request_validation.py`. Per-field bean-validation "
                 "for every request-side record (incl. sealed impls + PARTY payloads). Gap tags are "
                 "heuristic hints for the hygiene pass — verify before acting.\n")

    # ---- per-DTO tables ----
    lines.append("\n## Per-DTO fields\n")
    for class_name, rel, rows in records:
        lines.append(f"\n### {class_name}\n")
        lines.append(f"`{rel}`\n")
        if not rows:
            lines.append("_No components._\n"); continue
        lines.append("| Field (wire) | Type | Required | Size/Len | Numeric | Pattern/Email/Id | Temporal | Element | Gaps |")
        lines.append("|---|---|---|---|---|---|---|---|---|")
        for c, fx in rows:
            gaps = " ".join(f"`{g}`" for g in fx["gaps"]) if fx["gaps"] else "✅"
            lines.append(f"| `{c['json_key']}` | `{c['type']}` | {fx['req']} | {fx['size']} | {fx['num']} "
                         f"| {fx['pattern']} | {fx['temporal']} | {fx['element']} | {gaps} |")

    # ---- aggregated hygiene findings ----
    buckets = {}
    for class_name, rel, rows in records:
        for c, fx in rows:
            for g in fx["gaps"]:
                key = g.split("(")[0]
                buckets.setdefault(key, []).append(f"`{class_name}.{c['json_key']}` (`{c['type']}`)")
    lines.append("\n## Hygiene findings (grouped)\n")
    if not buckets:
        lines.append("_No gaps flagged._\n")
    order = ["REQUIRED-no-@NotNull", "no-max-len", "size-no-max", "no-size-cap",
             "elem-unconstrained", "no-@Future", "schema/size-maxlen-mismatch", "primitive-bool-absent=false"]
    blurb = {
        "REQUIRED-no-@NotNull": "Schema says REQUIRED but no @NotNull/@NotBlank — a missing value slips past bind validation (may 500 downstream instead of a clean 400).",
        "no-max-len": "String field with no @Size(max) — unbounded input length.",
        "size-no-max": "@Size present but no max — still unbounded.",
        "no-size-cap": "Collection with no @Size cap — unbounded element count.",
        "elem-unconstrained": "Collection elements carry no @NotNull/@Valid/@Size — null or oversized elements accepted.",
        "no-@Future": "Expiry/upper-bound timestamp with no @Future/@FutureOrPresent — past dates accepted.",
        "schema/size-maxlen-mismatch": "@Schema(maxLength) disagrees with @Size(max) — docs and enforcement diverge.",
        "primitive-bool-absent=false": "Primitive boolean can't distinguish an absent field from false.",
    }
    for key in order + [k for k in buckets if k not in order]:
        if key not in buckets:
            continue
        lines.append(f"\n**{key}** — {blurb.get(key, '')}  ({len(buckets[key])})")
        for item in buckets[key]:
            lines.append(f"- {item}")

    # ---- @Size(max) spread ----
    spread = {}       # digit literal -> fields (candidates to unify into constants)
    const_maxes = {}  # constant token -> fields (already unified — the precedent)
    for class_name, rel, rows in records:
        for c, fx in rows:
            annos = {n: a for n, a in c["field_annos"]}
            if "Size" in annos:
                mx = size_bound(annos["Size"], "max")
                if mx is None:
                    continue
                if mx.isdigit():
                    spread.setdefault(int(mx), []).append(f"{class_name}.{c['json_key']}")
                else:
                    const_maxes.setdefault(mx, []).append(f"{class_name}.{c['json_key']}")
    lines.append("\n## @Size(max) literal spread (to unify into constants)\n")
    lines.append("| max literal | count | fields |")
    lines.append("|---|---|---|")
    for mx in sorted(spread):
        fields = ", ".join(f"`{x}`" for x in spread[mx])
        lines.append(f"| {mx} | {len(spread[mx])} | {fields} |")
    lines.append("\n### Already using a named constant (the precedent to follow)\n")
    lines.append("| constant | fields |")
    lines.append("|---|---|")
    for k in sorted(const_maxes):
        lines.append(f"| `{k}` | {', '.join(f'`{x}`' for x in const_maxes[k])} |")

    # ---- temporal coverage ----
    lines.append("\n## Temporal fields — @Future coverage\n")
    lines.append("| Field | Has @Future? |")
    lines.append("|---|---|")
    for class_name, rel, rows in records:
        for c, fx in rows:
            if fx["kind"] == "temporal":
                has = any(n in TEMPORAL_CHECKS for n, _ in c["field_annos"])
                lines.append(f"| `{class_name}.{c['json_key']}` | {'yes — ' + fx['temporal'] if has else '**no**'} |")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("\n".join(lines) + "\n", encoding="utf-8")
    total = sum(len(r) for _, _, r in records)
    print(f"Wrote {OUT} ({len(records)} records, {total} fields)")


if __name__ == "__main__":
    main()

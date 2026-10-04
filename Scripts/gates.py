#!/usr/bin/env python3
"""Quality gates for ZTronAssetKit (stdlib only).

  gates.py coverage --json <llvm-cov export json> [--config Scripts/quality-gates.json]
  gates.py trace    [--spec SPEC.md] [--tests Tests] [--write docs/TRACEABILITY.md]
  gates.py unsafe   [--sources Sources] [--audit docs/UNSAFE-AUDIT.md] [--config ...]
  gates.py docs     [--sources Sources] [--config ...]
  gates.py selftest

Every subcommand prints its findings and a final line `<NAME>: PASS` or `<NAME>: FAIL`, and exits 0 / 1.
The thresholds live in Scripts/quality-gates.json and are not negotiable (CLAUDE.md, rule G1).
"""
import argparse
import json
import os
import re
import sys
import tempfile
from pathlib import Path


def load_cfg(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def read_tree(root, suffix=".swift"):
    files = {}
    for base, _dirs, names in os.walk(root):
        if "/.build" in base.replace("\\", "/") or "/checkouts" in base.replace("\\", "/"):
            continue
        for name in names:
            if name.endswith(suffix):
                path = os.path.join(base, name)
                with open(path, encoding="utf-8", errors="replace") as handle:
                    files[path.replace("\\", "/")] = handle.read()
    return files


# --------------------------------------------------------------------------------------------
# coverage
# --------------------------------------------------------------------------------------------
def coverage_check(report, cfg):
    """report = parsed `llvm-cov export` JSON. Returns (ok, lines)."""
    c = cfg["coverage"]
    files = report["data"][0]["files"]
    exclude = [re.compile(p) for p in c["exclude_path_regexes"]]
    device = [re.compile(p) for p in c.get("device_only_path_regexes", [])]
    per_target = {}
    device_lines = 0

    for entry in files:
        path = entry["filename"].replace("\\", "/")
        if any(r.search(path) for r in exclude):
            continue
        match = re.search(r"/Sources/([^/]+)/", path)
        if not match:
            continue
        lines = entry["summary"]["lines"]
        if any(r.search(path) for r in device):
            device_lines += lines["count"]
            continue
        bucket = per_target.setdefault(match.group(1), [0, 0])
        bucket[0] += lines["count"]
        bucket[1] += lines["covered"]

    ok, out = True, []
    critical = set(c.get("critical_targets", []))

    for target in c.get("expected_targets", []):
        if target not in per_target:
            ok = False
            out.append(f"COVERAGE target={target} MISSING from coverage data (renamed, empty, or excluded?) FAIL")

    total_n = total_c = 0
    for target, (count, covered) in sorted(per_target.items()):
        pct = 100.0 * covered / count if count else 100.0
        need = c["critical_min_lines_pct"] if target in critical else c["per_target_min_lines_pct"]
        good = pct + 1e-9 >= need
        ok &= good
        total_n += count
        total_c += covered
        out.append(f"COVERAGE target={target:<24} lines={pct:6.2f}% ({covered}/{count}) min={need:.1f} {'OK' if good else 'FAIL'}")

    overall = 100.0 * total_c / total_n if total_n else 0.0
    need = c["overall_min_lines_pct"]
    good = total_n > 0 and overall + 1e-9 >= need
    ok &= good
    out.append(f"COVERAGE overall lines={overall:.2f}% ({total_c}/{total_n}) min={need:.1f} {'OK' if good else 'FAIL'}")

    fraction = device_lines / (device_lines + total_n) if (device_lines + total_n) else 0.0
    cap = c.get("device_only_max_lines_fraction", 0.03)
    good = fraction <= cap + 1e-12
    ok &= good
    out.append(f"COVERAGE device-only-excluded lines={device_lines} share={100 * fraction:.2f}% max={100 * cap:.1f}% {'OK' if good else 'FAIL'}")
    return ok, out


def cmd_coverage(args):
    ok, out = coverage_check(json.load(open(args.json, encoding="utf-8")), load_cfg(args.config))
    print("\n".join(out))
    print("COVERAGE: PASS" if ok else "COVERAGE: FAIL")
    return 0 if ok else 1


# --------------------------------------------------------------------------------------------
# trace: every MUST requirement and every budget has a test whose display name carries its ID
# --------------------------------------------------------------------------------------------
REQ_LINE = re.compile(r"^- \*\*(R-[A-Z]+-\d+) \[(MUST|SHOULD|MAY)\]\*\*", re.M)
BUDGET_ROW = re.compile(r"^\| (P-\d+) \|", re.M)
ID_IN_NAME = re.compile(r"\b(?:R-[A-Z]+-\d+|P-\d+)\b")
TEST_NAME = re.compile(r'@Test\(\s*"((?:[^"\\]|\\.)*)"')


def trace_check(spec_text, test_files, cfg):
    reqs = {m.group(1): m.group(2) for m in REQ_LINE.finditer(spec_text)}
    budgets = set(BUDGET_ROW.findall(spec_text))
    seen = {}
    for path, text in test_files.items():
        for match in TEST_NAME.finditer(text):
            for ident in ID_IN_NAME.findall(match.group(1)):
                seen.setdefault(ident, []).append(f"{os.path.basename(path)}: {match.group(1)[:80]}")

    ok, out = True, []
    t = cfg.get("trace", {})
    musts = sorted(i for i, lvl in reqs.items() if lvl == "MUST")
    missing_must = [i for i in musts if i not in seen]
    missing_budget = sorted(b for b in budgets if b not in seen)
    unknown = sorted(i for i in seen if i not in reqs and i not in budgets)

    out.append(f"TRACE requirements={len(reqs)} (MUST={len(musts)}) budgets={len(budgets)} tests-with-ids={sum(len(v) for v in seen.values())}")
    if t.get("require_all_must", True) and missing_must:
        ok = False
        out.append(f"TRACE MUST without a test ({len(missing_must)}): {', '.join(missing_must)}")
    if t.get("require_all_budgets", True) and missing_budget:
        ok = False
        out.append(f"TRACE budgets without a benchmark test ({len(missing_budget)}): {', '.join(missing_budget)}")
    if unknown:
        ok = False
        out.append(f"TRACE test names cite unknown IDs: {', '.join(unknown)}")
    if not reqs:
        ok = False
        out.append("TRACE found no requirement lines in the spec (format drift?)")
    return ok, out, reqs, budgets, seen


def cmd_trace(args):
    spec = Path(args.spec).read_text(encoding="utf-8")
    ok, out, reqs, budgets, seen = trace_check(spec, read_tree(args.tests), load_cfg(args.config))
    print("\n".join(out))
    if args.write:
        Path(args.write).parent.mkdir(parents=True, exist_ok=True)
        rows = ["# Traceability (generated by Scripts/gates.py trace — do not edit)", "",
                "| ID | Level | Tests |", "|---|---|---|"]
        for ident in sorted(list(reqs) + sorted(budgets)):
            rows.append(f"| {ident} | {reqs.get(ident, 'BUDGET')} | {len(seen.get(ident, []))} |")
        Path(args.write).write_text("\n".join(rows) + "\n", encoding="utf-8")
    print("TRACE: PASS" if ok else "TRACE: FAIL")
    return 0 if ok else 1


# --------------------------------------------------------------------------------------------
# unsafe: every concurrency/memory escape hatch is audited, marked in code, and capped
# --------------------------------------------------------------------------------------------
MARKER = re.compile(r"UNSAFE-AUDIT:\s*(U-\d+)")


def unsafe_check(files, cfg, audit_text):
    u = cfg["unsafe"]
    patterns = [re.compile(p) for p in u["patterns"]]
    findings = []
    for path, text in sorted(files.items()):
        if "/Sources/" not in path.replace("\\", "/"):
            continue
        lines = text.splitlines()
        for index, line in enumerate(lines):
            code = line.split("//")[0]
            if not any(p.search(code) for p in patterns):
                continue
            context = " ".join(lines[max(0, index - 1): index + 1])
            marker = MARKER.search(context)
            findings.append((path, index + 1, line.strip(), marker.group(1) if marker else None))

    ok, out = True, []
    out.append(f"UNSAFE escapes found={len(findings)} max={u['max_escapes']}")
    if len(findings) > u["max_escapes"]:
        ok = False
        out.append("UNSAFE too many escape hatches")
    for path, line_no, text, marker in findings:
        if marker is None:
            ok = False
            out.append(f"UNSAFE unmarked: {path}:{line_no}: {text[:90]}")
        elif marker not in audit_text:
            ok = False
            out.append(f"UNSAFE {marker} at {path}:{line_no} has no entry in the audit document")
    return ok, out


def cmd_unsafe(args):
    audit = Path(args.audit).read_text(encoding="utf-8") if os.path.exists(args.audit) else ""
    ok, out = unsafe_check(read_tree(args.sources), load_cfg(args.config), audit)
    print("\n".join(out))
    print("UNSAFE: PASS" if ok else "UNSAFE: FAIL")
    return 0 if ok else 1


# --------------------------------------------------------------------------------------------
# docs: every public/open declaration carries a doc comment
# --------------------------------------------------------------------------------------------
DECL = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:public|open)\s+"
    r"(?:(?:final|static|class|nonisolated|indirect|mutating|override|convenience|required|lazy|isolated|consuming|borrowing)\s+)*"
    r"(?:func|var|let|init|subscript|class|struct|enum|protocol|actor|typealias|associatedtype)\b"
)


def docs_check(files, cfg):
    d = cfg["docs"]
    total = documented = exempt = 0
    missing = []
    for path, text in sorted(files.items()):
        if "/Sources/" not in path.replace("\\", "/"):
            continue
        lines = text.splitlines()
        for index, line in enumerate(lines):
            if not DECL.match(line):
                continue
            total += 1
            j = index - 1
            while j >= 0 and lines[j].strip().startswith("@"):
                j -= 1
            previous = lines[j].strip() if j >= 0 else ""
            if "docs:exempt" in line or "docs:exempt" in previous:
                exempt += 1
                documented += 1
            elif previous.startswith("///") or previous.endswith("*/"):
                documented += 1
            else:
                missing.append(f"{path}:{index + 1}: {line.strip()[:80]}")
    fraction = documented / total if total else 1.0
    ok = fraction + 1e-12 >= d["min_documented_public_fraction"] and exempt <= d["max_exempt"]
    out = [f"DOCS public declarations={total} documented={documented} exempt={exempt} fraction={100 * fraction:.1f}%"]
    out += [f"DOCS missing: {m}" for m in missing[:40]]
    if len(missing) > 40:
        out.append(f"DOCS ... and {len(missing) - 40} more")
    if exempt > d["max_exempt"]:
        out.append(f"DOCS too many docs:exempt markers ({exempt} > {d['max_exempt']})")
    return ok, out


def cmd_docs(args):
    ok, out = docs_check(read_tree(args.sources), load_cfg(args.config))
    print("\n".join(out))
    print("DOCS: PASS" if ok else "DOCS: FAIL")
    return 0 if ok else 1


# --------------------------------------------------------------------------------------------
# selftest: prove each gate passes good input AND fails bad input
# --------------------------------------------------------------------------------------------
def _report(entries):
    return {"data": [{"files": [
        {"filename": name, "summary": {"lines": {"count": n, "covered": c, "percent": 100.0 * c / n if n else 0}}}
        for name, n, c in entries]}]}


def cmd_selftest(_args):
    cfg = {
        "coverage": {
            "overall_min_lines_pct": 80.0, "per_target_min_lines_pct": 70.0,
            "critical_targets": ["Store"], "critical_min_lines_pct": 90.0,
            "expected_targets": ["Store", "Net"],
            "exclude_path_regexes": ["/Tests/"],
            "device_only_path_regexes": ["/Sources/Net/Live\\.swift$"], "device_only_max_lines_fraction": 0.03,
        },
        "unsafe": {"max_escapes": 1, "patterns": ["@unchecked\\s+Sendable", "nonisolated\\(unsafe\\)"]},
        "docs": {"min_documented_public_fraction": 1.0, "max_exempt": 1},
        "trace": {"require_all_must": True, "require_all_budgets": True},
    }
    failures = []

    def expect(label, got, want):
        if got != want:
            failures.append(f"{label}: expected {want}, got {got}")

    good = _report([("/p/Sources/Store/A.swift", 100, 95), ("/p/Sources/Net/B.swift", 100, 75),
                    ("/p/Tests/T.swift", 100, 0), ("/p/Sources/Net/Live.swift", 2, 0)])
    expect("coverage good", coverage_check(good, cfg)[0], True)
    expect("coverage critical below 90", coverage_check(_report([("/p/Sources/Store/A.swift", 100, 85), ("/p/Sources/Net/B.swift", 100, 99)]), cfg)[0], False)
    expect("coverage target below 70", coverage_check(_report([("/p/Sources/Store/A.swift", 100, 99), ("/p/Sources/Net/B.swift", 100, 60)]), cfg)[0], False)
    expect("coverage overall below 80", coverage_check(_report([("/p/Sources/Store/A.swift", 100, 91), ("/p/Sources/Net/B.swift", 400, 290)]), cfg)[0], False)
    expect("coverage missing target", coverage_check(_report([("/p/Sources/Store/A.swift", 100, 99)]), cfg)[0], False)
    expect("coverage device-only abuse", coverage_check(_report([("/p/Sources/Store/A.swift", 100, 99), ("/p/Sources/Net/B.swift", 100, 99), ("/p/Sources/Net/Live.swift", 50, 0)]), cfg)[0], False)

    spec = "- **R-X-1 [MUST]** a\n- **R-X-2 [SHOULD]** b\n- **R-X-3 [MUST]** c\n| P-1 | metric |\n"
    full = {"T.swift": '@Test("R-X-1: a") func a(){}\n@Test("R-X-3 c") func c(){}\n@Test("P-1 bench") func p(){}'}
    expect("trace good", trace_check(spec, full, cfg)[0], True)
    expect("trace missing MUST", trace_check(spec, {"T.swift": '@Test("R-X-1: a") func a(){}\n@Test("P-1") func p(){}'}, cfg)[0], False)
    expect("trace missing budget", trace_check(spec, {"T.swift": '@Test("R-X-1") f\n@Test("R-X-3") g'}, cfg)[0], False)
    expect("trace unknown id", trace_check(spec, {"T.swift": full["T.swift"] + '\n@Test("R-X-99 typo") z'}, cfg)[0], False)
    expect("trace prefix collision", trace_check("- **R-X-1 [MUST]** a\n- **R-X-10 [MUST]** b\n", {"T.swift": '@Test("R-X-10 only")'}, cfg)[0], False)
    expect("trace R-X-1 and R-X-10 both covered", trace_check("- **R-X-1 [MUST]** a\n- **R-X-10 [MUST]** b\n", {"T.swift": '@Test("R-X-1 a")\n@Test("R-X-10 b")'}, cfg)[0], True)

    audited = {"/p/Sources/K/A.swift": "// UNSAFE-AUDIT: U-001\nfinal class A: @unchecked Sendable {}\n"}
    expect("unsafe audited", unsafe_check(audited, cfg, "## U-001 reason")[0], True)
    expect("unsafe unmarked", unsafe_check({"/p/Sources/K/A.swift": "final class A: @unchecked Sendable {}"}, cfg, "")[0], False)
    expect("unsafe not in audit doc", unsafe_check(audited, cfg, "nothing here")[0], False)
    expect("unsafe cap", unsafe_check({"/p/Sources/K/A.swift": "// UNSAFE-AUDIT: U-001\nx: @unchecked Sendable\n// UNSAFE-AUDIT: U-002\nnonisolated(unsafe) var y"}, cfg, "U-001 U-002")[0], False)
    expect("unsafe comment mention ignored", unsafe_check({"/p/Sources/K/A.swift": "/// never use @unchecked Sendable\nfinal class A {}"}, cfg, "")[0], True)

    ok_src = {"/p/Sources/K/A.swift": "/// Doc.\n@MainActor\npublic func f() {}\n/// Doc.\npublic struct S {\n    /// Doc.\n    public init() {}\n}\n"}
    expect("docs good", docs_check(ok_src, cfg)[0], True)
    expect("docs missing", docs_check({"/p/Sources/K/A.swift": "public func f() {}\n"}, cfg)[0], False)
    expect("docs attribute between", docs_check({"/p/Sources/K/A.swift": "/// Doc.\n@available(iOS 15, *)\npublic final class C {}\n"}, cfg)[0], True)
    expect("docs exempt cap", docs_check({"/p/Sources/K/A.swift": "// docs:exempt a\npublic func f() {}\n// docs:exempt b\npublic func g() {}\n"}, cfg)[0], False)
    expect("docs internal ignored", docs_check({"/p/Sources/K/A.swift": "func f() {}\nprivate func g() {}\n"}, cfg)[0], True)

    if failures:
        print("\n".join(f"SELFTEST failure: {f}" for f in failures))
        print("SELFTEST: FAIL")
        return 1
    print("SELFTEST: PASS")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    default_cfg = str(Path(__file__).with_name("quality-gates.json"))

    p = sub.add_parser("coverage"); p.add_argument("--json", required=True); p.add_argument("--config", default=default_cfg); p.set_defaults(fn=cmd_coverage)
    p = sub.add_parser("trace"); p.add_argument("--spec", default="SPEC.md"); p.add_argument("--tests", default="Tests"); p.add_argument("--config", default=default_cfg); p.add_argument("--write"); p.set_defaults(fn=cmd_trace)
    p = sub.add_parser("unsafe"); p.add_argument("--sources", default="Sources"); p.add_argument("--audit", default="docs/UNSAFE-AUDIT.md"); p.add_argument("--config", default=default_cfg); p.set_defaults(fn=cmd_unsafe)
    p = sub.add_parser("docs"); p.add_argument("--sources", default="Sources"); p.add_argument("--config", default=default_cfg); p.set_defaults(fn=cmd_docs)
    p = sub.add_parser("selftest"); p.set_defaults(fn=cmd_selftest)

    args = parser.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""
Enumerate every custom error, require-string, and revert-string reachable from
a given (contract, function) entrypoint.

Primary pass: Slither walks internal + library + external calls starting from
the entrypoint. This captures everything in the transitive compile unit.

Secondary pass: hardcoded grep over EXTRA_SOURCES — files containing code that
runs downstream of the entrypoint but isn't in the compile unit (e.g. the
FreezeListBeforeTransferHook called via an interface, or PredicateRegistry
living in a separate sub-project). Edit EXTRA_SOURCES as wiring evolves.

Usage:
    python scripts/enumerate_errors.py <target.sol> <Contract> <function-sig>

Example:
    python scripts/enumerate_errors.py \\
        src/helper/DistributorCodeDepositor.sol DistributorCodeDepositor \\
        'deposit(ERC20,uint256,uint256,address,bytes,Attestation)'

Does NOT cover:
  - Solidity panics (overflow/div-by-zero/OOB) — need symbolic execution
  - Reverts in inline assembly (mstore+revert)
  - Reverts inside contracts not in the compile unit AND not in EXTRA_SOURCES
    (arbitrary ERC20s, runtime-configured modules)
"""

import re
import sys
from slither import Slither
from slither.slithir.operations import (
    InternalCall,
    HighLevelCall,
    LibraryCall,
    SolidityCall,
)
from slither.core.declarations import SolidityFunction


# Files that execute downstream of the entrypoint but aren't in the primary
# compile unit. Each entry is (path, function_filter). `function_filter` is a
# substring of function names to restrict grep to (None = whole file).
EXTRA_SOURCES = [
    ("src/helper/FreezeListBeforeTransferHook.sol", "beforeTransfer"),
    ("lib/predicate-contracts/src/PredicateRegistry.sol", "validateAttestation"),
]


def function_matches(fn, sig):
    return fn.full_name == sig or fn.name == sig


def find_entrypoint(slither, contract_name, sig):
    for c in slither.contracts:
        if c.name != contract_name:
            continue
        for f in c.functions:
            if function_matches(f, sig):
                return c, f
    return None, None


def collect_reachable(entry):
    seen = set()
    stack = [entry]
    while stack:
        fn = stack.pop()
        if fn in seen or fn is None:
            continue
        seen.add(fn)
        for m in fn.modifiers:
            if m not in seen:
                stack.append(m)
        for node in fn.nodes:
            for ir in node.irs:
                target = None
                if isinstance(ir, (InternalCall, LibraryCall, HighLevelCall)):
                    target = ir.function
                if target is not None and hasattr(target, "nodes"):
                    stack.append(target)
    return seen


def extract_errors_from_function(fn):
    results = []
    for node in fn.nodes:
        sm = node.source_mapping
        fname = sm.filename.short if hasattr(sm.filename, "short") else str(sm.filename)
        src = f"{fname}:{sm.lines[0]}" if sm.lines else fname

        for ir in node.irs:
            if isinstance(ir, SolidityCall) and isinstance(ir.function, SolidityFunction):
                name = ir.function.full_name
                if name.startswith("require(bool,string"):
                    try:
                        results.append(("require_str", ir.arguments[1].value, src))
                    except Exception:
                        results.append(("require_str", "<dynamic>", src))
                elif name.startswith("revert(string)"):
                    try:
                        results.append(("revert_str", ir.arguments[0].value, src))
                    except Exception:
                        results.append(("revert_str", "<dynamic>", src))

        expr = node.expression
        if expr is not None:
            text = str(expr)
            if text.startswith("revert ") and "(" in text:
                err_name = text[len("revert "):].split("(")[0].strip()
                if err_name and err_name[0].isupper():
                    results.append(("custom", err_name, src))
    return results


# Regexes for the grep pass. Multi-line-aware (DOTALL) since require/revert
# statements often span several lines.
RE_REQUIRE_STR = re.compile(r'require\s*\(.*?,\s*"([^"]+)"\s*\)', re.DOTALL)
RE_REVERT_STR = re.compile(r'revert\s*\(\s*"([^"]+)"\s*\)')
RE_REVERT_CUSTOM = re.compile(r'revert\s+([A-Z]\w*)\s*\(')


def _line_of(text, pos):
    return text.count("\n", 0, pos) + 1


def grep_extra_source(path, fn_filter):
    """Return list of (kind, message_or_name, file:line) within functions
    matching `fn_filter` (or whole file if None). Uses brace-depth tracking
    on the raw text to delimit function bodies, then runs regexes on each
    body block to catch multi-line require/revert statements."""
    results = []
    try:
        with open(path, "r") as f:
            text = f.read()
    except FileNotFoundError:
        return [("MISSING", path, "")]

    # Find all function headers and their body ranges.
    for hdr in re.finditer(r'\bfunction\s+(\w+)\s*\(', text):
        name = hdr.group(1)
        if fn_filter is not None and fn_filter not in name:
            continue
        # Find the first `{` after the header, then track brace depth.
        brace = text.find("{", hdr.end())
        if brace == -1:
            continue
        depth = 1
        i = brace + 1
        while i < len(text) and depth > 0:
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
            i += 1
        body_start, body_end = brace, i
        body = text[body_start:body_end]

        def record(regex, kind):
            for m in regex.finditer(body):
                line = _line_of(text, body_start + m.start())
                results.append((kind, m.group(1), f"{path}:{line}"))

        record(RE_REQUIRE_STR, "require_str")
        record(RE_REVERT_STR, "revert_str")
        record(RE_REVERT_CUSTOM, "custom")
    return results


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        sys.exit(1)
    target, contract_name, sig = sys.argv[1], sys.argv[2], sys.argv[3]

    slither = Slither(target)
    _, entry = find_entrypoint(slither, contract_name, sig)
    if entry is None:
        print(f"ERROR: {contract_name}.{sig} not found in {target}", file=sys.stderr)
        sys.exit(2)

    reachable = collect_reachable(entry)

    findings = []  # [(label, [(kind, msg, src), ...]), ...]
    for fn in sorted(reachable, key=lambda f: (f.contract.name, f.name)):
        errs = extract_errors_from_function(fn)
        if errs:
            findings.append((f"{fn.contract.name}.{fn.full_name}", errs))

    # Grep pass
    for path, fn_filter in EXTRA_SOURCES:
        errs = grep_extra_source(path, fn_filter)
        if errs:
            label = f"{path}" + (f" ({fn_filter})" if fn_filter else "")
            findings.append((label, errs))

    # Output
    print(f"# Errors reachable from `{contract_name}.{sig}`\n")
    print(f"_Slither pass: {len(reachable)} reachable functions. "
          f"Grep pass: {len(EXTRA_SOURCES)} extra source(s)._\n")
    print("**Excluded:** Solidity panics (overflow/div-by-zero/OOB), inline-assembly reverts, reverts inside contracts not in the compile unit and not in EXTRA_SOURCES (arbitrary ERC20s, runtime-configured modules).\n")

    seen_flat = set()
    flat = []
    for label, errs in findings:
        for kind, msg, src in errs:
            key = (kind, msg)
            if key in seen_flat:
                continue
            seen_flat.add(key)
            flat.append((kind, msg, label, src))

    print("## Summary (deduplicated)\n")
    print("| Kind | Error | Origin |")
    print("|------|-------|--------|")
    for kind, msg, label, src in sorted(flat, key=lambda x: (x[0], x[1])):
        print(f"| {kind} | `{msg}` | `{label}` @ {src} |")

    print("\n## Per-function detail\n")
    for label, errs in findings:
        print(f"### `{label}`\n")
        for kind, msg, src in errs:
            print(f"- **{kind}**: `{msg}` — {src}")
        print()


if __name__ == "__main__":
    main()

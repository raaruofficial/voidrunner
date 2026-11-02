#!/usr/bin/env python3
"""VOIDRUNNER bridge conformance instrument (CURE_PLAN R-5).

Fault class: SERVED-CLIENT <-> NATIVE BRIDGE PROTOCOL MISMATCH — the
served client invokes a bridge shape the shell does not expose (arity
mismatch, missing result callback, ack-as-promise), failing closed
inside the WebView, invisible to every native-surface battery. Type
instance: VOIDRUNNER v1.0.12 rejection, ticket 347104793320 (the
client called signMessage(message) 1-arg and awaited it as a promise;
the shell exposes signMessage(requestId, message), returns only an
ack, and delivers results solely via a window.__voidrunnerWalletResolve
callback the client never installed).

What it checks, mechanically (both halves required at every seal
where either side changes; the runtime half is battery R-1/R-2):

  SHELL  S1  the @JavascriptInterface method set + arities parsed from
             VoidrunnerWalletBridge.kt equal BridgeContract.kt's
             METHOD_ARITIES table (skipped with a note for pre-1.0.13
             shells that carry no BridgeContract.kt).
  CLIENT C1  the served bundle ASSIGNS window.__voidrunnerWalletResolve
             at least once (the result callback is defined) — directly
             (`.__voidrunnerWalletResolve =`), via a computed key
             (`["__voidrunnerWalletResolve"] =`), or via a string
             constant bound to that name and used as a computed key
             (`K="__voidrunnerWalletResolve"` + `[K] =`).
  CLIENT C2  for every ASYNC (ack/callback) bridge method the bundle
             actually calls, at least one call site passes exactly
             the contract arity. (Adapter-internal calls may use the
             adapter's own interface arity; a bundle whose ONLY
             dispatches are at a non-contract arity has no working
             raw dispatch — the v1.0.12 signature.) Scope is the
             async surface because that is the fault class's surface:
             a wrong-arity call to a synchronous getter throws
             visibly in JS instead of failing silently, and minified
             bundles legitimately contain same-named library methods
             (e.g. web3.js's own getPublicKey) that are not bridge
             calls at all.

Arg counting balances (), {}, [] and skips string/template/comment
spans. The instrument is a static tripwire: it fails the seal on
drift, and R-1/R-2 remain the runtime proof.

Usage:
  bridge-conformance.py --bundle <bundle-dir|js-file> --shell <shell-src-dir>
Exit: 0 = PASS, 1 = FAIL, 2 = usage/extraction error.
"""
import argparse
import glob
import pathlib
import re
import sys

RESOLVE_CALLBACK = "__voidrunnerWalletResolve"


# ---------------------------------------------------------------- shell
def parse_bridge_methods(kotlin: str):
    """@JavascriptInterface fun name(a, b) -> {name: arity}."""
    methods = {}
    for m in re.finditer(r"@JavascriptInterface\s+fun\s+(\w+)\s*\(([^)]*)\)", kotlin):
        name, params = m.group(1), m.group(2).strip()
        arity = 0 if not params else params.count(",") + 1
        methods[name] = arity
    return methods


def parse_contract_table(kotlin: str):
    """BridgeContract.kt METHOD_ARITIES entries: "name" to N."""
    table = {}
    body = re.search(r"METHOD_ARITIES[^=]*=\s*linkedMapOf\((.*?)\)", kotlin, re.S)
    if not body:
        return table
    for m in re.finditer(r'"(\w+)"\s+to\s+(\d+)', body.group(1)):
        table[m.group(1)] = int(m.group(2))
    return table


def parse_async_methods(kotlin: str):
    """BridgeContract.kt ASYNC_METHODS entries, if present."""
    body = re.search(r"ASYNC_METHODS[^=]*=\s*setOf\((.*?)\)", kotlin, re.S)
    if not body:
        return None
    return set(re.findall(r'"(\w+)"', body.group(1)))


# ---------------------------------------------------------------- client
def count_args(src: str, open_paren: int) -> int:
    """Count top-level arguments of the call whose '(' is at open_paren."""
    depth_paren = 0
    depth_brack = 0
    depth_brace = 0
    commas = 0
    saw_any = False
    i = open_paren
    n = len(src)
    while i < n:
        c = src[i]
        if c in "\"'`":
            quote = c
            i += 1
            while i < n:
                if src[i] == "\\":
                    i += 2
                    continue
                if src[i] == quote:
                    break
                if quote == "`" and src[i] == "$" and i + 1 < n and src[i + 1] == "{":
                    # template interpolation: skip its braces as a unit
                    d = 0
                    i += 1
                    while i < n:
                        if src[i] == "{":
                            d += 1
                        elif src[i] == "}":
                            d -= 1
                            if d == 0:
                                break
                        i += 1
                i += 1
            i += 1
            saw_any = True
            continue
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            j = src.find("\n", i)
            i = n if j < 0 else j
            continue
        if c == "/" and i + 1 < n and src[i + 1] == "*":
            j = src.find("*/", i)
            i = n if j < 0 else j + 2
            continue
        if c == "(":
            depth_paren += 1
            if depth_paren > 1:
                saw_any = True
        elif c == ")":
            depth_paren -= 1
            if depth_paren == 0:
                return (commas + 1) if saw_any else 0
            saw_any = True
        elif c == "[":
            depth_brack += 1
            saw_any = True
        elif c == "]":
            depth_brack -= 1
            saw_any = True
        elif c == "{":
            depth_brace += 1
            saw_any = True
        elif c == "}":
            depth_brace -= 1
            saw_any = True
        elif c == "," and depth_paren == 1 and depth_brack == 0 and depth_brace == 0:
            commas += 1
            saw_any = True
        elif not c.isspace():
            saw_any = True
        i += 1
    raise ValueError("unbalanced call")


def call_sites(src: str, method: str):
    """All (offset, argc) for `.method(` occurrences."""
    sites = []
    for m in re.finditer(r"\." + re.escape(method) + r"\s*\(", src):
        open_paren = m.end() - 1
        try:
            sites.append((m.start(), count_args(src, open_paren)))
        except ValueError:
            sites.append((m.start(), -1))
    return sites


# ---------------------------------------------------------------- main
def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bundle", required=True, help="bundle dir (public/assets/*.js) or a JS file")
    ap.add_argument("--shell", required=True, help="dir containing the wallet/*.kt sources")
    args = ap.parse_args()

    shell_dir = pathlib.Path(args.shell)
    bridge_files = list(shell_dir.rglob("VoidrunnerWalletBridge.kt"))
    if not bridge_files:
        print("ERROR: VoidrunnerWalletBridge.kt not found under", shell_dir)
        return 2
    bridge_src = bridge_files[0].read_text(encoding="utf-8")
    shell_methods = parse_bridge_methods(bridge_src)
    if not shell_methods:
        print("ERROR: no @JavascriptInterface methods parsed")
        return 2

    contract_files = list(shell_dir.rglob("BridgeContract.kt"))
    contract_text = contract_files[0].read_text(encoding="utf-8") if contract_files else ""
    contract = parse_contract_table(contract_text)
    async_methods = parse_async_methods(contract_text) or {"connectWallet", "signMessage", "signTransaction"}

    bundle = pathlib.Path(args.bundle)
    if bundle.is_dir():
        js_files = sorted(glob.glob(str(bundle / "public" / "assets" / "*.js"))) or \
            sorted(f for f in glob.glob(str(bundle / "**" / "*.js"), recursive=True)
                   if pathlib.Path(f).is_file())
    else:
        js_files = [str(bundle)]
    if not js_files:
        print("ERROR: no JS asset found under", bundle)
        return 2
    client_src = "\n".join(pathlib.Path(f).read_text(encoding="utf-8") for f in js_files)

    failures = []

    # S1 — shell internal consistency (bridge vs contract table)
    if contract:
        if shell_methods == contract:
            print(f"S1 PASS  bridge @JavascriptInterface set == BridgeContract table ({len(contract)} methods)")
        else:
            failures.append("S1")
            print("S1 FAIL  bridge/contract drift:")
            for name in sorted(set(shell_methods) | set(contract)):
                if shell_methods.get(name) != contract.get(name):
                    print(f"         {name}: bridge={shell_methods.get(name)} contract={contract.get(name)}")
    else:
        print("S1 SKIP  no BridgeContract.kt (pre-1.0.13 shell); contract taken from bridge source")

    reference = contract if contract else shell_methods

    # C1 — resolve callback defined (direct, computed-key, or via a
    # string constant bound to the callback name)
    assigns = len(re.findall(re.escape(RESOLVE_CALLBACK) + r"\s*=", client_src))
    assigns += len(re.findall(r"\[\s*[\"']" + re.escape(RESOLVE_CALLBACK) + r"[\"']\s*\]\s*=", client_src))
    for const in re.findall(r"(\w+)\s*=\s*[\"']" + re.escape(RESOLVE_CALLBACK) + r"[\"']", client_src):
        assigns += len(re.findall(r"\[\s*" + re.escape(const) + r"\s*\]\s*=", client_src))
    if assigns >= 1:
        print(f"C1 PASS  {RESOLVE_CALLBACK} assigned x{assigns}")
    else:
        failures.append("C1")
        print(f"C1 FAIL  {RESOLVE_CALLBACK} never assigned — results can never reach the client")

    # C2 — every called ASYNC bridge method has >= 1 contract-arity call site
    for method, arity in sorted(reference.items()):
        if method not in async_methods:
            continue
        sites = call_sites(client_src, method)
        if not sites:
            print(f"C2 SKIP  {method}: no call sites in bundle")
            continue
        argcs = sorted({a for _, a in sites})
        if arity in argcs:
            print(f"C2 PASS  {method}: call-site arities {argcs}, contract {arity} present ({len(sites)} sites)")
        else:
            failures.append(f"C2:{method}")
            print(f"C2 FAIL  {method}: call-site arities {argcs}, contract {arity} ABSENT ({len(sites)} sites)")

    print("VERDICT:", "PASS" if not failures else "FAIL (" + ", ".join(failures) + ")")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())

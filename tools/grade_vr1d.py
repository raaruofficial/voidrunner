#!/usr/bin/env python3
"""VR-1D grader: parse a post-connect hierarchy dump, restrict to nodes whose
package is com.voidrunner.app (VR's OWN window), and test whether the Connected
address node text EQUALS the expected pubkey character-for-character.
Usage: grade_vr1d.py <hier-vr1-after.xml> [expected_pubkey]
Exit 0 = PASS (exact equality found in a VR-package node), 1 = FAIL."""
import sys
import xml.etree.ElementTree as ET

EXPECTED = "WGSEgS1wRKJspT4hN8Rw947nX936YdhHRbuqftue9mu"
LABELS = {"CONNECTED", "SIGN TEST MESSAGE", "DISCONNECT", "WALLET", "Back",
          "CONNECT WALLET", "TRY AGAIN", "Not connected", "Error"}

def main():
    path = sys.argv[1]
    expected = sys.argv[2] if len(sys.argv) > 2 else EXPECTED
    root = ET.parse(path).getroot()
    vr_texts, other_pkgs = [], set()
    for node in root.iter("node"):
        pkg = node.get("package") or ""
        if pkg != "com.voidrunner.app":
            if pkg:
                other_pkgs.add(pkg)
            continue
        t = node.get("text") or ""
        if t:
            vr_texts.append(t)
    print(f"file={path}")
    print(f"non-VR packages present in dump: {sorted(other_pkgs) or 'none'}")
    print("VR-window texts:", vr_texts)
    addr_candidates = [t for t in vr_texts if t not in LABELS]
    print("address-node candidates (non-label texts):", addr_candidates)
    if expected in vr_texts:
        print(f"VR-1D: PASS — a com.voidrunner.app node's text EQUALS {expected} exactly")
        return 0
    print(f"VR-1D: FAIL — expected pubkey not present as an exact node text in VR's own window")
    return 1

if __name__ == "__main__":
    sys.exit(main())

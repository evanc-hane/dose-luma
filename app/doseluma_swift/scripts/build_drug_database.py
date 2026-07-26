#!/usr/bin/env python3
"""
build_drug_database.py
======================
Downloads public-domain drug data and builds the full production
DoseLumaDrugs.sqlite for bundling in the iOS app.

Data sources (all public domain / open government licence):
  • FDA NDC Directory       — https://open.fda.gov/apis/drug/ndc/
  • Health Canada DPD       — https://www.canada.ca/en/health-canada/...

Requires:  python3, requests, zipfile (stdlib)
Runtime:   ~5–10 min depending on network speed
Output:    DoseLuma/DoseLumaDrugs.sqlite  (~35–50 MB)

Usage:
    pip3 install requests
    python3 scripts/build_drug_database.py

After generating, add DoseLumaDrugs.sqlite to the Xcode project:
  1. Drag into project navigator
  2. Check "Copy items if needed"
  3. Add to DoseLuma target (not Watch target)
"""

import sqlite3, json, csv, io, os, sys, zipfile, pathlib
import urllib.request

SCRIPT_DIR = pathlib.Path(__file__).parent
OUTPUT     = SCRIPT_DIR.parent / "DoseLuma" / "DoseLumaDrugs.sqlite"

# ── Schema ───────────────────────────────────────────────────────────────────
SCHEMA = """
PRAGMA journal_mode = OFF;
PRAGMA synchronous  = OFF;

CREATE TABLE IF NOT EXISTS drugs (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    ndc          TEXT,
    din          TEXT,
    brand_name   TEXT NOT NULL,
    generic_name TEXT,
    strength     TEXT,
    dosage_form  TEXT,
    route        TEXT,
    manufacturer TEXT
);

CREATE TABLE IF NOT EXISTS imprints (
    id       INTEGER PRIMARY KEY AUTOINCREMENT,
    drug_id  INTEGER NOT NULL REFERENCES drugs(id),
    imprint  TEXT,
    shape    TEXT,
    color    TEXT
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_ndc     ON drugs(ndc);
CREATE UNIQUE INDEX IF NOT EXISTS idx_din     ON drugs(din);
CREATE        INDEX IF NOT EXISTS idx_imprint ON imprints(imprint);
CREATE        INDEX IF NOT EXISTS idx_shape   ON imprints(shape);
CREATE        INDEX IF NOT EXISTS idx_color   ON imprints(color);
"""

# ── FDA NDC Directory ─────────────────────────────────────────────────────────
# Full download (~40 MB JSON, updated weekly)
FDA_NDC_URL = "https://download.open.fda.gov/drug/ndc/drug-ndc-0001-of-0001.json.zip"

def download(url: str, desc: str) -> bytes:
    print(f"  Downloading {desc}...")
    with urllib.request.urlopen(url, timeout=120) as r:
        data = r.read()
    print(f"    {len(data) // 1024} KB downloaded")
    return data

def load_fda_ndc(con: sqlite3.Connection):
    print("\n── FDA NDC Directory ──────────────────────────────────")
    try:
        raw = download(FDA_NDC_URL, "FDA NDC JSON (~40 MB)")
    except Exception as e:
        print(f"  WARNING: FDA download failed ({e}). Skipping.")
        return

    with zipfile.ZipFile(io.BytesIO(raw)) as z:
        fname = z.namelist()[0]
        data  = json.loads(z.read(fname))

    results = data.get("results", [])
    print(f"  Parsing {len(results)} NDC records…")

    count = 0
    for r in results:
        ndc          = r.get("product_ndc", "")
        brand        = r.get("brand_name", "").strip()
        generic      = r.get("generic_name", "").strip().lower()
        strength_raw = r.get("active_ingredients", [])
        strength     = "; ".join(
            f"{i.get('name','').lower()} {i.get('strength','')}"
            for i in strength_raw
        ) if strength_raw else ""
        dosage_form  = r.get("dosage_form", "").lower()
        route        = "; ".join(r.get("route", [])).lower()
        mfr          = r.get("labeler_name", "").strip()

        if not brand or not ndc:
            continue
        try:
            con.execute(
                "INSERT OR IGNORE INTO drugs "
                "(ndc, brand_name, generic_name, strength, dosage_form, route, manufacturer)"
                " VALUES (?,?,?,?,?,?,?)",
                (ndc, brand, generic, strength, dosage_form, route, mfr)
            )
            count += 1
        except sqlite3.IntegrityError:
            pass

    con.commit()
    print(f"  Inserted {count} FDA drugs")


# ── Health Canada DPD ─────────────────────────────────────────────────────────
# Open Government Licence — Canada
HC_DPD_URL = "https://health-products.canada.ca/api/drug/drugproduct/?lang=en&type=json&status=MARKETED&limit=100000"

def load_hc_dpd(con: sqlite3.Connection):
    print("\n── Health Canada DPD ──────────────────────────────────")
    try:
        raw = download(HC_DPD_URL, "Health Canada DPD (~15 MB)")
    except Exception as e:
        print(f"  WARNING: HC DPD download failed ({e}). Skipping.")
        return

    data    = json.loads(raw)
    results = data if isinstance(data, list) else data.get("results", [])
    print(f"  Parsing {len(results)} DPD records…")

    count = 0
    for r in results:
        din       = str(r.get("drug_identification_number", "")).zfill(8)
        brand     = r.get("brand_name", "").strip()
        generic   = r.get("descriptor", "").strip().lower()
        strength  = r.get("strength", "").strip()
        form      = r.get("pharmaceutical_form", "").lower()
        route     = r.get("route_of_administration", "").lower()
        mfr       = r.get("company_name", "").strip()

        if not brand or not din or din == "00000000":
            continue
        try:
            con.execute(
                "INSERT OR IGNORE INTO drugs "
                "(din, brand_name, generic_name, strength, dosage_form, route, manufacturer)"
                " VALUES (?,?,?,?,?,?,?)",
                (din, brand, generic, strength, form, route, mfr)
            )
            count += 1
        except sqlite3.IntegrityError:
            pass

    con.commit()
    print(f"  Inserted {count} HC DPD drugs")


# ── Main ──────────────────────────────────────────────────────────────────────

def build():
    if OUTPUT.exists():
        OUTPUT.unlink()
        print(f"Removed existing database at {OUTPUT}")

    con = sqlite3.connect(str(OUTPUT))
    con.executescript(SCHEMA)

    load_fda_ndc(con)
    load_hc_dpd(con)

    # Optimise for read-only bundled use
    con.execute("VACUUM")
    con.execute("ANALYZE")
    con.close()

    size_mb = OUTPUT.stat().st_size / (1024 * 1024)
    print(f"\n✓ Built {OUTPUT}  ({size_mb:.1f} MB)")
    print(f"\nNext steps:")
    print(f"  1. Drag DoseLumaDrugs.sqlite into Xcode project navigator")
    print(f"  2. Check 'Copy items if needed'")
    print(f"  3. Add to DoseLuma target only (not Watch)")
    print(f"  4. Build and run — DrugDatabase.isAvailable will return true")

if __name__ == "__main__":
    build()

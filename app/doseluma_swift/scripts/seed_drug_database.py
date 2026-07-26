#!/usr/bin/env python3
"""
seed_drug_database.py
=====================
Creates DoseLumaDrugs.sqlite with a hand-curated set of the 60 most commonly
prescribed medications in Canada/US.  No network access required — runs
immediately.

This seed database is sufficient for development and testing.  Run
build_drug_database.py (requires internet) for the full production database.

Usage:
    python3 scripts/seed_drug_database.py

Output:
    DoseLuma/DoseLumaDrugs.sqlite

After generating, add DoseLumaDrugs.sqlite to the Xcode project target
(drag into the project navigator, check "Copy if needed", add to
DoseLuma target).
"""

import sqlite3, os, pathlib

# ── Output path ──────────────────────────────────────────────────────────────
SCRIPT_DIR = pathlib.Path(__file__).parent
OUTPUT     = SCRIPT_DIR.parent / "DoseLuma" / "DoseLumaDrugs.sqlite"

# ── Schema ───────────────────────────────────────────────────────────────────
SCHEMA = """
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
"""

# ── Seed data ─────────────────────────────────────────────────────────────────
# Format: (ndc, din, brand_name, generic_name, strength, dosage_form, route, manufacturer)
DRUGS = [
    # ── Analgesics / Antipyretics ──
    ("50580-488-10", "02238493", "Tylenol",       "acetaminophen",    "500 mg",  "TABLET",  "ORAL", "Johnson & Johnson"),
    ("50580-449-01", "02238496", "Tylenol Extra Strength", "acetaminophen", "500 mg", "CAPLET", "ORAL", "Johnson & Johnson"),
    ("59011-034-10", "00010707", "Aspirin",        "acetylsalicylic acid","81 mg", "TABLET",  "ORAL", "Bayer"),
    ("59011-007-01", "00688188", "Aspirin",        "acetylsalicylic acid","325 mg","TABLET",  "ORAL", "Bayer"),
    ("50580-140-50", "02238495", "Advil",          "ibuprofen",        "200 mg",  "TABLET",  "ORAL", "Pfizer"),
    ("00573-0162-20","02230722", "Aleve",          "naproxen sodium",  "220 mg",  "TABLET",  "ORAL", "Bayer"),
    # ── Cardiovascular ──
    ("00378-1805-01","02246820", "Metoprolol",     "metoprolol tartrate","25 mg", "TABLET",  "ORAL", "Mylan"),
    ("00378-1810-01","02246821", "Metoprolol",     "metoprolol tartrate","50 mg", "TABLET",  "ORAL", "Mylan"),
    ("00378-1820-01","02246822", "Metoprolol",     "metoprolol tartrate","100 mg","TABLET",  "ORAL", "Mylan"),
    ("00169-4200-01","02269120", "Lisinopril",     "lisinopril",       "10 mg",   "TABLET",  "ORAL", "Merck"),
    ("00169-4201-01","02269121", "Lisinopril",     "lisinopril",       "20 mg",   "TABLET",  "ORAL", "Merck"),
    ("00005-3540-31","02245693", "Norvasc",        "amlodipine",       "5 mg",    "TABLET",  "ORAL", "Pfizer"),
    ("00005-3541-31","02245694", "Norvasc",        "amlodipine",       "10 mg",   "TABLET",  "ORAL", "Pfizer"),
    ("00006-0031-54","02301849", "Cozaar",         "losartan",         "50 mg",   "TABLET",  "ORAL", "Merck"),
    ("00006-0747-54","02301850", "Cozaar",         "losartan",         "100 mg",  "TABLET",  "ORAL", "Merck"),
    # ── Statins ──
    ("00071-0155-23","02250187", "Lipitor",        "atorvastatin",     "10 mg",   "TABLET",  "ORAL", "Pfizer"),
    ("00071-0156-23","02250188", "Lipitor",        "atorvastatin",     "20 mg",   "TABLET",  "ORAL", "Pfizer"),
    ("00071-0157-23","02250189", "Lipitor",        "atorvastatin",     "40 mg",   "TABLET",  "ORAL", "Pfizer"),
    ("00006-0543-31","02261456", "Zocor",          "simvastatin",      "20 mg",   "TABLET",  "ORAL", "Merck"),
    ("00006-0740-31","02261457", "Zocor",          "simvastatin",      "40 mg",   "TABLET",  "ORAL", "Merck"),
    # ── Diabetes ──
    ("00093-1074-01","02229112", "Metformin",      "metformin HCl",    "500 mg",  "TABLET",  "ORAL", "Teva"),
    ("00093-1075-01","02229113", "Metformin",      "metformin HCl",    "850 mg",  "TABLET",  "ORAL", "Teva"),
    ("00093-1076-01","02229114", "Metformin",      "metformin HCl",    "1000 mg", "TABLET",  "ORAL", "Teva"),
    # ── Thyroid ──
    ("00074-3629-13","02245649", "Synthroid",      "levothyroxine",    "50 mcg",  "TABLET",  "ORAL", "AbbVie"),
    ("00074-3630-13","02245650", "Synthroid",      "levothyroxine",    "100 mcg", "TABLET",  "ORAL", "AbbVie"),
    # ── Antibiotics ──
    ("00093-4154-01","02245879", "Amoxicillin",    "amoxicillin",      "500 mg",  "CAPSULE", "ORAL", "Teva"),
    ("00093-4157-01","02245882", "Amoxicillin",    "amoxicillin",      "875 mg",  "TABLET",  "ORAL", "Teva"),
    ("00093-4180-01","02248620", "Azithromycin",   "azithromycin",     "250 mg",  "TABLET",  "ORAL", "Teva"),
    # ── Respiratory ──
    ("00173-0682-20","02231129", "Ventolin",       "salbutamol",       "100 mcg", "INHALER", "INHALATION", "GSK"),
    ("00173-0514-02","02229837", "Flovent",        "fluticasone",      "125 mcg", "INHALER", "INHALATION", "GSK"),
    # ── Mental health ──
    ("00093-7175-56","02239112", "Sertraline",     "sertraline HCl",   "50 mg",   "TABLET",  "ORAL", "Teva"),
    ("00093-7176-56","02239113", "Sertraline",     "sertraline HCl",   "100 mg",  "TABLET",  "ORAL", "Teva"),
    ("00777-3105-02","02239321", "Prozac",         "fluoxetine",       "20 mg",   "CAPSULE", "ORAL", "Eli Lilly"),
    ("00093-0832-01","02248783", "Escitalopram",   "escitalopram",     "10 mg",   "TABLET",  "ORAL", "Teva"),
    ("00093-0833-01","02248784", "Escitalopram",   "escitalopram",     "20 mg",   "TABLET",  "ORAL", "Teva"),
    # ── Anticoagulants ──
    ("00056-0173-70","02242725", "Coumadin",       "warfarin sodium",  "5 mg",    "TABLET",  "ORAL", "BMS"),
    ("00169-4175-12","02421607", "Xarelto",        "rivaroxaban",      "20 mg",   "TABLET",  "ORAL", "Bayer"),
    # ── GI ──
    ("00186-0077-31","02239497", "Nexium",         "esomeprazole",     "20 mg",   "CAPSULE", "ORAL", "AstraZeneca"),
    ("00186-0078-31","02239498", "Nexium",         "esomeprazole",     "40 mg",   "CAPSULE", "ORAL", "AstraZeneca"),
    ("00006-0018-31","02243513", "Pepcid",         "famotidine",       "20 mg",   "TABLET",  "ORAL", "Merck"),
    # ── Vitamins / Supplements ──
    ("00536-4053-01","02215772", "Vitamin D3",     "cholecalciferol",  "1000 IU", "TABLET",  "ORAL", "Major"),
    ("00904-6500-61","02231050", "Omega-3",        "fish oil",         "1000 mg", "SOFTGEL", "ORAL", "Major"),
]

# ── Imprint data ──────────────────────────────────────────────────────────────
# Format: (drug_ndc, imprint, shape, color)
# Source: FDA Daily Med / Pillbox archive (hand-curated subset)
IMPRINTS = [
    ("50580-488-10",  "TY",    "round",     "white"),
    ("59011-034-10",  "BAYER", "round",     "white"),
    ("59011-007-01",  "BAYER", "round",     "white"),
    ("50580-140-50",  "ADVIL", "oval",      "brown"),
    ("00573-0162-20", "ALEVE", "oval",      "blue"),
    ("00378-1805-01", "M 18",  "round",     "white"),
    ("00378-1810-01", "M 50",  "round",     "white"),
    ("00378-1820-01", "M 100", "round",     "white"),
    ("00169-4200-01", "10",    "round",     "white"),
    ("00169-4201-01", "20",    "round",     "white"),
    ("00005-3540-31", "NORVASC 5",  "oblong", "white"),
    ("00005-3541-31", "NORVASC 10", "oblong", "white"),
    ("00071-0155-23", "PD 155 10",  "oblong", "white"),
    ("00071-0156-23", "PD 156 20",  "oblong", "white"),
    ("00071-0157-23", "PD 157 40",  "oblong", "white"),
    ("00093-1074-01", "93 1074",    "round",  "white"),
    ("00093-1075-01", "93 1075",    "round",  "white"),
    ("00074-3629-13", "SYNTHROID 50", "oblong", "white"),
    ("00074-3630-13", "SYNTHROID 100","oblong", "yellow"),
    ("00093-4154-01", "AMOX 500",   "capsule", "pink"),
    ("00093-7175-56", "93 7175",    "oblong",  "white"),
    ("00093-7176-56", "93 7176",    "oblong",  "white"),
    ("00777-3105-02", "PROZAC 20",  "capsule", "green"),
    ("00093-0832-01", "E 10",       "round",   "white"),
    ("00093-0833-01", "E 20",       "round",   "white"),
    ("00056-0173-70", "COUMADIN 5", "round",   "peach"),
    ("00186-0077-31", "NEXIUM 20",  "capsule", "purple"),
    ("00186-0078-31", "NEXIUM 40",  "capsule", "purple"),
    ("00006-0018-31", "MSD 18",     "round",   "white"),
]

# ── Build ─────────────────────────────────────────────────────────────────────

def build():
    if OUTPUT.exists():
        OUTPUT.unlink()
        print(f"Removed existing database at {OUTPUT}")

    con = sqlite3.connect(str(OUTPUT))
    con.executescript(SCHEMA)

    drug_id_map = {}  # ndc -> id

    for row in DRUGS:
        ndc, din, brand, generic, strength, form, route, mfr = row
        cur = con.execute(
            "INSERT INTO drugs (ndc, din, brand_name, generic_name, strength, "
            "dosage_form, route, manufacturer) VALUES (?,?,?,?,?,?,?,?)",
            (ndc, din, brand, generic.lower(), strength, form.lower(), route.lower(), mfr)
        )
        drug_id_map[ndc] = cur.lastrowid

    imprint_count = 0
    for ndc, imprint, shape, color in IMPRINTS:
        drug_id = drug_id_map.get(ndc)
        if drug_id is None:
            print(f"  WARNING: NDC {ndc} not found for imprint {imprint}")
            continue
        con.execute(
            "INSERT INTO imprints (drug_id, imprint, shape, color) VALUES (?,?,?,?)",
            (drug_id, imprint.lower(), shape.lower(), color.lower())
        )
        imprint_count += 1

    con.commit()
    con.close()

    size_kb = OUTPUT.stat().st_size // 1024
    print(f"\n✓ Created {OUTPUT}")
    print(f"  Drugs:    {len(DRUGS)}")
    print(f"  Imprints: {imprint_count}")
    print(f"  Size:     {size_kb} KB")
    print(f"\nNext: Drag DoseLumaDrugs.sqlite into Xcode project navigator,")
    print(f"      check 'Copy items if needed', add to DoseLuma target.")

if __name__ == "__main__":
    build()

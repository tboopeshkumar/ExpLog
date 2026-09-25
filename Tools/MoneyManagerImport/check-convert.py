#!/usr/bin/env python3
"""Regression test for convert.py, on a synthetic Money Manager export.

    python3 Tools/MoneyManagerImport/check-convert.py

Builds a small .xlsx the way Money Manager lays it out — for someone whose
main currency is euros and whose categories aren't the ones this converter
was first written against — then converts it and checks the result. No real
data involved.
"""

import csv
import json
import pathlib
import subprocess
import sys
import tempfile
import zipfile
from xml.sax.saxutils import escape

HERE = pathlib.Path(__file__).parent
HEADER = ["Period", "Accounts", "Category", "Subcategory", "Note", "EUR",
          "Income/Expense", "Description", "Amount", "Currency", "Accounts"]
# Period is an Excel serial date: 46284.5 is 2026-09-19 12:00.
ROWS = [
    [46284.5, "Visa", "🍜 Food", "Lunch", "Bistro", 12.5, "Exp.", "", 12.5, "EUR", 12.5],
    [46284.6, "Visa", "🐶 Pets", "", "Vet", 80, "Exp.", "", 80, "EUR", 80],
    [46284.7, "Visa", "🎭 Culture", "", "Museum", 15, "Exp.", "", 15, "EUR", 15],
    [46284.8, "Cash", "Hobbies", "", "Paint", 22, "Exp.", "", 22, "EUR", 22],
    [46285.5, "Visa", "🍜 Food", "", "Trattoria", 30, "Exp.", "", 3300, "JPY", 30],
    [46285.6, "Salary", "Salary", "", "Pay", 3000, "Income", "", 3000, "EUR", 3000],
]


def column(index):
    return chr(ord("A") + index)


def write_xlsx(path, rows):
    """The minimum the converter reads: one worksheet, inline strings."""
    lines = []
    for r, row in enumerate(rows, start=1):
        cells = []
        for c, value in enumerate(row):
            ref = f"{column(c)}{r}"
            if isinstance(value, str):
                cells.append(f'<c r="{ref}" t="inlineStr"><is><t>{escape(value)}</t></is></c>')
            else:
                cells.append(f'<c r="{ref}"><v>{value}</v></c>')
        lines.append(f'<row r="{r}">{"".join(cells)}</row>')
    sheet = ('<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
             f'<sheetData>{"".join(lines)}</sheetData></worksheet>')
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("xl/worksheets/sheet1.xml", sheet)


def run(xlsx, out, *extra):
    return subprocess.run([sys.executable, str(HERE / "convert.py"), str(xlsx), str(out), *extra],
                          capture_output=True, text=True)


failures = 0


def expect(condition, label, detail=""):
    global failures
    print(f"  {'✓' if condition else '✗'} {label}{'' if condition or not detail else f' — {detail}'}")
    failures += 0 if condition else 1


with tempfile.TemporaryDirectory() as tmp:
    tmp = pathlib.Path(tmp)
    xlsx = tmp / "export.xlsx"
    write_xlsx(xlsx, [HEADER] + ROWS)

    print("\nCONVERTER (synthetic export, euros, unfamiliar categories)\n")
    result = run(xlsx, tmp / "out.csv")
    expect(result.returncode == 0, "converts without stopping at unknown categories", result.stdout + result.stderr)
    rows = list(csv.DictReader(open(tmp / "out.csv", encoding="utf-8")))
    by_note = {r["Merchant"]: r for r in rows}

    expect(len(rows) == 5, "expenses converted, income skipped", f"{len(rows)} rows")
    expect(all(r["Currency"] == "EUR" for r in rows), "main currency read from the export's header, not assumed")
    expect(by_note["Bistro"]["Category"] == "Dining" and by_note["Bistro"]["Subcategory"] == "Lunch",
           "a known category maps onto ExpLog's, subcategory kept")
    expect(by_note["Museum"]["Category"] == "Entertainment", "Money Manager's default 'Culture' maps to Entertainment")
    expect(by_note["Vet"]["Category"] == "Pets", "an unmapped category keeps its own name, emoji removed")
    expect(by_note["Paint"]["Category"] == "Hobbies", "…including one without an emoji")
    expect(by_note["Trattoria"]["Amount"] == "30.00" and by_note["Trattoria"]["Note"] == "JPY 3,300.00",
           "a foreign row comes in at its main-currency value, original amount in the note")
    expect("kept under their own name" in result.stdout and "Pets" in result.stdout,
           "the report lists categories kept under their own name")

    mapping = tmp / "map.json"
    mapping.write_text(json.dumps({"Hobbies": "Entertainment", "🐶 Pets": "Household"}), encoding="utf-8")
    run(xlsx, tmp / "mapped.csv", "--map", str(mapping))
    mapped = {r["Merchant"]: r for r in csv.DictReader(open(tmp / "mapped.csv", encoding="utf-8"))}
    expect(mapped["Paint"]["Category"] == "Entertainment" and mapped["Vet"]["Category"] == "Household",
           "--map overrides and extends the mapping")

print()
if failures:
    sys.exit(f"{failures} check(s) failed.")
print("All checks passed.\n")

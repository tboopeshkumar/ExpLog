#!/usr/bin/env python3
"""Convert a Money Manager (Realbyte) Excel export into an ExpLog CSV.

    python3 Tools/MoneyManagerImport/convert.py <export.xlsx> <out.csv>

Then AirDrop the CSV to the phone and use Settings -> Import CSV in ExpLog.

Standard library only. The export's columns are:

    Period, Accounts, Category, Subcategory, Note, AED, Income/Expense,
    Description, Amount, Currency, Accounts

How rows become ExpLog transactions:

- Date: "Period" is an Excel serial date-time in the phone's local time; it's
  written out as a local "yyyy-MM-ddTHH:mm:ss".
- Amount: always the main-currency column — Money Manager names it after your
  main currency ("AED") and fills it with the converted value for
  foreign-currency rows. Rows come in in that currency, with any original
  foreign amount kept in the note, so the history stays in one currency.
  (ExpLog totals never add currencies together; converting here keeps a
  year of imported history in the totals.)
- Merchant: "Description" when present (it holds the merchant on the rows that
  use it), otherwise "Note", otherwise the subcategory or category.
- Note: the Note when Description took the merchant slot, then any original
  foreign amount, joined with " · ".
- Subcategory: Money Manager's, as-is; ExpLog creates it under the mapped
  category on import.
- Category: mapped through CATEGORY_MAP. An unmapped category stops the
  conversion rather than being guessed.
- Income and transfer rows are skipped and counted; ExpLog records expenses.

Nothing is written unless the output reconciles with the input: same number of
expense rows, and the same main-currency total for every month.
"""

import csv
import datetime
import re
import sys
import zipfile
from collections import Counter, defaultdict
from decimal import Decimal
from xml.etree import ElementTree as ET

# Money Manager category (emoji and spacing stripped, lower-cased) -> ExpLog
# category. Names that aren't ExpLog defaults (Education, Household, Rent) are
# created by the import, with their own icons.
CATEGORY_MAP = {
    "groceries": "Groceries",
    "food": "Dining",
    "transport": "Transport",
    "flight": "Travel",
    "apparel": "Shopping",
    "beauty": "Shopping",
    "health": "Health",
    "medical": "Health",
    "social life": "Entertainment",
    "telecom": "Bills & Utilities",
    "electricity and water": "Bills & Utilities",
    "subscriptions": "Bills & Utilities",
    "gift": "Other",
    "other": "Other",
    "education": "Education",
    "household": "Household",
    "rent": "Rent",
}

EXPLOG_HEADER = ["Date", "Amount", "Currency", "Merchant", "Category", "Account", "Note", "Reference", "Subcategory"]
NS = {"m": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}


def read_rows(path):
    """Rows of the first sheet as dicts keyed by header text."""
    with zipfile.ZipFile(path) as z:
        shared = []
        if "xl/sharedStrings.xml" in z.namelist():
            for si in ET.fromstring(z.read("xl/sharedStrings.xml")).findall("m:si", NS):
                shared.append("".join(t.text or "" for t in si.iter("{%s}t" % NS["m"])))
        sheet = ET.fromstring(z.read("xl/worksheets/sheet1.xml"))

    grid = []
    for row in sheet.iter("{%s}row" % NS["m"]):
        cells = {}
        for c in row.findall("m:c", NS):
            column = re.match(r"[A-Z]+", c.get("r")).group(0)
            v = c.find("m:v", NS)
            kind = c.get("t")
            if kind == "s" and v is not None:
                cells[column] = shared[int(v.text)]
            elif kind == "inlineStr":
                cells[column] = "".join(t.text or "" for t in c.iter("{%s}t" % NS["m"]))
            else:
                cells[column] = v.text if v is not None else ""
        grid.append(cells)

    # Header text -> column letter. "Accounts" appears twice; the first one is
    # the account name, the second an amount in the account's currency.
    columns = {}
    for letter, name in sorted(grid[0].items()):
        columns.setdefault(name.strip(), letter)
    return [{name: (cells.get(letter) or "").strip() for name, letter in columns.items()} for cells in grid[1:]]


def excel_datetime(serial):
    moment = datetime.datetime(1899, 12, 30) + datetime.timedelta(days=float(serial))
    return moment.replace(microsecond=0) + datetime.timedelta(seconds=round(moment.microsecond / 1e6))


def category_key(name):
    """'🚖 Transport' -> 'transport', 'Groceries ' -> 'groceries'."""
    return re.sub(r"[^\w&' ]+", "", name, flags=re.UNICODE).strip().lower()


KNOWN_COLUMNS = {"Period", "Accounts", "Category", "Subcategory", "Note",
                 "Income/Expense", "Description", "Amount", "Currency"}


def main_currency(rows):
    """The header Money Manager names after the main currency, e.g. "AED"."""
    codes = [name for name in rows[0] if name not in KNOWN_COLUMNS and re.fullmatch(r"[A-Z]{3}", name)]
    if len(codes) != 1:
        sys.exit(f"Couldn't find the main-currency column (found {codes or 'none'}).")
    return codes[0]


def convert(rows, main):
    out, skipped, problems = [], Counter(), []
    for line, row in enumerate(rows, start=2):
        kind = row.get("Income/Expense", "")
        if not kind.lower().startswith("exp"):
            skipped[kind or "(blank)"] += 1
            continue

        mapped = CATEGORY_MAP.get(category_key(row.get("Category", "")))
        if row.get("Category") and mapped is None:
            problems.append(f"line {line}: unmapped category {row['Category']!r}")
            continue

        try:
            when = excel_datetime(row["Period"])
            amount = Decimal(row[main]).quantize(Decimal("0.01"))
        except Exception as error:  # noqa: BLE001 - report and carry on
            problems.append(f"line {line}: {error}")
            continue

        note, description = row.get("Note", ""), row.get("Description", "")
        subcategory, category = row.get("Subcategory", ""), row.get("Category", "")
        merchant = description or note or subcategory or re.sub(r"[^\w&' ]+", "", category).strip() or "Expense"

        note_parts = []
        if description and note:
            note_parts.append(note)
        currency = (row.get("Currency") or main).upper()
        if currency != main:
            original = Decimal(row["Amount"]).quantize(Decimal("0.01"))
            note_parts.append(f"{currency} {original:,}")

        out.append({
            "Date": when.strftime("%Y-%m-%dT%H:%M:%S"),
            "Amount": f"{amount}",
            "Currency": main,
            "Merchant": merchant,
            "Category": mapped or "",
            "Account": row.get("Accounts", ""),
            "Note": " · ".join(note_parts),
            "Reference": "",
            "Subcategory": subcategory if mapped else "",
        })
    return out, skipped, problems


def likely_duplicates(out):
    """Rows sharing merchant and amount within five minutes of another. Reported
    only; ExpLog imports them all, since it checks duplicates against existing
    data, not between rows of one file."""
    by_key = defaultdict(list)
    for row in out:
        by_key[(row["Merchant"], row["Amount"])].append(datetime.datetime.fromisoformat(row["Date"]))
    pairs = 0
    for times in by_key.values():
        times.sort()
        pairs += sum(1 for a, b in zip(times, times[1:]) if (b - a).total_seconds() <= 300)
    return pairs


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__.split("\n\n")[1])
    source, target = sys.argv[1], sys.argv[2]
    rows = read_rows(source)
    main = main_currency(rows)
    out, skipped, problems = convert(rows, main)

    # Reconcile before writing anything.
    expenses = [r for r in rows if r.get("Income/Expense", "").lower().startswith("exp")]
    source_months, out_months = defaultdict(Decimal), defaultdict(Decimal)
    for r in expenses:
        source_months[excel_datetime(r["Period"]).strftime("%Y-%m")] += Decimal(r[main])
    for r in out:
        out_months[r["Date"][:7]] += Decimal(r["Amount"])
    mismatched = [m for m in source_months if source_months[m].quantize(Decimal("0.01")) != out_months[m]]

    print(f"Read {len(rows)} rows from {source}")
    print(f"  expenses converted: {len(out)} of {len(expenses)}")
    for kind, count in skipped.items():
        print(f"  skipped (not an expense): {count} x {kind!r}")
    print(f"  main currency: {main}")
    print(f"  total {main}: {sum(Decimal(r['Amount']) for r in out):,}")
    print(f"  months: {min(out_months)} to {max(out_months)} ({len(out_months)})")
    print(f"  categories: {dict(Counter(r['Category'] for r in out).most_common())}")
    print(f"  accounts: {len(set(r['Account'] for r in out))}")
    foreign = sum(1 for r in rows if (r.get("Currency") or main).upper() != main)
    print(f"  foreign-currency rows converted to {main}: {foreign}")
    dupes = likely_duplicates(out)
    if dupes:
        # Informational only: ExpLog's import checks duplicates against what was
        # already stored, not between rows of the same file, so these all import.
        print(f"  {dupes} row(s) share merchant and amount within 5 minutes of another; "
              f"all are kept (separate records in the source)")

    if problems or len(out) != len(expenses) or mismatched:
        for p in problems[:20]:
            print("  PROBLEM:", p)
        for m in mismatched:
            print(f"  PROBLEM: {m} source {source_months[m]} != converted {out_months[m]}")
        sys.exit("Not written: fix the problems above.")

    with open(target, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=EXPLOG_HEADER)
        writer.writeheader()
        writer.writerows(out)
    print(f"Wrote {target} — every month's total matches the source.")


if __name__ == "__main__":
    main()

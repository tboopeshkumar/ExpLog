# ExpLog

Expense logging for iOS, built around one idea: select a bank SMS in Messages,
tap Share, tap ExpLog, and the expense is logged. No retyping.

## How it works

Two targets and one database:

| Piece | Job |
|---|---|
| `ExpLog` (app) | Transaction list, monthly totals, editing, cards, categories, CSV export |
| `ShareExtension` | Receives the SMS from the share sheet, parses it, shows a pre-filled form |

From Messages it's: long-press the SMS → Share → ExpLog → check the form → Save.

### Two ways of saving

Apple restricts **App Groups** — the shared container two targets use to read
one database — to paid Developer Program members. ExpLog works either way and
picks the route at runtime, in `SharedStore.isAppGroupAvailable`:

| | Paid account | Free Apple ID |
|---|---|---|
| Store | One database in the App Group | The app's own container |
| On Save | Extension writes it directly | Extension queues it in a shared keychain group |
| Appears in the app | Immediately | Next time ExpLog opens |
| Card + category prefill | In the form | Applied by the app on import |

You stay in Messages either way. The free path is `Shared/SharedInbox.swift`:
free team provisioning profiles grant keychain access to `<team>.*`, so a
shared keychain group works where an App Group doesn't. (Opening the app from
the extension isn't an option — iOS refuses `NSExtensionContext.open` from a
share extension.) Nothing needs rewriting if you enroll later — the App Group
route switches itself back on.

## The parser

`Shared/SMSParser.swift` matches each field independently rather than keeping a
rule set per bank, because card alerts share a grammar:

```
<card> at <merchant> for <CUR> <amount> on <date>
```

It handles the traps these messages set:

- **Two amounts per message.** Nearly every alert states the available balance
  or credit limit as well as the amount spent. The parser anchors on
  `for AED <amount>` rather than taking the first number it sees.
- **Multiple "at"s.** `at DIAMOND CABS CITYCENT for AED 17.00 on 20-Sep at 11:30`
  — the merchant match is non-greedy so it stops at the amount clause.
- **Years missing.** `20-Sep` is anchored to the message's year, stepping back
  one year when that would put the transaction in the future.
- **Messages that aren't transactions.** OTPs, declines and statement reminders
  are rejected outright rather than logged as spending.
- **Shouting, truncated merchants.** `ROUND CLOCK MART SUPERMA` becomes
  `Round Clock Mart Superma`; words with digits keep their case, so `20THFLOOR`
  survives intact.
- **Sentences that look like merchants.** `linked to account XX810001 was used
  for …` fits the "paid to X for" shape. A candidate holding a masked number,
  starting with "account" or "card", or containing a verb like "was" or
  "debited" is refused, and the next pattern gets a turn.

Amounts and dates are read however the bank writes them, not only the way
UAE banks do:

- `1,234.56`, `1.234,56` and `12,50` all read correctly: with both separators
  the last is the decimal point; a lone one followed by one or two digits is
  decimal. A lone one followed by exactly three digits is settled by the
  currency — `KWD 12.345` is three-decimal dinars, `JPY 1,850` is yen.
- Numeric dates that read either way (`09/05/2026`) take whichever reading is
  nearest the message's arrival, since an alert arrives within a day or two of
  the purchase. ISO (`2026-09-20`) and dotted (`20.09.2026`) dates work too,
  and so do month-first ones (`Sep 27 2026`, `Sep 5th, 2026`).
- A time is read wherever it appears — `at 11:30`, or `12:10PM` straight after
  the date.

Every transaction keeps its original SMS in `rawMessage`, so a parser bug can be
fixed months later without losing data.

### Tests

Both run on the Mac, no simulator involved:

```bash
./Tools/check-parser.sh
```

Field-by-field parsing of every known message format, plus the messages that
must be *refused* (OTPs, declines, statement reminders). **When a new format
shows up, add it to `Tools/ParserCheck/main.swift` with its expected fields
before touching the parser.**

```bash
./Tools/check-store.sh
```

UI behaviour — swipes, sheets, month switching, picking a merchant — is
covered by UI tests run in the simulator (`UITests/`; each file's header says
the data it expects, which `Tools/seed-demo.sh` provides):

```bash
xcodebuild test -project ExpLog.xcodeproj -scheme ExpLog -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

The data layer against a real SwiftData store: card matching, category
learning, duplicate detection, totals — the same path the share extension runs
when you tap Save.

On-device, Settings → Test message parsing does the same as the first one
interactively: paste a message, see exactly which fields were read.

## Subcategories

A category can have one optional level below it — Transport › Taxi — added in
Settings → Categories by tapping the category. The form shows a Subcategory
picker once the chosen category has any; changing the category clears a
subcategory that belonged to the old one. Subcategories take their parent's
icon and colour, are learned per merchant along with the category, and appear
in the Summary drill-down as a By subcategory breakdown. Deleting a
subcategory keeps its expenses in the category; deleting a category takes its
subcategories with it.

The CSV format gained a ninth column, Subcategory, and later two more for each
expense's exchange rate. All are optional on import, so older files still
read. Importing a file again fills in the
subcategory on expenses that are already stored but lack one — how history
imported before subcategories gets them — matched to each row's exact twin by
time, and only where the stored expense still has the row's category. The copy
of the subcategory an older import wrote into the note is removed; anything
else in the note stays. Running it twice changes nothing.

## Matching cards

Each card in Settings → Cards & accounts has SMS keywords — text copied from
its alerts, like `XXX4453` or `XXXX4453`. An alert containing one of them is
matched to that card, ignoring case. Keywords rather than a fixed four digits
because banks disagree on the mask: some write three digits, some four, some
"ending 4453". A card can have several.

- A keyword that starts or ends with a digit won't match inside a longer
  number: `4453` matches `XXXX4453` but not `144531`.
- Keywords need at least four characters, so a bare `453` can't match an
  amount like `AED 453.00`; write it with its mask, `XXX453`.
- When two cards match, the longer keyword wins.
- Two cards can't share a keyword; the editor offers to merge them instead,
  moving the expenses across.

The parser reads three- or four-digit cards and keeps them as written, so
"Add card" in the share form creates a card whose keyword already matches the
next alert. Settings → Test message parsing shows which card an alert matches.
Rules in `Shared/AccountMatching.swift`, covered by `check-store.sh`.

## Learning from messages

**Categories.** Saving an expense from a message with a category records a
`MerchantAlias`: the merchant as read from the message, the name you gave it,
its category and subcategory. The next alert from the same place arrives
already named and categorised. No training step — it just gets quieter over
time. Settings → Merchants lists what's remembered; tap one to rename it or
change its category (for future messages; logged expenses keep theirs), swipe
to forget it.

**Where the merchant is.** When a bank writes its alerts in a way the parser
misreads, the button beside Merchant in the form (shown when the expense came
from a message) opens the message as tappable words. Tap the merchant's first
word, then its last. With "Remember for messages like this" on, ExpLog keeps
where they were as a `MessageFormat`, and reads the merchant from the same
place in that bank's later alerts. It works like this
(`Shared/MerchantFormat.swift`):

- The words before the merchant are the anchor. The ones that change between
  alerts are wildcards: anything with a digit (cards, amounts, dates, times),
  month and day names, AM/PM, currency codes. So another card, amount or date
  in the same format still matches, and another bank's format doesn't.
- The merchant ends where the picked words end: at their comma, or before the
  next word. Picking `AMAZONUFR` out of `AMAZONUFR DI, AE` learns to leave out
  the capitalised word before the comma (the city), so the next alert's
  `CITYMART MOE DU, AE` reads `Citymart Moe`.
- A pattern is only kept if it reads the picked words back out of the message
  it came from. Picking again in the same format replaces the old one.

Settings → Message formats lists them, each with its message and the merchant
highlighted; swipe to forget one. The share extension can't see these when
there's no App Group, so the app reads the message again with them when the
expense arrives, unless you typed or picked a merchant in the share sheet.

A merchant memory keyed on a sentence fragment, like one from an older parser's
misreading, would pre-fill one shop's name and category on every alert in that
format. These are dropped at launch.

## Building your own copy

ExpLog isn't on the App Store; you build it onto your own iPhone. You need a
Mac with Xcode and an Apple ID — a free one works (see below).

1. Install the project generator:

   ```bash
   brew install xcodegen
   ```

2. Give the build your identity. Copy the example config and fill in your
   Apple team ID and a bundle-ID prefix of your own:

   ```bash
   cp Config/Local.xcconfig.example Config/Local.xcconfig
   ```

   `Config/Local.xcconfig` is git-ignored, so your identity never lands in the
   repository. Everything that depends on it — bundle IDs, the keychain group,
   the App Group — is derived from those two values. Your team ID is in Xcode →
   Settings → Accounts, or in the OU field of your "Apple Development"
   certificate. Without the file the build uses `com.example` and no team.

3. Generate the project and open it:

   ```bash
   xcodegen generate && open ExpLog.xcodeproj
   ```

4. Pick your iPhone as the destination and press ⌘R. The first run asks you to
   trust the developer on the phone: Settings → General → VPN & Device
   Management.

Then set it up for your cards and currency in the app: Settings → Main
currency, and Settings → Cards & accounts with each card's SMS keywords.

### Apple ID: free or paid

- **Free Apple ID** — works. The build expires after 7 days and has to be
  re-run from Xcode, and App Groups aren't available, so the extension takes the
  shared-keychain route described above.
- **Apple Developer Program ($99/yr)** — builds last a year, the App Group
  works, and iCloud sync becomes possible.

No App Store submission is involved either way.

## Turning on iCloud sync

The schema is already CloudKit-shaped — every attribute optional or defaulted,
no unique constraints, every relationship with an inverse. So enabling sync is
configuration, not migration:

1. Add the iCloud capability with CloudKit to both targets, same container.
2. Uncomment the `cloudKitDatabase:` line in `Shared/SharedStore.swift`.

Requires the paid developer account.

## Layout

```
Shared/           Compiled into both targets
  SMSParser.swift         Field extraction
  MerchantFormat.swift    Merchant patterns learned from a picked message
  LearnedParsing.swift    The parser plus what it has been taught
  ParsedTransaction.swift Parser output
  TransactionDraft.swift  Editable state, dedupe, alias learning
  SharedStore.swift       App Group SwiftData container
  Models/Models.swift     Transaction, ExpenseCategory, Account, MerchantAlias, MessageFormat
  Views/                  The form used by both the app and the extension
App/              Main app only
ShareExtension/   Extension only
Tools/            Parser regression suite (runs on macOS)
```

## Building from the command line

Xcode 27 no longer ships `Simulator.app` (it's `DeviceHub.app` now), and if
`xcode-select` still points at the Command Line Tools, pass `DEVELOPER_DIR`
instead of changing it globally:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project ExpLog.xcodeproj -scheme ExpLog -destination 'name=iPhone 17 Pro' CODE_SIGN_IDENTITY='-' build
```

Note `CODE_SIGN_IDENTITY='-'` rather than `CODE_SIGNING_ALLOWED=NO`. Disabling
signing entirely strips entitlements from the binary, so once the App Group is
switched on it silently won't resolve and the app quietly falls back to its own
container — which looks like the share extension saving into a void.

To look at the app with the sample data in it:

```bash
./Tools/seed-demo.sh <simulator-udid>
```

## The app icon

Drawn in code — `Tools/IconGen/main.swift` — rather than kept as a binary blob,
so colours and proportions are editable and the result is reproducible:

```bash
./Tools/make-icon.sh
```

That writes the 1024×1024 PNG into the asset catalog; Xcode derives the smaller
sizes. iOS requires a full square with no alpha and no rounded corners, so the
renderer produces exactly that and lets the system apply its own mask.

## Importing history

Settings → Import CSV reads ExpLog's own CSV format — an export from the app, or
history converted from another app. Rows already in ExpLog (same bank
reference, or same merchant and amount within five minutes) are skipped, so
importing the same file twice adds nothing; rows within one file are never
compared against each other, since two identical taxi fares are two records.
Missing categories and accounts are created by name. Covered by
`check-store.sh`.

### From Money Manager

Export from Money Manager to Excel, then convert on the Mac:

```bash
python3 Tools/MoneyManagerImport/convert.py export.xlsx ExpLog-import.csv
```

The converter maps categories with an ExpLog equivalent (see `CATEGORY_MAP`)
and keeps any other category under its own name; `--map my.json` overrides or
extends the mapping. Foreign-currency rows come in at Money Manager's
main-currency value, with the original amount in the note. It writes nothing
unless every month's total matches the source. `check-convert.py` tests it on
a synthetic export.
AirDrop the CSV to the phone and import it. Keep both files out of this
repository: they're real spending.

## The form

A new expense opens on the amount, keyboard up; Next moves on to the merchant.
The amount field takes digits and one decimal mark, and no more decimals than
the currency has (two for dirhams, three for dinars, none for yen). The
currency is the pill above it — your currencies first, as arranged in
Settings. Categories are a row of coloured chips, one tap to choose and
another to clear; a category with subcategories shows them as a second row.
The same form backs the share extension and editing ("Edit Expense").
`ExpenseFormUITests` drives it.

## Quick actions

Swipe an expense right for **Categorise** — a half-height sheet of categories
with their subcategories beneath, one tap to assign — and **Copy**, which opens
the form pre-filled with a copy dated now (not the bank reference or the SMS,
and at today's exchange rate). Swipe left to delete. The same three are in the
long-press menu, in the expense list and the Summary drill-downs. Categorising
this way saves through the editor's path, so a merchant from an SMS is learned.

## Logging alerts automatically

ExpLog adds a Shortcuts action, **Log Expense from Message**
(`App/LogExpenseIntent.swift`). Given an SMS, it does what sharing the message
does — learned formats, card keywords, remembered merchant names and
categories, the duplicate check — and saves, without opening the app. It skips
OTPs, declines and anything without an amount, and says "Already logged" for an
alert that's already there. An alert with no merchant is saved under its card
("Card XX5528") so nothing is lost.

To have alerts logged as they arrive, make a personal automation in Shortcuts
(steps as of iOS 27, where Automation moved into Library):

1. **Library → Automation → +**, then **Edit** to skip Describe a Shortcut.
2. In the search sheet, **Automation → Message**.
3. The trigger reads "Sender is Sender": tap **Sender**, change it to
   **Message**, and enter a phrase every alert from your bank uses (such as
   "was used for") as the Text. Matching the text is more reliable than the
   sender, which for banks is a name like "ADCB" rather than a contact.
4. Search for **ExpLog**, add **Log Expense from Message**, and set its
   Message via **Select Variable** to the trigger's **Message**.
5. Tap **⌄** beside "where" to check **Confirm Before Run** is off, then **‹**
   to save. It appears under Personal, switched on.

Make one per bank if their wording differs. Settings → Shortcuts → **Review
before saving** switches the action to opening ExpLog with the expense filled
in, to check and save — a tap per expense instead of none. The logic lives in
`Shared/MessageLogging.swift`, covered by `check-store.sh`. Tested in the
simulator by running the action by hand; a real SMS arriving can only be tried
on a phone.

## Months

The Expenses tab shows one month at a time, opening on the current one, with
its total and the expenses grouped by day (each day with its own total). The
‹ › arrows step a month; tapping the month's name opens a list of every month
that has expenses, by year with their totals, to jump straight to one, and
"This month" comes back. Future-dated expenses (instalments) sit in their own
months, one tap forward. Search covers every month.

Expenses and Summary share the chosen month, so switching tabs keeps your
place. Only that month's expenses are fetched (plus the first and last, for
where the arrows stop), so the list stays quick however much history there
is. Grouping and the arrows' limits are in `Shared/MonthIndex.swift`, covered
by `check-store.sh`; `MonthNavigationUITests` drives the switcher.

There's no sideways swipe between months: rows already use sideways swipes
for their quick actions.

## Monthly summary

The Summary tab shows one month's total and its spending by category or by
merchant (a switch it remembers), ranked, with each row's share as a bar.
Under the total: the spending per day, and a comparison with the month before
("↑ 18% vs August"). For the current month both count only expenses dated up
to today — an instalment due later doesn't inflate the pace — and the
comparison is with the same days of last month ("vs 1–3 Sep"), so an early
month isn't set against a whole one. Rules in `MonthPace`
(`Shared/MonthSummary.swift`), covered by `check-store.sh`.
Tapping a category opens its month — its total and share of the month, then a
breakdown by subcategory and by merchant
(top five, then "Show all"), then the expenses. Tapping a merchant lists its
expenses. Merchant names group ignoring case and extra spaces, shown under the
most common spelling; different names stay separate rather than being merged
on a guess. The totals come from `Shared/MonthSummary.swift`, which is
covered by `check-store.sh`.

The share bars are deliberately one colour. Nine category colours can't all be
told apart — system red and pink measure ΔE 3.3 against a floor of 15 — so the
chart doesn't rely on them: the bars show size, and the coloured icon and name
beside each bar say which category it is.

## Currencies

Every expense keeps its own currency (ISO 4217 code). Settings → Main currency
picks the default for new expenses and the currency totals are counted in; on
first launch it's set from whichever currency most existing expenses use, else
the device's region. The form's currency sign is a menu, for spending abroad,
and the parser recognises about thirty major currencies in alerts
(`Shared/Currency.swift`).

Your other currencies — any you've spent in, set a rate for or added — are
listed in Settings → Other currencies & rates. Tap Edit to drag them into
order: the form's currency menu offers the main currency, then yours in that
order, then the rest below a divider, so a second currency you use often is one
tap away. Swipe one left to remove it: its current rate is cleared (expenses
already logged keep theirs) and it stays off the list, even if you've spent in
it, until you add it again. The order is stored with the main currency (`currencyOrder`); without
an App Group the share extension can't read it, which matters little there,
since an alert says its own currency.

Totals are always in the main currency. The same screen holds the
current rate for each other currency (1 AED = 22.70 INR); an expense in another
currency takes that rate when it's logged and **keeps it** — changing the rate
later affects only expenses logged afterwards, so past totals never move. The
form shows an expense's rate and can adjust it for that one expense, and each
foreign expense shows what it counted as ("≈ Ð 110.13").

An expense with no rate — logged before one was set — can't be counted, so it's
shown beside the total ("Ð 1,465.12 + ₹2,500.00") rather than guessed at. The
rates screen offers, per currency, to give those older expenses the current
rate; it never changes an expense that already has one. CSV export and import
carry each expense's rate; imported history isn't given today's rate. Rules in
`Shared/CurrencySettings.swift` and `Shared/ExchangeRates.swift`, covered by
`check-store.sh`.

The Money Manager converter reads the main currency from the export's
converted-amount column, which Money Manager names after it.

## The Dirham sign

Amounts in AED show the UAE Dirham sign (U+20C3) rather than "AED". No iOS 27
font has a glyph for it — typed as text it renders as the LastResort
placeholder box — so it's a custom SF Symbol, `Shared/Symbols.xcassets`,
generated from the CC0 artwork on
[Wikimedia Commons](https://commons.wikimedia.org/wiki/File:UAE_Dirham_Symbol.svg)
and scaled to the text cap height. `Formatting.moneyText` interpolates it into
`Text`, so it takes the surrounding font size and colour. The CSV export and
alerts still write "AED". Once iOS fonts include U+20C3, the symbol can give
way to the plain character.

## Known gaps

- SMS are read in English. Banks that send alerts only in Arabic or another
  language aren't understood; Settings → Test message parsing shows what a
  message yields.
- The app's own text is English only.

- No App Intents target, so no fully hands-off Shortcuts automation yet. The
  parser and `TransactionDraft` are the hard part and are already shared, so
  adding one later is a small target, not a rewrite.
- No budgets or recurring transactions. Out of scope by choice.
- The share sheet flow has not been exercised through the UI — the extension is
  built, embedded and registered for text, and everything it does on Save is
  covered by `check-store.sh`, but nobody has yet tapped Share → ExpLog on a
  real message. That's the first thing to try on a device.

## Anonymised fixtures

The test fixtures use a fictional cardholder, banks, merchants and card digits.
Structure is preserved exactly — doubled spaces, truncated merchant names, the
trailing balance amount — because that is what the parser is tested against.
Anonymise the same way when adding a format, so this stays safe to keep public.

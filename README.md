# ExpMgr

Expense logging for iOS, built around one idea: select a bank SMS in Messages,
tap Share, tap ExpMgr, and the expense is logged. No retyping.

## How it works

Two targets and one database:

| Piece | Job |
|---|---|
| `ExpMgr` (app) | Transaction list, monthly totals, editing, cards, categories, CSV export |
| `ShareExtension` | Receives the SMS from the share sheet, parses it, shows a pre-filled form |

From Messages it's: long-press the SMS → Share → ExpMgr → check the form → Save.

### Two ways of saving

Apple restricts **App Groups** — the shared container two targets use to read
one database — to paid Developer Program members. ExpMgr works either way and
picks the route at runtime, in `SharedStore.isAppGroupAvailable`:

| | Paid account | Free Apple ID |
|---|---|---|
| Store | One database in the App Group | The app's own container |
| On Save | Extension writes it directly | Extension opens `expmgr://add?…`, the app saves it |
| App launches? | No | Yes, briefly |
| Card + category prefill | In the form | Applied by the app on receipt |

The free path is `Shared/TransactionLink.swift`. Nothing needs rewriting if you
enroll later — the App Group route switches itself back on.

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

The data layer against a real SwiftData store: card matching, category
learning, duplicate detection, totals — the same path the share extension runs
when you tap Save.

On-device, Settings → Test message parsing does the same as the first one
interactively: paste a message, see exactly which fields were read.

## Learning categories

Saving a transaction with a category records a `MerchantAlias` for that
merchant. The next alert from the same place arrives already categorised. No
training step, no rules to configure — it just gets quieter over time.

## Setup

One-time, after Xcode finishes installing:

```bash
brew install xcodegen
```

```bash
xcodegen generate && open ExpMgr.xcodeproj
```

Then in Xcode:

1. Select the **ExpMgr** target → Signing & Capabilities → pick your team.
2. Do the same for the **ShareExtension** target.

Bundle identifiers are `com.boopeshkumar.expmgr` and `.share`. They only have to
be globally unique — change them in `project.yml` and re-run `xcodegen generate`
if you'd rather use a domain you own. If you change the App Group ID, change it
in all three places: `project.yml` (both targets) and `SharedStore.appGroupID`.

Build and run. Press ⌘R.

### Getting it onto your phone

- **Free Apple ID** — works. The build expires after 7 days and has to be
  re-run from Xcode, and App Groups aren't available, so the extension takes the
  `expmgr://` route described above. Xcode will show an App Group provisioning
  error on the Signing pane; the app still builds and runs, and handles it at
  runtime.
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
  ParsedTransaction.swift Parser output
  TransactionDraft.swift  Editable state, dedupe, alias learning
  SharedStore.swift       App Group SwiftData container
  Models/Models.swift     Transaction, ExpenseCategory, Account, MerchantAlias
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
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project ExpMgr.xcodeproj -scheme ExpMgr -destination 'name=iPhone 17 Pro' CODE_SIGN_IDENTITY='-' build
```

Note `CODE_SIGN_IDENTITY='-'` rather than `CODE_SIGNING_ALLOWED=NO`. Disabling
signing entirely strips entitlements from the binary, so once the App Group is
switched on it silently won't resolve and the app quietly falls back to its own
container — which looks like the share extension saving into a void.

To look at the app with the sample data in it:

```bash
./Tools/seed-demo.sh <simulator-udid>
```

## Known gaps

- No App Intents target, so no fully hands-off Shortcuts automation yet. The
  parser and `TransactionDraft` are the hard part and are already shared, so
  adding one later is a small target, not a rewrite.
- Monthly totals assume a single currency; a mixed-currency month sums the
  numbers and labels them with the first transaction's currency.
- No budgets, recurring transactions, or reports. Out of MVP scope by choice.
- The share sheet flow has not been exercised through the UI — the extension is
  built, embedded and registered for text, and everything it does on Save is
  covered by `check-store.sh`, but nobody has yet tapped Share → ExpMgr on a
  real message. That's the first thing to try on a device.
- On the free-account route, `NSExtensionContext.open` is the documented way for
  an extension to launch its containing app, but it has not been exercised on a
  device here. If iOS refuses it, the form says so rather than failing silently.

## Anonymised fixtures

The test fixtures use a fictional cardholder, banks, merchants and card digits.
Structure is preserved exactly — doubled spaces, truncated merchant names, the
trailing balance amount — because that is what the parser is tested against.
Anonymise the same way when adding a format, so this stays safe to keep public.

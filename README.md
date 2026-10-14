# Bino

Fills web forms and signs in to websites from an encrypted vault on your Mac, clicks
through the pages, stops before anything final (pay, book, submit, create account), and
reports what it was not sure about. Works in Safari, Google Chrome, or the browser pane of
the Claude desktop app. Drive it from its window, from the terminal, or hand the terminal
commands to an AI agent (see [AGENTS.md](AGENTS.md)).

Everything runs on your Mac. The vault is encrypted with a key in the Secure Enclave and
opens with Touch ID. A small local model ([Decider](https://github.com/Mapika/decider),
Apache-2.0) answers "which kind of information does this field want?" with a probability,
which is where the confidence figures come from. No value from the vault is ever sent to
the model, to a report another program reads, or anywhere off this Mac.

## What you need

- A Mac with Touch ID (or a Mac with an Apple Watch or external Touch ID keyboard), macOS 15 or newer.
- Xcode 26 or newer (the free one from the App Store), for the Swift toolchain. Open it once
  so it installs its command line tools.
- Python 3.10 or newer (`python3 --version`; macOS has one, or `brew install python`).
- About 3 GB of disk for the model.

## Set up

```bash
git clone https://github.com/hudson3/bino-fill.git
cd bino-fill
make setup      # Python environment for the model, one time (installs decider-ai with Metal)
make install    # builds bino, puts it on your PATH and Bino.app in Applications
bino doctor     # tells you what is still missing
```

`make setup` installs the model runtime only. The model weights (Decider 4B, ~2.5 GB) are
downloaded from Hugging Face the first time the model loads: the first `bino fill` or
`bino doctor` takes a few minutes on that account. After that it loads in a few seconds.

If `bino` is not found after `make install`, add `~/.local/bin` to your PATH, or use
`/opt/homebrew/bin/bino` if you have Homebrew.

Things only you can do:

1. **Vault**: run `bino vault edit`, paste a note with your details into the left side (the
   whole thing from Notes is fine), fill the fields on the right (or press Auto-sort and
   check every entry), add your logins, then Save. Touch ID protects it from then on.
2. **Safari**: Settings > Advanced > tick "Show features for web developers", then
   Settings > Developer > tick "Allow JavaScript from Apple Events". The first run asks
   permission for your terminal (or Bino.app) to control Safari: allow it.
3. **Chrome** (optional): the first run asks permission to control Chrome: allow it. Also
   switch on your terminal (or Bino.app) in System Settings > Privacy & Security >
   Accessibility, which is how Bino reads a Chrome page.
4. **Claude's browser pane** (optional): the same Accessibility permission.

Optional: the Vault tool's **Auto-sort** button reads your pasted note with a local Ollama
model. `brew install ollama`, then `ollama pull llama3.2`. Without it, fill the fields by hand.

## Use

Open **Bino** from Applications (or run `bino`). The window has two tools: **Fill** (press
Fill with a form open in Safari's front tab, read the report) and **Vault** (what Bino
knows about you).

From the terminal:

| Command | What it does | Touch ID |
|---|---|---|
| `bino fill` | Fill the form in Safari's front tab and click through until the final step | Yes |
| `bino fill --dry-run` | What would be filled, with confidence, nothing typed | No |
| `bino login <site>` | Open the site, type the saved login, press "Sign in" | Yes |
| `bino login <site> --account <name>` | The same with one of several logins saved for the site (a name, part of it, or its number) | Yes |
| `bino signup [<site>]` | Fill a sign-up form with a new strong password and save it in the vault; the create button is left to you | Yes |
| `bino status` | Which site is in the front tab, whether it looks signed in, whether a login is saved for it | No |
| `bino tabs` | The open tabs, to pick one with `--tab` | No |
| `bino report` | The last report again | No |
| `bino vault edit` | Open the vault in the window | Yes |
| `bino vault rename <site> --account <name> --to <new name>` | Rename a saved login | Yes |
| `bino doctor` | Check that everything is in place | No |
| `bino update` | Pull `main`, rebuild, reinstall | No |

`fill`, `login`, `signup`, `status` and `tabs` take `--browser chrome` or `--browser claude`
to work in Google Chrome or the Claude desktop app's browser pane instead of Safari, and
`--tab <part of the address>` (or an id from `bino tabs`) to work in a tab other than the
front one. Every command takes `--json` to print one JSON object for another program.

## What it will and will not do

- Presses only buttons whose wording plainly means "continue" (and "Sign in" after it
  has typed a saved login). Anything that pays, books, orders or submits is never pressed.
  Wording it does not recognise is treated as "do not press".
- Stops on any page with card fields, a captcha, an unanswered question, a required
  field it could not fill, or an error from the site.
- Types a password only on the site saved next to it (or a host that signs people in for
  it, such as idmsa.apple.com for apple.com), and cards, passwords and travel document
  numbers only on https pages. A sign-in frame from any other origin gets nothing.
- Stops at a verification code (`two_factor`, with the keyboard left in the code box),
  a "trust this browser?" screen, a captcha, or a sign-up form. Never types a code.
- Leaves tick boxes, insurance-style questions, new-password fields and anything that
  looks like another person's details (second traveller, emergency contact) to you.
  Only `bino signup` fills new-password fields, with a password it makes and saves, and
  it never presses the button that creates the account.
- Never types your Social Security number. The vault has a slot for it so you can look it
  up, but a field asking for one is always left to you.
- Never sends a value to the model. The model sees field labels and names only.
- Reports hide passwords and security codes entirely and show only the tail of card,
  passport and traveller numbers. The JSON for other programs has no values at all.

Known limits: card boxes embedded from a payment provider cannot be reached (they are
listed in the report), unusual widgets such as seat maps are not handled, choosing from
dropdowns is not yet supported in Chrome or the Claude pane, and the model is English-only.

## How a field is decided

1. If the page declares the field (`autocomplete="given-name"`), that is used.
2. Otherwise fixed rules read the label and the field's name. When they are clear, done.
3. Otherwise the model is asked, and its probability becomes the confidence.
4. High confidence fills quietly, medium fills and lists it under "Check these", low
   leaves it blank and lists it.
5. A field none of that can answer is looked up in your pasted note, by a "label: value"
   line whose label matches the field's wording, and flagged for checking. Passwords never
   come from the note.

## Practice run

A made-up person in a separate vault, against a four-page practice airline booking:

```bash
make practice-vault                 # made-up person, separate from your real vault
make practice                       # serves http://localhost:8765/step1.html
BINO_HOME=.practice-home bino fill  # with that page open in Safari
```

Signing in on the practice site:
`BINO_HOME=.practice-home bino login localhost --url http://localhost:8765/step1.html`
(add `--browser chrome` to watch it in Chrome).

Making an account on the practice site (`--another` because the practice vault already
has a login for localhost):
`BINO_HOME=.practice-home bino signup --another --url http://localhost:8765/signup.html`.

`BINO_HOME` points Bino at a different folder. A vault without Touch ID can only ever
be created in such a folder, never in the real location.

## Layout

| Path | What |
|---|---|
| `Sources/BinoCore/Vault` | Secure Enclave encryption, vault model, note auto-sort, the login index |
| `Sources/BinoCore/Browser` | Safari (Apple Events), Chrome (Apple Events for tabs, accessibility for pages), Claude pane and test-browser drivers, the script that reads a page |
| `Sources/BinoCore/Mapping` | Rules, model client, value formatting, note lookup |
| `Sources/BinoCore/Runner` | Page loop, sign-in, sign-up, button rules, reports |
| `Sources/bino` | Command line and the Bino window (Fill, Vault) |
| `sidecar/` | Local model server |
| `testsite/` | Four-page practice airline booking, and a sign-up page |

## Tests

```bash
make test
```

Covers the safety rules, vault encryption, value formatting, end-to-end fills in an
off-screen WebKit page (including a full practice booking that must stop before "Pay"),
sign-ins (lookalike site, no https, sign-up form, verification code, forms in frames and
shadow DOM, staged Apple-style flows against a fake accessibility tree), sign-ups, tab
selection and account matching. No model, browser or Touch ID needed.

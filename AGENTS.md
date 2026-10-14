# Bino for AI agents

Paste the block below into the instructions of any AI agent that can run shell commands
on your Mac (Claude Code, Grok Bot, Codex, an MCP shell tool, ...). It tells the agent to
use Bino whenever a task needs a form filled or a sign-in, and never to handle your
passwords itself. Replace `<your name>` with what you want to be called.

Bino is installed at `~/.local/bin/bino` (and `/opt/homebrew/bin/bino` when Homebrew is
present). If the agent's shell cannot find `bino`, give it the full path.

```
To fill a web form or sign in to a site for <your name>, use the `bino` command
(~/.local/bin/bino). Never ask for, look up, type or invent their details or passwords
yourself: Bino types the saved values itself and <your name> approves with Touch ID.

Every command takes --json and prints exactly one JSON object on standard output
(progress goes to standard error). The JSON never contains a username, password or any
other vault value. Exit code 0 unless the command could not run ("ok": false, "error").

WHICH BROWSER
Safari is the default. Add --browser chrome for Google Chrome: Bino lists every tab in
every Chrome window (minimized, other desktops, tab groups), brings the one it needs on
screen itself, and opens the site in a new Chrome tab when needed. Add --browser claude
for the Claude desktop app's own browser pane: Bino cannot open pages there, so navigate
the pane to the sign-in page first and keep it as the active tab.
Always pass --tab <part of the page's address> (for example --tab apply.example.com) to
fill, signup, login and status, so Bino works in the right tab even when another is in
front. If it answers that no tab or several tabs match, run
bino tabs --browser <browser> --json and pass the "tab" id (for Chrome, "tab_id" works too).

COMMANDS (no Touch ID unless marked)
- bino status --tab <site> --json
    "browser" describes the tab: site, address, title, signed_in (true / false / unknown)
    and signed_in_by. saved_login is yes / no / unknown (unknown: the vault has not been
    unlocked yet; just try). accounts lists the names of the logins saved for the site.
    Add --site <host> to ask about a site no tab is on.
- bino tabs --json                     the open tabs (--browser chrome / claude too)
- bino fill --dry-run --tab <site> --json
    preview what would be filled, with confidence
- bino fill --tab <site> --json        [Touch ID] fill the form and click through, stopping
    before anything final. Add --account <name> when the form has a sign-in and several
    logins are saved for the site.
- bino login <host> --tab <host> --json   [Touch ID] sign in with the saved login.
    Give the host you actually want (appstoreconnect.apple.com), even when the login is
    saved for its parent domain (apple.com). Bino opens that host or uses the tab already
    on it, follows a "Sign in" link from a front page, types the username and password
    only on that site (or a host that signs people in for it) over https, including into
    a sign-in frame from another origin, presses Sign in, goes on to the password step
    when the site asks for the username first, and stops. --url <address on the same
    site> starts on a specific page.
    Several logins on one site: a login without a choice stops with reason which_account
    and stopped.accounts, typing nothing. Pick the one the task is about, or ask, then add
    --account <name>: the name, a part of it, or its number (1, 2). Names, never usernames.
- bino signup [<site>] --tab <site> --json   [Touch ID] fill the sign-up form in the tab:
    makes a strong password, saves it in the vault, types it, presses nothing. --url
    <sign-up page> opens it first, --username <name> asks for a username, --dry-run
    previews. You are never shown the password.
- bino report --json                   the last result again
- bino vault rename <site> --account <name> --to <new name> --json   [Touch ID] rename a
    saved login. Only if asked.

READ stopped.reason AFTER EVERY RUN and tell <your name> what is left:
- sign_in_pressed: signed in, carry on (sign_in_form_still_showing says if it did not take).
- two_factor: the site wants a code from a text, app or email. The code box already has
  the keyboard. <your name> types it. NEVER type a code.
- trust_prompt: "Trust this browser?" / "Stay signed in?" is showing. Their choice.
- already_signed_in: the page was past sign-in; nothing was typed. Carry on.
- which_account: choose an account as above.
- form_in_frame: the sign-in form is in a frame from stopped.origin that Bino could not
  read. Nothing was typed. Say so; do not type the password yourself.
- no_sign_in_form: open the site's login page and run again with --url.
- captcha, needs_you: <your name> does that step (stopped.fields names the boxes).
- password_withheld, or a refusal with no Touch ID prompt: no login is saved for the site
  (or the page is not that site / not https). Do not ask for the password. Ask <your name>
  to add it in Bino's Vault tool, or use bino signup if they have no account there yet.
- final_step: the form is filled up to the final button (stopped.button). Never press it.
- payment_page: stopped on a payment page. Leave it.
- sign_up_ready: the sign-up form is filled and the password saved; tell <your name> to
  tick anything in stopped.fields and press stopped.button themselves.
- page_errors, page_did_not_change, no_way_forward: report stopped.message.

WHAT YOU GET BACK
For each field: its label, the kind of information Bino judged it to want, the
confidence, whether it was filled, flagged or left, and "frame" (the host of the embedded
frame it sits in, when it does). "check" is the short list a person should look over.
Each page of a login carries "stage" (username, password, two_factor, trust_prompt,
signed_in). "report_file" is the full report with values, on the Mac, for <your name> to
read; you do not read it.

Bino stops before anything final (pay, book, submit, create account). Do not press those
buttons yourself either. Never make up or type a password.
```

# opencode-session-rescue

Single-file, double-click rescue for opencode sessions dying with:

> `Error from provider (Console): Upstream request failed: [invalid_request_error]`
> `reasoning 'encrypted_content' was not issued to this caller`

## The problem

opencode stores each assistant turn's thinking together with the provider's
encrypted signature, and replays that stored history on every follow-up prompt.
Those signatures are caller/endpoint-bound: once the upstream side rotates
(key, endpoint, failover), the stored signature stops verifying.

The poison lives in your session history, so **every further prompt in that
session fails identically** — while brand-new sessions work fine. Restarting
the terminal or the app changes nothing; the database still holds the stale
signatures.

## The fix

`Fix-EncryptedContent-Standalone.bat` is a batch/Python polyglot (double-click
it on Windows, or `python3 Fix-EncryptedContent-Standalone.bat` anywhere).
It:

1. **Backs up** `opencode.db` (+ WAL sidecars) and session storage to a
   timestamped folder — nothing is ever deleted.
2. Asks the installed CLI itself where its database lives (`opencode db path`),
   so it repairs the *live* store, not a guessed folder.
3. Removes **only** the stale signature/encrypted blobs from stored
   reasoning/thinking parts (`reasoning`, `thinking`, `redacted_thinking`,
   metadata subtrees, reasoning item ids).
4. Keeps **verbatim**: messages, thinking text, tool calls + results, file
   edits, todos.
5. Re-scans afterwards and reports any suspicious leftovers instead of
   claiming "clean".

Works on **stock opencode and forks** — pick `[1]` stock, `[2]` another
command (e.g. `victor`), or `[3]` paste a data folder directly. Handles
SQLite stores plus file-based `.json` / `.jsonl` session stores.
Python standard library only — nothing to install.

## Usage

1. **Close opencode** (TUI + any workers) — the DB may be locked otherwise.
2. Double-click `Fix-EncryptedContent-Standalone.bat`, pick the target.
3. Restart opencode and resume the old session.

Terminal use:

```bat
Fix-EncryptedContent-Portable.bat --bin victor --no-pause
Fix-EncryptedContent-Portable.bat --dir "D:\path\to\data-dir"
Repeat once per install — stock and forks keep separate stores. A run log
(Fix-EncryptedContent-LOG-*.txt) lands on your Desktop.

# 2>nul & @echo off & title Fix-EncryptedContent - rescue opencode sessions & where py >nul 2>nul & if errorlevel 1 (python "%~f0" %*) else (py -3 "%~f0" %*) & echo. & pause & exit /b
#!/usr/bin/env python3
"""
Fix-EncryptedContent v3 single-file: rescue opencode AND modified-opencode
sessions poisoned by stale reasoning signatures.

This file is a batch/Python polyglot: double-click it on Windows and the first
line hands the whole file to Python; `python3 file.bat` also works anywhere.

Error fixed:
  Error from provider (Console): Upstream request failed: [invalid_request_error]
  reasoning `encrypted_content` was not issued to this caller

Menu on double-click (no arguments needed) - two options:
  [1] opencode sessions  (STABLE - proven fix)
  [2] Bosun workers      (UNSTABLE - early development)

Direct use:
  Fix-EncryptedContent-Portable.bat --bosun
  Fix-EncryptedContent-Portable.bat --bin victor
  Fix-EncryptedContent-Portable.bat --dir "D:\\path\\to\\data-dir"

Safety: timestamped backup of DB + storage first. Nothing deleted. Stdlib only.
Quit the target app (TUI + workers) before running.
"""

import argparse
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
from datetime import datetime

APP = "Fix-EncryptedContent v4 session-locator"

# Key names carrying caller-bound secrets. Removed ONLY inside reasoning/thinking
# carriers or metadata subtrees - never part/message linkage, never tool data.
SIG_KEY_RE = re.compile(r"signature|encrypted|item_?id|reasoning.?encrypted", re.IGNORECASE)

# Dict types that carry model thinking in any opencode storage shape.
THINK_TYPES = {"reasoning", "thinking", "redacted_thinking", "reasoning_content"}

# Subtree names holding provider metadata (matched case-insensitively).
META_KEYS = {"metadata", "providermetadata", "provideroptions"}

# Linkage / payload keys that must NEVER be deleted even inside carriers.
KEEP_KEYS = {"id", "messageid", "message_id", "sessionid", "session_id",
             "callid", "call_id", "toolcallid", "tool_call_id", "text",
             "thinking", "time", "type", "tool", "input", "output"}

# Broad prefilter: any cell/file containing these MIGHT hold the poison.
PREFILTER_WORDS = ("reasoning", "thinking", "redacted", "signature",
                   "encrypted_content", "encryptedcontent", "providermetadata")

FILE_STORE_SUBDIRS = (
    os.path.join("storage", "part"),
    os.path.join("storage", "parts"),
    os.path.join("storage", "message"),
    os.path.join("storage", "messages"),
    os.path.join("storage", "session"),
    os.path.join("storage", "sessions"),
    "parts",
    "messages",
    "sessions",
    "session",
)

LOG_LINES = []


def log(msg=""):
    print(msg, flush=True)
    LOG_LINES.append(msg)


def pause_exit():
    try:
        if sys.stdin.isatty():
            input("  Press ENTER to close... ")
    except (EOFError, KeyboardInterrupt):
        pass


def run_quiet(cmd, timeout=20):
    # NOTE: decode with errors="replace" - some CLIs (e.g. `bosun`, a .CMD
    # shim) emit non-UTF8 bytes on stdout, which used to crash the reader
    # thread with UnicodeDecodeError instead of just yielding no output.
    try:
        proc = subprocess.run(cmd, capture_output=True, timeout=timeout)
        return proc.stdout.decode("utf-8", errors="replace").strip()
    except Exception:
        return ""


def candidate_data_dirs(extra_names=()):
    home = os.path.expanduser("~")
    names = ["opencode"] + [n for n in extra_names if n and n.lower() != "opencode"]
    dirs = []
    xdg = os.environ.get("XDG_DATA_HOME", "")
    if xdg:
        for n in names:
            dirs.append(os.path.join(xdg, n))
    for n in names:
        dirs.append(os.path.join(home, ".local", "share", n))
    for n in names:
        dirs.append(os.path.join(home, "." + n))
    for env in ("LOCALAPPDATA", "APPDATA"):
        base = os.environ.get(env, "")
        if base:
            for n in names:
                dirs.append(os.path.join(base, n))
            for n in names:
                dirs.append(os.path.join(base, n[:1].upper() + n[1:]))
    seen, out = set(), []
    for c in dirs:
        c = os.path.normpath(c)
        if c not in seen:
            seen.add(c)
            out.append(c)
    return out


def resolve_bin(name):
    return shutil.which(name) or shutil.which(name + ".exe")


def true_data_dir(bin_name="opencode", forced_dir=None):
    """Locate the live session DB for a given CLI command (or explicit dir)."""
    if forced_dir:
        d = os.path.normpath(os.path.expandvars(os.path.expanduser(forced_dir.strip('" '))))
        if os.path.isfile(os.path.join(d, "opencode.db")):
            return d, "explicit-dir(db)"
        if os.path.isdir(d):
            return d, "explicit-dir(stores)"
        log("  [ERROR] not a usable data dir: %s" % forced_dir)
        return None, "none"
    exe = resolve_bin(bin_name)
    extra = [] if bin_name.lower() == "opencode" else [bin_name.lower()]
    if exe:
        log("  CLI command: %s" % exe)
        out = run_quiet([exe, "db", "path"])
        if out:
            first = out.splitlines()[0].strip().strip('"').strip("'")
            if os.path.isfile(first):
                log("  CLI reports DB: %s" % first)
                return os.path.dirname(first), "cli"
            if os.path.isdir(first):
                if os.path.isfile(os.path.join(first, "opencode.db")):
                    log("  CLI reports dir: %s" % first)
                    return first, "cli"
            log("  (`%s db path` gave unusable output: %.100s)" % (bin_name, out))
        else:
            log("  (`%s db path` gave no output - fork may not support it)" % bin_name)
    else:
        log("  (command `%s` not on PATH - searching known locations)" % bin_name)
    for d in candidate_data_dirs(extra):
        if os.path.isfile(os.path.join(d, "opencode.db")):
            log("  Found DB by search: %s" % os.path.join(d, "opencode.db"))
            return d, "search"
    return None, "none"


def session_store_roots(extra_dir=None):
    """Everywhere local session content may live (for byte-level search)."""
    roots = []
    for d in candidate_data_dirs():
        if os.path.isdir(d):
            roots.append(d)
    appdata = os.environ.get("APPDATA", "")
    desk = os.path.join(appdata, "ai.opencode.desktop") if appdata else ""
    if desk and os.path.isdir(desk):
        roots.append(desk)
    code = os.path.join(appdata, "Code", "User") if appdata else ""
    for sub in ("workspaceStorage", "globalStorage"):
        p = os.path.join(code, sub)
        if code and os.path.isdir(p):
            roots.append(p)
    if extra_dir:
        extra_dir = os.path.normpath(os.path.expandvars(os.path.expanduser(extra_dir.strip('" '))))
        if os.path.isdir(extra_dir) and extra_dir not in roots:
            roots.append(extra_dir)
    return roots


def iter_session_files(roots):
    """Yield bounded candidate files: .db*, .dat, .vscdb, session json(l)."""
    seen = set()
    for root in roots:
        for dirpath, dirnames, filenames in os.walk(root):
            low = os.path.basename(dirpath).lower()
            if low in ("cache", "cacheddata", "gpu-cache", "dawncache",
                       "blob_storage", "node_modules", "logs", "crashpad"):
                dirnames[:] = []
                continue
            dirnames[:] = [d for d in dirnames if d.lower() != "node_modules"]
            for name in filenames:
                ln = name.lower()
                keep = (ln.startswith("opencode.db") or ln.endswith(".dat")
                        or ln.endswith(".vscdb")
                        or (ln.endswith(".json") and ("ses_" in ln or "session" in ln))
                        or ln.endswith(".jsonl"))
                if not keep:
                    continue
                p = os.path.join(dirpath, name)
                if p in seen:
                    continue
                seen.add(p)
                try:
                    if os.path.getsize(p) > 300 * 1024 * 1024:
                        continue
                except Exception:
                    continue
                yield p


def locate_session(ses_id, roots):
    """Byte-level search for a session id across candidate stores."""
    needle = ses_id.encode("utf-8", errors="replace")
    found, scanned = [], 0
    for path in iter_session_files(roots):
        scanned += 1
        try:
            with open(path, "rb") as fh:
                tail = b""
                while True:
                    chunk = fh.read(1 << 20)
                    if not chunk:
                        break
                    if needle in tail + chunk:
                        found.append(path)
                        break
                    tail = (tail + chunk)[-256:]
        except Exception:
            continue
    return found, scanned


def backup_db_file(db_path, ts):
    """Back up one database file (+ WAL/SHM sidecars) to a sibling folder."""
    dest = db_path + "-rescue-backup-" + ts
    os.makedirs(dest, exist_ok=True)
    copied = []
    for suffix in ("", "-wal", "-shm", "-journal"):
        src = db_path + suffix
        if os.path.isfile(src):
            shutil.copy2(src, os.path.join(dest, os.path.basename(src)))
            copied.append(os.path.basename(src))
    return dest, copied


def locate_and_fix(ses_id, extra_dir=None):
    """Find which local store owns a session id, then sanitize that store."""
    if not ses_id:
        log("  No session id given - nothing to do.")
        return 1
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    roots = session_store_roots(extra_dir)
    log("  Searching %d store location(s) for %s ..." % (len(roots), ses_id))
    for r in roots:
        log("    - %s" % r)
    found, scanned = locate_session(ses_id, roots)
    log("  Scanned %d file(s)." % scanned)
    if not found:
        log("  NOT FOUND in any local store. The session may live server-side")
        log("  (synced/cloud session) - paste this log to your assistant.")
        return 1
    log("  Session lives in:")
    for f in found:
        log("    - %s" % f)
    log("")
    for f in found:
        fl = f.lower()
        if fl.endswith(".db") or fl.endswith(".vscdb"):
            dest, copied = backup_db_file(f, ts)
            log("  Backup -> %s (%s)" % (dest, ", ".join(copied)))
            try:
                st = sanitize_db(f)
            except sqlite3.OperationalError as exc:
                log("  [ERROR] database is locked (%s). Close the app, re-run." % exc)
                return 1
            log("  rows updated: %d, carriers fixed: %d" % (
                st["rows_updated"], st["carriers_scrubbed"]))
            if st["residue"]:
                log("  LEFTOVER keys (paste to your assistant):")
                for r in st["residue"][:20]:
                    log("    - %s" % r)
            if st["rows_updated"] == 0 and not st["residue"]:
                log("  (no poison shapes in this store - history here is clean)")
        elif fl.endswith(".json") or fl.endswith(".jsonl"):
            dest, copied = backup_db_file(f, ts)
            log("  Backup -> %s" % dest)
            res = scrub_json_file(f)
            log("  file fixed: %s" % bool(isinstance(res, tuple) and res[0]))
        else:
            log("  %s : binary app-internal format - cannot safely edit." % f)
            log("  Paste this path to your assistant for the manual step.")
    return 0


def target_running(exe_names):
    """Best-effort check for running CLI processes (Windows tasklist)."""
    try:
        out = subprocess.run(["tasklist", "/NH"], capture_output=True,
                             text=True, timeout=15).stdout.lower() or ""
    except Exception:
        return None
    return [n for n in exe_names if (n.lower() + ".exe") in out]


def scrub_sig_tree(node):
    """Delete signature/encrypted keys inside a metadata subtree. Returns True if changed."""
    changed = False
    if isinstance(node, dict):
        for key in list(node.keys()):
            if SIG_KEY_RE.search(key) and key.lower() not in KEEP_KEYS:
                del node[key]
                changed = True
            elif scrub_sig_tree(node[key]):
                changed = True
    elif isinstance(node, list):
        for item in node:
            if scrub_sig_tree(item):
                changed = True
    return changed


def scrub_node(node):
    """Scrub poison anywhere in session JSON. Returns True if anything removed."""
    changed = False
    if isinstance(node, dict):
        ntype = str(node.get("type", "")).lower()
        if ntype in THINK_TYPES:
            for key in list(node.keys()):
                if key.lower() in META_KEYS and isinstance(node[key], dict):
                    if scrub_sig_tree(node[key]):
                        changed = True
                    if not node[key]:
                        del node[key]
                        changed = True
            for key in list(node.keys()):
                if (key.lower() not in KEEP_KEYS and key.lower() not in META_KEYS
                        and SIG_KEY_RE.search(key)):
                    del node[key]
                    changed = True
        else:
            for key in list(node.keys()):
                val = node[key]
                if key.lower() in META_KEYS and isinstance(val, dict):
                    if scrub_sig_tree(val):
                        changed = True
                    if not val:
                        del node[key]
                        changed = True
                elif scrub_node(val):
                    changed = True
    elif isinstance(node, list):
        for item in node:
            if scrub_node(item):
                changed = True
    return changed


def find_residue(node, hits, path=""):
    """Collect paths of remaining signature-ish keys (leftover report only)."""
    if isinstance(node, dict):
        ntype = str(node.get("type", "")).lower()
        in_carrier = ntype in THINK_TYPES
        for key, val in node.items():
            kl = key.lower()
            if (SIG_KEY_RE.search(key) and kl not in KEEP_KEYS
                    and (in_carrier or kl in META_KEYS or isinstance(val, (dict, list)))):
                preview = json.dumps(val, ensure_ascii=False)[:80]
                if len(json.dumps(val, ensure_ascii=False)) > 80:
                    preview += "..."
                hits.append("%s.%s = %s" % (path or "$", key, preview))
            find_residue(val, hits, "%s.%s" % (path or "$", key))
    elif isinstance(node, list):
        for i, item in enumerate(node[:50]):
            find_residue(item, hits, "%s[%d]" % (path or "$", i))


def has_prefilter(text):
    low = text.lower()
    return any(w in low for w in PREFILTER_WORDS)


def collect_session_ids(node, acc):
    if isinstance(node, dict):
        for key in ("sessionID", "session_id", "sessionId"):
            val = node.get(key)
            if isinstance(val, str) and val:
                acc.add(val)
        for value in node.values():
            collect_session_ids(value, acc)
    elif isinstance(node, list):
        for item in node:
            collect_session_ids(item, acc)


def backup_data_dir(datadir, ts):
    dest = datadir + "-rescue-backup-" + ts
    os.makedirs(dest, exist_ok=True)
    copied = []
    for name in ("opencode.db", "opencode.db-wal", "opencode.db-shm",
                 "opencode.db-journal", "auth.json"):
        src = os.path.join(datadir, name)
        if os.path.isfile(src):
            shutil.copy2(src, os.path.join(dest, name))
            copied.append(name)
    src = os.path.join(datadir, "storage")
    if os.path.isdir(src):
        shutil.copytree(src, os.path.join(dest, "storage"),
                        ignore=shutil.ignore_patterns("snapshot"),
                        dirs_exist_ok=True)
        copied.append("storage/ (without snapshot/)")
    return dest, copied


def list_tables(con):
    return [r[0] for r in con.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")]


def sanitize_db(db_path):
    stats = {"tables_scanned": 0, "cells_scanned": 0, "rows_updated": 0,
             "carriers_scrubbed": 0, "sessions": set(), "skipped": [],
             "residue": []}
    con = sqlite3.connect(db_path, timeout=60)
    try:
        log("  Tables: %s" % ", ".join(list_tables(con)))
        for table in list_tables(con):
            try:
                cols = [(r[1], (r[2] or "").upper()) for r in
                        con.execute('PRAGMA table_info("%s")' % table.replace('"', '""'))]
            except Exception as exc:
                stats["skipped"].append("%s (pragma: %s)" % (table, exc))
                continue
            text_cols = [c for c, t in cols if ("CHAR" in t or "TEXT" in t
                                                or "CLOB" in t or "JSON" in t or t == "")]
            if not text_cols:
                continue
            try:
                sql = (con.execute("SELECT sql FROM sqlite_master WHERE name=?",
                                   (table,)).fetchone()[0] or "").upper()
            except Exception:
                sql = ""
            has_rowid = "WITHOUT ROWID" not in sql
            stats["tables_scanned"] += 1
            likes = []
            for c in text_cols:
                q = '"%s"' % c.replace('"', '""')
                likes.append("%s LIKE '%%reasoning%%'" % q)
                likes.append("%s LIKE '%%thinking%%'" % q)
                likes.append("%s LIKE '%%signature%%'" % q)
                likes.append("%s LIKE '%%encrypted%%'" % q)
            sel = (["rowid"] if has_rowid else []) + ['"%s"' % c.replace('"', '""')
                                                      for c in text_cols]
            try:
                cur = con.execute('SELECT %s FROM "%s" WHERE %s' % (
                    ", ".join(sel), table.replace('"', '""'), " OR ".join(likes)))
            except Exception as exc:
                stats["skipped"].append("%s (scan: %s)" % (table, exc))
                continue
            for row in cur.fetchall():
                for idx, col in enumerate(text_cols, start=1 if has_rowid else 0):
                    val = row[idx]
                    if not isinstance(val, str) or not has_prefilter(val):
                        continue
                    stats["cells_scanned"] += 1
                    try:
                        doc = json.loads(val)
                    except Exception:
                        continue
                    before = json.dumps(doc, sort_keys=True)
                    carriers = sum(before.count('"%s"' % t) for t in
                                   ('"type": "reasoning"', '"type": "thinking"',
                                    '"type": "redacted_thinking"'))
                    if not scrub_node(doc):
                        continue
                    if has_rowid:
                        con.execute('UPDATE "%s" SET "%s"=? WHERE rowid=?' % (
                            table.replace('"', '""'), col.replace('"', '""')),
                            (json.dumps(doc, ensure_ascii=False), row[0]))
                        stats["rows_updated"] += 1
                    stats["carriers_scrubbed"] += carriers
                    collect_session_ids(doc, stats["sessions"])
        con.commit()
        for table in list_tables(con):
            try:
                cols = [r[1] for r in con.execute(
                    'PRAGMA table_info("%s")' % table.replace('"', '""'))]
            except Exception:
                continue
            if not cols:
                continue
            likes = []
            for c in cols:
                q = '"%s"' % c.replace('"', '""')
                likes.append("%s LIKE '%%signature%%'" % q)
                likes.append("%s LIKE '%%encrypted_content%%'" % q)
            try:
                cur = con.execute('SELECT rowid, %s FROM "%s" WHERE %s LIMIT 20' % (
                    ", ".join('"%s"' % c.replace('"', '""') for c in cols),
                    table.replace('"', '""'), " OR ".join(likes)))
            except Exception:
                continue
            for row in cur.fetchall():
                for val in row[1:]:
                    if not isinstance(val, str) or not has_prefilter(val):
                        continue
                    try:
                        doc = json.loads(val)
                    except Exception:
                        continue
                    hits = []
                    find_residue(doc, hits)
                    for h in hits[:5]:
                        stats["residue"].append("%s rowid=%s :: %s" % (table, row[0], h))
        try:
            con.execute("PRAGMA integrity_check")
        except Exception:
            pass
        if stats["rows_updated"]:
            try:
                con.execute("VACUUM")
            except Exception:
                pass
    finally:
        con.close()
    return stats


def scrub_json_file(path):
    """Scrub one .json / .jsonl session file in place. Returns (changed, sessions)."""
    try:
        with open(path, "r", encoding="utf-8") as fh:
            text = fh.read()
    except Exception:
        return False
    if not has_prefilter(text):
        return False
    if path.endswith(".jsonl"):
        lines = text.splitlines()
        changed_any = False
        out = []
        for line in lines:
            if not line.strip():
                out.append(line)
                continue
            try:
                doc = json.loads(line)
            except Exception:
                out.append(line)
                continue
            if scrub_node(doc):
                changed_any = True
                out.append(json.dumps(doc, ensure_ascii=False))
            else:
                out.append(line)
        if not changed_any:
            return False
        sessions = set()
        for line in out:
            try:
                collect_session_ids(json.loads(line), sessions)
            except Exception:
                pass
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("\n".join(out) + ("\n" if text.endswith("\n") else ""))
        return (True, sessions)
    try:
        doc = json.loads(text)
    except Exception:
        return False
    if not scrub_node(doc):
        return False
    sessions = set()
    collect_session_ids(doc, sessions)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, ensure_ascii=False, indent=2)
    return (True, sessions)


def sanitize_file_stores(datadir):
    stats = {"files_scanned": 0, "files_updated": 0, "sessions": set()}
    for sub in FILE_STORE_SUBDIRS:
        root = os.path.join(datadir, sub)
        if not os.path.isdir(root):
            continue
        for dirpath, _d, filenames in os.walk(root):
            for name in filenames:
                if not (name.endswith(".json") or name.endswith(".jsonl")):
                    continue
                stats["files_scanned"] += 1
                res = scrub_json_file(os.path.join(dirpath, name))
                if isinstance(res, tuple) and res[0]:
                    stats["files_updated"] += 1
                    stats["sessions"] |= res[1]
    return stats


def ask_menu():
    print("  What are we fixing today?")
    print("    [1] opencode sessions  (STABLE - proven fix)")
    print("    [2] Bosun workers      (UNSTABLE - early development)")
    try:
        choice = input("  Choice [1/2, Enter=1]: ").strip() or "1"
    except (EOFError, KeyboardInterrupt):
        return ("opencode", None)
    if choice == "2":
        return ("__bosun__", None)
    print("")
    print("  opencode target:")
    print("    [1] Stock opencode store  (default)")
    print("    [2] A data folder directly")
    print("    [3] Find where a session lives (still fails after cleaning)")
    try:
        sub = input("  Choice [1/2/3, Enter=1]: ").strip() or "1"
    except (EOFError, KeyboardInterrupt):
        return ("opencode", None)
    if sub == "3":
        try:
            sid = input("  Session id (e.g. ses_...): ").strip()
        except (EOFError, KeyboardInterrupt):
            sid = ""
        return ("__locate__", sid or None)
    if sub == "2":
        try:
            folder = input("  Data folder path: ").strip()
        except (EOFError, KeyboardInterrupt):
            folder = ""
        return ("opencode", folder or None)
    return ("opencode", None)


def bosun_flow():
    """Option 2: Bosun worker path. Status: UNSTABLE / early development.

    Workers spawn fresh `opencode run` sessions on every delegation and inherit
    the Captain's environment (no data-root redirect - verified in
    bosun/worker/run-worker.ts), so they share the stock session store and
    usually have nothing stored to scrub. This flow cleans the shared store,
    then hands over the 2-minute verification that actually decides the case.
    """
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    log("=" * 70)
    log("  OPTION 2: Bosun workers  (UNSTABLE - early development)")
    log("=" * 70)
    log("  Workers share the stock opencode session store, and fresh worker")
    log("  runs have no stored history - so scrubbing rarely applies to them.")
    log("  The verification at the end is the real test.")
    log("")
    running = target_running(["opencode", "bosun"])
    if running:
        log("  [!] Running: %s - close TUI/workers first (DB may lock)." % ", ".join(running))
        try:
            input("      Press ENTER once closed (Ctrl+C to abort)... ")
        except KeyboardInterrupt:
            log("Aborted - nothing was changed.")
            return 1
        log("")
    datadir, how = true_data_dir("opencode")
    if not datadir:
        log("  [ERROR] shared store not found - nothing to scrub.")
    else:
        log("  Shared store (%s): %s" % (how, datadir))
        dest, copied = backup_data_dir(datadir, ts)
        log("  Backup -> %s" % dest)
        db_path = os.path.join(datadir, "opencode.db")
        if os.path.isfile(db_path):
            try:
                st = sanitize_db(db_path)
            except sqlite3.OperationalError as exc:
                log("  [ERROR] database is locked (%s). Close apps, re-run." % exc)
                return 1
            log("  rows updated: %d, carriers fixed: %d" % (
                st["rows_updated"], st["carriers_scrubbed"]))
        fst = sanitize_file_stores(datadir)
        log("  files updated: %d" % fst["files_updated"])
    log("")
    log("  VERIFY (2 minutes, decides the case):")
    log("    1. Re-delegate ONE trivial task (e.g. append a marker line in a")
    log("       disposable workspace, then re-read it).")
    log("    2. GREEN -> incident over for workers. Nothing more to do.")
    log("    3. RED with the same encrypted_content error -> rotation is still")
    log("       happening mid-run. Paste the worker stderr; the fallback is a")
    log("       non-thinking worker model (nothing signable, nothing to stale).")
    log("  NOTE: failed attempts are one-shot runs - just re-delegate; their")
    log("  transcripts under .bosun/delegations were never touched.")
    return 0


def main():
    ap = argparse.ArgumentParser(prog="Fix-EncryptedContent-Portable.bat")
    ap.add_argument("--bin", default=None,
                    help="CLI command of the install to repair")
    ap.add_argument("--dir", default=None,
                    help="Data directory to repair directly")
    ap.add_argument("--find-session", default=None,
                    help="Locate which local store owns a session id, then fix it")
    ap.add_argument("--bosun", action="store_true",
                    help="Bosun worker path (UNSTABLE - early development)")
    ap.add_argument("--no-pause", action="store_true",
                    help="Do not wait for ENTER at the end (terminal use)")
    args = ap.parse_args()

    no_pause = args.no_pause
    if args.find_session:
        code = locate_and_fix(args.find_session, args.dir)
        if not no_pause:
            pause_exit()
        try:
            log_path = os.path.join(os.path.expanduser("~"), "Desktop",
                                    "Fix-EncryptedContent-LOG-%s.txt"
                                    % datetime.now().strftime("%Y%m%d-%H%M%S"))
            with open(log_path, "w", encoding="utf-8") as fh:
                fh.write("\n".join(LOG_LINES))
            print("\n  Log saved: %s" % log_path)
        except Exception:
            pass
        return code
    if args.bin is None and args.dir is None:
        if sys.stdin.isatty():
            args.bin, args.dir = ask_menu()
            if args.dir is None and args.bin is None:
                args.bin = "opencode"
        else:
            args.bin = "opencode"
    if args.bin == "__locate__":
        code = locate_and_fix(args.dir)
        if not no_pause:
            pause_exit()
        return code
    if args.bosun or args.bin == "__bosun__":
        code = bosun_flow()
        try:
            log_path = os.path.join(os.path.expanduser("~"), "Desktop",
                                    "Fix-EncryptedContent-LOG-%s.txt"
                                    % datetime.now().strftime("%Y%m%d-%H%M%S"))
            with open(log_path, "w", encoding="utf-8") as fh:
                fh.write("\n".join(LOG_LINES))
            print("")
            print("  Log saved: %s" % log_path)
        except Exception:
            pass
        if not no_pause:
            pause_exit()
        return code
    if args.bin is None:
        args.bin = "opencode"

    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    log("=" * 70)
    log("  %s  (%s)" % (APP, ts))
    log("  Target: %s" % (("folder " + args.dir) if args.dir
                           else ("command `" + args.bin + "`")))
    log("=" * 70)
    log("")

    watch = [w for w in ((["opencode", args.bin] if not args.dir else [args.bin])) if w]
    running = target_running(dict.fromkeys([w.lower() for w in watch]))
    if running:
        log("  [!] These look RUNNING: %s" % ", ".join(running))
        log("      Close the app and any workers first - the DB may be locked")
        log("      and new poison can be written mid-fix.")
        log("")
        try:
            input("      Press ENTER once closed (Ctrl+C to abort)... ")
        except KeyboardInterrupt:
            log("Aborted - nothing was changed.")
            return 1
        log("")

    datadir, how = true_data_dir(args.bin, args.dir)
    if not datadir:
        log("  [ERROR] No session database found.")
        if not args.dir:
            log("  If this fork keeps sessions elsewhere, re-run with:")
            log('    Fix-EncryptedContent-Standalone.bat --dir "D:\\path\\to\\data-dir"')
        return 1
    log("  Using data dir (%s): %s" % (how, datadir))
    log("")

    dest, copied = backup_data_dir(datadir, ts)
    log("  Backup -> %s" % dest)
    log("  Backed up: %s" % (", ".join(copied) if copied else "(no DB/storage found?)"))
    log("")

    sessions = set()
    total_rows = total_files = total_carriers = 0
    residue = []
    db_path = os.path.join(datadir, "opencode.db")
    if os.path.isfile(db_path):
        log("  Scanning session database...")
        try:
            st = sanitize_db(db_path)
        except sqlite3.OperationalError as exc:
            log("  [ERROR] database is locked (%s)." % exc)
            log("  Close the app fully and run again. Backup kept at:")
            log("    %s" % dest)
            return 1
        log("    tables scanned : %d" % st["tables_scanned"])
        log("    rows updated   : %d" % st["rows_updated"])
        log("    carriers fixed : %d" % st["carriers_scrubbed"])
        for s in st["skipped"]:
            log("    skipped: %s" % s)
        total_rows = st["rows_updated"]
        total_carriers = st["carriers_scrubbed"]
        sessions |= st["sessions"]
        residue = st["residue"]
        log("")

    log("  Scanning file-based session stores (.json/.jsonl)...")
    fst = sanitize_file_stores(datadir)
    log("    files updated  : %d" % fst["files_updated"])
    total_files = fst["files_updated"]
    sessions |= fst["sessions"]
    log("")
    log("=" * 70)
    if total_rows == 0 and total_files == 0:
        log("  No stale signatures found for this target - its sessions are clean.")
    else:
        log("  FIXED: %d DB row(s) + %d file(s), %d carriers scrubbed." % (
            total_rows, total_files, total_carriers))
        if sessions:
            log("  Sessions touched (%d):" % len(sessions))
            for s in sorted(sessions)[:25]:
                log("    - %s" % s)
        log("")
        log("  Kept verbatim: messages, thinking TEXT, tool calls + results,")
        log("  file edits, todos. Only stale encrypted blobs were removed.")
    if residue:
        log("")
        log("  LEFTOVER suspicious keys (paste these to your assistant):")
        for r in residue[:20]:
            log("    - %s" % r)
    log("")
    log("  Backup: %s" % dest)
    log("  Next: restart the app, resume the old session. Repeat per install")
    log("  (stock opencode AND each modified one) - they keep separate stores.")
    log("=" * 70)

    try:
        log_path = os.path.join(os.path.expanduser("~"), "Desktop",
                                "Fix-EncryptedContent-LOG-%s.txt" % ts)
        with open(log_path, "w", encoding="utf-8") as fh:
            fh.write("\n".join(LOG_LINES))
        log("")
        log("  Log saved: %s" % log_path)
    except Exception:
        pass
    if not no_pause:
        pause_exit()
    return 0


if __name__ == "__main__":
    sys.exit(main())

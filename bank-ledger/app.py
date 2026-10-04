#!/usr/bin/env python3
"""
BankLedger - a lightweight terminal client for the PostgreSQL ledger.

All business rules live in the database (procedures, functions, triggers).
This file only shows menus, reads input and calls those routines, so it
runs the same in cmd, PowerShell, bash or an IDE console.

Connection settings are read from a .env file next to this script (see
.env.example) or from environment variables:
    DB_NAME (default bankdb)     DB_USER (default postgres)
    DB_PASSWORD                  DB_HOST (default localhost)   DB_PORT (default 5432)
The standard PGDATABASE / PGUSER / PGPASSWORD / PGHOST / PGPORT variables also
work. If no password is set and the server wants one, the app asks for it.
"""
import getpass
import os
import subprocess
import sys
from datetime import datetime
from decimal import Decimal, InvalidOperation

import psycopg2
from psycopg2 import errors

RETRYABLE = (errors.SerializationFailure, errors.DeadlockDetected)


# ----------------------------------------------------------------------
# Connection
# ----------------------------------------------------------------------
def load_env_file():
    """Load KEY=VALUE lines from .env (next to this script) without overriding
    variables that are already set. No extra package needed."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env")
    if not os.path.isfile(path):
        return
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


def setting(db_name, pg_name, default=None):
    """DB_* variable first, then the standard PG* variable, then the default."""
    return os.getenv(db_name) or os.getenv(pg_name) or default


def connect():
    kw = {
        "dbname": setting("DB_NAME", "PGDATABASE", "bankdb"),
        "user": setting("DB_USER", "PGUSER", "postgres"),
    }
    for key, db_name, pg_name in (("host", "DB_HOST", "PGHOST"),
                                  ("port", "DB_PORT", "PGPORT"),
                                  ("password", "DB_PASSWORD", "PGPASSWORD")):
        value = setting(db_name, pg_name)
        if value:
            kw[key] = value
    try:
        return psycopg2.connect(**kw)
    except psycopg2.OperationalError as exc:
        if "password" in str(exc).lower() and "password" not in kw:
            kw["password"] = getpass.getpass("Database password: ")
            os.environ["PGPASSWORD"] = kw["password"]  # reused by pg_dump
            return psycopg2.connect(**kw)
        raise


# ----------------------------------------------------------------------
# Small helpers
# ----------------------------------------------------------------------
def db_message(exc):
    """Readable text for a database error."""
    diag = getattr(exc, "diag", None)
    if diag is not None and diag.message_primary:
        return diag.message_primary
    return str(exc).strip()


def print_table(headers, rows):
    if not rows:
        print("  (no rows)")
        return
    text = [["-" if v is None else str(v) for v in row] for row in rows]
    widths = [max(len(str(h)), *(len(r[i]) for r in text)) for i, h in enumerate(headers)]
    line = "  " + "-+-".join("-" * w for w in widths)
    print("  " + " | ".join(str(h).ljust(w) for h, w in zip(headers, widths)))
    print(line)
    for r in text:
        print("  " + " | ".join(v.ljust(w) for v, w in zip(r, widths)))
    print(f"  ({len(rows)} row{'s' if len(rows) != 1 else ''})")


def ask_text(prompt, required=True):
    while True:
        value = input(prompt).strip()
        if value or not required:
            return value or None
        print("  Please enter a value.")


def ask_int(prompt):
    while True:
        try:
            return int(input(prompt).strip())
        except ValueError:
            print("  Please enter a whole number.")


def ask_money(prompt):
    while True:
        try:
            value = Decimal(input(prompt).strip()).quantize(Decimal("0.01"))
            if value > 0:
                return value
            print("  Amount must be greater than zero.")
        except InvalidOperation:
            print("  Please enter a valid amount, e.g. 2500.50")


def query(conn, sql, params=None):
    """Run a SELECT and return (headers, rows)."""
    with conn.cursor() as cur:
        cur.execute(sql, params)
        return [d[0] for d in cur.description], cur.fetchall()


def execute(conn, sql, params=None):
    with conn.cursor() as cur:
        cur.execute(sql, params)


def flush_notices(conn):
    for note in conn.notices:
        print("  " + note.replace("NOTICE:", "").strip())
    del conn.notices[:]


def transact(conn, work, retries=3):
    """
    Run work(conn) as ONE transaction: commit on success, rollback on any
    error. Deadlocks and serialization failures are retried automatically.
    """
    for attempt in range(1, retries + 1):
        try:
            result = work(conn)
            conn.commit()
            return True, result
        except RETRYABLE as exc:
            conn.rollback()
            if attempt == retries:
                print(f"  [X] Gave up after {retries} attempts: {db_message(exc)}")
                return False, None
            print(f"  (conflict detected, retrying {attempt}/{retries - 1}...)")
        except psycopg2.Error as exc:
            conn.rollback()
            print(f"  [X] Rejected by the database: {db_message(exc)}")
            return False, None


# ----------------------------------------------------------------------
# Menu actions
# ----------------------------------------------------------------------
def create_customer(conn):
    name = ask_text("Full name : ")
    email = ask_text("Email     : ")
    phone = ask_text("Phone (optional, digits only): ", required=False)
    ok, res = transact(conn, lambda c: query(
        c, "INSERT INTO customers(full_name, email, phone) VALUES (%s, %s, %s) "
           "RETURNING customer_id", (name, email, phone)))
    if ok:
        print(f"  [OK] Customer created with ID {res[1][0][0]}")


def open_account(conn):
    print_table(*query(conn, "SELECT branch_id, branch_name, city FROM branches ORDER BY 1"))
    cust = ask_int("Customer ID : ")
    branch = ask_int("Branch ID   : ")
    acc_type = ask_text("Type (SAVINGS/CURRENT): ").upper()
    initial = input("Opening deposit (0 for none): ").strip() or "0"
    try:
        initial = Decimal(initial)
    except InvalidOperation:
        print("  Invalid amount.")
        return
    ok, res = transact(conn, lambda c: query(
        c, "SELECT fn_open_account(%s, %s, %s, %s)", (cust, branch, acc_type, initial)))
    if ok:
        print(f"  [OK] Account opened. New account number: {res[1][0][0]}")


def deposit(conn):
    acc, amt = ask_int("Account ID : "), ask_money("Amount     : ")
    note = ask_text("Remarks (optional): ", required=False)
    ok, _ = transact(conn, lambda c: execute(c, "CALL deposit(%s, %s, %s)", (acc, amt, note)))
    if ok:
        print(f"  [OK] Deposited {amt} into {acc}")


def withdraw(conn):
    acc, amt = ask_int("Account ID : "), ask_money("Amount     : ")
    note = ask_text("Remarks (optional): ", required=False)
    ok, _ = transact(conn, lambda c: execute(c, "CALL withdraw(%s, %s, %s)", (acc, amt, note)))
    if ok:
        print(f"  [OK] Withdrew {amt} from {acc}")


def transfer(conn):
    src = ask_int("From account : ")
    dst = ask_int("To account   : ")
    amt = ask_money("Amount       : ")
    note = ask_text("Remarks (optional): ", required=False)
    ok, _ = transact(conn, lambda c: execute(
        c, "CALL transfer_funds(%s, %s, %s, %s)", (src, dst, amt, note)))
    if ok:
        print(f"  [OK] Transferred {amt} from {src} to {dst}")


def balance(conn):
    acc = ask_int("Account ID : ")
    try:
        _, rows = query(conn, "SELECT fn_get_balance(%s), fn_account_location(%s)", (acc, acc))
        conn.commit()
        print(f"  Balance : {rows[0][0]}\n  Branch  : {rows[0][1]}")
    except psycopg2.Error as exc:
        conn.rollback()
        print(f"  [X] {db_message(exc)}")


def statement(conn):
    acc = ask_int("Account ID : ")
    limit = ask_int("How many entries? ")
    try:
        print_table(*query(conn, "SELECT * FROM fn_mini_statement(%s, %s)", (acc, limit)))
        conn.commit()
    except psycopg2.Error as exc:
        conn.rollback()
        print(f"  [X] {db_message(exc)}")


def change_status(conn):
    acc = ask_int("Account ID : ")
    status = ask_text("New status (ACTIVE/FROZEN/CLOSED): ").upper()
    ok, _ = transact(conn, lambda c: execute(c, "CALL set_account_status(%s, %s)", (acc, status)))
    if ok:
        print(f"  [OK] Account {acc} is now {status}")


def show_view(conn, sql):
    try:
        print_table(*query(conn, sql))
        conn.commit()
    except psycopg2.Error as exc:
        conn.rollback()
        print(f"  [X] {db_message(exc)}")


def reports(conn):
    menu = {
        "1": ("All accounts",            "SELECT * FROM v_account_overview ORDER BY account_id"),
        "2": ("Branch summary",          "SELECT * FROM v_branch_summary ORDER BY branch_id"),
        "3": ("Customer portfolio",      "SELECT * FROM v_customer_portfolio ORDER BY total_balance DESC"),
        "4": ("Daily volume",            "SELECT * FROM v_daily_volume ORDER BY txn_date DESC, txn_type"),
        "5": ("Dormant accounts",        "SELECT * FROM v_dormant_accounts"),
        "6": ("Audit log (last 20)",     "SELECT audit_id, account_id, action, old_balance, new_balance, "
                                         "old_status, new_status, changed_by, changed_at::timestamp(0) "
                                         "FROM audit_log ORDER BY audit_id DESC LIMIT 20"),
    }
    for key, (title, _) in menu.items():
        print(f"  {key}. {title}")
    choice = input("Report: ").strip()
    if choice in menu:
        show_view(conn, menu[choice][1])


def batch_queue(conn):
    print("  1. Add a transfer to the queue\n  2. Show the queue\n  3. Process all pending")
    choice = input("Choice: ").strip()
    if choice == "1":
        src, dst = ask_int("From account : "), ask_int("To account   : ")
        amt = ask_money("Amount       : ")
        ok, _ = transact(conn, lambda c: execute(
            c, "INSERT INTO transfer_queue(from_account, to_account, amount) VALUES (%s, %s, %s)",
            (src, dst, amt)))
        if ok:
            print("  [OK] Queued.")
    elif choice == "2":
        show_view(conn, "SELECT queue_id, from_account, to_account, amount, status, error_msg "
                        "FROM transfer_queue ORDER BY queue_id")
    elif choice == "3":
        ok, _ = transact(conn, lambda c: execute(c, "CALL process_transfer_queue()"))
        flush_notices(conn)
        if ok:
            show_view(conn, "SELECT queue_id, from_account, to_account, amount, status, error_msg "
                            "FROM transfer_queue ORDER BY queue_id")


def interest(conn):
    raw = input("Monthly interest rate in % (default 0.5): ").strip() or "0.5"
    try:
        rate = Decimal(raw)
    except InvalidOperation:
        print("  Invalid rate.")
        return
    ok, _ = transact(conn, lambda c: execute(c, "CALL apply_monthly_interest(%s)", (rate,)))
    flush_notices(conn)


def backup(conn):
    os.makedirs("backups", exist_ok=True)
    name = os.path.join("backups", f"bankdb_{datetime.now():%Y%m%d_%H%M%S}.sql")
    cmd = ["pg_dump", "-U", setting("DB_USER", "PGUSER", "postgres"),
           "-d", setting("DB_NAME", "PGDATABASE", "bankdb"), "-f", name]
    if setting("DB_HOST", "PGHOST"):
        cmd += ["-h", setting("DB_HOST", "PGHOST")]
    if setting("DB_PORT", "PGPORT"):
        cmd += ["-p", setting("DB_PORT", "PGPORT")]
    # pg_dump only understands PGPASSWORD, so pass the .env password through
    if setting("DB_PASSWORD", "PGPASSWORD"):
        os.environ["PGPASSWORD"] = setting("DB_PASSWORD", "PGPASSWORD")
    try:
        subprocess.run(cmd, check=True)
        print(f"  [OK] Backup written to {name}")
    except FileNotFoundError:
        print("  [X] pg_dump was not found. Add PostgreSQL's bin folder to your PATH.")
    except subprocess.CalledProcessError:
        print("  [X] pg_dump failed - check the message above.")


# ----------------------------------------------------------------------
# Main menu
# ----------------------------------------------------------------------
MENU = [
    ("Create customer", create_customer),
    ("Open account", open_account),
    ("Deposit", deposit),
    ("Withdraw", withdraw),
    ("Transfer funds", transfer),
    ("View balance", balance),
    ("Mini statement", statement),
    ("Freeze / unfreeze / close account", change_status),
    ("Reports and audit log", reports),
    ("Batch transfer queue", batch_queue),
    ("Apply monthly interest", interest),
    ("Backup database (pg_dump)", backup),
]


def main():
    load_env_file()
    try:
        conn = connect()
    except psycopg2.Error as exc:
        print(f"Could not connect to the database: {db_message(exc)}")
        print("Check that PostgreSQL is running and that your .env file (DB_NAME / DB_USER / DB_PASSWORD) is correct.")
        sys.exit(1)

    print("=" * 46)
    print("  BankLedger - PostgreSQL terminal banking")
    print("=" * 46)
    try:
        while True:
            print()
            for i, (title, _) in enumerate(MENU, 1):
                print(f"  {i:>2}. {title}")
            print("   0. Exit")
            choice = input("\nChoose an option: ").strip()
            if choice == "0":
                break
            if choice.isdigit() and 1 <= int(choice) <= len(MENU):
                print()
                MENU[int(choice) - 1][1](conn)
            else:
                print("  Unknown option.")
    except (KeyboardInterrupt, EOFError):
        print()
    finally:
        conn.close()
        print("Goodbye.")


if __name__ == "__main__":
    main()

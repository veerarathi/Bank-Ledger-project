"""
BankLedger (SQLite edition) - business logic layer.

SQLite has no stored procedures, so the routines that were PL/pgSQL in the
PostgreSQL version live here as Python functions. The rules that can still be
enforced by the database itself (CHECK constraints, foreign keys, triggers
BK001-BK004, views) stay in sql/schema.sql.

Every public function runs as ONE transaction (BEGIN IMMEDIATE ... COMMIT).
Any error rolls the whole thing back, so debit + credit happen together or
not at all. BEGIN IMMEDIATE takes SQLite's write lock up front, which plays
the role of SELECT ... FOR UPDATE in PostgreSQL (SQLite locks the whole
database file, not single rows).
"""
import os
import sqlite3
from contextlib import contextmanager
from decimal import Decimal, ROUND_HALF_UP

BASE = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.environ.get("BANK_DB", os.path.join(BASE, "bankledger.db"))
SCHEMA_FILE = os.path.join(BASE, "sql", "schema.sql")

CENT = Decimal("0.01")


class BankError(Exception):
    """A business rule was broken (the Python equivalent of RAISE EXCEPTION)."""


# ----------------------------------------------------------------------
# Connection and transaction helpers
# ----------------------------------------------------------------------
def connect(path=None):
    # isolation_level=None -> we control BEGIN / COMMIT ourselves
    conn = sqlite3.connect(path or DB_PATH, isolation_level=None, timeout=10)
    conn.execute("PRAGMA foreign_keys = ON")   # off by default in SQLite!
    return conn


@contextmanager
def transaction(conn):
    conn.execute("BEGIN IMMEDIATE")
    try:
        yield conn
    except BaseException:
        conn.execute("ROLLBACK")
        raise
    else:
        conn.execute("COMMIT")


def money(value):
    return Decimal(str(value)).quantize(CENT, rounding=ROUND_HALF_UP)


def error_text(exc):
    return str(exc).strip()


# ----------------------------------------------------------------------
# Internal routines (no transaction of their own - callers wrap them)
# ----------------------------------------------------------------------
def _account(conn, account_id):
    return conn.execute(
        "SELECT status, balance FROM accounts WHERE account_id = ?", (account_id,)
    ).fetchone()


def _deposit(conn, account, amount, remarks):
    if amount is None or amount <= 0:
        raise BankError("Deposit amount must be positive")
    row = _account(conn, account)
    if row is None:
        raise BankError(f"Account {account} does not exist")
    if row[0] != "ACTIVE":
        raise BankError(f"Account {account} is {row[0]}, deposit refused")
    conn.execute(
        "INSERT INTO transactions(txn_type, to_account, amount, remarks) "
        "VALUES ('DEPOSIT', ?, ?, ?)", (account, float(amount), remarks))
    conn.execute(
        "UPDATE accounts SET balance = ROUND(balance + ?, 2) WHERE account_id = ?",
        (float(amount), account))


def _withdraw(conn, account, amount, remarks):
    if amount is None or amount <= 0:
        raise BankError("Withdrawal amount must be positive")
    row = _account(conn, account)
    if row is None:
        raise BankError(f"Account {account} does not exist")
    status, balance = row[0], money(row[1])
    if status != "ACTIVE":
        raise BankError(f"Account {account} is {status}, withdrawal refused")
    if balance < amount:
        raise BankError(f"Insufficient funds: balance {balance} is less than {amount}")
    conn.execute(
        "INSERT INTO transactions(txn_type, from_account, amount, remarks) "
        "VALUES ('WITHDRAWAL', ?, ?, ?)", (account, float(amount), remarks))
    conn.execute(
        "UPDATE accounts SET balance = ROUND(balance - ?, 2) WHERE account_id = ?",
        (float(amount), account))


def _transfer(conn, src, dst, amount, remarks):
    # 1. validate input
    if src is None or dst is None:
        raise BankError("Both source and destination accounts are required")
    if src == dst:
        raise BankError("Cannot transfer to the same account")
    if amount is None or amount <= 0:
        raise BankError("Transfer amount must be positive")
    # 2. (the write lock is already held by BEGIN IMMEDIATE)
    # 3. validate status + balance
    from_row, to_row = _account(conn, src), _account(conn, dst)
    if from_row is None:
        raise BankError(f"Source account {src} does not exist")
    if to_row is None:
        raise BankError(f"Destination account {dst} does not exist")
    if from_row[0] != "ACTIVE":
        raise BankError(f"Source account {src} is {from_row[0]}")
    if to_row[0] != "ACTIVE":
        raise BankError(f"Destination account {dst} is {to_row[0]}")
    if money(from_row[1]) < amount:
        raise BankError(
            f"Insufficient funds: balance {money(from_row[1])} is less than {amount}")
    # 4. ledger row (trigger BK004 enforces the daily limit)
    conn.execute(
        "INSERT INTO transactions(txn_type, from_account, to_account, amount, remarks) "
        "VALUES ('TRANSFER', ?, ?, ?, ?)", (src, dst, float(amount), remarks))
    # 5. debit + credit (triggers write the audit trail)
    conn.execute(
        "UPDATE accounts SET balance = ROUND(balance - ?, 2) WHERE account_id = ?",
        (float(amount), src))
    conn.execute(
        "UPDATE accounts SET balance = ROUND(balance + ?, 2) WHERE account_id = ?",
        (float(amount), dst))


# ----------------------------------------------------------------------
# Public "procedures" (each one is a single atomic transaction)
# ----------------------------------------------------------------------
def deposit(conn, account, amount, remarks=None):
    with transaction(conn):
        _deposit(conn, account, money(amount), remarks)


def withdraw(conn, account, amount, remarks=None):
    with transaction(conn):
        _withdraw(conn, account, money(amount), remarks)


def transfer_funds(conn, src, dst, amount, remarks=None):
    with transaction(conn):
        _transfer(conn, src, dst, money(amount), remarks)


def set_account_status(conn, account, status):
    status = status.upper()
    if status not in ("ACTIVE", "FROZEN", "CLOSED"):
        raise BankError(f"Invalid status {status}, use ACTIVE, FROZEN or CLOSED")
    with transaction(conn):
        row = _account(conn, account)
        if row is None:
            raise BankError(f"Account {account} does not exist")
        if status == "CLOSED" and money(row[1]) != 0:
            raise BankError(
                f"Withdraw the remaining balance {money(row[1])} before closing the account")
        conn.execute("UPDATE accounts SET status = ? WHERE account_id = ?", (status, account))


def create_customer(conn, name, email, phone=None):
    with transaction(conn):
        cur = conn.execute(
            "INSERT INTO customers(full_name, email, phone) VALUES (?, ?, ?)",
            (name, email, phone))
        return cur.lastrowid


def open_account(conn, customer, branch, acc_type, initial=0):
    """Returns the new account number (fn_open_account)."""
    initial = money(initial)
    if initial < 0:
        raise BankError("Opening deposit cannot be negative")
    with transaction(conn):
        cur = conn.execute(
            "INSERT INTO accounts(customer_id, branch_id, account_type) VALUES (?, ?, ?)",
            (customer, branch, acc_type.upper()))
        new_id = cur.lastrowid
        if initial > 0:
            _deposit(conn, new_id, initial, "Opening deposit")
        return new_id


def apply_monthly_interest(conn, rate_percent=Decimal("0.5")):
    """Credit interest to every ACTIVE savings account. Returns how many got it."""
    rate = Decimal(str(rate_percent))
    if rate <= 0:
        raise BankError("Interest rate must be positive")
    with transaction(conn):
        rows = conn.execute(
            "SELECT account_id, balance FROM accounts "
            "WHERE account_type = 'SAVINGS' AND status = 'ACTIVE' ORDER BY account_id"
        ).fetchall()
        count = 0
        for account_id, balance in rows:
            interest = (money(balance) * rate / 100).quantize(CENT, rounding=ROUND_HALF_UP)
            if interest > 0:
                conn.execute(
                    "INSERT INTO transactions(txn_type, to_account, amount, remarks) "
                    "VALUES ('INTEREST', ?, ?, ?)",
                    (account_id, float(interest), f"Monthly interest @ {rate}%"))
                conn.execute(
                    "UPDATE accounts SET balance = ROUND(balance + ?, 2) WHERE account_id = ?",
                    (float(interest), account_id))
                count += 1
        return count


def process_transfer_queue(conn):
    """
    Process every PENDING row. Each row runs inside its own SAVEPOINT, so one
    failing transfer is rolled back alone and the rest carry on.
    Returns (done, failed).
    """
    with transaction(conn):
        rows = conn.execute(
            "SELECT queue_id, from_account, to_account, amount FROM transfer_queue "
            "WHERE status = 'PENDING' ORDER BY queue_id").fetchall()
        done = failed = 0
        for queue_id, src, dst, amount in rows:
            conn.execute("SAVEPOINT queue_row")
            try:
                _transfer(conn, src, dst, money(amount), f"Batch #{queue_id}")
                conn.execute("RELEASE queue_row")
                conn.execute(
                    "UPDATE transfer_queue SET status = 'DONE', "
                    "processed_at = datetime('now','localtime') WHERE queue_id = ?",
                    (queue_id,))
                done += 1
            except (BankError, sqlite3.Error) as exc:
                conn.execute("ROLLBACK TO queue_row")
                conn.execute("RELEASE queue_row")
                conn.execute(
                    "UPDATE transfer_queue SET status = 'FAILED', error_msg = ?, "
                    "processed_at = datetime('now','localtime') WHERE queue_id = ?",
                    (error_text(exc), queue_id))
                failed += 1
        return done, failed


def queue_transfer(conn, src, dst, amount):
    with transaction(conn):
        conn.execute(
            "INSERT INTO transfer_queue(from_account, to_account, amount) VALUES (?, ?, ?)",
            (src, dst, float(money(amount))))


# ----------------------------------------------------------------------
# Read-only "functions"
# ----------------------------------------------------------------------
def get_balance(conn, account):
    row = _account(conn, account)
    if row is None:
        raise BankError(f"Account {account} does not exist")
    return money(row[1])


def account_location(conn, account):
    row = conn.execute(
        "SELECT b.branch_name || ', ' || b.city FROM accounts a "
        "JOIN branches b ON b.branch_id = a.branch_id WHERE a.account_id = ?",
        (account,)).fetchone()
    return row[0] if row else None


def mini_statement(conn, account, limit=10):
    """Returns (headers, rows) for the last `limit` entries of one account."""
    cur = conn.execute(
        """
        SELECT t.txn_id, t.txn_time, t.txn_type,
               CASE WHEN t.to_account = :a THEN 'CREDIT' ELSE 'DEBIT' END AS direction,
               CASE WHEN t.to_account = :a THEN t.from_account ELSE t.to_account END AS counterparty,
               t.amount, t.remarks
          FROM transactions t
         WHERE t.from_account = :a OR t.to_account = :a
         ORDER BY t.txn_time DESC, t.txn_id DESC
         LIMIT :n
        """, {"a": account, "n": limit})
    return [d[0] for d in cur.description], cur.fetchall()


# ----------------------------------------------------------------------
# Install + sample data
# ----------------------------------------------------------------------
def init_db(conn):
    """Drop and recreate every table, trigger and view from sql/schema.sql."""
    with open(SCHEMA_FILE, encoding="utf-8") as fh:
        conn.executescript(fh.read())


def seed_db(conn):
    """Sample data. Money moves through the same routines as real use, so the
    triggers fire and audit_log is filled exactly as in production."""
    with transaction(conn):
        conn.executemany("INSERT INTO branches(branch_name, city) VALUES (?, ?)", [
            ("Main Branch", "Indore"), ("City Center", "Bhopal"), ("Tech Park", "Pune")])
        conn.executemany("INSERT INTO customers(full_name, email, phone) VALUES (?, ?, ?)", [
            ("Rajesh Kumar", "rajesh.kumar@example.com", "9876543210"),
            ("Anita Sharma", "anita.sharma@example.com", "9876500011"),
            ("Vikram Singh", "vikram.singh@example.com", "9876500022"),
            ("Priya Patel",  "priya.patel@example.com",  "9876500033"),
            ("Rohan Mehta",  "rohan.mehta@example.com",  "9876500044"),
            ("Sneha Iyer",   "sneha.iyer@example.com",   "9876500055")])
        conn.executemany(
            "INSERT INTO accounts(customer_id, branch_id, account_type) VALUES (?, ?, ?)", [
                (1, 1, "SAVINGS"),   # 1001 Rajesh  Main Branch
                (2, 1, "SAVINGS"),   # 1002 Anita   Main Branch
                (3, 2, "SAVINGS"),   # 1003 Vikram  City Center
                (4, 2, "CURRENT"),   # 1004 Priya   City Center
                (5, 3, "SAVINGS"),   # 1005 Rohan   Tech Park
                (6, 3, "SAVINGS"),   # 1006 Sneha   Tech Park
                (1, 2, "CURRENT"),   # 1007 Rajesh  City Center
                (1, 3, "SAVINGS"),   # 1008 Rajesh  Tech Park
                (2, 2, "SAVINGS")])  # 1009 Anita   City Center (stays dormant)
        conn.executemany(
            "INSERT INTO nominees(account_id, nominee_no, nominee_name, relation, share_percent) "
            "VALUES (?, ?, ?, ?, ?)", [
                (1001, 1, "Meera Kumar", "Spouse", 60),
                (1001, 2, "Aman Kumar", "Son", 40),
                (1002, 1, "Ravi Sharma", "Father", 100)])

        for acc, amt in [(1001, 80000), (1002, 30000), (1003, 45000), (1004, 12000),
                         (1005, 60000), (1006, 25000), (1007, 18000), (1008, 9000)]:
            _deposit(conn, acc, money(amt), "Initial funding")

        for src, dst, amt, note in [
                (1001, 1002, 5000, "Rent share"), (1002, 1003, 1500, "Books"),
                (1003, 1004, 2500, "Loan repayment"), (1005, 1001, 7000, "Invoice 114"),
                (1006, 1005, 3000, "Gift"), (1007, 1008, 1000, "Savings top-up"),
                (1001, 1003, 4000, "Fees")]:
            _transfer(conn, src, dst, money(amt), note)
        _withdraw(conn, 1004, money(2000), "ATM")
        _withdraw(conn, 1001, money(10000), "Cash")

        conn.execute("UPDATE accounts SET status = 'FROZEN' WHERE account_id = 1009")

        # Batch queue demo: 1 valid, 1 insufficient funds, 1 frozen account
        conn.executemany(
            "INSERT INTO transfer_queue(from_account, to_account, amount) VALUES (?, ?, ?)",
            [(1003, 1004, 2000), (1005, 1006, 9999999), (1009, 1001, 10)])


def setup(conn):
    init_db(conn)
    seed_db(conn)

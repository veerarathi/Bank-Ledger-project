"""
Automated tests for the SQLite edition.   Run:   python -m unittest -v
Every test builds a fresh temporary database with the sample data.
"""
import os
import sqlite3
import tempfile
import unittest
from decimal import Decimal

import ledger
from ledger import BankError


class LedgerTests(unittest.TestCase):
    def setUp(self):
        fd, self.path = tempfile.mkstemp(suffix=".db")
        os.close(fd)
        self.conn = ledger.connect(self.path)
        ledger.setup(self.conn)

    def tearDown(self):
        self.conn.close()
        os.remove(self.path)

    # helpers
    def bal(self, acc):
        return ledger.get_balance(self.conn, acc)

    def scalar(self, sql, *params):
        return self.conn.execute(sql, params).fetchone()[0]

    def total(self):
        return money_sum(self.conn)

    # ---- sample data -------------------------------------------------
    def test_seed_balances(self):
        expected = {1001: 68000, 1002: 33500, 1003: 48000, 1004: 12500, 1005: 56000,
                    1006: 22000, 1007: 17000, 1008: 10000, 1009: 0}
        for acc, amount in expected.items():
            self.assertEqual(self.bal(acc), Decimal(amount), f"account {acc}")
        self.assertEqual(self.scalar("SELECT status FROM accounts WHERE account_id=1009"), "FROZEN")
        self.assertEqual(self.scalar("SELECT COUNT(*) FROM transactions"), 17)

    # ---- transfer_funds (atomicity) ---------------------------------
    def test_valid_transfer(self):
        before = self.total()
        ledger.transfer_funds(self.conn, 1001, 1002, 100, "rent")
        self.assertEqual(self.bal(1001), Decimal("67900.00"))
        self.assertEqual(self.bal(1002), Decimal("33600.00"))
        self.assertEqual(self.total(), before)          # money is only moved

    def test_failed_transfers_change_nothing(self):
        txns = self.scalar("SELECT COUNT(*) FROM transactions")
        cases = [(1004, 1001, 9999999), (1001, 1009, 10), (1009, 1001, 10),
                 (1001, 1001, 10), (1001, 1002, -5), (1001, 5555, 10)]
        for src, dst, amt in cases:
            with self.assertRaises((BankError, sqlite3.Error), msg=(src, dst, amt)):
                ledger.transfer_funds(self.conn, src, dst, amt)
        self.assertEqual(self.bal(1001), Decimal(68000))
        self.assertEqual(self.bal(1004), Decimal("12500"))
        self.assertEqual(self.scalar("SELECT COUNT(*) FROM transactions"), txns)

    def test_deposit_withdraw(self):
        ledger.deposit(self.conn, 1008, 500)
        ledger.withdraw(self.conn, 1008, 200)
        self.assertEqual(self.bal(1008), Decimal("10300"))
        with self.assertRaises(BankError):
            ledger.withdraw(self.conn, 1008, 10 ** 7)
        with self.assertRaises(BankError):
            ledger.deposit(self.conn, 1009, 10)         # frozen

    def test_decimal_precision(self):
        ledger.deposit(self.conn, 1008, "0.10")
        ledger.deposit(self.conn, 1008, "0.20")
        self.assertEqual(self.bal(1008), Decimal("10000.30"))

    # ---- triggers ----------------------------------------------------
    def test_ledger_is_append_only_BK003(self):
        with self.assertRaisesRegex(sqlite3.IntegrityError, "BK003"):
            self.conn.execute("UPDATE transactions SET amount = 1 WHERE txn_id = 1")
        with self.assertRaisesRegex(sqlite3.IntegrityError, "BK003"):
            self.conn.execute("DELETE FROM transactions")

    def test_cannot_delete_funded_account_BK002(self):
        with self.assertRaisesRegex(sqlite3.IntegrityError, "BK002"):
            self.conn.execute("DELETE FROM accounts WHERE account_id = 1001")

    def test_frozen_guard_BK001(self):
        with self.assertRaisesRegex(sqlite3.IntegrityError, "BK001"):
            self.conn.execute("UPDATE accounts SET balance = balance + 1 WHERE account_id = 1009")

    def test_daily_limit_BK004(self):
        ledger.deposit(self.conn, 1001, 60000)
        ledger.transfer_funds(self.conn, 1001, 1002, 30000)     # 19000 + 30000 = 49000 used
        with self.assertRaisesRegex(sqlite3.IntegrityError, "BK004"):
            ledger.transfer_funds(self.conn, 1001, 1002, 30000)
        self.assertEqual(self.bal(1001), Decimal("98000"))      # failed one rolled back

    def test_audit_trail(self):
        before = self.scalar("SELECT COUNT(*) FROM audit_log")
        ledger.transfer_funds(self.conn, 1001, 1002, 100)
        self.assertEqual(self.scalar("SELECT COUNT(*) FROM audit_log"), before + 2)
        # an UPDATE that changes nothing must not be logged
        self.conn.execute("UPDATE accounts SET balance = balance WHERE account_id = 1001")
        self.assertEqual(self.scalar("SELECT COUNT(*) FROM audit_log"), before + 2)

    def test_status_rules_and_delete_cascade(self):
        with self.assertRaises(BankError):                      # still has money
            ledger.set_account_status(self.conn, 1001, "CLOSED")
        with self.assertRaises(BankError):
            ledger.set_account_status(self.conn, 1001, "BROKEN")
        cust = ledger.create_customer(self.conn, "Test User", "test.user@example.com", "9999999999")
        acc = ledger.open_account(self.conn, cust, 1, "savings")
        self.assertEqual(acc, 1010)                             # numbering continues
        self.conn.execute("INSERT INTO nominees VALUES (?, 1, 'N', 'Friend', 100)", (acc,))
        self.conn.execute("DELETE FROM accounts WHERE account_id = ?", (acc,))
        self.assertEqual(self.scalar("SELECT COUNT(*) FROM nominees WHERE account_id=?", acc), 0)
        self.assertEqual(self.scalar(
            "SELECT COUNT(*) FROM audit_log WHERE account_id=? AND action='DELETE'", acc), 1)

    def test_check_constraints(self):
        with self.assertRaises(sqlite3.IntegrityError):
            ledger.create_customer(self.conn, "Bad Email", "not-an-email")
        with self.assertRaises(sqlite3.IntegrityError):
            ledger.create_customer(self.conn, "Bad Phone", "a@b.co", "12ab")
        with self.assertRaises(sqlite3.IntegrityError):         # duplicate email
            ledger.create_customer(self.conn, "Dup", "rajesh.kumar@example.com")

    def test_active_view_check_option(self):
        with self.assertRaisesRegex(sqlite3.IntegrityError, "CHECK OPTION"):
            self.conn.execute("UPDATE v_active_accounts SET status = 'FROZEN' WHERE account_id = 1001")

    # ---- batch + interest -------------------------------------------
    def test_queue_uses_savepoints(self):
        done, failed = ledger.process_transfer_queue(self.conn)
        self.assertEqual((done, failed), (1, 2))
        rows = dict(self.conn.execute("SELECT queue_id, status FROM transfer_queue").fetchall())
        self.assertEqual(rows, {1: "DONE", 2: "FAILED", 3: "FAILED"})
        self.assertEqual(self.bal(1003), Decimal("46000"))      # only the valid one moved money
        self.assertEqual(ledger.process_transfer_queue(self.conn), (0, 0))

    def test_interest(self):
        before = self.bal(1001)
        self.assertEqual(ledger.apply_monthly_interest(self.conn, "0.5"), 6)
        self.assertEqual(self.bal(1001), before + Decimal("340.00"))
        with self.assertRaises(BankError):
            ledger.apply_monthly_interest(self.conn, 0)

    # ---- reconciliation ---------------------------------------------
    def test_ledger_reconciles_with_balances(self):
        ledger.transfer_funds(self.conn, 1002, 1005, 123.45)
        ledger.apply_monthly_interest(self.conn)
        ledger.deposit(self.conn, 1008, 10)
        bad = self.conn.execute("""
            SELECT a.account_id FROM accounts a
             WHERE ROUND(a.balance
                   - (COALESCE((SELECT SUM(amount) FROM transactions WHERE to_account   = a.account_id),0)
                    - COALESCE((SELECT SUM(amount) FROM transactions WHERE from_account = a.account_id),0)), 2) <> 0
        """).fetchall()
        self.assertEqual(bad, [])

    def test_mini_statement(self):
        headers, rows = ledger.mini_statement(self.conn, 1001, 3)
        self.assertEqual(len(rows), 3)
        self.assertEqual(rows[0][2], "WITHDRAWAL")              # newest first


def money_sum(conn):
    return ledger.money(conn.execute("SELECT SUM(balance) FROM accounts").fetchone()[0])


if __name__ == "__main__":
    unittest.main(verbosity=2)

# BankLedger: Terminal Banking System on SQLite

A lightweight, terminal-based banking ledger built for a **Database Management Systems** course. Money moves through atomic transactions, every balance change is logged by a trigger, and database constraints make sure money is never lost or created.

The project runs with **only Python**. There is no database server to install, no ORM, and no extra packages: SQLite ships inside Python's standard library.

## Features

* **Normalized schema (3NF/BCNF)**: primary and foreign keys, `CHECK` constraints, autoincrement ids, a weak entity (`nominees`) and indexes
* **Atomic fund transfers**: debit and credit succeed together or not at all
* **Business logic layer** (`ledger.py`): `deposit`, `withdraw`, `transfer_funds`, `set_account_status`, `open_account`, `apply_monthly_interest`, `process_transfer_queue`, `get_balance`, `mini_statement`
* **5 business rules enforced by triggers** (8 trigger objects): automatic audit log, frozen-account guard, delete guard, append-only ledger, daily outgoing limit
* **Views**: joins, aggregates, a masked view and an updatable view with a check-option trigger
* **Batch transfers with SAVEPOINTs**: one failing transfer is rolled back alone while the rest continue
* **21 showcase queries**: joins, sub-queries, set operators, window functions, CTE, relational division, query plan
* **17 automated tests** using Python's built-in `unittest`
* **Terminal menu with 12 options**, including mini statement, reports, batch transfers and one-click `.sql` backup

## Tech Stack

| Layer | Technology |
|---|---|
| Database | SQLite 3.25+ (built into Python) |
| Business logic | Python 3.9+ (`sqlite3`, `decimal`) |
| Client | Terminal menu (`app.py`) |
| Tests | `unittest` |
| Backup | `iterdump()` to a `.sql` file |

## Project Structure

```
bank-ledger/
├── README.md
├── LICENSE
├── .gitignore
├── app.py              # terminal menu (thin client)
├── ledger.py           # business logic: deposit, withdraw, transfer, interest, batch queue
├── run_queries.py      # runs sql/queries.sql and prints the results
├── test_ledger.py      # 17 automated tests
├── sql/
│   ├── schema.sql      # tables, constraints, indexes, triggers, views
│   └── queries.sql     # 21 showcase queries
└── backups/            # menu option 12 writes .sql dumps here
```

The database file `bankledger.db` is created on the first run and is ignored by Git.

## Database Design

| Table | Purpose | Key constraints |
|---|---|---|
| `branches` | Bank branches | PK, unique name |
| `customers` | Account holders | PK, unique and format-checked email, phone check |
| `accounts` | Savings / current accounts | FK to customer and branch, `balance >= 0`, type and status checks, ids start at 1001 |
| `nominees` | Weak entity of account | composite PK (`account_id`, `nominee_no`), `ON DELETE CASCADE` |
| `transactions` | Append-only ledger | table-level `CHECK` ties transaction type to from/to accounts |
| `audit_log` | History of account changes | written only by triggers |
| `transfer_queue` | Batch transfers | status `PENDING / DONE / FAILED` |

### Triggers

| Rule | Trigger(s) | Event | What it does | Code |
|---|---|---|---|---|
| Audit trail | `trg_account_audit_update`, `trg_account_audit_delete` | AFTER UPDATE / DELETE on `accounts` | Writes old and new balance/status to `audit_log` (only when something changed) | - |
| Frozen guard | `trg_block_inactive_update` | BEFORE UPDATE OF balance | Refuses balance changes on FROZEN / CLOSED accounts | `BK001` |
| Delete guard | `trg_block_account_delete` | BEFORE DELETE on `accounts` | Refuses deleting an account that still holds money | `BK002` |
| Append-only ledger | `trg_ledger_no_update`, `trg_ledger_no_delete` | BEFORE UPDATE / DELETE on `transactions` | Keeps the ledger immutable | `BK003` |
| Daily limit | `trg_daily_limit` | BEFORE INSERT on `transactions` | Rejects outgoing money above 50 000 per account per day | `BK004` |

`v_active_accounts` also has an `INSTEAD OF UPDATE` trigger that works like `WITH CHECK OPTION`: a row cannot be changed so that it leaves the ACTIVE set.

### Transfer flow: `transfer_funds(src, dst, amount, remarks)`

Runs as one transaction (`BEGIN IMMEDIATE ... COMMIT`):

1. Amount must be positive and source and destination must differ
2. The write lock is taken up front, so no other writer can interfere
3. Both accounts must exist and be ACTIVE
4. Source must have sufficient funds
5. Insert the ledger row (trigger `BK004` checks the daily limit)
6. Debit the source and credit the destination (triggers write the audit trail)

Any failed check raises an error and **the whole transaction rolls back**.

## ACID: Where Each Property Comes From

| Property | How it is enforced |
|---|---|
| **Atomicity** | Every routine runs inside one transaction. An error triggers `ROLLBACK`, so debit and credit both happen or neither does |
| **Consistency** | `CHECK (balance >= 0)`, foreign keys (`PRAGMA foreign_keys = ON`) and triggers keep the data valid |
| **Isolation** | `BEGIN IMMEDIATE` takes SQLite's write lock before any read, so writers run one at a time |
| **Durability** | SQLite's journal persists committed transactions to disk |

## Getting Started

### Prerequisites

* Python 3.9 or later (nothing else)

### Run it

```bash
# 1. Clone the repo
git clone https://github.com/sourabhvamdevan/bank-ledger.git
cd bank-ledger

# 2. Start the app (creates bankledger.db with sample data on first run)
python app.py
```

On Windows use `py app.py` if `python` is not recognised. In VS Code, open the folder and run the same command in the integrated terminal.

| Command | What it does |
|---|---|
| `python app.py` | Start the menu |
| `python app.py --reset` | Delete everything and reload the sample data |
| `python run_queries.py` | Run all 21 showcase queries |
| `python run_queries.py Q11` | Run only the query whose title starts with `Q11` |
| `python -m unittest -v` | Run the automated tests |

## Usage

```
  1. Create customer            7. Mini statement
  2. Open account               8. Freeze / unfreeze / close account
  3. Deposit                    9. Reports and audit log
  4. Withdraw                  10. Batch transfer queue
  5. Transfer funds            11. Apply monthly interest
  6. View balance              12. Backup database (.sql dump)
```

The sample data has accounts `1001` to `1009` (account `1009` is frozen). Example transfer:

```
Choose an option: 5
From account : 1001
To account   : 1002
Amount       : 100
Remarks (optional): rent
  [OK] Transferred 100 from 1001 to 1002
```

A failed action shows the reason and changes nothing:

```
  [X] Rejected: Account 2000 does not exist
  [X] Rejected: Insufficient funds: balance 12500.00 is less than 9999999.00
```

## Testing

```bash
python -m unittest -v
```

Each test builds a fresh temporary database with the sample data. The 17 tests cover:

* Seed balances and a valid transfer (total money in the bank stays constant)
* Failed transfers: insufficient funds, frozen account, same account, negative amount, unknown account (balances and ledger unchanged)
* Triggers `BK001` to `BK004`, the audit trail, and the check-option view
* Deposit, withdraw, decimal precision, status rules and cascade delete of nominees
* Batch queue with savepoints (1 done, 2 failed) and monthly interest
* Reconciliation: every stored balance equals credits minus debits in the ledger

### Manual demos

1. **Rollback on failure**: transfer more than the sender's balance. Both balances stay unchanged.
2. **Automatic audit trail**: make one transfer, then open *Reports and audit log*. Debit and credit rows appear even though the Python code never writes to `audit_log`.
3. **Daily limit**: send two transfers of 30 000 from the same account on the same day. The second one is rejected with `BK004`.
4. **Savepoints**: add transfers to the queue (option 10) and process them. Failed rows get status `FAILED` with the reason, valid rows still go through.

## Design Notes

* **No stored procedures.** SQLite does not support them, so the logic that would be PL/pgSQL lives in `ledger.py`. Rules that the database can enforce itself (constraints, foreign keys, triggers, views) stay in `sql/schema.sql`.
* **Whole-database locking.** `BEGIN IMMEDIATE` locks the entire database file, not single rows, which is simple and safe for a single-file application.
* **Money handling.** SQLite stores `NUMERIC` as a float, so the app calculates with Python's `Decimal` and every update uses `ROUND(..., 2)`.
* **Fixed trigger messages.** SQLite's `RAISE()` accepts only constant text, so trigger errors do not include the account number.
* **No roles or `GRANT`.** SQLite has no user accounts. `v_public_accounts` shows the idea of a masked view but does not restrict anyone.
* **Rewritten queries.** `> ALL` and `> ANY` use `MAX` and `MIN`, `ROLLUP` uses `UNION ALL`, and `EXPLAIN ANALYZE` becomes `EXPLAIN QUERY PLAN`.

## Troubleshooting

| Problem | Fix |
|---|---|
| `python` is not recognised | Use `py app.py` on Windows, or reinstall Python and tick "Add to PATH" |
| `Database file looks empty or broken` | Run `python app.py --reset` |
| `database is locked` | Close other programs that have `bankledger.db` open (DB browsers, a second terminal) |
| Window functions fail in `queries.sql` | Your SQLite is older than 3.25; check with `python -c "import sqlite3; print(sqlite3.sqlite_version)"` |
| Want a clean start | Delete `bankledger.db` or run `python app.py --reset` |

## Future Improvements

* Minimum-balance rule for savings accounts
* Fraud flag for several large transfers within a few minutes
* Restore command in the menu to load a backup
* Unit tests for the menu layer
* Port to PostgreSQL with PL/pgSQL stored procedures

## License

MIT. See [LICENSE](LICENSE).

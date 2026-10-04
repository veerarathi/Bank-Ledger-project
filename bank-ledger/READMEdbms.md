# BankLedger: Terminal Banking System on PostgreSQL

A lightweight, terminal-based banking ledger where **the business logic lives inside the database**. Money moves through PL/pgSQL stored procedures, every balance change is logged by a trigger, and ACID transactions guarantee that money is never lost or created.

The Python client is intentionally thin: it shows a menu and calls the database. Built for a **Database Management Systems** course (CSE3001).

!\[Architecture](docs/diagrams/architecture.png)

## Features

* **Normalized schema (3NF/BCNF)**: primary and foreign keys, `CHECK` constraints, identity columns, a weak entity (`nominees`) and indexes
* **Atomic fund transfers**: debit and credit succeed together or not at all
* **Stored procedures and functions (PL/pgSQL)**: `deposit`, `withdraw`, `transfer\_funds`, `set\_account\_status`, `apply\_monthly\_interest`, `process\_transfer\_queue`, `fn\_open\_account`, `fn\_get\_balance`, `fn\_mini\_statement`, `fn\_account\_location`
* **5 triggers**: automatic audit log, frozen-account guard, delete guard, append-only ledger, daily outgoing limit
* **Views and security**: joins, aggregates, a masked view, an updatable view with `WITH CHECK OPTION`, and role-based `GRANT`s
* **Concurrency safe**: row locks (`FOR UPDATE`) taken in a fixed order prevent race conditions and deadlocks
* **21 showcase queries**: joins, sub-queries, set operators, window functions, CTE, `ROLLUP`, `EXPLAIN`
* **Terminal menu with 12 options**, including mini statement, reports, batch transfers and one-click `pg\_dump` backup

## Tech Stack

|Layer|Technology|
|-|-|
|Database|PostgreSQL 14+|
|Procedural logic|PL/pgSQL (procedures, functions, triggers)|
|Client|Python 3.9+, `psycopg2-binary`|
|Backup|`pg\_dump` (called from the menu)|

No ORM, no web server and no Docker needed.

## Project Structure

```
bank-ledger/
├── README.md
├── LICENSE
├── .gitignore
├── .env.example                   # copy to .env and add your credentials
├── requirements.txt
├── app.py                         # terminal client (thin)
├── sql/
│   ├── 01\_schema.sql              # tables, constraints, sequences, indexes
│   ├── 02\_functions\_procedures.sql
│   ├── 03\_triggers.sql
│   ├── 04\_views.sql               # views + GRANT
│   ├── 05\_seed.sql                # sample data (loaded through the procedures)
│   ├── 06\_queries.sql             # 21 showcase queries (run separately, optional)
│   └── install.sql                # optional: runs 01-05 in one command
├── demos/
│   └── TRANSACTION\_DEMOS.md       # rollback, isolation, deadlock, savepoint, 2PC
├── docs/
│   ├── Project\_Report.docx
│   └── diagrams/                  # ER, class, use-case, sequence, architecture
└── backups/                       # database backups are saved here
```

The `backups/` folder is where menu option 12 (*Backup database*) writes its `.sql` dump files. The folder is kept in Git through an empty `.gitkeep` file, while the dumps themselves are ignored through `.gitignore`.

## Database Design

!\[ER diagram](docs/diagrams/er.png)

|Table|Purpose|Key constraints|
|-|-|-|
|`branches`|Bank branches|PK, unique name|
|`customers`|Account holders|PK, unique and format-checked email, phone check|
|`accounts`|Savings / current accounts|FK to customer and branch, `balance >= 0`, type and status checks|
|`nominees`|Weak entity of account|composite PK (`account\_id`, `nominee\_no`), `ON DELETE CASCADE`|
|`transactions`|Append-only ledger|table-level `CHECK` ties transaction type to from/to accounts|
|`audit\_log`|History of account changes|written only by a trigger|
|`transfer\_queue`|Batch transfers|status `PENDING / DONE / FAILED`|

### Triggers

|Trigger|Table|Event|What it does|Error code|
|-|-|-|-|-|
|`trg\_account\_audit`|`accounts`|AFTER UPDATE / DELETE|Writes old and new balance/status, user and time to `audit\_log`|-|
|`trg\_block\_inactive\_update`|`accounts`|BEFORE UPDATE OF balance|Refuses balance changes on FROZEN / CLOSED accounts|`BK001`|
|`trg\_block\_account\_delete`|`accounts`|BEFORE DELETE|Refuses deleting an account that still holds money|`BK002`|
|`trg\_ledger\_immutable`|`transactions`|BEFORE UPDATE / DELETE|Keeps the ledger append-only|`BK003`|
|`trg\_daily\_limit`|`transactions`|BEFORE INSERT|Rejects outgoing money above 50 000 per account per day|`BK004`|

### Stored procedure: `transfer\_funds(sender, receiver, amount, remarks)`

Runs as one transaction:

1. Amount must be positive and sender and receiver must differ
2. Locks both accounts in ascending id order (`FOR UPDATE`)
3. Both accounts must exist and be active (not frozen or closed)
4. Sender must have sufficient funds
5. Writes the ledger row, debits the sender, credits the receiver

Any failed check raises an exception, which **rolls back the entire transaction**.

## ACID: Where Each Property Comes From

|Property|How it is enforced|
|-|-|
|**Atomicity**|`RAISE EXCEPTION` aborts the whole transaction, so debit and credit both happen or neither does|
|**Consistency**|`CHECK (balance >= 0)`, foreign keys and triggers keep the data valid|
|**Isolation**|`SELECT ... FOR UPDATE` row locks (always in the same order) stop concurrent transfers from interfering|
|**Durability**|PostgreSQL's Write-Ahead Log (WAL) persists committed transactions|

## Getting Started

### Prerequisites

* PostgreSQL 14 or later (`psql`, `createdb` and `pg\_dump` must be on your `PATH`)
* Python 3.9+

### Setup

```bash
# 1. Clone the repo
git clone https://github.com/<your-username>/bank-ledger.git
cd bank-ledger

# 2. Create the database and load the SQL files in order
createdb -U postgres bankdb
psql -U postgres -d bankdb -v ON\_ERROR\_STOP=1 -f sql/01\_schema.sql
psql -U postgres -d bankdb -v ON\_ERROR\_STOP=1 -f sql/02\_functions\_procedures.sql
psql -U postgres -d bankdb -v ON\_ERROR\_STOP=1 -f sql/03\_triggers.sql
psql -U postgres -d bankdb -v ON\_ERROR\_STOP=1 -f sql/04\_views.sql
psql -U postgres -d bankdb -v ON\_ERROR\_STOP=1 -f sql/05\_seed.sql

# 3. Install Python dependencies
pip install -r requirements.txt

# 4. Configure credentials
cp .env.example .env        # on Windows cmd: copy .env.example .env
# edit .env with your database details

# 5. Run the app
python app.py
```

> \*\*Shortcut:\*\* steps 2's five `psql` commands can be replaced by one: `psql -U postgres -d bankdb -v ON\_ERROR\_STOP=1 -f sql/install.sql`
>
> `01\_schema.sql` drops and recreates every project table, so re-running the SQL files resets the data to the sample set.

### Environment Variables

Put these in a `.env` file in the project root (the file is git-ignored):

```
DB\_NAME=bankdb
DB\_USER=postgres
DB\_PASSWORD=your\_password\_here
DB\_HOST=localhost
DB\_PORT=5432
```

If `DB\_PASSWORD` is empty and the server needs one, the app asks for it when it starts.

## Usage

```
  1. Create customer            7. Mini statement
  2. Open account               8. Freeze / unfreeze / close account
  3. Deposit                    9. Reports and audit log
  4. Withdraw                  10. Batch transfer queue
  5. Transfer funds            11. Apply monthly interest
  6. View balance              12. Backup database (pg\_dump)
```

Example transfer (the sample data has accounts `1001` to `1009`):

```
Choose an option: 5
From account : 1001
To account   : 1002
Amount       : 100
Remarks (optional): rent
  \[OK] Transferred 100 from 1001 to 1002
```

Failed transfers show the reason raised by the database, for example an insufficient-funds message or a frozen-account error.

## Demos

Step-by-step experiments are in [`demos/TRANSACTION\_DEMOS.md`](demos/TRANSACTION_DEMOS.md). The three most useful ones:

1. **Rollback on failure**: transfer more than the sender's balance. The procedure raises an exception and both balances stay unchanged. You can also run `BEGIN; CALL transfer\_funds(...); ROLLBACK;` and watch the balances return to their old values.
2. **Automatic audit trail**: make one successful transfer, then open *Reports and audit log*. Rows for the debit and credit appear even though the Python code never writes to `audit\_log`.
3. **Concurrency and locking**: open two `psql` sessions, start a transfer in the first without committing, and the second transfer on the same accounts waits on the row lock until the first one commits or rolls back.

The same file also covers isolation levels, deadlocks, savepoints, crash recovery, backup/restore and two-phase commit.

## Troubleshooting

|Problem|Fix|
|-|-|
|`psql` or `pg\_dump` not recognised|Add PostgreSQL's `bin` folder to `PATH`|
|`password authentication failed`|Fix `DB\_PASSWORD` in `.env`, or leave it empty and enter the password at the prompt|
|`database "bankdb" does not exist`|Run `createdb -U postgres bankdb`|
|`CREATE PROCEDURE` syntax error|PostgreSQL must be version 11 or newer (14+ recommended)|
|`permission denied to create role`|Run the SQL files as a superuser such as `postgres`|

## Future Improvements

* Unit tests for procedures using pgTAP
* Low-balance alerts using `pg\_notify`
* Minimum-balance rule for savings accounts
* Fraud flag for several large transfers within a few minutes
* Scheduled backups and a restore command in the menu

## License

MIT. See [LICENSE](LICENSE).


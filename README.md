# Wallet Ledger: Terminal Banking with SQL, PL/pgSQL & Transactions

A lightweight, terminal-based mini banking system where the **business logic lives inside the database**. Fund transfers are handled by a PL/pgSQL stored procedure, every balance change is logged automatically by a trigger, and ACID transactions guarantee that money is never lost or created.

The Python client is intentionally thin: it only shows a menu and calls the database.

---

## Features

- **Account management**: accounts with owner, balance and `Active` / `Frozen` status
- **Atomic fund transfers**: debit and credit succeed together or not at all
- **Automatic audit logging**: a database trigger records every balance change, with no logging code in the app
- **Data integrity**: `CHECK` constraints reject negative balances even if the procedure has a bug
- **Concurrency safe**: row-level locks (`FOR UPDATE`) in a fixed order prevent race conditions and deadlocks
- **Terminal menu**: view balance, transfer funds, view audit log

---

## Tech Stack

| Layer | Technology |
|---|---|
| Database | PostgreSQL |
| Procedural logic | PL/pgSQL (stored procedure + trigger) |
| Client | Python 3, `psycopg2` |

> **Note:** Oracle's PL/SQL is heavyweight. PostgreSQL's PL/pgSQL works almost identically and runs on a much lighter open-source engine.

---

## Project Structure

```
wallet-ledger/
├── README.md
├── .gitignore
├── .env.example
├── requirements.txt
├── sql/
│   ├── 01_schema.sql        # tables and constraints
│   ├── 02_trigger.sql       # audit trigger
│   ├── 03_procedures.sql    # transfer_funds procedure
│   └── 04_seed.sql          # sample accounts
├── app/
│   └── main.py              # terminal client
└── docs/
    └── demo.md              # rollback and concurrency demos
```

---

## Database Design

### Tables

**`accounts`**

| Column | Type | Notes |
|---|---|---|
| `account_id` | SERIAL | Primary key |
| `owner_name` | VARCHAR(100) | Required |
| `balance` | NUMERIC(12,2) | `CHECK (balance >= 0)` |
| `status` | VARCHAR(10) | `Active` or `Frozen` |

**`audit_log`**

| Column | Type | Notes |
|---|---|---|
| `log_id` | SERIAL | Primary key |
| `account_id` | INT | References `accounts` |
| `action` | TEXT | e.g. `Balance changed: 500.00 -> 400.00` |
| `timestamp` | TIMESTAMP | Defaults to `now()` |

### Trigger: `trg_log_transactions`
Fires `AFTER UPDATE OF balance` on `accounts`. Whenever a balance changes, it inserts a row into `audit_log` with the old and new values. The application never writes to the log directly.

### Stored Procedure: `transfer_funds(sender_id, receiver_id, amount)`
Validates and performs a transfer in one transaction:

1. Amount must be positive
2. Sender and receiver must differ
3. Locks both rows in a fixed order (`ORDER BY account_id FOR UPDATE`)
4. Both accounts must exist and be `Active`
5. Sender must have sufficient funds
6. Debits the sender, credits the receiver

Any failed check raises an exception, which rolls back the entire transaction.

---

## ACID Properties: Where Each One Comes From

| Property | How it is enforced |
|---|---|
| **Atomicity** | `RAISE EXCEPTION` aborts the whole transaction, so debit and credit both happen or neither does |
| **Consistency** | `CHECK (balance >= 0)` and status constraints keep the data valid |
| **Isolation** | `SELECT ... FOR UPDATE` row locks stop concurrent transfers from interfering |
| **Durability** | PostgreSQL's Write-Ahead Log (WAL) persists committed transactions |

---

## Getting Started

### Prerequisites

- PostgreSQL 11 or later (needed for `CREATE PROCEDURE`)
- Python 3.8+

### Setup

```bash
# 1. Clone the repo
git clone https://github.com/sourabhvamdevan/wallet-ledger.git
cd wallet-ledger

# 2. Create the database and load the SQL files in order
createdb wallet
psql -d wallet -f sql/01_schema.sql
psql -d wallet -f sql/02_trigger.sql
psql -d wallet -f sql/03_procedures.sql
psql -d wallet -f sql/04_seed.sql

# 3. Install Python dependencies
pip install -r requirements.txt

# 4. Configure credentials
cp .env.example .env
# edit .env with your database details

# 5. Run the app
python app/main.py
```

### Environment Variables

```
DB_NAME=wallet
DB_USER=postgres
DB_PASSWORD=your_password_here
DB_HOST=localhost
```

---

## Usage

```
1) Balance  2) Transfer  3) Audit log  4) Exit
> 2
From: 1
To: 2
Amount: 100
Transfer successful
```

Failed transfers show the reason from the database, for example `Insufficient funds (balance: 50.00)` or `Account is frozen`.

---

## Demos

### 1. Rollback on failure
Transfer more than the sender's balance. The procedure raises an exception and **both balances stay unchanged**.

### 2. Automatic audit trail
Run one successful transfer, then open the audit log. Two rows appear, one for the debit and one for the credit, even though the Python code never touches `audit_log`.

### 3. Concurrency and locking
Open two terminals:

```sql
-- Terminal 1
BEGIN;
CALL transfer_funds(1, 2, 100);
-- do not commit yet

-- Terminal 2
BEGIN;
CALL transfer_funds(1, 2, 50);
-- waits on the row lock until Terminal 1 commits or rolls back
```

---

## Future Improvements

- Deposit and withdraw procedures
- Dedicated `transactions` history table with transaction IDs
- `SAVEPOINT` example for partial rollbacks
- Account freeze/unfreeze admin commands
- Unit tests for procedures using `pgTAP`

---

## Author

Veera 

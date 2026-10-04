# Transaction & Concurrency Demos

Run these with **two terminals** open, both connected to the database:

```
psql -U postgres -d bankdb
```

Call them **Session 1** and **Session 2**. Reinstall (`sql/install.sql`) before each demo so the data is in a known state: account **1001** has 68 000.00 and **1002** has 33 500.00 after seeding.

---

## 1. Atomicity - all or nothing

```sql
-- Session 1
BEGIN;
CALL transfer_funds(1001, 1002, 1000, 'atomic test');
SELECT account_id, balance FROM accounts WHERE account_id IN (1001, 1002);  -- both changed
ROLLBACK;
SELECT account_id, balance FROM accounts WHERE account_id IN (1001, 1002);  -- back to the original values
```

A failing transfer leaves nothing behind either:

```sql
CALL transfer_funds(1001, 1002, 99999999, 'too big');
-- ERROR: Insufficient funds ...
SELECT count(*) FROM transactions WHERE remarks = 'too big';   -- 0
```

## 2. Consistency - constraints and triggers protect the rules

```sql
UPDATE accounts SET balance = -5 WHERE account_id = 1001;       -- CHECK constraint ck_balance_non_negative
UPDATE transactions SET amount = 1 WHERE txn_id = 1;            -- ERROR BK003 (append-only ledger)
DELETE FROM accounts WHERE account_id = 1001;                   -- ERROR BK002 (account holds money)
UPDATE accounts SET balance = balance + 1 WHERE account_id = 1009;  -- ERROR BK001 (account is FROZEN)
```

Daily limit (trigger `trg_daily_limit`, limit 50 000 per account per day):

```sql
CALL transfer_funds(1001, 1002, 30000);   -- OK  (19 000 already used today + 30 000 = 49 000)
CALL transfer_funds(1001, 1002, 5000);    -- ERROR BK004 Daily outgoing limit exceeded
```

## 3. Isolation - non-repeatable read

```sql
-- Session 1
BEGIN;                                   -- READ COMMITTED (default)
SELECT balance FROM accounts WHERE account_id = 1001;     -- e.g. 68000.00

-- Session 2
UPDATE accounts SET balance = balance + 500 WHERE account_id = 1001;   -- autocommits

-- Session 1
SELECT balance FROM accounts WHERE account_id = 1001;     -- 68500.00  (value changed inside ONE transaction)
COMMIT;
```

Same experiment at a stricter level:

```sql
-- Session 1
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT balance FROM accounts WHERE account_id = 1001;

-- Session 2
UPDATE accounts SET balance = balance + 500 WHERE account_id = 1001;

-- Session 1
SELECT balance FROM accounts WHERE account_id = 1001;     -- SAME value as before (snapshot)
UPDATE accounts SET balance = balance - 1 WHERE account_id = 1001;
-- ERROR: could not serialize access due to concurrent update
ROLLBACK;
```

`app.py` automatically retries a transfer that fails with this error (SQLSTATE 40001).

## 4. Lost update - and why `balance = balance + x` is safe

Unsafe pattern (read in the application, write back a computed value):

```sql
-- Session 1
BEGIN;
SELECT balance FROM accounts WHERE account_id = 1001;   -- app reads 68000

-- Session 2
BEGIN;
SELECT balance FROM accounts WHERE account_id = 1001;   -- app reads 68000
UPDATE accounts SET balance = 68100 WHERE account_id = 1001;   -- +100
COMMIT;

-- Session 1
UPDATE accounts SET balance = 68200 WHERE account_id = 1001;   -- +200, overwrites Session 2's +100
COMMIT;                                                        -- +100 is LOST
```

Safe pattern - the database calculates and the row lock serialises writers (this is what the procedures do):

```sql
UPDATE accounts SET balance = balance + 100 WHERE account_id = 1001;
```

## 5. Locking and deadlock

```sql
-- Session 1
BEGIN;
UPDATE accounts SET balance = balance - 1 WHERE account_id = 1001;

-- Session 2
BEGIN;
UPDATE accounts SET balance = balance - 1 WHERE account_id = 1002;

-- Session 1  (waits for Session 2)
UPDATE accounts SET balance = balance + 1 WHERE account_id = 1002;

-- Session 2  (closes the cycle)
UPDATE accounts SET balance = balance + 1 WHERE account_id = 1001;
-- ERROR: deadlock detected  -> PostgreSQL aborts one session, the other continues
```

Run `ROLLBACK;` in the aborted session and `COMMIT;` in the other.

**The fix used by `transfer_funds`:** it always locks the lower account number first (`ORDER BY account_id FOR UPDATE`). Run two opposite transfers at the same moment, `1001 -> 1002` and `1002 -> 1001`, from both sessions: one waits, then proceeds. No deadlock.

To watch the locks:

```sql
SELECT pid, locktype, relation::regclass, mode, granted FROM pg_locks WHERE relation = 'accounts'::regclass;
```

## 6. Savepoints - partial rollback

```sql
BEGIN;
CALL transfer_funds(1001, 1002, 100, 'first');
SAVEPOINT after_first;
CALL transfer_funds(1001, 1002, 200, 'second');
ROLLBACK TO SAVEPOINT after_first;      -- undo only the second transfer
COMMIT;                                 -- the first one is saved
SELECT remarks FROM transactions WHERE remarks IN ('first', 'second');   -- only 'first'
```

Batch version: `CALL process_transfer_queue();` processes the 3 seeded queue rows. The valid one succeeds, the other two are marked `FAILED` with the reason, and nothing already done is lost.

```sql
SELECT queue_id, status, error_msg FROM transfer_queue ORDER BY queue_id;
```

## 7. Durability and crash recovery

**Uncommitted work disappears when a session dies**

```sql
-- Session 1
BEGIN;
CALL transfer_funds(1001, 1002, 700, 'never committed');
SELECT pg_backend_pid();         -- note the number, e.g. 12345

-- Session 2
SELECT pg_terminate_backend(12345);   -- use the number you noted

-- Session 2 (afterwards)
SELECT count(*) FROM transactions WHERE remarks = 'never committed';   -- 0
```

**Committed work survives a server crash** (write-ahead log replay)

```sql
CALL transfer_funds(1001, 1002, 1, 'durable');   -- autocommit -> committed
```

Then stop the server *without* a clean shutdown and start it again:

```
pg_ctl stop -m immediate -D <your data directory>
pg_ctl start -D <your data directory>
```

```sql
SELECT * FROM transactions WHERE remarks = 'durable';   -- still there
```

(On Windows installs, use the "Stop/Start Service" entries in Services, or run `pg_ctl` from PostgreSQL's `bin` folder.)

## 8. Backup and restore

```
pg_dump -U postgres -d bankdb -f backups/bankdb.sql          # same as menu option 12
createdb -U postgres bankdb_restored
psql -U postgres -d bankdb_restored -f backups/bankdb.sql
```

## 9. Two-phase commit (optional)

Needs `max_prepared_transactions = 10` in `postgresql.conf` and a restart.

```sql
BEGIN;
CALL transfer_funds(1001, 1002, 10, '2pc');
PREPARE TRANSACTION 'tx_demo';          -- phase 1: vote YES, changes are now durable but invisible
SELECT gid FROM pg_prepared_xacts;
COMMIT PREPARED 'tx_demo';              -- phase 2 (or ROLLBACK PREPARED 'tx_demo')
```

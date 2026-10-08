-- =====================================================================
-- schema.sql  |  BankLedger (SQLite edition)
-- Tables + indexes + triggers + views in one file.
-- WARNING: this script DROPS and recreates every project object.
-- =====================================================================

DROP VIEW  IF EXISTS v_active_accounts;
DROP VIEW  IF EXISTS v_public_accounts;
DROP VIEW  IF EXISTS v_dormant_accounts;
DROP VIEW  IF EXISTS v_daily_volume;
DROP VIEW  IF EXISTS v_branch_summary;
DROP VIEW  IF EXISTS v_customer_portfolio;
DROP VIEW  IF EXISTS v_account_overview;
DROP TABLE IF EXISTS transfer_queue;
DROP TABLE IF EXISTS audit_log;
DROP TABLE IF EXISTS transactions;
DROP TABLE IF EXISTS nominees;
DROP TABLE IF EXISTS accounts;
DROP TABLE IF EXISTS customers;
DROP TABLE IF EXISTS branches;

-- ---------------------------------------------------------------------
-- TABLES
-- (Money columns are NUMERIC; SQLite stores them as REAL, so every
--  update in the app uses ROUND(..., 2).)
-- ---------------------------------------------------------------------
CREATE TABLE branches (
    branch_id    INTEGER PRIMARY KEY AUTOINCREMENT,
    branch_name  TEXT NOT NULL UNIQUE,
    city         TEXT NOT NULL
);

CREATE TABLE customers (
    customer_id  INTEGER PRIMARY KEY AUTOINCREMENT,
    full_name    TEXT NOT NULL,
    email        TEXT NOT NULL UNIQUE
                 CONSTRAINT ck_customer_email CHECK (email LIKE '%_@_%._%'),
    phone        TEXT
                 CONSTRAINT ck_customer_phone CHECK (
                     phone IS NULL OR
                     (length(phone) BETWEEN 7 AND 15 AND phone NOT GLOB '*[^0-9+]*')),
    created_at   TEXT NOT NULL DEFAULT (datetime('now','localtime'))
);

-- account numbers start at 1001 (see the sqlite_sequence insert below)
CREATE TABLE accounts (
    account_id    INTEGER PRIMARY KEY AUTOINCREMENT,
    customer_id   INTEGER NOT NULL REFERENCES customers(customer_id) ON DELETE RESTRICT,
    branch_id     INTEGER NOT NULL REFERENCES branches(branch_id)    ON DELETE RESTRICT,
    account_type  TEXT NOT NULL
                  CONSTRAINT ck_account_type CHECK (account_type IN ('SAVINGS','CURRENT')),
    balance       NUMERIC NOT NULL DEFAULT 0
                  CONSTRAINT ck_balance_non_negative CHECK (balance >= 0),
    status        TEXT NOT NULL DEFAULT 'ACTIVE'
                  CONSTRAINT ck_account_status CHECK (status IN ('ACTIVE','FROZEN','CLOSED')),
    opened_on     TEXT NOT NULL DEFAULT (date('now','localtime'))
);

-- WEAK ENTITY: identified by account_id + nominee_no
CREATE TABLE nominees (
    account_id     INTEGER NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
    nominee_no     INTEGER NOT NULL CHECK (nominee_no > 0),
    nominee_name   TEXT NOT NULL,
    relation       TEXT NOT NULL,
    share_percent  NUMERIC NOT NULL DEFAULT 100
                   CHECK (share_percent > 0 AND share_percent <= 100),
    PRIMARY KEY (account_id, nominee_no)
);

-- THE IMMUTABLE LEDGER
CREATE TABLE transactions (
    txn_id        INTEGER PRIMARY KEY AUTOINCREMENT,
    txn_type      TEXT NOT NULL
                  CONSTRAINT ck_txn_type CHECK (txn_type IN ('DEPOSIT','WITHDRAWAL','TRANSFER','INTEREST')),
    from_account  INTEGER REFERENCES accounts(account_id),
    to_account    INTEGER REFERENCES accounts(account_id),
    amount        NUMERIC NOT NULL CHECK (amount > 0),
    txn_time      TEXT NOT NULL DEFAULT (datetime('now','localtime')),
    remarks       TEXT,
    CONSTRAINT ck_txn_shape CHECK (
           (txn_type IN ('DEPOSIT','INTEREST') AND from_account IS NULL     AND to_account IS NOT NULL)
        OR (txn_type = 'WITHDRAWAL'            AND from_account IS NOT NULL AND to_account IS NULL)
        OR (txn_type = 'TRANSFER'              AND from_account IS NOT NULL AND to_account IS NOT NULL
                                               AND from_account <> to_account)
    )
);

-- filled only by triggers; no FK on purpose so history survives deletes
CREATE TABLE audit_log (
    audit_id     INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id   INTEGER NOT NULL,
    action       TEXT NOT NULL CHECK (action IN ('UPDATE','DELETE')),
    old_balance  NUMERIC,
    new_balance  NUMERIC,
    old_status   TEXT,
    new_status   TEXT,
    changed_by   TEXT NOT NULL DEFAULT 'bankledger_app',
    changed_at   TEXT NOT NULL DEFAULT (datetime('now','localtime'))
);

CREATE TABLE transfer_queue (
    queue_id      INTEGER PRIMARY KEY AUTOINCREMENT,
    from_account  INTEGER NOT NULL REFERENCES accounts(account_id),
    to_account    INTEGER NOT NULL REFERENCES accounts(account_id),
    amount        NUMERIC NOT NULL CHECK (amount > 0),
    status        TEXT NOT NULL DEFAULT 'PENDING'
                  CHECK (status IN ('PENDING','DONE','FAILED')),
    error_msg     TEXT,
    queued_at     TEXT NOT NULL DEFAULT (datetime('now','localtime')),
    processed_at  TEXT
);

-- first account number will be 1001
INSERT INTO sqlite_sequence(name, seq) VALUES ('accounts', 1000);

-- ---------------------------------------------------------------------
-- INDEXES
-- ---------------------------------------------------------------------
CREATE INDEX idx_accounts_customer ON accounts(customer_id);
CREATE INDEX idx_accounts_branch   ON accounts(branch_id);
CREATE INDEX idx_txn_from          ON transactions(from_account, txn_time DESC);
CREATE INDEX idx_txn_to            ON transactions(to_account,   txn_time DESC);
CREATE INDEX idx_audit_account     ON audit_log(account_id, changed_at DESC);
CREATE INDEX idx_queue_pending     ON transfer_queue(queue_id) WHERE status = 'PENDING';

-- =====================================================================
-- TRIGGERS  (error codes BK001..BK004 appear in the message text)
-- SQLite's RAISE() only accepts a fixed message, so the account number
-- is not part of the text here (the PostgreSQL version includes it).
-- =====================================================================

-- 1. AUDIT TRAIL (the application never writes audit_log)
CREATE TRIGGER trg_account_audit_update
AFTER UPDATE ON accounts
WHEN NEW.balance IS NOT OLD.balance OR NEW.status IS NOT OLD.status
BEGIN
    INSERT INTO audit_log(account_id, action, old_balance, new_balance, old_status, new_status)
    VALUES (OLD.account_id, 'UPDATE', OLD.balance, NEW.balance, OLD.status, NEW.status);
END;

CREATE TRIGGER trg_account_audit_delete
AFTER DELETE ON accounts
BEGIN
    INSERT INTO audit_log(account_id, action, old_balance, old_status)
    VALUES (OLD.account_id, 'DELETE', OLD.balance, OLD.status);
END;

-- 2. FROZEN / CLOSED GUARD
CREATE TRIGGER trg_block_inactive_update
BEFORE UPDATE OF balance ON accounts
WHEN OLD.status <> 'ACTIVE' AND NEW.balance IS NOT OLD.balance
BEGIN
    SELECT RAISE(ABORT, 'BK001: account is FROZEN or CLOSED, balance cannot be changed');
END;

-- 3. DELETE GUARD
CREATE TRIGGER trg_block_account_delete
BEFORE DELETE ON accounts
WHEN OLD.balance <> 0
BEGIN
    SELECT RAISE(ABORT, 'BK002: account still holds money, it cannot be deleted');
END;

-- 4. IMMUTABLE LEDGER
CREATE TRIGGER trg_ledger_no_update
BEFORE UPDATE ON transactions
BEGIN
    SELECT RAISE(ABORT, 'BK003: the transaction ledger is append-only, UPDATE is not allowed');
END;

CREATE TRIGGER trg_ledger_no_delete
BEFORE DELETE ON transactions
BEGIN
    SELECT RAISE(ABORT, 'BK003: the transaction ledger is append-only, DELETE is not allowed');
END;

-- 5. DAILY OUTGOING LIMIT (50 000 per account per day)
CREATE TRIGGER trg_daily_limit
BEFORE INSERT ON transactions
WHEN NEW.from_account IS NOT NULL
 AND (SELECT COALESCE(SUM(t.amount), 0)
        FROM transactions t
       WHERE t.from_account = NEW.from_account
         AND t.txn_time >= date('now','localtime')) + NEW.amount > 50000
BEGIN
    SELECT RAISE(ABORT, 'BK004: daily outgoing limit of 50000 exceeded for this account');
END;

-- =====================================================================
-- VIEWS
-- =====================================================================
CREATE VIEW v_account_overview AS
SELECT a.account_id,
       c.full_name   AS owner,
       b.branch_name AS branch,
       b.city,
       a.account_type,
       a.balance,
       a.status,
       a.opened_on
  FROM accounts a
  JOIN customers c ON c.customer_id = a.customer_id
  JOIN branches  b ON b.branch_id   = a.branch_id;

CREATE VIEW v_customer_portfolio AS
SELECT c.customer_id,
       c.full_name,
       COUNT(a.account_id)         AS accounts,
       COALESCE(SUM(a.balance), 0) AS total_balance
  FROM customers c
  LEFT JOIN accounts a ON a.customer_id = c.customer_id
 GROUP BY c.customer_id, c.full_name;

CREATE VIEW v_branch_summary AS
SELECT b.branch_id,
       b.branch_name,
       b.city,
       COUNT(a.account_id)                   AS accounts,
       COALESCE(SUM(a.balance), 0)           AS total_deposits,
       COALESCE(ROUND(AVG(a.balance), 2), 0) AS avg_balance
  FROM branches b
  LEFT JOIN accounts a ON a.branch_id = b.branch_id
 GROUP BY b.branch_id, b.branch_name, b.city;

CREATE VIEW v_daily_volume AS
SELECT date(t.txn_time) AS txn_date,
       t.txn_type,
       COUNT(*)         AS txn_count,
       SUM(t.amount)    AS total_amount
  FROM transactions t
 GROUP BY date(t.txn_time), t.txn_type;

CREATE VIEW v_dormant_accounts AS
SELECT a.account_id, c.full_name AS owner, a.balance, a.status, a.opened_on
  FROM accounts a
  JOIN customers c ON c.customer_id = a.customer_id
 WHERE NOT EXISTS (SELECT 1 FROM transactions t
                    WHERE t.from_account = a.account_id
                       OR t.to_account   = a.account_id);

-- SECURITY VIEW: masked names, no balances (SQLite has no roles/GRANT,
-- so this view only shows the idea; it does not restrict anybody).
CREATE VIEW v_public_accounts AS
SELECT a.account_id,
       substr(c.full_name, 1, 1) ||
       replace(hex(zeroblob(max(length(c.full_name) - 1, 0))), '00', '*') AS owner_masked,
       b.branch_name AS branch,
       a.account_type,
       a.status
  FROM accounts a
  JOIN customers c ON c.customer_id = a.customer_id
  JOIN branches  b ON b.branch_id   = a.branch_id;

-- UPDATABLE VIEW: SQLite has no WITH CHECK OPTION, so an INSTEAD OF
-- trigger provides the same behaviour.
CREATE VIEW v_active_accounts AS
SELECT account_id, customer_id, branch_id, account_type, balance, status
  FROM accounts
 WHERE status = 'ACTIVE';

CREATE TRIGGER trg_active_accounts_update
INSTEAD OF UPDATE ON v_active_accounts
BEGIN
    SELECT RAISE(ABORT, 'CHECK OPTION: the row would no longer be ACTIVE')
     WHERE NEW.status <> 'ACTIVE';
    UPDATE accounts
       SET account_type = NEW.account_type,
           balance      = NEW.balance
     WHERE account_id = OLD.account_id;
END;

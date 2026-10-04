-- =====================================================================
-- 01_schema.sql  |  BankLedger - tables, constraints, sequences, indexes
-- Target: PostgreSQL 14+
-- WARNING: this script DROPS and recreates all project tables.
-- =====================================================================

DROP TABLE IF EXISTS transfer_queue, audit_log, transactions,
                     nominees, accounts, customers, branches CASCADE;

-- ---------------------------------------------------------------------
-- BRANCHES
-- ---------------------------------------------------------------------
CREATE TABLE branches (
    branch_id    INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    branch_name  VARCHAR(60) NOT NULL UNIQUE,
    city         VARCHAR(40) NOT NULL
);

-- ---------------------------------------------------------------------
-- CUSTOMERS
-- ---------------------------------------------------------------------
CREATE TABLE customers (
    customer_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name    VARCHAR(80)  NOT NULL,
    email        VARCHAR(120) NOT NULL UNIQUE
                 CONSTRAINT ck_customer_email CHECK (email LIKE '%_@_%._%'),
    phone        VARCHAR(15)
                 CONSTRAINT ck_customer_phone CHECK (phone ~ '^[0-9+]{7,15}$'),
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- ACCOUNTS  (account numbers start at 1001 - an identity sequence)
-- ---------------------------------------------------------------------
CREATE TABLE accounts (
    account_id    BIGINT GENERATED ALWAYS AS IDENTITY (START WITH 1001) PRIMARY KEY,
    customer_id   BIGINT        NOT NULL REFERENCES customers(customer_id) ON DELETE RESTRICT,
    branch_id     INT           NOT NULL REFERENCES branches(branch_id)    ON DELETE RESTRICT,
    account_type  VARCHAR(10)   NOT NULL
                  CONSTRAINT ck_account_type CHECK (account_type IN ('SAVINGS','CURRENT')),
    balance       NUMERIC(14,2) NOT NULL DEFAULT 0
                  CONSTRAINT ck_balance_non_negative CHECK (balance >= 0),
    status        VARCHAR(10)   NOT NULL DEFAULT 'ACTIVE'
                  CONSTRAINT ck_account_status CHECK (status IN ('ACTIVE','FROZEN','CLOSED')),
    opened_on     DATE          NOT NULL DEFAULT CURRENT_DATE
);

-- ---------------------------------------------------------------------
-- NOMINEES  (WEAK ENTITY: identified by account_id + nominee_no)
-- ---------------------------------------------------------------------
CREATE TABLE nominees (
    account_id     BIGINT       NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
    nominee_no     SMALLINT     NOT NULL CHECK (nominee_no > 0),
    nominee_name   VARCHAR(80)  NOT NULL,
    relation       VARCHAR(30)  NOT NULL,
    share_percent  NUMERIC(5,2) NOT NULL DEFAULT 100
                   CHECK (share_percent > 0 AND share_percent <= 100),
    PRIMARY KEY (account_id, nominee_no)
);

-- ---------------------------------------------------------------------
-- TRANSACTIONS  (the immutable ledger)
-- DEPOSIT / INTEREST : money comes IN   -> only to_account is set
-- WITHDRAWAL         : money goes OUT   -> only from_account is set
-- TRANSFER           : both are set and must differ
-- ---------------------------------------------------------------------
CREATE TABLE transactions (
    txn_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    txn_type      VARCHAR(10)   NOT NULL
                  CONSTRAINT ck_txn_type CHECK (txn_type IN ('DEPOSIT','WITHDRAWAL','TRANSFER','INTEREST')),
    from_account  BIGINT        REFERENCES accounts(account_id),
    to_account    BIGINT        REFERENCES accounts(account_id),
    amount        NUMERIC(14,2) NOT NULL CHECK (amount > 0),
    txn_time      TIMESTAMPTZ   NOT NULL DEFAULT now(),
    remarks       VARCHAR(120),
    CONSTRAINT ck_txn_shape CHECK (
           (txn_type IN ('DEPOSIT','INTEREST') AND from_account IS NULL     AND to_account IS NOT NULL)
        OR (txn_type = 'WITHDRAWAL'            AND from_account IS NOT NULL AND to_account IS NULL)
        OR (txn_type = 'TRANSFER'              AND from_account IS NOT NULL AND to_account IS NOT NULL
                                               AND from_account <> to_account)
    )
);

-- ---------------------------------------------------------------------
-- AUDIT_LOG  (filled only by triggers)
-- account_id deliberately has NO foreign key, so the history survives
-- even if an account row is deleted.
-- ---------------------------------------------------------------------
CREATE TABLE audit_log (
    audit_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_id   BIGINT        NOT NULL,
    action       VARCHAR(10)   NOT NULL CHECK (action IN ('UPDATE','DELETE')),
    old_balance  NUMERIC(14,2),
    new_balance  NUMERIC(14,2),
    old_status   VARCHAR(10),
    new_status   VARCHAR(10),
    changed_by   TEXT          NOT NULL DEFAULT current_user,
    changed_at   TIMESTAMPTZ   NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- TRANSFER_QUEUE  (batch transfers processed with a loop + savepoints)
-- ---------------------------------------------------------------------
CREATE TABLE transfer_queue (
    queue_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    from_account  BIGINT        NOT NULL REFERENCES accounts(account_id),
    to_account    BIGINT        NOT NULL REFERENCES accounts(account_id),
    amount        NUMERIC(14,2) NOT NULL CHECK (amount > 0),
    status        VARCHAR(10)   NOT NULL DEFAULT 'PENDING'
                  CHECK (status IN ('PENDING','DONE','FAILED')),
    error_msg     TEXT,
    queued_at     TIMESTAMPTZ   NOT NULL DEFAULT now(),
    processed_at  TIMESTAMPTZ
);

-- ---------------------------------------------------------------------
-- INDEXES (foreign keys are not indexed automatically in PostgreSQL)
-- ---------------------------------------------------------------------
CREATE INDEX idx_accounts_customer ON accounts(customer_id);
CREATE INDEX idx_accounts_branch   ON accounts(branch_id);
CREATE INDEX idx_txn_from          ON transactions(from_account, txn_time DESC);
CREATE INDEX idx_txn_to            ON transactions(to_account,   txn_time DESC);
CREATE INDEX idx_audit_account     ON audit_log(account_id, changed_at DESC);
CREATE INDEX idx_queue_pending     ON transfer_queue(queue_id) WHERE status = 'PENDING';

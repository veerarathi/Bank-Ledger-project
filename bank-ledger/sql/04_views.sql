-- =====================================================================
-- 04_views.sql  |  BankLedger views and role-based access
-- =====================================================================

-- Full picture of every account (3-table join)
CREATE OR REPLACE VIEW v_account_overview AS
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

-- Aggregate: one row per customer (LEFT JOIN keeps customers with no account)
CREATE OR REPLACE VIEW v_customer_portfolio AS
SELECT c.customer_id,
       c.full_name,
       COUNT(a.account_id)             AS accounts,
       COALESCE(SUM(a.balance), 0)     AS total_balance
  FROM customers c
  LEFT JOIN accounts a ON a.customer_id = c.customer_id
 GROUP BY c.customer_id, c.full_name;

-- Aggregate: one row per branch
CREATE OR REPLACE VIEW v_branch_summary AS
SELECT b.branch_id,
       b.branch_name,
       b.city,
       COUNT(a.account_id)                       AS accounts,
       COALESCE(SUM(a.balance), 0)               AS total_deposits,
       COALESCE(ROUND(AVG(a.balance), 2), 0)     AS avg_balance
  FROM branches b
  LEFT JOIN accounts a ON a.branch_id = b.branch_id
 GROUP BY b.branch_id, b.branch_name, b.city;

-- Daily volume by transaction type
CREATE OR REPLACE VIEW v_daily_volume AS
SELECT t.txn_time::date  AS txn_date,
       t.txn_type,
       COUNT(*)          AS txn_count,
       SUM(t.amount)     AS total_amount
  FROM transactions t
 GROUP BY t.txn_time::date, t.txn_type;

-- Accounts that have never sent or received money
CREATE OR REPLACE VIEW v_dormant_accounts AS
SELECT a.account_id, c.full_name AS owner, a.balance, a.status, a.opened_on
  FROM accounts a
  JOIN customers c ON c.customer_id = a.customer_id
 WHERE NOT EXISTS (SELECT 1
                     FROM transactions t
                    WHERE t.from_account = a.account_id
                       OR t.to_account   = a.account_id);

-- SECURITY VIEW: masks names and hides balances (for tellers)
CREATE OR REPLACE VIEW v_public_accounts AS
SELECT a.account_id,
       LEFT(c.full_name, 1) || REPEAT('*', GREATEST(LENGTH(c.full_name) - 1, 0)) AS owner_masked,
       b.branch_name AS branch,
       a.account_type,
       a.status
  FROM accounts a
  JOIN customers c ON c.customer_id = a.customer_id
  JOIN branches  b ON b.branch_id   = a.branch_id;

-- UPDATABLE VIEW with CHECK OPTION: only ACTIVE rows can be seen/edited through it
CREATE OR REPLACE VIEW v_active_accounts AS
SELECT account_id, customer_id, branch_id, account_type, balance, status
  FROM accounts
 WHERE status = 'ACTIVE'
  WITH CHECK OPTION;

-- ---------------------------------------------------------------------
-- ROLE-BASED ACCESS: a teller may read the masked view but not the tables.
-- (Needs a role with CREATEROLE, e.g. the postgres superuser.)
-- ---------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bank_teller') THEN
        CREATE ROLE bank_teller NOLOGIN;
    END IF;
END $$;

GRANT SELECT ON v_public_accounts TO bank_teller;

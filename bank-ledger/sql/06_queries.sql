-- =====================================================================
-- 06_queries.sql  |  Showcase queries (run after 05_seed.sql)
-- Each query is tagged with the syllabus topic it demonstrates.
-- =====================================================================

-- Q1  JOIN (3 tables): every account with owner and branch
SELECT a.account_id, c.full_name, b.branch_name, a.balance
  FROM accounts a
  JOIN customers c ON c.customer_id = a.customer_id
  JOIN branches  b ON b.branch_id   = a.branch_id
 ORDER BY a.account_id;

-- Q2  GROUP BY + HAVING: customers holding more than one account
SELECT c.full_name, COUNT(*) AS accounts, SUM(a.balance) AS total_balance
  FROM customers c
  JOIN accounts a ON a.customer_id = c.customer_id
 GROUP BY c.full_name
HAVING COUNT(*) > 1
 ORDER BY total_balance DESC;

-- Q3  Aggregates: deposits per branch
SELECT b.branch_name, COUNT(a.account_id) AS accounts,
       SUM(a.balance) AS total, ROUND(AVG(a.balance), 2) AS average,
       MAX(a.balance) AS richest, MIN(a.balance) AS poorest
  FROM branches b
  LEFT JOIN accounts a ON a.branch_id = b.branch_id
 GROUP BY b.branch_name;

-- Q4  Nested sub-query: accounts holding more than the bank-wide average
SELECT account_id, balance
  FROM accounts
 WHERE balance > (SELECT AVG(balance) FROM accounts)
 ORDER BY balance DESC;

-- Q5  Correlated sub-query: the richest account of each branch
SELECT a.branch_id, a.account_id, a.balance
  FROM accounts a
 WHERE a.balance = (SELECT MAX(x.balance) FROM accounts x WHERE x.branch_id = a.branch_id);

-- Q6  ALL operator: accounts richer than every Bhopal (City Center) account
SELECT account_id, balance
  FROM accounts
 WHERE balance > ALL (SELECT balance FROM accounts WHERE branch_id = 2);

-- Q7  ANY operator: accounts richer than at least one Tech Park account
SELECT account_id, balance
  FROM accounts
 WHERE balance > ANY (SELECT balance FROM accounts WHERE branch_id = 3)
 ORDER BY balance;

-- Q8  SET operators: UNION / INTERSECT / EXCEPT on senders and receivers
SELECT from_account AS account_id FROM transactions WHERE txn_type = 'TRANSFER'
UNION
SELECT to_account FROM transactions WHERE txn_type = 'TRANSFER';        -- sent OR received

SELECT from_account FROM transactions WHERE txn_type = 'TRANSFER'
INTERSECT
SELECT to_account   FROM transactions WHERE txn_type = 'TRANSFER';      -- sent AND received

SELECT to_account   FROM transactions WHERE txn_type = 'TRANSFER'
EXCEPT
SELECT from_account FROM transactions WHERE txn_type = 'TRANSFER';      -- received, never sent

-- Q9  RELATIONAL DIVISION: customers with an account in EVERY branch
SELECT c.full_name
  FROM customers c
 WHERE NOT EXISTS (
        SELECT 1 FROM branches b
         WHERE NOT EXISTS (SELECT 1 FROM accounts a
                            WHERE a.customer_id = c.customer_id
                              AND a.branch_id   = b.branch_id));

-- Q10 SELF JOIN: pairs of accounts that belong to the same customer
SELECT a1.customer_id, a1.account_id AS account_1, a2.account_id AS account_2
  FROM accounts a1
  JOIN accounts a2 ON a1.customer_id = a2.customer_id
                  AND a1.account_id  < a2.account_id
 ORDER BY a1.customer_id;

-- Q11 WINDOW FUNCTION: running balance of account 1001
SELECT txn_id, txn_time::timestamp(0) AS at, txn_type,
       CASE WHEN to_account = 1001 THEN amount ELSE -amount END AS signed_amount,
       SUM(CASE WHEN to_account = 1001 THEN amount ELSE -amount END)
           OVER (ORDER BY txn_time, txn_id) AS running_total
  FROM transactions
 WHERE 1001 IN (from_account, to_account)
 ORDER BY txn_time, txn_id;

-- Q12 WINDOW FUNCTION: rank accounts inside their branch
SELECT branch_id, account_id, balance,
       RANK() OVER (PARTITION BY branch_id ORDER BY balance DESC) AS rank_in_branch
  FROM accounts;

-- Q13 CTE: top senders by total money transferred out
WITH sent AS (
    SELECT from_account, SUM(amount) AS total_sent, COUNT(*) AS transfers
      FROM transactions
     WHERE txn_type = 'TRANSFER'
     GROUP BY from_account
)
SELECT s.from_account, c.full_name, s.total_sent, s.transfers
  FROM sent s
  JOIN accounts  a ON a.account_id  = s.from_account
  JOIN customers c ON c.customer_id = a.customer_id
 ORDER BY s.total_sent DESC
 LIMIT 3;

-- Q14 CASE (conditional expression): balance tiers
SELECT account_id, balance,
       CASE WHEN balance >= 50000 THEN 'Gold'
            WHEN balance >= 20000 THEN 'Silver'
            ELSE 'Standard' END AS tier
  FROM accounts
 ORDER BY balance DESC;

-- Q15 Single-row functions: string handling
SELECT UPPER(full_name)              AS name_upper,
       SPLIT_PART(email, '@', 2)     AS email_domain,
       LENGTH(full_name)             AS name_length
  FROM customers;

-- Q16 ROLLUP: totals per transaction type and a grand total
SELECT COALESCE(txn_type, 'ALL TYPES') AS txn_type, COUNT(*) AS txns, SUM(amount) AS total
  FROM transactions
 GROUP BY ROLLUP (txn_type);

-- Q17 Views: using the views from 04_views.sql
SELECT * FROM v_branch_summary;
SELECT * FROM v_customer_portfolio ORDER BY total_balance DESC;
SELECT * FROM v_dormant_accounts;
SELECT * FROM v_public_accounts;

-- Q18 Audit trail written by the trigger
SELECT audit_id, account_id, action, old_balance, new_balance, old_status, new_status, changed_by
  FROM audit_log
 ORDER BY audit_id DESC
 LIMIT 10;

-- Q19 Query cost (Unit 4): compare the plan with and without the index
EXPLAIN ANALYZE SELECT * FROM transactions WHERE from_account = 1001;
-- To see the difference:  DROP INDEX idx_txn_from;  run it again; then re-create the index.

-- Q20 Calling the stored functions
SELECT fn_get_balance(1001)       AS balance,
       fn_account_location(1001)  AS location;
SELECT * FROM fn_mini_statement(1001, 5);

-- Q21 Reconciliation: stored balance must equal credits minus debits in the ledger
WITH ledger AS (
    SELECT a.account_id,
           a.balance AS stored_balance,
           COALESCE((SELECT SUM(t.amount) FROM transactions t WHERE t.to_account   = a.account_id), 0)
         - COALESCE((SELECT SUM(t.amount) FROM transactions t WHERE t.from_account = a.account_id), 0)
             AS ledger_balance
      FROM accounts a
)
SELECT account_id, stored_balance, ledger_balance, stored_balance - ledger_balance AS difference
  FROM ledger
 ORDER BY account_id;      -- every difference must be 0.00

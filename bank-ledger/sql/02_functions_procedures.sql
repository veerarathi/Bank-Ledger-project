-- =====================================================================
-- 02_functions_procedures.sql  |  BankLedger business logic (PL/pgSQL)
-- Convention:  PROCEDURES perform actions (call with CALL)
--              FUNCTIONS  return values   (call with SELECT)
-- None of them COMMIT: the caller (psql / app.py) owns the transaction,
-- so every routine is automatically atomic with whatever surrounds it.
-- =====================================================================

-- ---------------------------------------------------------------------
-- DEPOSIT
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE deposit(p_account BIGINT, p_amount NUMERIC, p_remarks TEXT DEFAULT NULL)
LANGUAGE plpgsql AS $$
DECLARE
    v_status TEXT;
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Deposit amount must be positive';
    END IF;

    SELECT status INTO v_status FROM accounts WHERE account_id = p_account FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Account % does not exist', p_account;
    END IF;
    IF v_status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'Account % is %, deposit refused', p_account, v_status;
    END IF;

    INSERT INTO transactions(txn_type, to_account, amount, remarks)
    VALUES ('DEPOSIT', p_account, p_amount, p_remarks);

    UPDATE accounts SET balance = balance + p_amount WHERE account_id = p_account;
END $$;

-- ---------------------------------------------------------------------
-- WITHDRAW
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE withdraw(p_account BIGINT, p_amount NUMERIC, p_remarks TEXT DEFAULT NULL)
LANGUAGE plpgsql AS $$
DECLARE
    v_status  TEXT;
    v_balance NUMERIC;
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Withdrawal amount must be positive';
    END IF;

    SELECT status, balance INTO v_status, v_balance
      FROM accounts WHERE account_id = p_account FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Account % does not exist', p_account;
    END IF;
    IF v_status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'Account % is %, withdrawal refused', p_account, v_status;
    END IF;
    IF v_balance < p_amount THEN
        RAISE EXCEPTION 'Insufficient funds: balance % is less than %', v_balance, p_amount;
    END IF;

    INSERT INTO transactions(txn_type, from_account, amount, remarks)
    VALUES ('WITHDRAWAL', p_account, p_amount, p_remarks);

    UPDATE accounts SET balance = balance - p_amount WHERE account_id = p_account;
END $$;

-- ---------------------------------------------------------------------
-- TRANSFER_FUNDS  - the heart of the project (ACID in one procedure)
--   1. validate input
--   2. lock BOTH rows in ascending account_id order (prevents deadlock)
--   3. validate status + balance on the locked rows
--   4. write ledger row  (trigger enforces the daily limit)
--   5. debit + credit    (triggers write the audit trail)
-- Any RAISE EXCEPTION rolls back everything done by the caller's transaction.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE transfer_funds(p_from BIGINT, p_to BIGINT, p_amount NUMERIC,
                                           p_remarks TEXT DEFAULT NULL)
LANGUAGE plpgsql AS $$
DECLARE
    v_from_status TEXT;
    v_from_bal    NUMERIC;
    v_to_status   TEXT;
BEGIN
    IF p_from IS NULL OR p_to IS NULL THEN
        RAISE EXCEPTION 'Both source and destination accounts are required';
    END IF;
    IF p_from = p_to THEN
        RAISE EXCEPTION 'Cannot transfer to the same account';
    END IF;
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Transfer amount must be positive';
    END IF;

    -- Step 2: consistent lock order = no deadlocks between opposite transfers
    PERFORM 1 FROM accounts
     WHERE account_id IN (p_from, p_to)
     ORDER BY account_id
       FOR UPDATE;

    -- Step 3: validate on the locked rows
    SELECT status, balance INTO v_from_status, v_from_bal
      FROM accounts WHERE account_id = p_from;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Source account % does not exist', p_from;
    END IF;

    SELECT status INTO v_to_status FROM accounts WHERE account_id = p_to;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Destination account % does not exist', p_to;
    END IF;

    IF v_from_status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'Source account % is %', p_from, v_from_status;
    END IF;
    IF v_to_status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'Destination account % is %', p_to, v_to_status;
    END IF;
    IF v_from_bal < p_amount THEN
        RAISE EXCEPTION 'Insufficient funds: balance % is less than %', v_from_bal, p_amount;
    END IF;

    -- Steps 4 and 5
    INSERT INTO transactions(txn_type, from_account, to_account, amount, remarks)
    VALUES ('TRANSFER', p_from, p_to, p_amount, p_remarks);

    UPDATE accounts SET balance = balance - p_amount WHERE account_id = p_from;
    UPDATE accounts SET balance = balance + p_amount WHERE account_id = p_to;
END $$;

-- ---------------------------------------------------------------------
-- SET_ACCOUNT_STATUS  (freeze / unfreeze / close)
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE set_account_status(p_account BIGINT, p_status VARCHAR)
LANGUAGE plpgsql AS $$
DECLARE
    v_balance NUMERIC;
BEGIN
    IF p_status NOT IN ('ACTIVE','FROZEN','CLOSED') THEN
        RAISE EXCEPTION 'Invalid status %, use ACTIVE, FROZEN or CLOSED', p_status;
    END IF;

    SELECT balance INTO v_balance FROM accounts WHERE account_id = p_account FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Account % does not exist', p_account;
    END IF;
    IF p_status = 'CLOSED' AND v_balance <> 0 THEN
        RAISE EXCEPTION 'Withdraw the remaining balance % before closing the account', v_balance;
    END IF;

    UPDATE accounts SET status = p_status WHERE account_id = p_account;
END $$;

-- ---------------------------------------------------------------------
-- FN_OPEN_ACCOUNT  - returns the new account number
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_open_account(p_customer BIGINT, p_branch INT,
                                           p_type VARCHAR, p_initial NUMERIC DEFAULT 0)
RETURNS BIGINT
LANGUAGE plpgsql AS $$
DECLARE
    v_id BIGINT;
BEGIN
    IF p_initial < 0 THEN
        RAISE EXCEPTION 'Opening deposit cannot be negative';
    END IF;

    INSERT INTO accounts(customer_id, branch_id, account_type)
    VALUES (p_customer, p_branch, UPPER(p_type))
    RETURNING account_id INTO v_id;

    IF p_initial > 0 THEN
        CALL deposit(v_id, p_initial, 'Opening deposit');
    END IF;
    RETURN v_id;
END $$;

-- ---------------------------------------------------------------------
-- FN_GET_BALANCE
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_get_balance(p_account BIGINT)
RETURNS NUMERIC
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_balance NUMERIC;
BEGIN
    SELECT balance INTO v_balance FROM accounts WHERE account_id = p_account;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Account % does not exist', p_account;
    END IF;
    RETURN v_balance;
END $$;

-- ---------------------------------------------------------------------
-- FN_ACCOUNT_LOCATION  (like the cleaner/depot function in the lab sheet)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_account_location(p_account BIGINT)
RETURNS TEXT
LANGUAGE sql STABLE AS $$
    SELECT b.branch_name || ', ' || b.city
      FROM accounts a
      JOIN branches b ON b.branch_id = a.branch_id
     WHERE a.account_id = p_account;
$$;

-- ---------------------------------------------------------------------
-- FN_MINI_STATEMENT - last N entries for one account
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_mini_statement(p_account BIGINT, p_limit INT DEFAULT 10)
RETURNS TABLE (txn_id BIGINT, txn_time TIMESTAMPTZ, txn_type VARCHAR,
               direction TEXT, counterparty BIGINT, amount NUMERIC, remarks VARCHAR)
LANGUAGE sql STABLE AS $$
    SELECT t.txn_id,
           t.txn_time,
           t.txn_type,
           CASE WHEN t.to_account = p_account THEN 'CREDIT' ELSE 'DEBIT' END,
           CASE WHEN t.to_account = p_account THEN t.from_account ELSE t.to_account END,
           t.amount,
           t.remarks
      FROM transactions t
     WHERE t.from_account = p_account OR t.to_account = p_account
     ORDER BY t.txn_time DESC, t.txn_id DESC
     LIMIT p_limit;
$$;

-- ---------------------------------------------------------------------
-- APPLY_MONTHLY_INTEREST - EXPLICIT CURSOR with WHERE CURRENT OF
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE apply_monthly_interest(p_rate_percent NUMERIC DEFAULT 0.5)
LANGUAGE plpgsql AS $$
DECLARE
    cur_savings CURSOR FOR
        SELECT account_id, balance
          FROM accounts
         WHERE account_type = 'SAVINGS' AND status = 'ACTIVE'
           FOR UPDATE;
    rec        RECORD;
    v_interest NUMERIC;
    v_count    INT := 0;
BEGIN
    IF p_rate_percent <= 0 THEN
        RAISE EXCEPTION 'Interest rate must be positive';
    END IF;

    FOR rec IN cur_savings LOOP
        v_interest := ROUND(rec.balance * p_rate_percent / 100, 2);
        IF v_interest > 0 THEN
            INSERT INTO transactions(txn_type, to_account, amount, remarks)
            VALUES ('INTEREST', rec.account_id, v_interest,
                    'Monthly interest @ ' || p_rate_percent || '%');
            UPDATE accounts SET balance = balance + v_interest WHERE CURRENT OF cur_savings;
            v_count := v_count + 1;
        END IF;
    END LOOP;

    RAISE NOTICE 'Interest credited to % savings account(s)', v_count;
END $$;

-- ---------------------------------------------------------------------
-- PROCESS_TRANSFER_QUEUE - loop + per-row SAVEPOINT behaviour.
-- A BEGIN ... EXCEPTION block in PL/pgSQL is an implicit savepoint:
-- if one transfer fails only that row is rolled back; the rest go on.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE process_transfer_queue()
LANGUAGE plpgsql AS $$
DECLARE
    rec       RECORD;
    v_done    INT := 0;
    v_failed  INT := 0;
BEGIN
    FOR rec IN SELECT q.queue_id, q.from_account, q.to_account, q.amount
                 FROM transfer_queue q
                WHERE q.status = 'PENDING'
                ORDER BY q.queue_id
    LOOP
        BEGIN
            CALL transfer_funds(rec.from_account, rec.to_account, rec.amount,
                                'Batch #' || rec.queue_id);
            UPDATE transfer_queue
               SET status = 'DONE', processed_at = now()
             WHERE queue_id = rec.queue_id;
            v_done := v_done + 1;
        EXCEPTION WHEN OTHERS THEN
            UPDATE transfer_queue
               SET status = 'FAILED', error_msg = SQLERRM, processed_at = now()
             WHERE queue_id = rec.queue_id;
            v_failed := v_failed + 1;
        END;
    END LOOP;

    RAISE NOTICE 'Queue processed: % done, % failed', v_done, v_failed;
END $$;

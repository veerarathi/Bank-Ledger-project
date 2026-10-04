-- =====================================================================
-- 03_triggers.sql  |  BankLedger triggers
--
--  #  Trigger                     Table         When / Event
--  1  trg_account_audit           accounts      AFTER  UPDATE or DELETE   (audit trail)
--  2  trg_block_inactive_update   accounts      BEFORE UPDATE OF balance   (frozen/closed guard)
--  3  trg_block_account_delete    accounts      BEFORE DELETE              (no deleting funded accounts)
--  4  trg_ledger_immutable        transactions  BEFORE UPDATE or DELETE    (append-only ledger)
--  5  trg_daily_limit             transactions  BEFORE INSERT              (daily outgoing limit)
--
-- User-defined SQLSTATE codes:  BK001 BK002 BK003 BK004
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. AUDIT TRAIL  (transparent: the application never writes audit_log)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_audit_account() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        INSERT INTO audit_log(account_id, action, old_balance, old_status)
        VALUES (OLD.account_id, 'DELETE', OLD.balance, OLD.status);
        RETURN OLD;
    END IF;

    -- UPDATE: log only when something we care about really changed
    IF NEW.balance IS DISTINCT FROM OLD.balance
       OR NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO audit_log(account_id, action, old_balance, new_balance, old_status, new_status)
        VALUES (OLD.account_id, 'UPDATE', OLD.balance, NEW.balance, OLD.status, NEW.status);
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_account_audit ON accounts;
CREATE TRIGGER trg_account_audit
    AFTER UPDATE OR DELETE ON accounts
    FOR EACH ROW EXECUTE FUNCTION fn_audit_account();

-- ---------------------------------------------------------------------
-- 2. FROZEN / CLOSED GUARD  (second line of defence behind the procedures)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_block_inactive_update() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.balance IS DISTINCT FROM OLD.balance THEN
        RAISE EXCEPTION 'Account % is %: balance cannot be changed', OLD.account_id, OLD.status
              USING ERRCODE = 'BK001';
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_block_inactive_update ON accounts;
CREATE TRIGGER trg_block_inactive_update
    BEFORE UPDATE OF balance ON accounts
    FOR EACH ROW
    WHEN (OLD.status <> 'ACTIVE')
    EXECUTE FUNCTION fn_block_inactive_update();

-- ---------------------------------------------------------------------
-- 3. DELETE GUARD  (money must never vanish with a deleted row)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_block_account_delete() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.balance <> 0 THEN
        RAISE EXCEPTION 'Account % still holds %: it cannot be deleted', OLD.account_id, OLD.balance
              USING ERRCODE = 'BK002';
    END IF;
    RETURN OLD;
END $$;

DROP TRIGGER IF EXISTS trg_block_account_delete ON accounts;
CREATE TRIGGER trg_block_account_delete
    BEFORE DELETE ON accounts
    FOR EACH ROW EXECUTE FUNCTION fn_block_account_delete();

-- ---------------------------------------------------------------------
-- 4. IMMUTABLE LEDGER  (ledger rows may only be added, never changed)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_ledger_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'The transaction ledger is append-only: % is not allowed', TG_OP
          USING ERRCODE = 'BK003';
END $$;

DROP TRIGGER IF EXISTS trg_ledger_immutable ON transactions;
CREATE TRIGGER trg_ledger_immutable
    BEFORE UPDATE OR DELETE ON transactions
    FOR EACH ROW EXECUTE FUNCTION fn_ledger_immutable();

-- ---------------------------------------------------------------------
-- 5. DAILY OUTGOING LIMIT  (business rule enforced inside the database)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_enforce_daily_limit() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    c_daily_limit CONSTANT NUMERIC := 50000;
    v_spent_today NUMERIC;
BEGIN
    SELECT COALESCE(SUM(t.amount), 0) INTO v_spent_today
      FROM transactions t
     WHERE t.from_account = NEW.from_account
       AND t.txn_time >= CURRENT_DATE;

    IF v_spent_today + NEW.amount > c_daily_limit THEN
        RAISE EXCEPTION 'Daily outgoing limit of % exceeded for account % (already used %)',
              c_daily_limit, NEW.from_account, v_spent_today
              USING ERRCODE = 'BK004';
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_daily_limit ON transactions;
CREATE TRIGGER trg_daily_limit
    BEFORE INSERT ON transactions
    FOR EACH ROW
    WHEN (NEW.from_account IS NOT NULL)
    EXECUTE FUNCTION fn_enforce_daily_limit();

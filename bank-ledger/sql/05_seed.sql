-- =====================================================================
-- 05_seed.sql  |  Sample data
-- Money is moved through the stored procedures, so the triggers fire
-- and audit_log is populated exactly as in real use.
-- Run this on a freshly created schema (identity counters start clean):
-- customers get ids 1-6 and accounts get ids 1001-1009.
-- =====================================================================

INSERT INTO branches(branch_name, city) VALUES
    ('Main Branch', 'Indore'),
    ('City Center', 'Bhopal'),
    ('Tech Park',   'Pune');

INSERT INTO customers(full_name, email, phone) VALUES
    ('Rajesh Kumar', 'rajesh.kumar@example.com', '9876543210'),
    ('Anita Sharma', 'anita.sharma@example.com', '9876500011'),
    ('Vikram Singh', 'vikram.singh@example.com', '9876500022'),
    ('Priya Patel',  'priya.patel@example.com',  '9876500033'),
    ('Rohan Mehta',  'rohan.mehta@example.com',  '9876500044'),
    ('Sneha Iyer',   'sneha.iyer@example.com',   '9876500055');

INSERT INTO accounts(customer_id, branch_id, account_type) VALUES
    (1, 1, 'SAVINGS'),   -- 1001  Rajesh  Main Branch
    (2, 1, 'SAVINGS'),   -- 1002  Anita   Main Branch
    (3, 2, 'SAVINGS'),   -- 1003  Vikram  City Center
    (4, 2, 'CURRENT'),   -- 1004  Priya   City Center
    (5, 3, 'SAVINGS'),   -- 1005  Rohan   Tech Park
    (6, 3, 'SAVINGS'),   -- 1006  Sneha   Tech Park
    (1, 2, 'CURRENT'),   -- 1007  Rajesh  City Center
    (1, 3, 'SAVINGS'),   -- 1008  Rajesh  Tech Park
    (2, 2, 'SAVINGS');   -- 1009  Anita   City Center (stays dormant)

-- Weak entity rows (identified by account + nominee number)
INSERT INTO nominees(account_id, nominee_no, nominee_name, relation, share_percent) VALUES
    (1001, 1, 'Meera Kumar', 'Spouse', 60),
    (1001, 2, 'Aman Kumar',  'Son',    40),
    (1002, 1, 'Ravi Sharma', 'Father', 100);

-- Opening funds
CALL deposit(1001, 80000, 'Initial funding');
CALL deposit(1002, 30000, 'Initial funding');
CALL deposit(1003, 45000, 'Initial funding');
CALL deposit(1004, 12000, 'Initial funding');
CALL deposit(1005, 60000, 'Initial funding');
CALL deposit(1006, 25000, 'Initial funding');
CALL deposit(1007, 18000, 'Initial funding');
CALL deposit(1008,  9000, 'Initial funding');

-- Everyday activity
CALL transfer_funds(1001, 1002, 5000, 'Rent share');
CALL transfer_funds(1002, 1003, 1500, 'Books');
CALL transfer_funds(1003, 1004, 2500, 'Loan repayment');
CALL transfer_funds(1005, 1001, 7000, 'Invoice 114');
CALL transfer_funds(1006, 1005, 3000, 'Gift');
CALL transfer_funds(1007, 1008, 1000, 'Savings top-up');
CALL transfer_funds(1001, 1003, 4000, 'Fees');
CALL withdraw(1004, 2000, 'ATM');
CALL withdraw(1001, 10000, 'Cash');

-- Freeze the dormant account (shows the status audit trail)
CALL set_account_status(1009, 'FROZEN');

-- Batch queue for the demo: 1 valid, 1 insufficient funds, 1 frozen account
INSERT INTO transfer_queue(from_account, to_account, amount) VALUES
    (1003, 1004, 2000),
    (1005, 1006, 9999999),
    (1009, 1001, 10);

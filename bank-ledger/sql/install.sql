-- =====================================================================
-- install.sql  |  One-shot installer
-- Usage (from any folder):
--     psql -U postgres -d bankdb -v ON_ERROR_STOP=1 -f sql/install.sql
-- \ir = "include relative" to this file's own folder.
-- =====================================================================
\echo '>>> 1/5  Creating schema'
\ir 01_schema.sql
\echo '>>> 2/5  Creating functions and procedures'
\ir 02_functions_procedures.sql
\echo '>>> 3/5  Creating triggers'
\ir 03_triggers.sql
\echo '>>> 4/5  Creating views'
\ir 04_views.sql
\echo '>>> 5/5  Loading sample data'
\ir 05_seed.sql
\echo '>>> BankLedger installed successfully.'

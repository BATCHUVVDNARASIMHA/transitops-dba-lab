-- 04_tuning.sql
-- Tuning with execution plans: the card history lookup before and after a local
-- (partition-aligned) index. EXPLAIN PLAN and DBMS_XPLAN need no extra licence.
-- AWR and ASH reports need the Diagnostics Pack, so check licensing before
-- running them on a production system.

WHENEVER SQLERROR EXIT SQL.SQLCODE
SET FEEDBACK ON VERIFY OFF SERVEROUTPUT ON LINESIZE 200 PAGESIZE 200

DECLARE
    n NUMBER;
BEGIN
    SELECT COUNT(*) INTO n FROM dba_indexes WHERE owner = 'TRANSITOPS' AND index_name = 'IX_FARE_TAP_CARD';
    IF n > 0 THEN
        EXECUTE IMMEDIATE 'DROP INDEX transitops.ix_fare_tap_card';
    END IF;
END;
/

PROMPT Plan before: full scan of every partition
EXPLAIN PLAN SET STATEMENT_ID = 'before' FOR
SELECT COUNT(*), SUM(amount) FROM transitops.fare_tap WHERE card_id = 77;

SELECT plan_table_output FROM TABLE(DBMS_XPLAN.DISPLAY(NULL, 'before', 'BASIC +COST +PARTITION'));

CREATE INDEX transitops.ix_fare_tap_card ON transitops.fare_tap (card_id, tap_ts) LOCAL;

BEGIN
    DBMS_STATS.GATHER_TABLE_STATS(ownname => 'TRANSITOPS', tabname => 'FARE_TAP', cascade => TRUE);
END;
/

PROMPT Plan after: index range scan per partition
EXPLAIN PLAN SET STATEMENT_ID = 'after' FOR
SELECT COUNT(*), SUM(amount) FROM transitops.fare_tap WHERE card_id = 77;

SELECT plan_table_output FROM TABLE(DBMS_XPLAN.DISPLAY(NULL, 'after', 'BASIC +COST +PARTITION'));

EXIT

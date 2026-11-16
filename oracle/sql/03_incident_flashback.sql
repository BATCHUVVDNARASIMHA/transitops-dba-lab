-- 03_incident_flashback.sql
-- The same incident as the SQL Server drill: an UPDATE without a WHERE clause
-- retires the whole fleet. On Oracle the first tool to reach for is Flashback,
-- which reads the "before" image from undo and needs no restore at all.
--
--   Flashback Query   inspect the table as it was (AS OF SCN)
--   Flashback Table   put the table back to that SCN, online
--
-- Flashback depends on undo retention. Once the undo has been overwritten the
-- fallback is RMAN point-in-time recovery, which is what rman/backup_and_validate.sh
-- keeps possible.

WHENEVER SQLERROR EXIT SQL.SQLCODE
SET FEEDBACK ON VERIFY OFF SERVEROUTPUT ON LINESIZE 200 PAGESIZE 100

VARIABLE good_scn NUMBER

BEGIN
    SELECT current_scn INTO :good_scn FROM v$database;
END;
/

PROMPT Before the incident
SELECT status, COUNT(*) AS vehicles FROM transitops.vehicle GROUP BY status ORDER BY status;

-- The bad statement.
UPDATE transitops.vehicle SET status = 'RETIRED', last_modified = SYSTIMESTAMP;
COMMIT;

PROMPT After the incident
SELECT status, COUNT(*) AS vehicles FROM transitops.vehicle GROUP BY status ORDER BY status;

PROMPT Flashback Query: the table as it was at the recorded SCN
SELECT status, COUNT(*) AS vehicles
FROM transitops.vehicle AS OF SCN :good_scn
GROUP BY status
ORDER BY status;

-- Repair. FLASHBACK TABLE is DDL, so the SCN is concatenated instead of bound.
BEGIN
    EXECUTE IMMEDIATE 'FLASHBACK TABLE transitops.vehicle TO SCN ' || TO_CHAR(:good_scn);
END;
/

PROMPT After Flashback Table
SELECT status, COUNT(*) AS vehicles FROM transitops.vehicle GROUP BY status ORDER BY status;

DECLARE
    n NUMBER;
BEGIN
    SELECT COUNT(*) INTO n FROM transitops.vehicle WHERE status = 'RETIRED';
    IF n <> 26 THEN
        RAISE_APPLICATION_ERROR(-20001, 'Repair check failed: expected 26 retired vehicles, found ' || n);
    END IF;
    DBMS_OUTPUT.PUT_LINE('Repair verified: 26 retired vehicles, as before the incident.');
END;
/

EXIT

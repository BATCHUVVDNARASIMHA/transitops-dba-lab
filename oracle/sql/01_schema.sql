-- 01_schema.sql
-- TRANSITOPS schema in the FREEPDB1 pluggable database: a subset of the SQL Server
-- model, enough to show the same administration tasks on Oracle.
--
--   - a dedicated tablespace
--   - a schema-only owner account (NO AUTHENTICATION): nobody can log in as the owner
--   - fare taps interval-partitioned by month: Oracle creates each month's partition
--     automatically, where SQL Server needs an explicit split
--
-- The script rebuilds the schema objects each time it runs.

WHENEVER SQLERROR EXIT SQL.SQLCODE
SET FEEDBACK ON VERIFY OFF SERVEROUTPUT ON LINESIZE 200 PAGESIZE 100

DECLARE
    n NUMBER;
BEGIN
    SELECT COUNT(*) INTO n FROM dba_tablespaces WHERE tablespace_name = 'TRANSIT_DATA';
    IF n = 0 THEN
        EXECUTE IMMEDIATE q'[CREATE TABLESPACE transit_data
                             DATAFILE '/opt/oracle/oradata/FREE/FREEPDB1/transit_data01.dbf'
                             SIZE 200M AUTOEXTEND ON NEXT 100M MAXSIZE 2G]';
    END IF;

    SELECT COUNT(*) INTO n FROM dba_users WHERE username = 'TRANSITOPS';
    IF n = 0 THEN
        EXECUTE IMMEDIATE 'CREATE USER transitops NO AUTHENTICATION DEFAULT TABLESPACE transit_data QUOTA UNLIMITED ON transit_data';
    END IF;

    FOR t IN (SELECT table_name FROM dba_tables WHERE owner = 'TRANSITOPS') LOOP
        EXECUTE IMMEDIATE 'DROP TABLE transitops."' || t.table_name || '" CASCADE CONSTRAINTS PURGE';
    END LOOP;
END;
/

CREATE TABLE transitops.garage (
    garage_id    NUMBER(4)     CONSTRAINT pk_garage PRIMARY KEY,
    garage_name  VARCHAR2(60)  NOT NULL
);

CREATE TABLE transitops.vehicle (
    vehicle_id     NUMBER(6)     CONSTRAINT pk_vehicle PRIMARY KEY,
    fleet_number   VARCHAR2(10)  NOT NULL CONSTRAINT uq_vehicle_fleet_number UNIQUE,
    garage_id      NUMBER(4)     NOT NULL CONSTRAINT fk_vehicle_garage REFERENCES transitops.garage (garage_id),
    status         VARCHAR2(12)  NOT NULL CONSTRAINT ck_vehicle_status CHECK (status IN ('ACTIVE', 'IN_SHOP', 'RETIRED')),
    last_modified  TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL
);

-- FLASHBACK TABLE needs row movement.
ALTER TABLE transitops.vehicle ENABLE ROW MOVEMENT;

CREATE TABLE transitops.operator (
    operator_id      NUMBER(6)      CONSTRAINT pk_operator PRIMARY KEY,
    employee_number  CHAR(7)        NOT NULL CONSTRAINT uq_operator_employee_number UNIQUE,
    full_name        VARCHAR2(80)   NOT NULL,
    email            VARCHAR2(120)  NOT NULL,
    garage_id        NUMBER(4)      NOT NULL CONSTRAINT fk_operator_garage REFERENCES transitops.garage (garage_id)
);

CREATE TABLE transitops.fare_tap (
    tap_id   NUMBER(12)   NOT NULL,
    tap_ts   DATE         NOT NULL,
    card_id  NUMBER(8)    NOT NULL,
    stop_id  NUMBER(6)    NOT NULL,
    amount   NUMBER(6,2)  NOT NULL
)
PARTITION BY RANGE (tap_ts) INTERVAL (NUMTOYMINTERVAL(1, 'MONTH'))
(PARTITION p_before_2026_05 VALUES LESS THAN (DATE '2026-05-01'));

INSERT INTO transitops.garage (garage_id, garage_name)
SELECT LEVEL, CASE LEVEL WHEN 1 THEN 'North Bus Garage' WHEN 2 THEN 'South Bus Garage'
                         WHEN 3 THEN 'East Bus and Streetcar Garage' ELSE 'Central Rail Yard' END
FROM dual CONNECT BY LEVEL <= 4;

INSERT INTO transitops.vehicle (vehicle_id, fleet_number, garage_id, status)
SELECT LEVEL,
       'V' || LPAD(LEVEL, 4, '0'),
       1 + MOD(LEVEL, 4),
       CASE WHEN MOD(LEVEL, 25) = 0 THEN 'RETIRED' WHEN MOD(LEVEL, 9) = 0 THEN 'IN_SHOP' ELSE 'ACTIVE' END
FROM dual CONNECT BY LEVEL <= 650;

INSERT INTO transitops.operator (operator_id, employee_number, full_name, email, garage_id)
SELECT LEVEL,
       'E' || TO_CHAR(100000 + LEVEL),
       'Operator ' || LEVEL,
       'operator' || LEVEL || '@transitops.example',
       1 + MOD(LEVEL, 4)
FROM dual CONNECT BY LEVEL <= 1200;

INSERT INTO transitops.fare_tap (tap_id, tap_ts, card_id, stop_id, amount)
SELECT LEVEL,
       DATE '2026-05-01' + MOD(LEVEL * 7907, 184) + (18000 + MOD(LEVEL * 48271, 68400)) / 86400,
       1 + MOD(LEVEL * 104729, 120000),
       CASE WHEN MOD(LEVEL * 7919, 1009) < 353 THEN 1 ELSE 2 + MOD(LEVEL * 131, 598) END,
       2.50
FROM dual CONNECT BY LEVEL <= 300000;

COMMIT;

BEGIN
    DBMS_STATS.GATHER_SCHEMA_STATS(ownname => 'TRANSITOPS');
END;
/

SELECT table_name, num_rows
FROM dba_tables
WHERE owner = 'TRANSITOPS'
ORDER BY table_name;

SELECT partition_name, high_value, num_rows
FROM dba_tab_partitions
WHERE table_owner = 'TRANSITOPS' AND table_name = 'FARE_TAP'
ORDER BY partition_position;

EXIT

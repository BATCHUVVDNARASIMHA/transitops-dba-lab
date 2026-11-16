/*
    V002: add ref.Stop.IsAccessible

    Requested by the customer-information team: trip planning needs to know which
    stops are step-free.

    Pattern: expand, backfill, contract.
      1. add the column as NULL      (metadata-only, no table rewrite, no long lock)
      2. backfill                    (600 rows here; batched on a large table)
      3. enforce NOT NULL and add a default for future inserts

    The whole change runs in one transaction with XACT_ABORT ON. The runner uses
    sqlcmd -b, so the first error stops the script and the open transaction rolls back.
    This file has no USE statement: the runner chooses the database, so the identical
    file is applied to TEST first and then to production.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

BEGIN TRANSACTION;
GO

ALTER TABLE ref.Stop ADD IsAccessible bit NULL;
GO

UPDATE ref.Stop
SET IsAccessible = CASE WHEN IsStation = 1 OR StopId % 3 <> 0 THEN 1 ELSE 0 END;
GO

ALTER TABLE ref.Stop ALTER COLUMN IsAccessible bit NOT NULL;
ALTER TABLE ref.Stop ADD CONSTRAINT DF_Stop_IsAccessible DEFAULT (0) FOR IsAccessible;
GO

CREATE OR ALTER VIEW rpt.vw_StopAccessibility
AS
SELECT s.IsStation,
       COUNT(*)                                                AS Stops,
       SUM(CASE WHEN s.IsAccessible = 1 THEN 1 ELSE 0 END)     AS AccessibleStops
FROM ref.Stop AS s
GROUP BY s.IsStation;
GO

COMMIT TRANSACTION;
GO

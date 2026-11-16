/*
    Lab 5, session B: the dispatch screen asks how many vehicles are available.
    Under the default READ COMMITTED isolation level the reader needs shared locks
    and queues behind session A's exclusive locks. With READ_COMMITTED_SNAPSHOT on,
    it reads the last committed version of each row and does not wait.
    The time it waited is recorded as the lab result.
*/
SET NOCOUNT ON;
USE TransitOps;
GO

DECLARE @Start  datetime2(7) = SYSDATETIME(),
        @Phase  varchar(20)  = CAST(DBAdmin.dba.fn_GetConfig(N'LabPhase') AS varchar(20)),
        @Active int;

SELECT @Active = COUNT(*)
FROM ops.Vehicle AS v
WHERE v.Status = 'ACTIVE';

INSERT DBAdmin.lab.PerfResult (Lab, Phase, Metric, Value, Detail)
VALUES ('LAB5_BLOCKING', @Phase, 'reader_wait_ms', DATEDIFF(MILLISECOND, @Start, SYSDATETIME()),
        N'Vehicle availability query while a writer holds locks on ops.Vehicle');
GO

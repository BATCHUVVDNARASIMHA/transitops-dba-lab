/*
    Lab 2: implicit conversion

    Symptom   Looking up a card by serial number is slow, although CardSerial has a
              unique index.
    Cause     CardSerial is varchar. The application sends the serial as nvarchar
              (the default for many database drivers). nvarchar outranks varchar, so
              SQL Server converts the COLUMN, on every row, and the index can only be
              scanned. The plan shows CONVERT_IMPLICIT on CardSerial.
    Fix       Send the parameter as varchar. In practice that is a driver setting or a
              one-line change in the data access layer, not a database change.
    Note      With a SQL collation (as here) the scan is unavoidable. With a Windows
              collation the engine can still seek, which is why this problem appears
              on some servers and not on others with the same code.
*/
SET NOCOUNT ON;
USE TransitOps;
GO

DECLARE @Serial varchar(20);
SELECT @Serial = c.CardSerial FROM fare.Card AS c WHERE c.CardId = 4242;

EXEC lab.usp_FindCard_UnicodeParam @CardSerial = @Serial;
GO
EXEC DBAdmin.lab.usp_RecordProcStats N'TransitOps', N'lab.usp_FindCard_UnicodeParam', 'LAB2_IMPLICIT_CONVERSION', 'before';
GO

DECLARE @Serial varchar(20);
SELECT @Serial = c.CardSerial FROM fare.Card AS c WHERE c.CardId = 4242;

EXEC lab.usp_FindCard @CardSerial = @Serial;
GO
EXEC DBAdmin.lab.usp_RecordProcStats N'TransitOps', N'lab.usp_FindCard', 'LAB2_IMPLICIT_CONVERSION', 'after';
GO

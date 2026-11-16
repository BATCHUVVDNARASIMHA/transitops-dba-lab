# Performance labs

Six problems that show up on real OLTP systems, each reproduced on the TransitOps
data, diagnosed, fixed and measured. `scripts/perf.sh` runs all of them.

## How the measurements work

Each lab query lives in a stored procedure. After it runs, the lab copies
`last_logical_reads`, `last_worker_time` and `last_elapsed_time` for that procedure
from `sys.dm_exec_procedure_stats` into `DBAdmin.lab.PerfResult`. Before and after
are therefore measured by the engine. Logical reads are the headline number because
they do not change with how busy the host is.

The data is deliberately skewed: the hub station (StopId 1) carries about 35 percent
of all taps and StopId 600 carries exactly 50. Uniform test data hides most
plan-quality problems.

## Lab 1: missing index

| | |
|---|---|
| Symptom | Customer service waits for a card's tap history. |
| Diagnosis | `fare.Tap` is clustered on `(TapDateTime, TapId)`. Nothing leads on `CardId`, so one card's history reads every row in the date range. The missing-index DMVs report the same gap. |
| Fix | Nonclustered index on `(CardId, TapDateTime) INCLUDE (StopId, Amount)`, built `ONLINE`, partition-aligned. |
| Trade-off | One more index to maintain on every insert. Justified for a lookup that runs all day. |

## Lab 2: implicit conversion

| | |
|---|---|
| Symptom | Card lookup by serial number is slow although `CardSerial` has a unique index. |
| Diagnosis | The column is `varchar`, the application sends `nvarchar`. Data type precedence converts the column side, on every row. The plan shows `CONVERT_IMPLICIT` and an index scan. |
| Fix | Pass the parameter as `varchar` (a driver setting or one line in the data access layer). No schema change. |
| Note | With a Windows collation the engine can still seek, which is why the same code is slow on one server and fine on another. |

## Lab 3: function on an indexed column

| | |
|---|---|
| Symptom | A one-station, one-day report scans the table. |
| Diagnosis | The predicate is `CONVERT(char(8), TapDateTime, 112) = ...`. The function must be computed for every row, so there is no seek and no partition elimination. |
| Fix | Half-open range on the bare column: `TapDateTime >= @Day AND TapDateTime < DATEADD(DAY, 1, @Day)`. |

## Lab 4: parameter sniffing

| | |
|---|---|
| Symptom | The same procedure is fast for most stops and very slow for the hub. |
| Diagnosis | The plan is compiled for the first parameter value and reused. A plan built for 50 rows (index seek plus key lookup) is reused for half a million rows. |
| Fix A | `OPTION (RECOMPILE)` on the statement. |
| Fix B | SQL Server 2022 Parameter Sensitive Plan optimization, which keeps several plans per statement. The lab turns it off to reproduce the problem, then on again, and records both. |
| Rejected | Forcing a single plan: that only chooses who gets the bad plan. |

## Lab 5: blocking

| | |
|---|---|
| Symptom | The dispatch screen freezes while a maintenance batch runs. |
| Diagnosis | A long transaction holds exclusive row locks on `ops.Vehicle`. Under the default READ COMMITTED level the reader waits for shared locks. `dba.usp_CaptureBlocking` records the chain while it exists; the `DBA_Concurrency` Extended Events session keeps the blocked process report. |
| Fix | `READ_COMMITTED_SNAPSHOT ON`: readers use row versions and stop waiting on writers. |
| Trade-off | Row versions live in tempdb, and code that relied on readers being blocked must be reviewed first. The root cause, the long transaction, should also be shortened. |

## Lab 6: deadlock

| | |
|---|---|
| Symptom | Intermittent error 1205 in two application functions. |
| Diagnosis | "Close work order" locks WorkOrder then Vehicle; "pull vehicle from service" locks Vehicle then WorkOrder. The deadlock graph from Extended Events shows both sessions, their statements and the victim. |
| Fix | Both procedures take locks in the same order (Vehicle, then WorkOrder) and retry on error 1205. |
| Proof | The legacy sessions produce one deadlock; the fixed procedures, run with the same overlap, produce none. |

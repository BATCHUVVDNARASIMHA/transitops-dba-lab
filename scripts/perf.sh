#!/usr/bin/env bash
# Six performance labs. Labs 1 to 4 measure a query before and after a fix.
# Labs 5 and 6 need concurrent sessions, which is why they are driven from here.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

P="$SQL_DIR/50_performance"

deadlock_count() {
    local n
    n="$(scalar DBAdmin "DECLARE @n int; EXEC @n = dba.usp_GetDeadlocks @CountOnly = 1; SELECT @n;")"
    if ! [[ "$n" =~ ^[0-9]+$ ]]; then
        echo "Could not read the deadlock count (got '$n')." >&2
        return 1
    fi
    printf '%s' "$n"
}

# Session A holds locks for 12 s. Session B starts 2 s later and has to wait.
blocking_scenario() {
    local capture="$1" writer reader
    run_file "$P/550_lab5_blocking_writer.sql" &
    writer=$!
    sleep 2
    run_file "$P/551_lab5_blocking_reader.sql" &
    reader=$!
    if [[ "$capture" == "capture" ]]; then
        sleep 5
        step "capturing the blocking chain while it exists"
        run_query DBAdmin "EXEC dba.usp_CaptureBlocking @MinWaitMs = 1000;"
    fi
    wait "$writer"
    wait "$reader"
}

log "Lab objects"
run_file "$P/500_lab_objects.sql"

log "Lab 1: missing index"
run_file "$P/510_lab1_missing_index.sql"

log "Lab 2: implicit conversion"
run_file "$P/520_lab2_implicit_conversion.sql"

log "Lab 3: function on an indexed column"
run_file "$P/530_lab3_sargability.sql"

log "Lab 4: parameter sniffing"
run_file "$P/540_lab4_parameter_sniffing.sql"

log "Lab 5: blocking (reader behind a long transaction)"
run_query DBAdmin "EXEC dba.usp_SetConfig N'LabPhase', N'before';"
blocking_scenario capture

step "fix: READ_COMMITTED_SNAPSHOT, readers use row versions instead of shared locks"
run_query master "ALTER DATABASE TransitOps SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;"
run_query DBAdmin "EXEC dba.usp_SetConfig N'LabPhase', N'after';"
blocking_scenario nocapture

log "Lab 6: deadlock (two code paths, opposite lock order)"
VEHICLE_ID="$(scalar TransitOps "SELECT VehicleId FROM maint.WorkOrder WHERE WorkOrderId = 1;")"
run_query DBAdmin "EXEC dba.usp_SetConfig N'Lab6VehicleId', N'$VEHICLE_ID';"

count_start="$(deadlock_count)"
run_file "$P/560_lab6_deadlock_session_a.sql" &
session_a=$!
sleep 1
run_file "$P/561_lab6_deadlock_session_b.sql" &
session_b=$!
rc_a=0
rc_b=0
wait "$session_a" || rc_a=$?
wait "$session_b" || rc_b=$?
step "session A exit code $rc_a, session B exit code $rc_b (the deadlock victim exits non-zero)"

sleep 4   # let the Extended Events session dispatch the report
count_legacy="$(deadlock_count)"
run_query DBAdmin "INSERT lab.PerfResult (Lab, Phase, Metric, Value, Detail)
                   VALUES ('LAB6_DEADLOCK', 'before', 'deadlocks', $((count_legacy - count_start)), N'Two code paths lock Vehicle and WorkOrder in opposite orders');"

step "deadlock report from the DBA_Concurrency Extended Events session"
run_query DBAdmin "EXEC dba.usp_GetDeadlocks;"

step "fix: both procedures lock Vehicle first, then WorkOrder, and retry on error 1205"
run_query TransitOps "EXEC app.usp_CloseWorkOrder @WorkOrderId = 1, @HoldSeconds = 4;" &
session_a=$!
sleep 1
run_query TransitOps "EXEC app.usp_PullVehicleFromService @VehicleId = $VEHICLE_ID, @WorkOrderId = 1, @HoldSeconds = 4;" &
session_b=$!
wait "$session_a"
wait "$session_b"

sleep 4
count_fixed="$(deadlock_count)"
run_query DBAdmin "INSERT lab.PerfResult (Lab, Phase, Metric, Value, Detail)
                   VALUES ('LAB6_DEADLOCK', 'after', 'deadlocks', $((count_fixed - count_legacy)), N'Both procedures lock Vehicle first, then WorkOrder');"

log "Results: before and after, measured by the engine"
run_query DBAdmin "SELECT s.Lab AS lab, s.Metric AS metric, CAST(s.BeforeValue AS bigint) AS before_value,
                          CAST(s.AfterValue AS bigint) AS after_value, s.ImprovementFactor AS improvement_factor
                   FROM lab.vw_PerfSummary AS s ORDER BY s.Lab, s.Metric;"

log "Query Store: most expensive queries recorded during the labs"
run_query DBAdmin "EXEC dba.usp_QueryStoreTopQueries @DatabaseName = N'TransitOps', @Top = 8;"

log "Log backup (index builds are fully logged in FULL recovery)"
run_query DBAdmin "EXEC dba.usp_BackupDatabase @DatabaseName = N'TransitOps', @BackupType = 'LOG', @Description = N'Log backup after the performance labs';"

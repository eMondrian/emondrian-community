#!/usr/bin/env bash
set -Eeuo pipefail

CLICKHOUSE_CLIENT=(
  clickhouse-client
  --host=127.0.0.1
  --multiquery
)

DATA_DIR="/data/ontime"

query() {
  "${CLICKHOUSE_CLIENT[@]}" --query "$1"
}

echo "============================================================"
echo "Waiting for ClickHouse..."
echo "============================================================"

ATTEMPTS=0
MAX_ATTEMPTS=60

until query "SELECT 1" >/dev/null 2>&1; do

  ATTEMPTS=$((ATTEMPTS + 1))

  if (( ATTEMPTS >= MAX_ATTEMPTS )); then
    echo "ERROR: ClickHouse is not available after ${MAX_ATTEMPTS} seconds."
    exit 1
  fi

  sleep 1
done

echo "ClickHouse is ready. Creating OnTime tables..."

query "
CREATE TABLE IF NOT EXISTS ontime
(
    Year UInt16,
    Quarter UInt8,
    Month UInt8,
    DayofMonth UInt8,
    DayOfWeek UInt8,
    FlightDate Date,

    Reporting_Airline LowCardinality(String),
    DOT_ID_Reporting_Airline Int32,
    IATA_CODE_Reporting_Airline LowCardinality(String),
    Tail_Number LowCardinality(String),
    Flight_Number_Reporting_Airline LowCardinality(String),

    OriginAirportID Int32,
    OriginAirportSeqID Int32,
    OriginCityMarketID Int32,
    Origin FixedString(5),
    OriginCityName LowCardinality(String),
    OriginState FixedString(2),
    OriginStateFips FixedString(2),
    OriginStateName LowCardinality(String),
    OriginWac Int32,

    DestAirportID Int32,
    DestAirportSeqID Int32,
    DestCityMarketID Int32,
    Dest FixedString(5),
    DestCityName LowCardinality(String),
    DestState FixedString(2),
    DestStateFips FixedString(2),
    DestStateName LowCardinality(String),
    DestWac Int32,

    CRSDepTime Float32,
    DepTime Float32,
    DepDelay Float32,
    DepDelayMinutes Float32,
    DepDel15 Float32,
    DepartureDelayGroups LowCardinality(String),
    DepTimeBlk LowCardinality(String),

    TaxiOut Float32,
    WheelsOff LowCardinality(String),
    WheelsOn LowCardinality(String),
    TaxiIn Float32,

    CRSArrTime Float32,
    ArrTime Float32,
    ArrDelay Float32,
    ArrDelayMinutes Float32,
    ArrDel15 Float32,
    ArrivalDelayGroups LowCardinality(String),
    ArrTimeBlk LowCardinality(String),

    Cancelled Float32,
    CancellationCode FixedString(1),
    Diverted Float32,

    CRSElapsedTime Float32,
    ActualElapsedTime Float32,
    AirTime Float32,
    Flights Float32,
    Distance Float32,
    DistanceGroup Float32,

    CarrierDelay Float32,
    WeatherDelay Float32,
    NASDelay Float32,
    SecurityDelay Float32,
    LateAircraftDelay Float32,

    FirstDepTime Float32,
    TotalAddGTime Float32,
    LongestAddGTime Float32,

    DivAirportLandings Float32,
    DivReachedDest Float32,
    DivActualElapsedTime Float32,
    DivArrDelay Float32,
    DivDistance Float32,

    Div1Airport LowCardinality(String),
    Div1AirportID Int32,
    Div1AirportSeqID Int32,
    Div1WheelsOn Float32,
    Div1TotalGTime Float32,
    Div1LongestGTime Float32,
    Div1WheelsOff Float32,
    Div1TailNum LowCardinality(String),

    Div2Airport LowCardinality(String),
    Div2AirportID Int32,
    Div2AirportSeqID Int32,
    Div2WheelsOn Float32,
    Div2TotalGTime Float32,
    Div2LongestGTime Float32,
    Div2WheelsOff Float32,
    Div2TailNum LowCardinality(String),

    Div3Airport LowCardinality(String),
    Div3AirportID Int32,
    Div3AirportSeqID Int32,
    Div3WheelsOn Float32,
    Div3TotalGTime Float32,
    Div3LongestGTime Float32,
    Div3WheelsOff Float32,
    Div3TailNum LowCardinality(String),

    Div4Airport LowCardinality(String),
    Div4AirportID Int32,
    Div4AirportSeqID Int32,
    Div4WheelsOn Float32,
    Div4TotalGTime Float32,
    Div4LongestGTime Float32,
    Div4WheelsOff Float32,
    Div4TailNum LowCardinality(String),

    Div5Airport LowCardinality(String),
    Div5AirportID Int32,
    Div5AirportSeqID Int32,
    Div5WheelsOn Float32,
    Div5TotalGTime Float32,
    Div5LongestGTime Float32,
    Div5WheelsOff Float32,
    Div5TailNum LowCardinality(String)
)
ENGINE = MergeTree
ORDER BY
(
    Year,
    Quarter,
    Month,
    DayofMonth,
    FlightDate,
    IATA_CODE_Reporting_Airline
);
"

query "
CREATE TABLE IF NOT EXISTS ontime_imported_files
(
    FileName String,
    ImportedAt DateTime DEFAULT now(),
    ImportedRows UInt64
)
ENGINE = MergeTree
ORDER BY FileName;
"

shopt -s nullglob
CSV_FILES=("$DATA_DIR"/*.csv)
shopt -u nullglob

if (( ${#CSV_FILES[@]} == 0 )); then

  echo "ERROR: No CSV files found in:"
  echo "$DATA_DIR"
  echo
  echo "Run setup-ontime.sh before starting ClickHouse."

  exit 1
fi

echo "============================================================"
echo "OnTime CSV files found: ${#CSV_FILES[@]}"
echo "============================================================"

START_TIME=$(date +%s)

IMPORTED=0
SKIPPED=0

for file in "${CSV_FILES[@]}"; do

  filename="$(basename "$file")"

  escaped_filename="${filename//\'/\'\'}"

  already_imported="$(
    query "
      SELECT count()
      FROM ontime_imported_files
      WHERE FileName = '${escaped_filename}'
    " |
    tr -d '[:space:]'
  )"

  if [[ "$already_imported" != "0" ]]; then

    echo "Skip (already imported): $filename"

    SKIPPED=$((SKIPPED + 1))

    continue
  fi

  echo
  echo "Importing: $filename"

  FILE_START=$(date +%s)

  BEFORE_ROWS="$(
    query "SELECT count() FROM ontime" |
    tr -d '[:space:]'
  )"

  "${CLICKHOUSE_CLIENT[@]}" \
    --date_time_input_format=best_effort \
    --max_insert_threads=8 \
    --query="INSERT INTO ontime FORMAT CSVWithNames" \
    < "$file"

  AFTER_ROWS="$(
    query "SELECT count() FROM ontime" |
    tr -d '[:space:]'
  )"

  IMPORTED_ROWS=$((AFTER_ROWS - BEFORE_ROWS))

  printf '%s\t%s\n' "$filename" "$IMPORTED_ROWS" \
    | "${CLICKHOUSE_CLIENT[@]}" \
        --query="INSERT INTO ontime_imported_files (FileName, ImportedRows) FORMAT TabSeparated"

  FILE_END=$(date +%s)

  FILE_DURATION=$((FILE_END - FILE_START))

  echo "    Imported rows: $(printf "%'d" "$IMPORTED_ROWS")"
  echo "    Total rows:    $(printf "%'d" "$AFTER_ROWS")"
  echo "    Time:          ${FILE_DURATION}s"

  IMPORTED=$((IMPORTED + 1))

done

TOTAL_END=$(date +%s)
TOTAL_DURATION=$((TOTAL_END - START_TIME))

FINAL_ROWS="$(
  query "SELECT count() FROM ontime" |
  tr -d '[:space:]'
)"

MIN_YEAR="$(
  query "SELECT min(Year) FROM ontime" |
  tr -d '[:space:]'
)"

MAX_YEAR="$(
  query "SELECT max(Year) FROM ontime" |
  tr -d '[:space:]'
)"

echo
echo "============================================================"
echo "OnTime initialization complete"
echo "============================================================"
echo "Imported files: $IMPORTED"
echo "Skipped files:  $SKIPPED"
echo "Total rows:     $(printf "%'d" "$FINAL_ROWS")"
echo "Year range:     $MIN_YEAR - $MAX_YEAR"
echo "Total time:     ${TOTAL_DURATION}s"
echo "============================================================"

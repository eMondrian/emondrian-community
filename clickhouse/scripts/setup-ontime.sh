#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLICKHOUSE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DATA_DIR="$CLICKHOUSE_DIR/datasets/ontime"

BASE_URL="https://transtats.bts.gov/PREZIP/"

DEFAULT_SAMPLE_YEAR="2022"
DEFAULT_SAMPLE_MONTH="1"

MODE=""
YEAR=""
MONTHS=()

usage() {
  cat <<'USAGE'
Usage:
  ./clickhouse/scripts/setup-ontime.sh --sample [--months ...]
  ./clickhouse/scripts/setup-ontime.sh --year YYYY [--months ...]
  ./clickhouse/scripts/setup-ontime.sh --full

Options:
  --sample         Quick demo dataset. Defaults to January 2022 only.
  --year YYYY      Download all available months for a year,
                   or selected months with --months.
  --full           Download every available OnTime ZIP.
                   WARNING: this can be very large.
  --months LIST    Limit months for --sample / --year.

Examples:
  --months 1 2 12
  --months 1,2,12

Examples:
  ./clickhouse/scripts/setup-ontime.sh --sample
  ./clickhouse/scripts/setup-ontime.sh --sample --months 1 2 3
  ./clickhouse/scripts/setup-ontime.sh --year 2022
  ./clickhouse/scripts/setup-ontime.sh --year 2022 --months 1,2,12
  ./clickhouse/scripts/setup-ontime.sh --full
USAGE
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: Required command '$1' is not installed."
    exit 1
  fi
}

is_month() {
  local value="$1"

  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  (( value >= 1 && value <= 12 ))
}

parse_months_arg() {
  local token="$1"
  local part

  if [[ "$token" == *,* ]]; then
    IFS=',' read -ra parts <<< "$token"

    for part in "${parts[@]}"; do
      [[ -n "$part" ]] && MONTHS+=("$part")
    done
  else
    MONTHS+=("$token")
  fi
}

if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sample)
      MODE="sample"
      YEAR="$DEFAULT_SAMPLE_YEAR"
      shift
      ;;

    --year)
      MODE="year"
      YEAR="${2:-}"

      if [[ -z "$YEAR" || ! "$YEAR" =~ ^[0-9]{4}$ ]]; then
        echo "ERROR: --year requires a four-digit year, for example 2022."
        exit 1
      fi

      shift 2
      ;;

    --full)
      MODE="full"
      shift
      ;;

    --months)
      shift

      if [[ $# -eq 0 || "${1:0:2}" == "--" ]]; then
        echo "ERROR: --months requires at least one month."
        exit 1
      fi

      while [[ $# -gt 0 && "${1:0:2}" != "--" ]]; do
        parse_months_arg "$1"
        shift
      done
      ;;

    -h|--help)
      usage
      exit 0
      ;;

    *)
      echo "ERROR: Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$MODE" ]]; then
  echo "ERROR: Choose --sample, --year YYYY, or --full."
  exit 1
fi

if [[ "$MODE" == "full" && ${#MONTHS[@]} -gt 0 ]]; then
  echo "ERROR: --months cannot be used with --full."
  exit 1
fi

if [[ "$MODE" == "sample" && ${#MONTHS[@]} -eq 0 ]]; then
  MONTHS=("$DEFAULT_SAMPLE_MONTH")
fi

if [[ "$MODE" == "year" && ${#MONTHS[@]} -eq 0 ]]; then
  MONTHS=(1 2 3 4 5 6 7 8 9 10 11 12)
fi

if [[ ${#MONTHS[@]} -gt 0 ]]; then

  for month in "${MONTHS[@]}"; do

    if ! is_month "$month"; then
      echo "ERROR: Invalid month '$month'. Allowed values are 1..12."
      exit 1
    fi

  done

  mapfile -t MONTHS < <(
    printf '%s\n' "${MONTHS[@]}" |
    sort -n -u
  )
fi

require_command curl
require_command grep
require_command sort
require_command unzip

mkdir -p "$DATA_DIR"

AVAILABLE_FILE="$(mktemp)"
SELECTED_FILE="$(mktemp)"

trap 'rm -f "$AVAILABLE_FILE" "$SELECTED_FILE"' EXIT

echo "==> [1/3] Reading the official BTS OnTime file list"

curl \
  -fsSL \
  --retry 5 \
  --retry-delay 3 \
  --connect-timeout 30 \
  "$BASE_URL" \
  | grep -oE 'On_Time_Reporting_Carrier_On_Time_Performance[^"<[:space:]]*_[0-9]{4}_[0-9]{1,2}\.zip' \
  | sort -Vu \
  > "$AVAILABLE_FILE"

if [[ ! -s "$AVAILABLE_FILE" ]]; then
  echo "ERROR: Could not read the OnTime ZIP list from:"
  echo "$BASE_URL"
  exit 1
fi

: > "$SELECTED_FILE"

if [[ "$MODE" == "full" ]]; then

  cat "$AVAILABLE_FILE" > "$SELECTED_FILE"

else

  for month in "${MONTHS[@]}"; do

    match="$(
      grep -E "_${YEAR}_${month}\.zip$" "$AVAILABLE_FILE" |
      head -n 1 ||
      true
    )"

    if [[ -z "$match" ]]; then
      echo "ERROR: No OnTime file found for ${YEAR}-${month}."
      exit 1
    fi

    echo "$match" >> "$SELECTED_FILE"

  done
fi

FILE_COUNT="$(wc -l < "$SELECTED_FILE" | tr -d ' ')"

echo "    Files selected: $FILE_COUNT"

if [[ "$MODE" == "full" ]]; then
  echo "    WARNING: --full can download a very large amount of data."
fi

echo "==> [2/3] Downloading ZIP files"

while IFS= read -r filename; do

  [[ -z "$filename" ]] && continue

  zip_path="$DATA_DIR/$filename"
  csv_path="$DATA_DIR/${filename%.zip}.csv"

  if [[ -f "$csv_path" ]]; then
    echo "    Skip (CSV already exists): $(basename "$csv_path")"
    continue
  fi

  echo "    Download: $filename"

  if [[ -f "$zip_path" ]]; then
    echo "    Resume existing partial ZIP"
  fi

  if ! curl \
      -fL \
      --retry 5 \
      --retry-delay 5 \
      --connect-timeout 30 \
      -C - \
      -o "$zip_path" \
      "${BASE_URL}${filename}"
  then

    echo "    Resume failed. Retrying this file from the beginning..."

    rm -f "$zip_path"

    curl \
      -fL \
      --retry 5 \
      --retry-delay 5 \
      --connect-timeout 30 \
      -o "$zip_path" \
      "${BASE_URL}${filename}"
  fi

done < "$SELECTED_FILE"

echo "==> [3/3] Extracting ZIP files"

while IFS= read -r filename; do

  [[ -z "$filename" ]] && continue

  zip_path="$DATA_DIR/$filename"
  csv_path="$DATA_DIR/${filename%.zip}.csv"

  if [[ -f "$csv_path" ]]; then
    continue
  fi

  if [[ ! -f "$zip_path" ]]; then
    echo "ERROR: Expected ZIP not found:"
    echo "$zip_path"
    exit 1
  fi

  echo "    Extract: $filename"

  unzip \
    -o \
    "$zip_path" \
    -d "$DATA_DIR" \
    >/dev/null

  rm -f "$zip_path"

done < "$SELECTED_FILE"

CSV_COUNT="$(
  find "$DATA_DIR" \
    -maxdepth 1 \
    -type f \
    -name '*.csv' |
  wc -l |
  tr -d ' '
)"

DATA_SIZE="$(
  du -sh "$DATA_DIR" |
  awk '{print $1}'
)"

echo
echo "Done."
echo "CSV files: $CSV_COUNT"
echo "Dataset size: $DATA_SIZE"
echo "Location: $DATA_DIR"

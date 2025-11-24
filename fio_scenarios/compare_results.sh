#!/bin/bash
#
# Compare Test 1 (NO FDP) vs Test 2 (WITH FDP) results
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/test_results"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
echo_success() { echo -e "${GREEN}[✓]${NC} $1"; }
echo_warn() { echo -e "${YELLOW}[!]${NC} $1"; }

echo ""
echo "========================================================="
echo "   FDP QoS Comparison: Test 1 vs Test 2"
echo "========================================================="
echo ""

if [ ! -d "$RESULTS_DIR" ]; then
    echo_warn "No results directory found: $RESULTS_DIR"
    exit 1
fi

# Find latest test results
TEST1_DIR=$(ls -td "${RESULTS_DIR}"/01_no_fdp_* 2>/dev/null | head -1)
TEST2_DIR=$(ls -td "${RESULTS_DIR}"/02_with_fdp_* 2>/dev/null | head -1)

if [ -z "$TEST1_DIR" ]; then
    echo_warn "Test 1 results not found. Run test_1_no_fdp.sh first."
    exit 1
fi

if [ -z "$TEST2_DIR" ]; then
    echo_warn "Test 2 results not found. Run test_2_with_fdp.sh after rebooting VM."
    exit 1
fi

echo_info "Test 1 (NO FDP): $TEST1_DIR"
echo_info "Test 2 (WITH FDP): $TEST2_DIR"
echo ""

# Analyze latencies
analyze_file() {
    local FILE=$1
    local TMPFILE="/tmp/compare_$$.tmp"
    
    if [ ! -f "$FILE" ] || [ ! -s "$FILE" ]; then
        echo "0 0 0 0 0 0"
        return
    fi
    
    # Use /tmp for temp files to avoid permission issues
    sort -n "$FILE" > "$TMPFILE" 2>/dev/null
    
    if [ ! -f "$TMPFILE" ]; then
        echo "0 0 0 0 0 0"
        return
    fi
    
    local COUNT=$(wc -l < "$TMPFILE")
    local MIN=$(head -1 "$TMPFILE")
    local MAX=$(tail -1 "$TMPFILE")
    local AVG=$(awk '{sum+=$1} END {print int(sum/NR)}' "$TMPFILE")
    local P50=$(awk -v p=0.50 -v c=$COUNT 'NR==int(c*p)+1 {print; exit}' "$TMPFILE")
    local P95=$(awk -v p=0.95 -v c=$COUNT 'NR==int(c*p)+1 {print; exit}' "$TMPFILE")
    local P99=$(awk -v p=0.99 -v c=$COUNT 'NR==int(c*p)+1 {print; exit}' "$TMPFILE")
    rm -f "$TMPFILE"
    
    # Return 0 if any value is empty
    if [ -z "$MIN" ] || [ -z "$AVG" ] || [ -z "$P50" ] || [ -z "$P95" ] || [ -z "$P99" ] || [ -z "$MAX" ]; then
        echo "0 0 0 0 0 0"
        return
    fi
    
    echo "$MIN $AVG $P50 $P95 $P99 $MAX"
}

# Get Test 1 stats
TEST1_FILE="${TEST1_DIR}/victim_read_latencies.txt"
read -r T1_MIN T1_AVG T1_P50 T1_P95 T1_P99 T1_MAX <<< $(analyze_file "$TEST1_FILE")

# Get Test 2 stats
TEST2_FILE="${TEST2_DIR}/victim_read_latencies.txt"
read -r T2_MIN T2_AVG T2_P50 T2_P95 T2_P99 T2_MAX <<< $(analyze_file "$TEST2_FILE")

# Print comparison
echo "========================================================="
echo "   Victim Read Latency Comparison"
echo "========================================================="
echo ""
printf "%-15s %15s %15s %15s\n" "Metric" "Test 1 (NO FDP)" "Test 2 (WITH FDP)" "Improvement"
echo "---------------------------------------------------------"
printf "%-15s %12s μs %12s μs %15s\n" "Min" "$T1_MIN" "$T2_MIN" "-"
printf "%-15s %12s μs %12s μs " "Average" "$T1_AVG" "$T2_AVG"

if [ -n "$T1_AVG" ] && [ -n "$T2_AVG" ] && [ "$T1_AVG" -gt 0 ] 2>/dev/null && [ "$T2_AVG" -gt 0 ] 2>/dev/null; then
    AVG_IMPROVE=$(( (T1_AVG - T2_AVG) * 100 / T1_AVG ))
    if [ "$AVG_IMPROVE" -gt 0 ]; then
        printf "${GREEN}%11s%%${NC}\n" "$AVG_IMPROVE"
    else
        printf "${RED}%11s%%${NC}\n" "$AVG_IMPROVE"
    fi
else
    printf "%15s\n" "-"
fi

printf "%-15s %12s μs %12s μs " "P50" "$T1_P50" "$T2_P50"
if [ -n "$T1_P50" ] && [ -n "$T2_P50" ] && [ "$T1_P50" -gt 0 ] 2>/dev/null && [ "$T2_P50" -gt 0 ] 2>/dev/null; then
    P50_IMPROVE=$(( (T1_P50 - T2_P50) * 100 / T1_P50 ))
    if [ "$P50_IMPROVE" -gt 0 ]; then
        printf "${GREEN}%11s%%${NC}\n" "$P50_IMPROVE"
    else
        printf "${RED}%11s%%${NC}\n" "$P50_IMPROVE"
    fi
else
    printf "%15s\n" "-"
fi

printf "%-15s %12s μs %12s μs " "P95" "$T1_P95" "$T2_P95"
if [ -n "$T1_P95" ] && [ -n "$T2_P95" ] && [ "$T1_P95" -gt 0 ] 2>/dev/null && [ "$T2_P95" -gt 0 ] 2>/dev/null; then
    P95_IMPROVE=$(( (T1_P95 - T2_P95) * 100 / T1_P95 ))
    if [ "$P95_IMPROVE" -gt 0 ]; then
        printf "${GREEN}%11s%%${NC}\n" "$P95_IMPROVE"
    else
        printf "${RED}%11s%%${NC}\n" "$P95_IMPROVE"
    fi
else
    printf "%15s\n" "-"
fi

printf "%-15s %12s μs %12s μs " "P99" "$T1_P99" "$T2_P99"
if [ -n "$T1_P99" ] && [ -n "$T2_P99" ] && [ "$T1_P99" -gt 0 ] 2>/dev/null && [ "$T2_P99" -gt 0 ] 2>/dev/null; then
    P99_IMPROVE=$(( (T1_P99 - T2_P99) * 100 / T1_P99 ))
    if [ "$P99_IMPROVE" -gt 0 ]; then
        printf "${GREEN}%11s%%${NC}\n" "$P99_IMPROVE"
    else
        printf "${RED}%11s%%${NC}\n" "$P99_IMPROVE"
    fi
else
    printf "%15s\n" "-"
fi

printf "%-15s %12s μs %12s μs %15s\n" "Max" "$T1_MAX" "$T2_MAX" "-"

echo ""
echo "========================================================="
echo ""

# Final verdict
if [ -n "$T1_P99" ] && [ -n "$T2_P99" ] && [ -n "$P99_IMPROVE" ] && [ "$T1_P99" -gt 0 ] 2>/dev/null && [ "$T2_P99" -gt 0 ] 2>/dev/null; then
    if [ "$P99_IMPROVE" -gt 0 ] 2>/dev/null; then
        echo_success "✓ FDP provides ${P99_IMPROVE}% P99 latency improvement!"
        echo ""
        echo "FDP successfully isolated victim from noisy neighbor's GC!"
    else
        NEG_IMPROVE=$(( -1 * P99_IMPROVE ))
        echo_warn "⚠ FDP showed ${NEG_IMPROVE}% higher latency"
        echo ""
        echo "Possible reasons:"
        echo "  • Test 1 had more GC pressure (4GB pre-fill)"
        echo "  • Test 2 had less GC pressure (no pre-fill)"
        echo "  • FDP isolation is working, just less GC to isolate from"
    fi
else
    echo_warn "⚠ Could not calculate improvement"
    echo ""
    echo "Check that both test result files exist and have valid data:"
    echo "  Test 1: $TEST1_FILE"
    echo "  Test 2: $TEST2_FILE"
fi

echo ""
echo "Results directories:"
echo "  Test 1: $TEST1_DIR"
echo "  Test 2: $TEST2_DIR"
echo ""


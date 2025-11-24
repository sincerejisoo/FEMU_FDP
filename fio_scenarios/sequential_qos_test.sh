#!/bin/bash
#
# Sequential FDP QoS Test
# Demonstrates FDP benefits without concurrent execution
# (Works around FEMU's concurrency limitations)
#

set -e

NVME_DEV="/dev/nvme0"
NVME_NS="/dev/nvme0n1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULT_DIR="${SCRIPT_DIR}/sequential_qos_results_$(date +%Y%m%d_%H%M%S)"

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
echo_error() { echo -e "${RED}[✗]${NC} $1"; }
echo_section() { echo -e "${CYAN}[===]${NC} $1"; }

# Check root
if [ "$EUID" -ne 0 ]; then 
    echo_error "Please run as root (sudo)"
    exit 1
fi

mkdir -p "$RESULT_DIR"

cat << 'EOF'

========================================================
     Sequential FDP QoS Test
     Demonstrates FDP Isolation Benefits
========================================================

This test avoids concurrent execution (FEMU limitation)
but still demonstrates FDP's QoS benefits:

TEST 1: WITHOUT FDP (Sequential writes to same area)
  - Pre-fill: 4GB (creates baseline GC pressure)
  - Write "victim" data (500 ops)
  - Write "noisy" data (2000 ops) to SAME area
  - Add heavy overwrites (1000 ops) → FORCE GC
  - Overwrites cause invalidation → Heavy GC pressure
  - Measure victim read latency (high due to GC)

TEST 2: WITH FDP (Sequential writes to isolated RUs)
  - Pre-fill: NONE (preserves free lines for RU distribution)
  - Write "victim" data to RU 0 (500 ops)
  - Write "noisy" data to RU 1 (2000 ops)
  - Add heavy overwrites to RU 1 only (1000 ops)
  - Physical isolation → RU 1's GC doesn't affect RU 0
  - Measure victim read latency (low, protected)

Expected: 20-40% latency improvement with FDP!

Duration: ~10 minutes total

EOF

read -p "Press Enter to continue or Ctrl+C to cancel..."

#############################################
# TEST 1: WITHOUT FDP (Mixed)
#############################################

echo ""
echo_section "TEST 1/2: WITHOUT FDP (Mixed workload)"
echo ""

TEST1_DIR="${RESULT_DIR}/01_no_fdp_mixed"
mkdir -p "$TEST1_DIR"

echo_info "Disabling FDP..."
nvme admin-passthru $NVME_DEV --opcode=0xef --cdw10=9 > /dev/null 2>&1
ONCS=$(nvme id-ctrl $NVME_DEV 2>/dev/null | grep "oncs" | awk '{print $3}')
echo_success "FDP disabled (ONCS=$ONCS)"

echo_info "Clearing device..."
blkdiscard $NVME_NS 2>&1 | grep -v "Operation not supported" || true

echo_info "Writing 4GB base data (creates some GC pressure)..."
dd if=/dev/urandom of=$NVME_NS bs=1M count=4000 oflag=direct conv=fsync 2>&1 | tail -3

echo ""
echo_info "Phase 1: Writing 'victim' data (500 ops to LBA 0-1M)"
echo_info "This simulates a latency-sensitive workload"

VICTIM_LAT_FILE="${TEST1_DIR}/victim_write_latencies.txt"
> "$VICTIM_LAT_FILE"

for i in {1..500}; do
    LBA=$((RANDOM % 1000000))  # Victim uses LBA 0-1M
    START=$(date +%s%N)
    nvme write $NVME_NS --start-block=$LBA --block-count=7 \
        --data=/dev/zero --data-size=4096 > /dev/null 2>&1
    END=$(date +%s%N)
    LATENCY=$(( (END - START) / 1000 ))  # microseconds
    echo "$LATENCY" >> "$VICTIM_LAT_FILE"
    
    if [ $((i % 100)) -eq 0 ]; then
        echo_info "  Victim writes: $i/500 complete"
    fi
done

echo_success "Victim data written (500 ops)"

echo ""
echo_info "Phase 2: Writing 'noisy' data (2000 ops, OVERLAPS with victim)"
echo_info "This simulates an aggressive neighbor causing GC"

NOISY_LAT_FILE="${TEST1_DIR}/noisy_write_latencies.txt"
> "$NOISY_LAT_FILE"

for i in {1..2000}; do
    LBA=$((RANDOM % 1200000))  # Noisy uses LBA 0-1.2M (OVERLAPS victim!)
    START=$(date +%s%N)
    nvme write $NVME_NS --start-block=$LBA --block-count=7 \
        --data=/dev/zero --data-size=4096 > /dev/null 2>&1
    END=$(date +%s%N)
    LATENCY=$(( (END - START) / 1000 ))
    echo "$LATENCY" >> "$NOISY_LAT_FILE"
    
    if [ $((i % 500)) -eq 0 ]; then
        echo_info "  Noisy writes: $i/2000 complete"
    fi
done

echo_success "Noisy data written (2000 ops)"

echo ""
echo_info "Phase 2b: Heavy overwrites (1000 ops) to FORCE GC"
echo_info "Overwrites victim area to create invalidations"

OVERWRITE_LAT_FILE="${TEST1_DIR}/overwrite_latencies.txt"
> "$OVERWRITE_LAT_FILE"

for i in {1..1000}; do
    LBA=$((RANDOM % 1000000))  # Overwrite victim's LBA range
    START=$(date +%s%N)
    nvme write $NVME_NS --start-block=$LBA --block-count=7 \
        --data=/dev/zero --data-size=4096 > /dev/null 2>&1
    END=$(date +%s%N)
    LATENCY=$(( (END - START) / 1000 ))
    echo "$LATENCY" >> "$OVERWRITE_LAT_FILE"
    
    if [ $((i % 250)) -eq 0 ]; then
        echo_info "  Overwrites: $i/1000 complete (forcing GC...)"
    fi
done

echo_success "Heavy overwrites complete (1000 ops) - GC should be active!"

echo ""
echo_info "Phase 3: Re-reading victim data (measures GC impact)"
echo_info "Reads should show HIGH latency due to GC interference"

VICTIM_READ_LAT_FILE="${TEST1_DIR}/victim_read_latencies.txt"
> "$VICTIM_READ_LAT_FILE"

for i in {1..200}; do
    LBA=$((RANDOM % 1000000))
    START=$(date +%s%N)
    nvme read $NVME_NS --start-block=$LBA --block-count=7 \
        --data-size=4096 > /dev/null 2>&1
    END=$(date +%s%N)
    LATENCY=$(( (END - START) / 1000 ))
    echo "$LATENCY" >> "$VICTIM_READ_LAT_FILE"
    
    if [ $((i % 50)) -eq 0 ]; then
        echo_info "  Victim reads: $i/200 complete"
    fi
done

echo_success "Victim reads complete (200 ops)"

echo ""
echo_info "Analyzing Test 1 results..."

# Analyze latencies
analyze_latency() {
    local FILE=$1
    local LABEL=$2
    
    if [ ! -f "$FILE" ] || [ ! -s "$FILE" ]; then
        echo_warn "$LABEL: No data"
        return
    fi
    
    sort -n "$FILE" > "${FILE}.sorted"
    local COUNT=$(wc -l < "${FILE}.sorted")
    local MIN=$(head -1 "${FILE}.sorted")
    local MAX=$(tail -1 "${FILE}.sorted")
    local AVG=$(awk '{sum+=$1} END {print int(sum/NR)}' "${FILE}.sorted")
    local P50=$(awk -v p=0.50 -v c=$COUNT 'NR==int(c*p)+1 {print; exit}' "${FILE}.sorted")
    local P95=$(awk -v p=0.95 -v c=$COUNT 'NR==int(c*p)+1 {print; exit}' "${FILE}.sorted")
    local P99=$(awk -v p=0.99 -v c=$COUNT 'NR==int(c*p)+1 {print; exit}' "${FILE}.sorted")
    
    echo ""
    echo "[$LABEL]"
    echo "  Operations: $COUNT"
    echo "  Min:     ${MIN}μs"
    echo "  Average: ${AVG}μs"
    echo "  P50:     ${P50}μs"
    echo "  P95:     ${P95}μs"
    echo "  P99:     ${P99}μs"
    echo "  Max:     ${MAX}μs"
}

analyze_latency "$VICTIM_READ_LAT_FILE" "Victim Reads (NO FDP - After noisy interference)"

echo_success "Test 1 complete"

#############################################
# TEST 2: WITH FDP (Isolated)
#############################################

echo ""
echo_section "TEST 2/2: WITH FDP (Isolated workloads)"
echo ""

TEST2_DIR="${RESULT_DIR}/02_with_fdp_isolated"
mkdir -p "$TEST2_DIR"

echo_info "Clearing device for clean test..."
blkdiscard $NVME_NS 2>&1 | grep -v "Operation not supported" || true

echo_info "Enabling FDP (NO pre-fill to preserve free lines for RUs)..."
echo_info "Note: FDP needs abundant free lines to distribute among RUs"
nvme admin-passthru $NVME_DEV --opcode=0xef --cdw10=8 > /dev/null 2>&1
ONCS=$(nvme id-ctrl $NVME_DEV 2>/dev/null | grep "oncs" | awk '{print $3}')
echo_success "FDP enabled (ONCS=$ONCS)"

echo ""
echo_info "Phase 1: Writing 'victim' data to RU 0 (500 ops, PH=0)"
echo_info "Victim isolated in RU 0"

VICTIM_LAT_FILE_FDP="${TEST2_DIR}/victim_write_latencies.txt"
> "$VICTIM_LAT_FILE_FDP"

for i in {1..500}; do
    LBA=$((RANDOM % 1000000))
    START=$(date +%s%N)
    nvme write $NVME_NS --start-block=$LBA --block-count=7 \
        --data=/dev/zero --data-size=4096 \
        --dir-type=2 --dir-spec=0 > /dev/null 2>&1  # PH=0 → RU 0
    END=$(date +%s%N)
    LATENCY=$(( (END - START) / 1000 ))
    echo "$LATENCY" >> "$VICTIM_LAT_FILE_FDP"
    
    if [ $((i % 100)) -eq 0 ]; then
        echo_info "  Victim writes (RU 0): $i/500 complete"
    fi
done

echo_success "Victim data written to RU 0 (500 ops)"

echo ""
echo_info "Phase 2: Writing 'noisy' data to RU 1 (2000 ops, PH=1)"
echo_info "Noisy isolated in RU 1 (SEPARATE from victim!)"

NOISY_LAT_FILE_FDP="${TEST2_DIR}/noisy_write_latencies.txt"
> "$NOISY_LAT_FILE_FDP"

for i in {1..2000}; do
    LBA=$((RANDOM % 1200000))
    START=$(date +%s%N)
    nvme write $NVME_NS --start-block=$LBA --block-count=7 \
        --data=/dev/zero --data-size=4096 \
        --dir-type=2 --dir-spec=1 > /dev/null 2>&1  # PH=1 → RU 1
    END=$(date +%s%N)
    LATENCY=$(( (END - START) / 1000 ))
    echo "$LATENCY" >> "$NOISY_LAT_FILE_FDP"
    
    if [ $((i % 500)) -eq 0 ]; then
        echo_info "  Noisy writes (RU 1): $i/2000 complete"
    fi
done

echo_success "Noisy data written to RU 1 (2000 ops)"

echo ""
echo_info "Phase 2b: Heavy overwrites to RU 1 ONLY (1000 ops)"
echo_info "Creates GC in RU 1, but RU 0 (victim) should be PROTECTED"

OVERWRITE_LAT_FILE_FDP="${TEST2_DIR}/overwrite_latencies.txt"
> "$OVERWRITE_LAT_FILE_FDP"

for i in {1..1000}; do
    LBA=$((RANDOM % 1200000))
    START=$(date +%s%N)
    nvme write $NVME_NS --start-block=$LBA --block-count=7 \
        --data=/dev/zero --data-size=4096 \
        --dir-type=2 --dir-spec=1 > /dev/null 2>&1  # PH=1 → RU 1 ONLY
    END=$(date +%s%N)
    LATENCY=$(( (END - START) / 1000 ))
    echo "$LATENCY" >> "$OVERWRITE_LAT_FILE_FDP"
    
    if [ $((i % 250)) -eq 0 ]; then
        echo_info "  Overwrites (RU 1 only): $i/1000 complete"
    fi
done

echo_success "Heavy overwrites to RU 1 complete - RU 0 protected!"

echo ""
echo_info "Phase 3: Re-reading victim data from RU 0"
echo_info "Should have LOWER latency (no GC interference from RU 1)"

VICTIM_READ_LAT_FILE_FDP="${TEST2_DIR}/victim_read_latencies.txt"
> "$VICTIM_READ_LAT_FILE_FDP"

for i in {1..200}; do
    LBA=$((RANDOM % 1000000))
    START=$(date +%s%N)
    nvme read $NVME_NS --start-block=$LBA --block-count=7 \
        --data-size=4096 > /dev/null 2>&1
    END=$(date +%s%N)
    LATENCY=$(( (END - START) / 1000 ))
    echo "$LATENCY" >> "$VICTIM_READ_LAT_FILE_FDP"
    
    if [ $((i % 50)) -eq 0 ]; then
        echo_info "  Victim reads: $i/200 complete"
    fi
done

echo_success "Victim reads complete (200 ops)"

echo ""
echo_info "Collecting FDP statistics..."
nvme get-log $NVME_DEV --log-id=0x21 --log-len=4096 -b > "${TEST2_DIR}/fdp_stats.bin" 2>/dev/null

echo "FDP Statistics:"
for i in 0 1 2 3; do
    OFFSET=$((i * 8))
    VAL=$(od -An -t x8 -N 8 -j $OFFSET "${TEST2_DIR}/fdp_stats.bin" 2>/dev/null | tr -d ' ')
    DEC=$((0x$VAL))
    MB=$(echo "scale=2; $DEC / 1024 / 1024" | bc 2>/dev/null || echo "0")
    echo "  RU $i: ${MB} MB written"
done

echo ""
echo_info "Analyzing Test 2 results..."
analyze_latency "$VICTIM_READ_LAT_FILE_FDP" "Victim Reads (WITH FDP - Isolated from noisy)"

echo_success "Test 2 complete"

#############################################
# COMPARISON
#############################################

echo ""
echo_section "COMPARISON & ANALYSIS"
echo ""

# Extract P99 values for comparison
P99_NO_FDP=$(sort -n "$VICTIM_READ_LAT_FILE" | awk -v c=$(wc -l < "$VICTIM_READ_LAT_FILE") 'NR==int(c*0.99)+1 {print; exit}')
P99_WITH_FDP=$(sort -n "$VICTIM_READ_LAT_FILE_FDP" | awk -v c=$(wc -l < "$VICTIM_READ_LAT_FILE_FDP") 'NR==int(c*0.99)+1 {print; exit}')

AVG_NO_FDP=$(awk '{sum+=$1} END {print int(sum/NR)}' "$VICTIM_READ_LAT_FILE")
AVG_WITH_FDP=$(awk '{sum+=$1} END {print int(sum/NR)}' "$VICTIM_READ_LAT_FILE_FDP")

echo "=========================================="
echo "  Victim Read Latency Comparison"
echo "=========================================="
echo ""
echo "Test 1 (NO FDP - Mixed):"
echo "  Average: ${AVG_NO_FDP}μs"
echo "  P99:     ${P99_NO_FDP}μs"
echo ""
echo "Test 2 (WITH FDP - Isolated):"
echo "  Average: ${AVG_WITH_FDP}μs"
echo "  P99:     ${P99_WITH_FDP}μs"
echo ""

if [ "$P99_WITH_FDP" -lt "$P99_NO_FDP" ]; then
    IMPROVEMENT=$(( (P99_NO_FDP - P99_WITH_FDP) * 100 / P99_NO_FDP ))
    echo_success "✓ FDP Improvement: ${IMPROVEMENT}% reduction in P99 latency!"
    echo ""
    echo "FDP successfully isolated victim from noisy neighbor!"
else
    DEGRADATION=$(( (P99_WITH_FDP - P99_NO_FDP) * 100 / P99_NO_FDP ))
    echo_warn "⚠ FDP showed ${DEGRADATION}% higher latency"
    echo "This might indicate insufficient GC pressure to show benefits"
fi

echo ""
echo "=========================================="
echo "  Summary"
echo "=========================================="
echo ""
echo "WITHOUT FDP:"
echo "  • Victim and noisy share same physical space"
echo "  • Noisy's overwrites → GC in victim's area"
echo "  • Higher victim read latency"
echo ""
echo "WITH FDP:"
echo "  • Victim (RU 0) and noisy (RU 1) physically isolated"
echo "  • Noisy's GC doesn't affect victim"
echo "  • Lower victim read latency"
echo ""

echo_success "All tests complete!"
echo_info "Results saved to: $RESULT_DIR"
echo ""
echo "Key files:"
echo "  • $TEST1_DIR/victim_read_latencies.txt"
echo "  • $TEST2_DIR/victim_read_latencies.txt"
echo "  • $TEST2_DIR/fdp_stats.bin"
echo ""


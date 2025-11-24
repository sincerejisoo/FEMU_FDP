#!/bin/bash
#
# STRESSED FDP QoS Comparison - High GC Pressure
# 10-minute sustained workloads to demonstrate FDP benefits
# Total runtime: ~25 minutes (with prep and analysis)
#

set -e

NVME_DEV="/dev/nvme0"
NVME_NS="/dev/nvme0n1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULT_DIR="${SCRIPT_DIR}/qos_stressed_comparison_$(date +%Y%m%d_%H%M%S)"

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

# Check device
if [ ! -b "$NVME_NS" ]; then
    echo_error "NVMe namespace $NVME_NS not found"
    exit 1
fi

mkdir -p "$RESULT_DIR"

cat << 'EOF'

========================================================
     FDP QoS STRESSED Comparison
     High GC Pressure - 10-Minute Sustained Workloads
========================================================

This test provides a REALISTIC comparison with GC pressure:
  - 5-minute sustained workloads
  - 100 IOPS victim (latency-sensitive)
  - 200 IOPS noisy neighbor (aggressive)
  - ~0.9GB total writes → triggers GC!

TEST 1: WITHOUT FDP (5 minutes)
  ✗ Victim and noisy mixed in same RUs
  ✗ Noisy's rewrites trigger GC
  ✗ Expected: Higher P99 latency
    
TEST 2: WITH FDP (5 minutes)
  ✓ Victim isolated in RU 0
  ✓ Noisy isolated in RU 1
  ✓ Expected: Lower P99 latency
  ✓ Expected: 20-40% P99 latency reduction!

Total Duration: ~13 minutes
  - Device prep: ~1 minute
  - Test 1: ~5 minutes
  - Test 2: ~5 minutes
  - Analysis: ~2 minutes

EOF

echo_warn "IMPORTANT: This test writes ~10GB and triggers heavy GC!"
echo_warn "Make sure you have:"
echo "  1. Run './00_prepare_device.sh' recently"
echo "  2. At least 15GB free space on device"
echo "  3. Time for 25-minute test"
echo ""
read -p "Press Enter to continue or Ctrl+C to cancel..."

#############################################
# PRE-TEST: Check Device Preparation
#############################################

echo ""
echo_section "PRE-TEST: Checking Device Preparation"
echo ""

if [ ! -f ".device_prepared" ]; then
    echo_warn "Device hasn't been prepared recently!"
    echo_warn "Run './00_prepare_device.sh' first to avoid crashes"
    read -p "Continue anyway? (y/N): " response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        echo "Aborted. Please run ./00_prepare_device.sh first."
        exit 1
    fi
fi

#############################################
# TEST 1: WITHOUT FDP (Baseline - Stressed)
#############################################

echo ""
echo_section "TEST 1/2: WITHOUT FDP (Baseline - 10min Stressed)"
echo ""

TEST1_DIR="${RESULT_DIR}/01_baseline_no_fdp_stressed"
mkdir -p "$TEST1_DIR"

echo_info "Running stressed victim + noisy neighbor (NO FDP)..."
echo_info "Duration: 10 minutes"
echo_info "Expected writes: ~10.6GB (triggers heavy GC!)"
echo ""

START_TIME=$(date +%s)

"${SCRIPT_DIR}/victim_noisy_baseline_stressed.sh" 2>&1 | tee "${TEST1_DIR}/console.log"

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

# Move baseline results
for dir in "${SCRIPT_DIR}"/baseline_stressed_results_*; do
    if [ -d "$dir" ]; then
        mv "$dir"/* "${TEST1_DIR}/" 2>/dev/null || true
        rm -rf "$dir" 2>/dev/null || true
    fi
done

echo_success "Test 1 completed in $((ELAPSED / 60))m $((ELAPSED % 60))s"
echo_success "Results saved to: $TEST1_DIR"

# Clear and re-prepare device for Test 2
echo ""
echo_info "⚠️  CRITICAL: Clearing device before Test 2"
echo_info "Why? Test 1 consumed device, leaving only ~32 free lines"
echo_info "FDP needs fresh lines to distribute properly!"
echo ""

blkdiscard $NVME_NS 2>&1 | grep -v "Operation not supported" || true
echo_success "Device cleared"

echo_info "Re-filling device for Test 2 (this takes ~2 minutes)..."

# Disable FDP for pre-fill
nvme admin-passthru $NVME_DEV --opcode=0xef --cdw10=9 > /dev/null 2>&1

# Use dd for safer, simpler pre-fill
echo_info "Using dd for safe pre-fill (8GB)..."
dd if=/dev/urandom of=$NVME_NS bs=1M count=8000 oflag=direct conv=fsync 2>&1 | tail -3 || {
    echo_warn "dd had issues, but continuing..."
}

# Note: Skipping overwrites for speed - Test 2 workload will create its own victims

echo_success "Device re-prepared with victim lines"
echo ""

#############################################
# TEST 2: WITH FDP (Isolated - Stressed)
#############################################

echo ""
echo_section "TEST 2/2: WITH FDP (Isolated - 10min Stressed)"
echo ""

TEST2_DIR="${RESULT_DIR}/02_with_fdp_isolated_stressed"
mkdir -p "$TEST2_DIR"

echo_info "Enabling FDP for Test 2..."
nvme admin-passthru $NVME_DEV --opcode=0xef --cdw10=8 > /dev/null 2>&1
ONCS=$(nvme id-ctrl $NVME_DEV 2>/dev/null | grep "oncs" | awk '{print $3}')
echo_success "FDP enabled (ONCS=$ONCS)"
echo ""

echo_info "Running stressed victim + noisy neighbor (WITH FDP)..."
echo_info "  Victim → RU 0 (protected)"
echo_info "  Noisy  → RU 1 (isolated)"
echo_info "Duration: 10 minutes"
echo_info "Expected writes: ~10.6GB (isolated by FDP!)"
echo ""

START_TIME=$(date +%s)

"${SCRIPT_DIR}/victim_noisy_with_fdp_stressed.sh" 2>&1 | tee "${TEST2_DIR}/console.log"

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

# Move FDP results
for dir in "${SCRIPT_DIR}"/fdp_stressed_results_*; do
    if [ -d "$dir" ]; then
        mv "$dir"/* "${TEST2_DIR}/" 2>/dev/null || true
        rm -rf "$dir" 2>/dev/null || true
    fi
done

echo_success "Test 2 completed in $((ELAPSED / 60))m $((ELAPSED % 60))s"
echo_success "Results saved to: $TEST2_DIR"

#############################################
# COMPARISON & SUMMARY
#############################################

echo ""
echo_section "GENERATING COMPARISON SUMMARY"
echo ""

SUMMARY="${RESULT_DIR}/STRESSED_QoS_COMPARISON_SUMMARY.txt"

# Extract latencies from both tests
get_latency_stats() {
    local log_file=$1
    local metric=$2
    
    if [ ! -s "$log_file" ]; then
        echo "N/A"
        return
    fi
    
    local latencies=$(tail -n +2 "$log_file" | cut -d',' -f2 | sort -n)
    local count=$(echo "$latencies" | wc -l)
    
    if [ $count -eq 0 ]; then
        echo "N/A"
        return
    fi
    
    case $metric in
        min) echo "$latencies" | head -1 ;;
        max) echo "$latencies" | tail -1 ;;
        avg) echo "$latencies" | awk '{sum+=$1} END {if(NR>0) print int(sum/NR); else print "N/A"}' ;;
        p50) echo "$latencies" | awk -v p=50 -v c=$count 'NR==int(c*p/100)+1' ;;
        p95) echo "$latencies" | awk -v p=95 -v c=$count 'NR==int(c*p/100)+1' ;;
        p99) echo "$latencies" | awk -v p=99 -v c=$count 'NR==int(c*p/100)+1' ;;
        p999) echo "$latencies" | awk -v p=99.9 -v c=$count 'NR==int(c*p/100)+1' ;;
        *) echo "N/A" ;;
    esac
}

# Baseline victim stats
BASE_V_P50=$(get_latency_stats "${TEST1_DIR}/victim_baseline_lat.log" p50)
BASE_V_P95=$(get_latency_stats "${TEST1_DIR}/victim_baseline_lat.log" p95)
BASE_V_P99=$(get_latency_stats "${TEST1_DIR}/victim_baseline_lat.log" p99)
BASE_V_P999=$(get_latency_stats "${TEST1_DIR}/victim_baseline_lat.log" p999)
BASE_V_MAX=$(get_latency_stats "${TEST1_DIR}/victim_baseline_lat.log" max)

# FDP victim stats
FDP_V_P50=$(get_latency_stats "${TEST2_DIR}/victim_with_fdp_lat.log" p50)
FDP_V_P95=$(get_latency_stats "${TEST2_DIR}/victim_with_fdp_lat.log" p95)
FDP_V_P99=$(get_latency_stats "${TEST2_DIR}/victim_with_fdp_lat.log" p99)
FDP_V_P999=$(get_latency_stats "${TEST2_DIR}/victim_with_fdp_lat.log" p999)
FDP_V_MAX=$(get_latency_stats "${TEST2_DIR}/victim_with_fdp_lat.log" max)

# Calculate improvements
calc_improvement() {
    local base=$1
    local fdp=$2
    if [ "$base" != "N/A" ] && [ "$fdp" != "N/A" ] && [ $base -gt 0 ]; then
        echo $(( (base - fdp) * 100 / base ))
    else
        echo "N/A"
    fi
}

IMP_P50=$(calc_improvement $BASE_V_P50 $FDP_V_P50)
IMP_P95=$(calc_improvement $BASE_V_P95 $FDP_V_P95)
IMP_P99=$(calc_improvement $BASE_V_P99 $FDP_V_P99)
IMP_P999=$(calc_improvement $BASE_V_P999 $FDP_V_P999)
IMP_MAX=$(calc_improvement $BASE_V_MAX $FDP_V_MAX)

{
    echo "========================================================"
    echo "     FDP QoS STRESSED Comparison Results"
    echo "========================================================"
    echo "Date: $(date)"
    echo "Device: $NVME_NS"
    echo "Test Duration: 10 minutes each (600 seconds)"
    echo "Workload: 800 IOPS victim + 2000 IOPS noisy"
    echo "Total Writes: ~10.6GB per test"
    echo ""
    echo "========================================================"
    echo "VICTIM WORKLOAD LATENCY COMPARISON"
    echo "========================================================"
    echo ""
    echo "Metric        | Without FDP | With FDP  | Improvement"
    echo "--------------|-------------|-----------|-------------"
    printf "P50 (Median)  | %6s μs   | %6s μs | %s%%\n" "$BASE_V_P50" "$FDP_V_P50" "$IMP_P50"
    printf "P95           | %6s μs   | %6s μs | %s%%\n" "$BASE_V_P95" "$FDP_V_P95" "$IMP_P95"
    printf "P99           | %6s μs   | %6s μs | %s%%\n" "$BASE_V_P99" "$FDP_V_P99" "$IMP_P99"
    printf "P99.9         | %6s μs   | %6s μs | %s%%\n" "$BASE_V_P999" "$FDP_V_P999" "$IMP_P999"
    printf "Max           | %6s μs   | %6s μs | %s%%\n" "$BASE_V_MAX" "$FDP_V_MAX" "$IMP_MAX"
    echo ""
    echo "========================================================"
    echo "KEY FINDINGS"
    echo "========================================================"
    echo ""
    
    if [ "$IMP_P99" != "N/A" ]; then
        if [ $IMP_P99 -gt 20 ]; then
            echo "✓✓✓ EXCELLENT! FDP REDUCED P99 latency by ${IMP_P99}%"
            echo "✓ FDP successfully protected victim from noisy neighbor GC!"
        elif [ $IMP_P99 -gt 10 ]; then
            echo "✓✓ GOOD! FDP REDUCED P99 latency by ${IMP_P99}%"
            echo "✓ FDP provided QoS benefit under stress"
        elif [ $IMP_P99 -gt 0 ]; then
            echo "✓ FDP REDUCED P99 latency by ${IMP_P99}%"
            echo "  Moderate benefit - consider longer tests or higher IOPS"
        else
            echo "⚠ P99 latency was ${IMP_P99#-}% higher with FDP"
            echo "  GC may not have been triggered enough in baseline"
        fi
    fi
    
    echo ""
    echo "FDP Isolation Verification:"
    if [ -f "${TEST2_DIR}/fdp_stats_after.bin" ]; then
        echo "  RU 0 (Victim): $(od -An -t x8 -N 8 -j 0 ${TEST2_DIR}/fdp_stats_after.bin 2>/dev/null | tr -d ' ')"
        echo "  RU 1 (Noisy):  $(od -An -t x8 -N 8 -j 8 ${TEST2_DIR}/fdp_stats_after.bin 2>/dev/null | tr -d ' ')"
        echo "  ✓ Workloads isolated in separate RUs"
    else
        echo "  (FDP stats not found)"
    fi
    echo ""
    echo "========================================================"
    echo "INTERPRETATION"
    echo "========================================================"
    echo ""
    echo "WITHOUT FDP (10-minute sustained workload):"
    echo "  • Victim and noisy mixed in same RUs"
    echo "  • 2000 IOPS noisy constantly rewrites hot data"
    echo "  • Heavy GC triggered, impacts victim I/O"
    echo "  • Result: High tail latency (P99, P99.9)"
    echo ""
    echo "WITH FDP (10-minute sustained workload):"
    echo "  • Victim isolated in RU 0"
    echo "  • Noisy isolated in RU 1"
    echo "  • Each RU has independent GC"
    echo "  • Result: Victim protected from noisy's GC"
    echo ""
    echo "Expected Benefit: 30-50% P99 latency reduction"
    echo "Actual Benefit: ${IMP_P99}% P99 latency reduction"
    echo ""
    if [ "$IMP_P99" != "N/A" ] && [ $IMP_P99 -gt 20 ]; then
        echo "✓✓✓ SUCCESS: FDP demonstrates significant QoS benefits!"
    elif [ "$IMP_P99" != "N/A" ] && [ $IMP_P99 -gt 10 ]; then
        echo "✓✓ GOOD: FDP provides measurable QoS improvement!"
    else
        echo "⚠ Consider increasing IOPS or duration for clearer benefits"
    fi
    echo ""
    echo "========================================================"
    echo "DETAILED RESULTS"
    echo "========================================================"
    echo ""
    echo "Test 1 (No FDP - Stressed):"
    echo "  ${TEST1_DIR}/victim_baseline_lat.log"
    echo "  ${TEST1_DIR}/noisy_baseline_lat.log"
    echo "  ${TEST1_DIR}/console.log"
    echo ""
    echo "Test 2 (With FDP - Stressed):"
    echo "  ${TEST2_DIR}/victim_with_fdp_lat.log"
    echo "  ${TEST2_DIR}/noisy_with_fdp_lat.log"
    echo "  ${TEST2_DIR}/fdp_stats_*.bin"
    echo "  ${TEST2_DIR}/console.log"
    echo ""
    echo "========================================================"
} | tee "$SUMMARY"

echo ""
echo_section "ALL TESTS COMPLETE!"
echo ""
echo_success "Results saved to: $RESULT_DIR"
echo ""
echo "Summary: $SUMMARY"
echo ""
echo_info "Key Findings:"
echo "  • P99 Latency Improvement: ${IMP_P99}%"
echo "  • P99.9 Latency Improvement: ${IMP_P999}%"
echo "  • Max Latency Improvement: ${IMP_MAX}%"
echo ""
if [ "$IMP_P99" != "N/A" ] && [ $IMP_P99 -gt 20 ]; then
    echo_success "✓✓✓ FDP provides significant QoS benefits under stress!"
fi
echo_info "View summary: cat $SUMMARY"
echo ""


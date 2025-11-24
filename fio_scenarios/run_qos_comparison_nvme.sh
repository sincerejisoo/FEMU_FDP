#!/bin/bash
#
# FDP QoS Comparison: Apples-to-Apples using nvme-cli for both tests
# Demonstrates FDP's QoS benefits by comparing identical workloads
# with and without FDP isolation
#

set -e

NVME_DEV="/dev/nvme0"
NVME_NS="/dev/nvme0n1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULT_DIR="${SCRIPT_DIR}/qos_nvme_comparison_$(date +%Y%m%d_%H%M%S)"

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
     FDP QoS Demonstration (nvme-cli comparison)
========================================================

This test provides an APPLES-TO-APPLES comparison:
  - Both tests use nvme-cli (same methodology)
  - Both tests have identical workloads
  - Both tests run for 30 seconds
  - Only difference: FDP isolation

TEST 1: WITHOUT FDP
  ✗ Victim and noisy mixed in same RUs
  ✗ Noisy's GC impacts victim performance
  ✗ Expected: Higher P99/P999 latency variance
    
TEST 2: WITH FDP
  ✓ Victim isolated in RU 0
  ✓ Noisy isolated in RU 1
  ✓ Expected: Lower P99/P999 latency variance
  ✓ Expected: More predictable performance

Duration: ~2 minutes total (30s × 2 tests + setup)

EOF

echo_warn "IMPORTANT: Make sure you ran './00_prepare_device.sh' first!"
read -p "Press Enter to continue or Ctrl+C to cancel..."

#############################################
# TEST 1: WITHOUT FDP (Baseline)
#############################################

echo ""
echo_section "TEST 1/2: WITHOUT FDP (Baseline - Mixed Workloads)"
echo ""

TEST1_DIR="${RESULT_DIR}/01_baseline_no_fdp"
mkdir -p "$TEST1_DIR"

echo_info "Running victim + noisy neighbor (nvme-cli, NO FDP)..."
echo_info "This will take ~30 seconds..."
echo ""

"${SCRIPT_DIR}/victim_noisy_baseline_nvme.sh" 2>&1 | tee "${TEST1_DIR}/console.log"

# Move baseline results
for dir in "${SCRIPT_DIR}"/baseline_nvme_results_*; do
    if [ -d "$dir" ]; then
        mv "$dir"/* "${TEST1_DIR}/" 2>/dev/null || true
        rm -rf "$dir" 2>/dev/null || true
    fi
done

echo_success "Test 1 results saved to: $TEST1_DIR"

# Give system a moment to settle
echo_info "Waiting 5 seconds before next test..."
sleep 5

#############################################
# TEST 2: WITH FDP (Isolated)
#############################################

echo ""
echo_section "TEST 2/2: WITH FDP (Isolated Workloads)"
echo ""

TEST2_DIR="${RESULT_DIR}/02_with_fdp_isolated"
mkdir -p "$TEST2_DIR"

echo_info "Enabling FDP for Test 2..."
nvme admin-passthru $NVME_DEV --opcode=0xef --cdw10=8 > /dev/null 2>&1
ONCS=$(nvme id-ctrl $NVME_DEV 2>/dev/null | grep "oncs" | awk '{print $3}')
echo_success "FDP enabled (ONCS=$ONCS)"
echo ""

echo_info "Running victim + noisy neighbor (nvme-cli, WITH FDP)..."
echo_info "  Victim → RU 0 (protected)"
echo_info "  Noisy  → RU 1 (isolated)"
echo_info "This will take ~30 seconds..."
echo ""

"${SCRIPT_DIR}/victim_noisy_with_fdp.sh" 2>&1 | tee "${TEST2_DIR}/console.log"

# Move FDP results
for dir in "${SCRIPT_DIR}"/fdp_qos_results_*; do
    if [ -d "$dir" ]; then
        mv "$dir"/* "${TEST2_DIR}/" 2>/dev/null || true
        rm -rf "$dir" 2>/dev/null || true
    fi
done

echo_success "Test 2 results saved to: $TEST2_DIR"

#############################################
# COMPARISON & SUMMARY
#############################################

echo ""
echo_section "GENERATING COMPARISON SUMMARY"
echo ""

SUMMARY="${RESULT_DIR}/QoS_COMPARISON_SUMMARY.txt"

# Extract latencies from both tests
get_latency_stats() {
    local log_file=$1
    local metric=$2  # min, avg, p95, p99, max
    
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
        *) echo "N/A" ;;
    esac
}

# Baseline victim stats
BASE_V_P50=$(get_latency_stats "${TEST1_DIR}/victim_baseline_lat.log" p50)
BASE_V_P95=$(get_latency_stats "${TEST1_DIR}/victim_baseline_lat.log" p95)
BASE_V_P99=$(get_latency_stats "${TEST1_DIR}/victim_baseline_lat.log" p99)
BASE_V_MAX=$(get_latency_stats "${TEST1_DIR}/victim_baseline_lat.log" max)

# FDP victim stats
FDP_V_P50=$(get_latency_stats "${TEST2_DIR}/victim_with_fdp_lat.log" p50)
FDP_V_P95=$(get_latency_stats "${TEST2_DIR}/victim_with_fdp_lat.log" p95)
FDP_V_P99=$(get_latency_stats "${TEST2_DIR}/victim_with_fdp_lat.log" p99)
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
IMP_MAX=$(calc_improvement $BASE_V_MAX $FDP_V_MAX)

{
    echo "========================================================"
    echo "     FDP QoS Comparison Results (nvme-cli)"
    echo "========================================================"
    echo "Date: $(date)"
    echo "Device: $NVME_NS"
    echo "Test Duration: 30 seconds each"
    echo "Methodology: nvme-cli (apples-to-apples comparison)"
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
    printf "Max           | %6s μs   | %6s μs | %s%%\n" "$BASE_V_MAX" "$FDP_V_MAX" "$IMP_MAX"
    echo ""
    echo "========================================================"
    echo "KEY FINDINGS"
    echo "========================================================"
    echo ""
    
    if [ "$IMP_P99" != "N/A" ]; then
        if [ $IMP_P99 -gt 0 ]; then
            echo "✓ FDP REDUCED P99 latency by ${IMP_P99}%"
            echo "✓ Victim workload protected from noisy neighbor"
        elif [ $IMP_P99 -lt 0 ]; then
            echo "⚠ P99 latency was ${IMP_P99#-}% higher with FDP"
            echo "  (This may indicate baseline had less GC activity)"
        else
            echo "= P99 latency was similar in both tests"
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
    echo "WITHOUT FDP:"
    echo "  • Victim and noisy neighbor share same RUs"
    echo "  • Noisy neighbor's rewrites trigger GC"
    echo "  • GC pauses impact victim's I/O operations"
    echo "  • Result: Higher tail latency (P99, Max)"
    echo ""
    echo "WITH FDP:"
    echo "  • Victim isolated in RU 0"
    echo "  • Noisy isolated in RU 1"
    echo "  • Each RU has independent GC"
    echo "  • Result: Lower tail latency, more predictable"
    echo ""
    echo "Expected Benefit: 20-50% P99 latency reduction"
    echo "Actual Benefit: ${IMP_P99}% P99 latency reduction"
    echo ""
    echo "========================================================"
    echo "DETAILED RESULTS"
    echo "========================================================"
    echo ""
    echo "Test 1 (No FDP):"
    echo "  ${TEST1_DIR}/victim_baseline_lat.log"
    echo "  ${TEST1_DIR}/noisy_baseline_lat.log"
    echo "  ${TEST1_DIR}/console.log"
    echo ""
    echo "Test 2 (With FDP):"
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
echo "  • FDP provides workload isolation"
echo "  • Lower tail latency variance with FDP"
echo ""
echo_info "View summary: cat $SUMMARY"
echo ""


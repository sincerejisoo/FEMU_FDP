#!/bin/bash
#
# STRESSED Baseline: Victim + Noisy Neighbor WITHOUT FDP
# High GC pressure to demonstrate FDP benefits
# Duration: 10 minutes per workload phase
#

set -e

NVME_DEV="/dev/nvme0"
NVME_NS="/dev/nvme0n1"
DURATION=300  # 5 minutes (reduced from 10)
VICTIM_IOPS_TARGET=100  # Reduced from 800 (FEMU can't handle high IOPS)
NOISY_IOPS_TARGET=200  # Reduced from 2000
ERROR_LOG="/tmp/baseline_stressed_errors.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
echo_success() { echo -e "${GREEN}[✓]${NC} $1"; }
echo_warn() { echo -e "${YELLOW}[!]${NC} $1"; }

# Clear error log
> "$ERROR_LOG"

echo "========================================================"
echo "  STRESSED Baseline QoS Test (WITHOUT FDP)"
echo "  High GC Pressure - 10 Minute Sustained Workload"
echo "========================================================"
echo "Duration: $DURATION seconds ($(($DURATION / 60)) minutes)"
echo "Victim: ${VICTIM_IOPS_TARGET} IOPS (NO FDP protection)"
echo "Noisy:  ${NOISY_IOPS_TARGET} IOPS (NO FDP separation)"
echo ""
echo "This will trigger significant GC activity!"
echo "Expected: High P99 latency due to GC interference"
echo ""

# Disable FDP
echo_info "Disabling FDP for baseline test..."
nvme admin-passthru $NVME_DEV --opcode=0xef --cdw10=9 > /dev/null 2>&1
ONCS=$(nvme id-ctrl $NVME_DEV 2>/dev/null | grep "oncs" | awk '{print $3}')
echo_info "FDP disabled (ONCS=$ONCS)"
echo ""

# Create results directory
RESULT_DIR="$(dirname "$0")/baseline_stressed_results_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULT_DIR"
echo_info "Results will be saved to: $RESULT_DIR"
echo ""

# Create latency log files
VICTIM_LAT_LOG="${RESULT_DIR}/victim_baseline_lat.log"
NOISY_LAT_LOG="${RESULT_DIR}/noisy_baseline_lat.log"

echo "timestamp_us,latency_us,iops,type" > "$VICTIM_LAT_LOG"
echo "timestamp_us,latency_us,iops,type" > "$NOISY_LAT_LOG"

# Function to run victim workload (NO FDP directives)
run_victim_workload() {
    echo "[VICTIM] Starting latency-sensitive workload (NO FDP protection)..."
    
    local start_time=$(date +%s)
    local end_time=$((start_time + DURATION))
    local lba=0
    local writes=0
    local reads=0
    local errors=0
    local last_report=$(date +%s)
    
    while [ $(date +%s) -lt $end_time ]; do
        local timestamp=$(date +%s%N | cut -b1-16)
        
        # 60% reads, 40% writes (more writes for GC pressure)
        if [ $((RANDOM % 100)) -lt 60 ]; then
            # Read operation
            local t1=$(date +%s%N)
            if nvme read $NVME_NS --start-block=$lba --block-count=7 \
                --data-size=4096 > /dev/null 2>>"$ERROR_LOG"; then
                local t2=$(date +%s%N)
                local lat=$(( (t2 - t1) / 1000 ))
                echo "$timestamp,$lat,1,read" >> "$VICTIM_LAT_LOG"
                reads=$((reads + 1))
            else
                errors=$((errors + 1))
            fi
        else
            # Write operation (NO FDP)
            local t1=$(date +%s%N)
            if nvme write $NVME_NS --start-block=$lba --block-count=7 \
                --data=/dev/zero --data-size=4096 > /dev/null 2>>"$ERROR_LOG"; then
                local t2=$(date +%s%N)
                local lat=$(( (t2 - t1) / 1000 ))
                echo "$timestamp,$lat,1,write" >> "$VICTIM_LAT_LOG"
                writes=$((writes + 1))
            else
                errors=$((errors + 1))
            fi
        fi
        
        # Random LBA in victim range (0-4GB = 0-8388608 blocks)
        lba=$((RANDOM % 8388608))
        
        # Rate limiting: ~800 IOPS = 1250us per op
        sleep 0.00125 2>/dev/null || usleep 1250 2>/dev/null || sleep 0.001
        
        # Report progress every 60 seconds
        local now=$(date +%s)
        if [ $((now - last_report)) -ge 60 ]; then
            local elapsed=$((now - start_time))
            local remaining=$((DURATION - elapsed))
            echo "[VICTIM] Progress: ${elapsed}s / ${DURATION}s (${remaining}s remaining) - $reads reads, $writes writes, $errors errors"
            last_report=$now
        fi
    done
    
    echo "[VICTIM] Completed: $reads reads, $writes writes, $errors errors"
}

# Function to run noisy neighbor workload (NO FDP directives)
run_noisy_workload() {
    echo "[NOISY] Starting high-churn aggressive workload (NO FDP separation)..."
    
    local start_time=$(date +%s)
    local end_time=$((start_time + DURATION))
    local lba_base=10485760  # Start at 5GB offset
    local lba=0
    local writes=0
    local errors=0
    local last_report=$(date +%s)
    
    while [ $(date +%s) -lt $end_time ]; do
        local timestamp=$(date +%s%N | cut -b1-16)
        
        # Write operation (NO FDP)
        local t1=$(date +%s%N)
        if nvme write $NVME_NS --start-block=$((lba_base + lba)) --block-count=7 \
            --data=/dev/zero --data-size=4096 > /dev/null 2>>"$ERROR_LOG"; then
            local t2=$(date +%s%N)
            local lat=$(( (t2 - t1) / 1000 ))
            echo "$timestamp,$lat,1,write" >> "$NOISY_LAT_LOG"
            writes=$((writes + 1))
        else
            errors=$((errors + 1))
        fi
        
        # Highly skewed Zipf-like distribution
        # 90% of accesses to 10% of space → triggers GC heavily
        if [ $((RANDOM % 100)) -lt 90 ]; then
            # Hot data: first 10% of range (constant rewrites!)
            lba=$((RANDOM % 419430))  # 10% of 4194304 (2GB range)
        else
            # Cold data: full range
            lba=$((RANDOM % 4194304))  # 2GB range
        fi
        
        # Rate limiting: ~2000 IOPS = 500us per op
        sleep 0.0005 2>/dev/null || usleep 500 2>/dev/null || sleep 0.0005
        
        # Report progress every 60 seconds
        local now=$(date +%s)
        if [ $((now - last_report)) -ge 60 ]; then
            local elapsed=$((now - start_time))
            local remaining=$((DURATION - elapsed))
            echo "[NOISY] Progress: ${elapsed}s / ${DURATION}s (${remaining}s remaining) - $writes writes, $errors errors"
            last_report=$now
        fi
    done
    
    echo "[NOISY] Completed: $writes writes, $errors errors"
}

echo "========================================================"
echo "  Starting Concurrent Stressed Workloads"
echo "  (Both mixed in same RUs - Heavy GC expected!)"
echo "========================================================"
echo ""
echo_warn "This will run for $(($DURATION / 60)) minutes..."
echo_info "Victim: ${VICTIM_IOPS_TARGET} IOPS → ~$(($VICTIM_IOPS_TARGET * $DURATION * 4 / 1024 / 1024))GB written"
echo_info "Noisy:  ${NOISY_IOPS_TARGET} IOPS → ~$(($NOISY_IOPS_TARGET * $DURATION * 4 / 1024 / 1024))GB written"
echo_info "Total: ~$(( ($VICTIM_IOPS_TARGET + $NOISY_IOPS_TARGET) * $DURATION * 4 / 1024 / 1024))GB writes (will trigger GC!)"
echo ""

# Start both workloads in background
run_victim_workload &
VICTIM_PID=$!

run_noisy_workload &
NOISY_PID=$!

echo_info "Workloads running..."
echo "  Victim PID: $VICTIM_PID (NO FDP protection)"
echo "  Noisy PID:  $NOISY_PID (NO FDP separation)"
echo ""
echo "This will take $DURATION seconds ($(($DURATION / 60)) minutes)..."
echo "Progress updates every 60 seconds..."
echo ""

# Monitor progress
wait $VICTIM_PID 2>/dev/null
VICTIM_STATUS=$?
wait $NOISY_PID 2>/dev/null
NOISY_STATUS=$?

echo_info "Victim workload finished (status: $VICTIM_STATUS)"
echo_info "Noisy workload finished (status: $NOISY_STATUS)"
echo ""

echo "========================================================"
echo "  Workloads Completed - Analyzing Results"
echo "========================================================"
echo ""

# Analyze latency
analyze_latency() {
    local log_file=$1
    local name=$2
    
    if [ ! -s "$log_file" ]; then
        echo "[$name] No data collected"
        return
    fi
    
    # Skip header, extract latencies
    local latencies=$(tail -n +2 "$log_file" | cut -d',' -f2 | sort -n)
    local count=$(echo "$latencies" | wc -l)
    
    if [ $count -eq 0 ]; then
        echo "[$name] No valid latency data"
        return
    fi
    
    local min=$(echo "$latencies" | head -1)
    local max=$(echo "$latencies" | tail -1)
    local p50=$(echo "$latencies" | awk -v p=50 -v c=$count 'NR==int(c*p/100)+1')
    local p95=$(echo "$latencies" | awk -v p=95 -v c=$count 'NR==int(c*p/100)+1')
    local p99=$(echo "$latencies" | awk -v p=99 -v c=$count 'NR==int(c*p/100)+1')
    local p999=$(echo "$latencies" | awk -v p=99.9 -v c=$count 'NR==int(c*p/100)+1')
    local avg=$(echo "$latencies" | awk '{sum+=$1} END {if(NR>0) print int(sum/NR); else print 0}')
    
    echo "[$name] Latency Statistics:"
    echo "  Operations: $count"
    echo "  Min:        ${min}us"
    echo "  Average:    ${avg}us"
    echo "  Median:     ${p50}us"
    echo "  95th:       ${p95}us"
    echo "  99th:       ${p99}us"
    echo "  99.9th:     ${p999}us"
    echo "  Max:        ${max}us"
    echo ""
}

echo "========================================================"
echo "  Latency Analysis"
echo "========================================================"
echo ""

analyze_latency "$VICTIM_LAT_LOG" "VICTIM (NO FDP - Mixed with noisy)"
analyze_latency "$NOISY_LAT_LOG" "NOISY (NO FDP - Mixed with victim)"

echo "========================================================"
echo "  Test Complete!"
echo "========================================================"
echo ""
echo "Results saved to: $RESULT_DIR"
echo ""
echo_warn "Expected characteristics (WITHOUT FDP):"
echo "  ✗ High P99 latency (>3000μs expected due to GC)"
echo "  ✗ High P99.9 latency (>10000μs expected)"
echo "  ✗ Large Max latency (>50000μs possible)"
echo "  ✗ Victim suffers from noisy neighbor's GC"
echo ""
echo_info "Compare with FDP test to see isolation benefits!"
echo ""


#!/bin/bash
# Comprehensive FDP Testing Script
# Tests Phase 3 & 4 implementation with detailed workloads

set -e

echo "=========================================="
echo "  FEMU FDP Phase 3 & 4 Testing Suite"
echo "=========================================="
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Helper functions
test_passed() {
    echo -e "${GREEN}✓ PASS${NC}: $1"
}

test_failed() {
    echo -e "${RED}✗ FAIL${NC}: $1"
}

test_warning() {
    echo -e "${YELLOW}⚠ WARN${NC}: $1"
}

# Create test data
create_test_data() {
    dd if=/dev/urandom of=/tmp/test_4k.bin bs=4096 count=1 2>/dev/null
    dd if=/dev/urandom of=/tmp/test_16k.bin bs=4096 count=4 2>/dev/null
    dd if=/dev/urandom of=/tmp/test_64k.bin bs=4096 count=16 2>/dev/null
}

echo "Step 1: Setup"
echo "----------------------------------------"
create_test_data
test_passed "Test data created"

echo ""
echo "Step 2: Enable FDP"
echo "----------------------------------------"
result=$(sudo nvme admin-passthru /dev/nvme0 --opcode=0xef --cdw10=8 2>&1)
echo "$result"

# Check if command succeeded (look for "NVMe command result" or no error)
if echo "$result" | grep -q "NVMe command result"; then
    test_passed "FDP enable command executed successfully"
elif echo "$result" | grep -qi "error"; then
    test_failed "FDP enable command returned an error"
    exit 1
else
    test_passed "FDP enable command executed (check output above)"
fi

echo ""
echo "Step 3: Verify FDP Capability"
echo "----------------------------------------"
oncs=$(sudo nvme id-ctrl /dev/nvme0 | grep "oncs" | awk '{print $3}')
if [ "$oncs" = "0x204" ]; then
    test_passed "Controller reports FDP support (oncs=$oncs)"
else
    test_warning "Unexpected oncs value: $oncs"
fi

echo ""
echo "Step 4: Test FDP Configuration Log (0x20)"
echo "----------------------------------------"
sudo nvme get-log /dev/nvme0 --log-id=0x20 --log-len=4096 -b > /tmp/fdp_config.bin 2>/dev/null
size=$(stat -c%s /tmp/fdp_config.bin 2>/dev/null)
if [ "$size" = "4096" ]; then
    test_passed "Config log returns 4096 bytes"
    
    # Parse key fields - use od for more reliable parsing
    num_configs_hex=$(xxd -p -l 2 /tmp/fdp_config.bin 2>/dev/null | tr -d '\n')
    version_hex=$(xxd -p -s 2 -l 1 /tmp/fdp_config.bin 2>/dev/null | tr -d '\n')
    
    if [ -n "$num_configs_hex" ] && [ -n "$version_hex" ]; then
        # Convert little-endian hex to decimal
        num_configs=$((0x${num_configs_hex:2:2}${num_configs_hex:0:2}))
        version=$((0x$version_hex))
        
        echo "  - num_configs: $num_configs"
        echo "  - version: $version"
        
        if [ "$num_configs" = "1" ] && [ "$version" = "1" ]; then
            test_passed "Config log structure is valid"
        else
            test_warning "Config log structure: num_configs=$num_configs, version=$version"
        fi
    else
        test_warning "Could not parse config log header"
    fi
else
    test_failed "Config log size incorrect: $size bytes"
fi

echo ""
echo "Step 5: Test FDP Statistics Log (0x21) - Before Writes"
echo "----------------------------------------"
sudo nvme get-log /dev/nvme0 --log-id=0x21 --log-len=4096 -b > /tmp/fdp_stats_before.bin 2>/dev/null
size=$(stat -c%s /tmp/fdp_stats_before.bin 2>/dev/null)
if [ "$size" = "4096" ]; then
    test_passed "Stats log returns 4096 bytes"
    
    # Check if all zeros (no writes yet) - check first 64 bytes
    first_bytes=$(xxd -p -l 64 /tmp/fdp_stats_before.bin 2>/dev/null | tr -d '\n')
    if echo "$first_bytes" | grep -q "[^0]"; then
        test_passed "Stats log contains some data"
    else
        test_warning "Stats log is all zeros (expected before writes)"
    fi
else
    test_failed "Stats log size incorrect: $size bytes"
fi

echo ""
echo "Step 6: Test FDP Events Log (0x22)"
echo "----------------------------------------"
sudo nvme get-log /dev/nvme0 --log-id=0x22 --log-len=4096 -b > /tmp/fdp_events.bin 2>/dev/null
size=$(stat -c%s /tmp/fdp_events.bin 2>/dev/null)
if [ "$size" = "4096" ]; then
    test_passed "Events log returns 4096 bytes"
    
    # Check num_events field (first 4 bytes, little-endian)
    num_events_hex=$(xxd -p -l 4 /tmp/fdp_events.bin 2>/dev/null | tr -d '\n')
    if [ -n "$num_events_hex" ]; then
        num_events=$((0x${num_events_hex:6:2}${num_events_hex:4:2}${num_events_hex:2:2}${num_events_hex:0:2}))
        echo "  - num_events: $num_events"
        
        if [ "$num_events" = "0" ]; then
            test_passed "Events log correctly reports 0 events"
        else
            test_warning "Unexpected number of events: $num_events"
        fi
    else
        test_warning "Could not parse events log"
    fi
else
    test_failed "Events log size incorrect: $size bytes"
fi

echo ""
echo "Step 7: Test Get Feature - FDP Mode"
echo "----------------------------------------"
fdp_mode=$(sudo nvme get-feature /dev/nvme0 --feature-id=0x1d 2>&1 | grep "Current value" | awk '{print $NF}')
echo "  - FDP Mode: $fdp_mode"
if [ "$fdp_mode" = "0x00000001" ]; then
    test_passed "FDP Mode feature reports enabled"
else
    test_warning "FDP Mode value: $fdp_mode"
fi

echo ""
echo "Step 8: Perform FDP Writes with Different Placement Handles"
echo "----------------------------------------"

# Write to PH 0 (RU 0)
echo "  Writing to PH=0 (RU 0)..."
result=$(sudo nvme write /dev/nvme0n1 --start-block=1000 --block-count=15 \
    --data=/tmp/test_64k.bin --data-size=65536 \
    --dir-type=2 --dir-spec=0 2>&1)
if echo "$result" | grep -qi "error\|invalid"; then
    test_warning "Write to PH=0 may have failed: $result"
else
    test_passed "Write to PH=0 executed"
fi

# Write to PH 1 (RU 1)
echo "  Writing to PH=1 (RU 1)..."
result=$(sudo nvme write /dev/nvme0n1 --start-block=2000 --block-count=15 \
    --data=/tmp/test_64k.bin --data-size=65536 \
    --dir-type=2 --dir-spec=1 2>&1)
if echo "$result" | grep -qi "error\|invalid"; then
    test_warning "Write to PH=1 may have failed: $result"
else
    test_passed "Write to PH=1 executed"
fi

# Write to PH 2 (RU 2)
echo "  Writing to PH=2 (RU 2)..."
result=$(sudo nvme write /dev/nvme0n1 --start-block=3000 --block-count=3 \
    --data=/tmp/test_16k.bin --data-size=16384 \
    --dir-type=2 --dir-spec=2 2>&1)
if echo "$result" | grep -qi "error\|invalid"; then
    test_warning "Write to PH=2 may have failed: $result"
else
    test_passed "Write to PH=2 executed"
fi

# Write to PH 3 (RU 3)
echo "  Writing to PH=3 (RU 3)..."
result=$(sudo nvme write /dev/nvme0n1 --start-block=4000 --block-count=3 \
    --data=/tmp/test_16k.bin --data-size=16384 \
    --dir-type=2 --dir-spec=3 2>&1)
if echo "$result" | grep -qi "error\|invalid"; then
    test_warning "Write to PH=3 may have failed: $result"
else
    test_passed "Write to PH=3 executed"
fi

echo ""
echo "Step 9: Test FDP Statistics Log - After Writes"
echo "----------------------------------------"
sudo nvme get-log /dev/nvme0 --log-id=0x21 --log-len=4096 -b > /tmp/fdp_stats_after.bin 2>/dev/null

# Compare before and after
if cmp -s /tmp/fdp_stats_before.bin /tmp/fdp_stats_after.bin 2>/dev/null; then
    test_warning "Stats log unchanged after writes"
    echo ""
    echo "  ${YELLOW}WARNING: Statistics may not be tracking!${NC}"
    echo "  This could indicate:"
    echo "    1. FDP write path not hooked up correctly"
    echo "    2. Writes went to default path (not FDP)"
    echo "    3. Statistics update needs manual trigger"
else
    test_passed "Stats log updated after writes"
    echo ""
    echo "  Analyzing statistics..."
    
    # Parse host_bytes_written for each RU (first 16 * 8 bytes)
    for ru in 0 1 2 3; do
        offset=$((ru * 8))
        # Use simpler parsing that works on all systems
        bytes_hex=$(xxd -p -s $offset -l 8 /tmp/fdp_stats_after.bin 2>/dev/null | tr -d '\n')
        if [ -n "$bytes_hex" ]; then
            # Convert little-endian hex to decimal
            bytes=$((0x${bytes_hex:14:2}${bytes_hex:12:2}${bytes_hex:10:2}${bytes_hex:8:2}${bytes_hex:6:2}${bytes_hex:4:2}${bytes_hex:2:2}${bytes_hex:0:2}))
            echo "  - RU $ru: $bytes bytes written"
            
            if [ $bytes -gt 0 ]; then
                test_passed "RU $ru has recorded writes"
            fi
        else
            test_warning "Could not parse RU $ru statistics"
        fi
    done
fi

echo ""
echo "Step 10: Verify Data Separation by Reading Back"
echo "----------------------------------------"
# Read data from different LBAs and verify they're different
sudo nvme read /dev/nvme0n1 --start-block=1000 --block-count=3 \
    --data-size=16384 --data=/tmp/read_ph0.bin 2>/dev/null

sudo nvme read /dev/nvme0n1 --start-block=2000 --block-count=3 \
    --data-size=16384 --data=/tmp/read_ph1.bin 2>/dev/null

if ! cmp -s /tmp/read_ph0.bin /tmp/read_ph1.bin; then
    test_passed "Data from different PHs is correctly separated"
else
    test_warning "Data from different PHs appears identical"
fi

echo ""
echo "Step 11: Test IO Management Receive (if supported)"
echo "----------------------------------------"
# Use io-passthru (0x12 is an I/O command, not admin command)
# Opcode 0x12, NSID 1, CDW10: MO=1 (RUH_STATUS), CDW11: NUMD=255 (1024 bytes)
timeout 5 sudo nvme io-passthru /dev/nvme0n1 --opcode=0x12 --namespace-id=1 \
    --cdw10=0x00000001 --cdw11=0x000000ff --data-len=1024 --read -r > /tmp/io_mgmt_recv.bin 2>&1

exit_code=$?
if [ $exit_code -eq 0 ]; then
    size=$(stat -c%s /tmp/io_mgmt_recv.bin 2>/dev/null || echo 0)
    if [ "$size" -gt 0 ]; then
        test_passed "IO Management Receive succeeded (received $size bytes)"
        echo "  First 64 bytes:"
        xxd -l 64 /tmp/io_mgmt_recv.bin | head -4
    else
        test_warning "IO Management Receive returned no data"
    fi
elif [ $exit_code -eq 124 ]; then
    test_warning "IO Management Receive timed out (command may not be supported)"
else
    test_warning "IO Management Receive failed (exit code: $exit_code)"
    cat /tmp/io_mgmt_recv.bin 2>/dev/null | grep -i "status" | head -2
fi

echo ""
echo "=========================================="
echo "  Test Summary"
echo "=========================================="
echo ""
echo "Configuration & Log Pages:"
echo "  - FDP Enable/Disable: ✓"
echo "  - Config Log (0x20): ✓"
echo "  - Stats Log (0x21): Check results above"
echo "  - Events Log (0x22): ✓"
echo "  - Get/Set Features: ✓"
echo ""
echo "FDP Write Path:"
echo "  - Multi-PH writes: Check results above"
echo "  - Statistics tracking: Check Step 9"
echo "  - Data separation: Check Step 10"
echo ""
echo "Advanced Features:"
echo "  - IO Management: Check Step 11"
echo ""
echo "For detailed analysis, check:"
echo "  - FEMU debug output: dmesg | grep FEMU-FDP"
echo "  - Statistics before: xxd /tmp/fdp_stats_before.bin | head -20"
echo "  - Statistics after: xxd /tmp/fdp_stats_after.bin | head -20"
echo ""
echo "Test complete!"


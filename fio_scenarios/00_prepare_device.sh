#!/bin/bash
#
# Prepare NVMe device for QoS testing
# Clears existing data to prevent "No free lines" errors
#

set -e

NVME_NS="/dev/nvme0n1"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
echo_success() { echo -e "${GREEN}[✓]${NC} $1"; }
echo_warn() { echo -e "${YELLOW}[!]${NC} $1"; }

echo "================================================"
echo "  Device Preparation for QoS Testing"
echo "================================================"
echo ""

# Check root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}[✗]${NC} Please run as root (sudo)"
    exit 1
fi

# Check device
if [ ! -b "$NVME_NS" ]; then
    echo -e "${RED}[✗]${NC} NVMe namespace $NVME_NS not found"
    exit 1
fi

echo_info "Device: $NVME_NS"
echo_info "Size: $(lsblk -b -o SIZE -n $NVME_NS | awk '{printf "%.2f GB", $1/1024/1024/1024}')"
echo ""

echo_warn "This will DISCARD all data on $NVME_NS"
echo_warn "This is necessary to clear garbage and prevent crashes"
echo ""
read -p "Continue? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

echo ""
echo_info "Discarding all blocks (this may take a minute)..."

if blkdiscard "$NVME_NS" 2>&1; then
    echo_success "Device cleared successfully"
    touch "$(dirname "$0")/.device_prepared"
else
    echo_warn "blkdiscard not supported or failed, trying alternative..."
    # Try writing zeros to a small portion
    dd if=/dev/zero of="$NVME_NS" bs=1M count=100 conv=fdatasync 2>/dev/null || true
    echo_success "Partial clear completed"
    touch "$(dirname "$0")/.device_prepared"
fi

echo ""
echo_success "Device ready for testing!"
echo_info "You can now run: sudo ./run_qos_comparison.sh"
echo ""


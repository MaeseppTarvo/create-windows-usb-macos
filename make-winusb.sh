#!/bin/bash

set -e

### === CONFIGURATION === ###
ISO_PATH=""  # Leave empty to prompt
MOUNT_DIR="/Volumes"
BIOS_MODE=""  # Leave empty to prompt (UEFI or CSM)
FORMAT_TYPE=""  # Auto-determined based on BIOS_MODE
PARTITION_TABLE=""  # Auto-determined based on BIOS_MODE
### ====================== ###

# Note: Script will prompt for sudo password when needed for disk operations

# Prompt for ISO if not set
if [ -z "$ISO_PATH" ]; then
  read -p "📂 Enter path to Windows ISO: " ISO_PATH
  if [ ! -f "$ISO_PATH" ]; then
    echo "❌ File not found: $ISO_PATH"
    exit 1
  fi
else
  echo "📁 ISO_PATH is set to: $ISO_PATH"
  read -p "❓ Continue with this ISO? Type YES to confirm: " iso_confirm
  if [ "$iso_confirm" != "YES" ]; then
    echo "Aborted by user."
    exit 1
  fi
fi

# Prompt for BIOS mode if not set
if [ -z "$BIOS_MODE" ]; then
  echo ""
  echo "📋 What BIOS mode will you use to boot?"
  echo ""
  echo "   1. UEFI (Recommended - Modern PCs, 2012+)"
  echo "      → Faster, no file size limits"
  echo "      → Uses: exFAT format + GPT partition table"
  echo "      → BIOS must be set to UEFI mode (NOT CSM/Legacy)"
  echo ""
  echo "   2. CSM/Legacy BIOS (Old PCs or compatibility mode)"
  echo "      → Slower, requires splitting large files"
  echo "      → Uses: FAT32 format + MBR partition table"
  echo "      → Works with any BIOS mode"
  echo ""
  read -p "Enter choice (1 or 2): " bios_choice
  
  if [ "$bios_choice" = "1" ]; then
    BIOS_MODE="UEFI"
    FORMAT_TYPE="EXFAT"
    PARTITION_TABLE="GPT"
    echo "✅ Selected: UEFI mode (exFAT + GPT)"
  elif [ "$bios_choice" = "2" ]; then
    BIOS_MODE="CSM"
    FORMAT_TYPE="FAT32"
    PARTITION_TABLE="MBR"
    echo "✅ Selected: CSM/Legacy mode (FAT32 + MBR)"
  else
    echo "❌ Invalid choice. Exiting."
    exit 1
  fi
else
  echo "📁 BIOS_MODE is set to: $BIOS_MODE"
  # Auto-determine format and partition table
  if [ "$BIOS_MODE" = "UEFI" ]; then
    FORMAT_TYPE="EXFAT"
    PARTITION_TABLE="GPT"
  else
    FORMAT_TYPE="FAT32"
    PARTITION_TABLE="MBR"
  fi
fi

### 2. Mount and validate ISO early
echo "💿 Mounting ISO image..."

# Mount ISO and extract mount point directly
ISO_PATH_MOUNTED=$(hdiutil mount "$ISO_PATH" 2>&1 | grep -o '/Volumes/.*' | head -n 1)

# Fallback: parse the tab-separated output
if [ -z "$ISO_PATH_MOUNTED" ]; then
  ISO_PATH_MOUNTED=$(hdiutil mount "$ISO_PATH" 2>&1 | awk '/\/Volumes\// {for(i=1;i<=NF;i++) if($i ~ /^\/Volumes\//) print $i}' | head -n 1)
fi

# Fallback: check most recently mounted volume
if [ -z "$ISO_PATH_MOUNTED" ]; then
  sleep 2
  ISO_PATH_MOUNTED=$(mount | grep "/Volumes/" | tail -n 1 | awk '{print $3}')
fi

# Final validation
if [ -z "$ISO_PATH_MOUNTED" ] || [ ! -d "$ISO_PATH_MOUNTED" ]; then
  echo "❌ Failed to mount ISO or could not detect mounted volume."
  echo "   Please check if the ISO file is valid."
  exit 1
fi

echo "📁 ISO mounted at: $ISO_PATH_MOUNTED"

### 2.5. Pre-flight validation checks
echo ""
echo "🔍 Running pre-flight validation checks..."

# Check which install file exists and get its size
if [ -f "$ISO_PATH_MOUNTED/sources/install.wim" ]; then
  INSTALL_FILE="install.wim"
  INSTALL_SIZE=$(stat -f%z "$ISO_PATH_MOUNTED/sources/install.wim" 2>/dev/null || stat -c%s "$ISO_PATH_MOUNTED/sources/install.wim" 2>/dev/null)
  INSTALL_SIZE_MB=$((INSTALL_SIZE / 1024 / 1024))
  echo "✅ Found: sources/$INSTALL_FILE (${INSTALL_SIZE_MB}MB)"
elif [ -f "$ISO_PATH_MOUNTED/sources/install.esd" ]; then
  INSTALL_FILE="install.esd"
  INSTALL_SIZE=$(stat -f%z "$ISO_PATH_MOUNTED/sources/install.esd" 2>/dev/null || stat -c%s "$ISO_PATH_MOUNTED/sources/install.esd" 2>/dev/null)
  INSTALL_SIZE_MB=$((INSTALL_SIZE / 1024 / 1024))
  echo "✅ Found: sources/$INSTALL_FILE (${INSTALL_SIZE_MB}MB)"
else
  echo "❌ Neither install.wim nor install.esd found in ISO."
  echo "   This may not be a valid Windows installation ISO."
  hdiutil unmount "$ISO_PATH_MOUNTED" 2>/dev/null
  exit 1
fi

# Check if wimlib is available ONLY if using FAT32
if [ "$FORMAT_TYPE" = "FAT32" ]; then
  echo "🔍 Checking for wimlib-imagex (required for FAT32)..."
  if ! command -v wimlib-imagex &> /dev/null; then
    echo "⚠️  wimlib-imagex is required to split large install files for FAT32."
    echo "📦 Installing wimlib now..."
    if ! brew install wimlib; then
      echo "❌ Failed to install wimlib. Cannot proceed."
      echo "   Please install manually: brew install wimlib"
      hdiutil unmount "$ISO_PATH_MOUNTED" 2>/dev/null
      exit 1
    fi
    if ! command -v wimlib-imagex &> /dev/null; then
      echo "❌ wimlib installation completed but wimlib-imagex not found."
      hdiutil unmount "$ISO_PATH_MOUNTED" 2>/dev/null
      exit 1
    fi
  fi
  echo "✅ wimlib-imagex is available"
else
  echo "✅ Using exFAT - no file splitting required"
fi

# Calculate total ISO size
echo "🔍 Calculating ISO size..."
ISO_TOTAL_SIZE_KB=$(du -sk "$ISO_PATH_MOUNTED" | awk '{print $1}')
ISO_TOTAL_SIZE_MB=$((ISO_TOTAL_SIZE_KB / 1024))
ISO_TOTAL_SIZE_GB=$((ISO_TOTAL_SIZE_MB / 1024))
echo "📊 ISO total size: ${ISO_TOTAL_SIZE_GB}GB (${ISO_TOTAL_SIZE_MB}MB)"

echo "✅ All pre-flight checks passed!"
echo ""

echo "🔍 Scanning for USB drives..."

CANDIDATES=($(diskutil list external | grep '^/dev/' | awk '{print $1}'))

if [ ${#CANDIDATES[@]} -eq 0 ]; then
  echo "🔌 No USB drive detected. Please insert one and press Enter..."
  read
  sleep 3
  diskutil list external | grep '^/dev/' | awk '{print $1}' > /tmp/usb-candidates.txt
  CANDIDATES=($(cat /tmp/usb-candidates.txt))
fi

if [ ${#CANDIDATES[@]} -eq 0 ]; then
  echo "⚠️  Still no USB drive found. Falling back to /dev/disk2"
  USB_DISK="/dev/disk2"
elif [ ${#CANDIDATES[@]} -eq 1 ]; then
  USB_DISK="${CANDIDATES[0]}"
  DISK_SIZE=$(diskutil info "$USB_DISK" | awk -F ': ' '/Disk Size/ && !/Total/ { print $2 }' | xargs)
  echo "✅ Detected USB drive: $USB_DISK ($DISK_SIZE)"
else
  echo "⚠️  Multiple USB drives found. Please select one:"
  for i in "${!CANDIDATES[@]}"; do
    size=$(diskutil info "${CANDIDATES[$i]}" | awk -F ': ' '/Disk Size/ && !/Total/ { print $2 }')
    echo "$((i+1)). ${CANDIDATES[$i]} ($size)"
  done
  read -p "Enter the number of the disk to use: " choice
  USB_DISK="${CANDIDATES[$((choice-1))]}"
fi

# Check USB capacity vs ISO size
DISK_SIZE_BYTES=$(diskutil info "$USB_DISK" | awk -F '[()]' '/Disk Size/ && !/Total/ { print $2 }' | awk '{print $1}')
DISK_SIZE_GB=$((DISK_SIZE_BYTES / 1000 / 1000 / 1000))
DISK_SIZE_USABLE_GB=$((DISK_SIZE_GB * 95 / 100))  # Account for formatting overhead
echo "📊 USB capacity: ${DISK_SIZE_GB}GB (usable: ~${DISK_SIZE_USABLE_GB}GB after formatting)"

# Compare sizes
if [ $ISO_TOTAL_SIZE_GB -gt $DISK_SIZE_USABLE_GB ]; then
  echo ""
  echo "⚠️  WARNING: ISO size (${ISO_TOTAL_SIZE_GB}GB) might be larger than USB capacity (~${DISK_SIZE_USABLE_GB}GB)"
  read -p "❓ Continue anyway? (yes/no): " continue_choice
  if [ "$continue_choice" != "yes" ]; then
    echo "Aborted by user."
    hdiutil unmount "$ISO_PATH_MOUNTED" 2>/dev/null
    exit 1
  fi
else
  echo "✅ USB has sufficient space for this ISO"
fi

echo ""
echo "🚨 WARNING: This will ERASE EVERYTHING on $USB_DISK"
read -p "Type YES to continue: " confirm
confirm=$(echo "$confirm" | tr '[:upper:]' '[:lower:]')
if [[ "$confirm" != "yes" && "$confirm" != "y" ]]; then
  echo "Aborted."
  exit 1
fi

### 1. Erase USB with chosen format and partition table
if [ "$BIOS_MODE" = "UEFI" ]; then
  echo "🧼 Erasing USB drive..."
  echo "   Format: exFAT (no 4GB limit)"
  echo "   Partition: GPT (UEFI - creates 2 partitions automatically)"
  sudo diskutil eraseDisk ExFAT "WIN11USB" "$PARTITION_TABLE" "$USB_DISK"
else
  echo "🧼 Erasing USB drive..."
  echo "   Format: FAT32 (will split large files)"
  echo "   Partition: MBR (CSM/Legacy - single partition)"
  sudo diskutil eraseDisk MS-DOS "WIN11USB" "$PARTITION_TABLE" "$USB_DISK"
fi

### 2. Detect mounted volume path more reliably
echo "🔍 Detecting mounted USB volume..."
sleep 3
USB_PATH=$(mount | grep "$USB_DISK" | grep -v "EFI" | awk '{print $3}' | head -n 1)

if [ -z "$USB_PATH" ] || [ ! -d "$USB_PATH" ]; then
  # Try finding WIN11USB specifically
  USB_PATH="/Volumes/WIN11USB"
fi

if [ -z "$USB_PATH" ] || [ ! -d "$USB_PATH" ]; then
  # Fallback to most recent non-EFI volume
  USB_PATH=$(ls -td /Volumes/* | grep -v "EFI" | head -n1)
fi

if [ ! -d "$USB_PATH" ]; then
  echo "❌ Could not locate mounted USB volume."
  exit 1
fi

echo "📦 USB mounted at: $USB_PATH"

### 3. Copy ISO files based on format type
if [ "$FORMAT_TYPE" = "EXFAT" ]; then
  echo "📤 Copying ALL ISO files (exFAT has no file size limits)..."
  echo "   This will take several minutes..."
  if ! sudo rsync -avh --progress \
    --no-perms --no-owner --no-group --inplace \
    "$ISO_PATH_MOUNTED"/ "$USB_PATH"/; then
    echo "❌ File copy failed. Aborting."
    hdiutil unmount "$ISO_PATH_MOUNTED" 2>/dev/null
    exit 1
  fi
  echo "✅ All files copied successfully!"
else
  # FAT32: Exclude large files and split them
  echo "📤 Copying ISO files (excluding large install.wim/install.esd files)..."
  echo "   This will take several minutes..."
  if ! sudo rsync -avh --progress \
    --no-perms --no-owner --no-group --inplace \
    --exclude='sources/install.wim' \
    --exclude='sources/install.esd' \
    "$ISO_PATH_MOUNTED"/ "$USB_PATH"/; then
    echo "❌ File copy failed. Aborting."
    hdiutil unmount "$ISO_PATH_MOUNTED" 2>/dev/null
    exit 1
  fi
  
  ### 4. Split large install file to fit FAT32 (4GB limit)
  echo "🪓 Splitting sources/$INSTALL_FILE to .swm format for FAT32..."
  echo "   This may take 10-15 minutes for large files..."
  if ! sudo wimlib-imagex split "$ISO_PATH_MOUNTED/sources/$INSTALL_FILE" "$USB_PATH/sources/install.swm" 4000; then
    echo "❌ Failed to split $INSTALL_FILE"
    hdiutil unmount "$ISO_PATH_MOUNTED" 2>/dev/null
    exit 1
  fi
  
  ### 5. Clean up any leftover install files
  if [ -f "$USB_PATH/sources/install.wim" ]; then
    echo "🧹 Removing leftover install.wim..."
    sudo rm "$USB_PATH/sources/install.wim"
  fi
  if [ -f "$USB_PATH/sources/install.esd" ]; then
    echo "🧹 Removing leftover install.esd..."
    sudo rm "$USB_PATH/sources/install.esd"
  fi
fi

### 6. Eject USB and cleanup
echo "📤 Ejecting USB drive..."
sudo diskutil eject "$USB_DISK"

echo "🔽 Unmounting ISO image..."
hdiutil unmount "$ISO_PATH_MOUNTED" || echo "⚠️  Failed to unmount ISO."

echo ""
echo "🎉 DONE: Bootable Windows USB created successfully!"
echo ""
if [ "$BIOS_MODE" = "UEFI" ]; then
  echo "📊 USB PARTITION STRUCTURE:"
  echo "   Your USB now has 2 partitions (this is correct!):"
  echo "   1. EFI System Partition (~200MB) - Boot files (hidden)"
  echo "   2. WIN11USB (main) - Windows installation files (visible)"
  echo ""
  echo "   ℹ️  UEFI automatically boots from the EFI partition"
  echo "   ℹ️  You just select 'USB Drive' from boot menu"
  echo ""
  echo "⚙️  IMPORTANT - BIOS SETTINGS REQUIRED:"
  echo "   1. Restart PC and enter BIOS (usually DEL or F2 key)"
  echo "   2. Find 'Boot Mode' setting (under Boot or Advanced tab)"
  echo "   3. Set Boot Mode to: UEFI"
  echo "   4. Make sure it's NOT set to: CSM, Legacy, or Legacy+UEFI"
  echo "   5. Disable Secure Boot if Windows installation fails"
  echo "   6. Save and restart"
  echo "   7. Press F11 (or F12) for boot menu"
  echo "   8. Select your USB drive (entire drive, not a partition)"
  echo ""
  echo "   ⚠️  This USB will NOT work in CSM/Legacy mode!"
else
  echo "📊 USB PARTITION STRUCTURE:"
  echo "   Your USB has 1 partition:"
  echo "   - WIN11USB - All Windows files (including split install files)"
  echo ""
  echo "⚙️  BIOS SETTINGS:"
  echo "   1. Boot Mode: CSM/Legacy (or UEFI with CSM enabled)"
  echo "   2. Press F11 (or F12) for boot menu"
  echo "   3. Select USB drive from boot menu"
  echo ""
  echo "   ℹ️  This USB works in any BIOS mode"
fi
echo ""
echo "🚀 Ready to install Windows!"

# 🪟 Create Bootable Windows USB from macOS (CLI-only)

Create a Windows 10/11 bootable USB stick **entirely from macOS command line**, with full support for large `install.wim` files and no GUI tools or Boot Camp required.

> ✅ No apps. No Boot Camp. No bullshit. Just terminal.

---

## ✨ Features

- Fully macOS-native: no external Windows tools
- Handles `install.wim` > 4GB by splitting to `.swm`
- USB volume name auto-detection
- One script handles everything from formatting to setup
- Built-in checks and clear logs

---

## 🔧 Requirements

- macOS (tested on Ventura & Sonoma)
- Homebrew (for `wimlib`)
- A Windows ISO (`.iso`)
- A USB stick (8GB+ recommended)

---

## 🚀 Quick Start

1. **Clone this repo**

   ```bash
   git clone https://github.com/MaeseppTarvo/create-windows-usb-macos.git
   cd create-windows-usb-macos
   ```

2. **Make script executable**

   ```bash
   chmod +x make-winusb.sh
   ```

3. **Run it**

   ```bash
   sudo ./make-winusb.sh
   ```

---

## ⚠️ Warning

This script will erase your USB stick. Double-check `/dev/diskX` before continuing.

Use:

```bash
diskutil list
```

to identify your USB device.

---

## 💡 How It Works

- Erases the USB stick as FAT32 with MBR
- Mounts your Windows ISO
- Copies all files *except* `install.wim`
- Splits `install.wim` into `install.swm`, `install2.swm` etc. to fit FAT32 limits
- Removes the original `install.wim` if needed
- Ejects the USB and unmounts the ISO

---

## 📃 License

MIT — fork it, improve it, and tag me if you survived the same pain.  
Made with frustration by [@tarvo](https://github.com/MaeseppTarvo) and [@chad](https://chatgpt.com)

---

✅ The full script continues in `make-winusb.sh` in this repo.

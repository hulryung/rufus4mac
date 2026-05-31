# rufus4mac

A macOS-native equivalent of [Rufus](https://rufus.ie) — create bootable USB drives
(Windows install media, Linux distros, and general disk images) on macOS.

> **Status:** early development. This is not a literal port of the Windows C/Win32
> codebase; it is a native macOS rebuild of Rufus-equivalent functionality, since
> Rufus's core depends on Windows-only APIs (Format API, WMI, SetupAPI, Windows
> bootloader code). macOS uses different mechanisms (IOKit, `diskutil`, raw
> `/dev/diskN` writes, Authorization Services).

## Roadmap

| Phase | Scope |
|-------|-------|
| **1 — MVP** | USB device selection, ISO/image selection, write to USB (DD + FAT32 copy modes), basic format |
| **2 — Windows media** | install.wim split for FAT32, UEFI:NTFS, Windows 11 TPM/Secure Boot bypass |
| **3 — Full format options** | MBR/GPT partition schemes, file system & cluster size selection, volume labels, bad-block check |
| **4 — Extras** | ISO downloader, Linux persistence, checksums, localization |

## License

TBD

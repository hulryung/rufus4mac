# WimSplit

Splits a Windows Imaging (WIM) file into `.swm` parts that fit on FAT32, with no dependency on
[wimlib](https://wimlib.net) and no compression codec.

**MIT licensed** (see `LICENSE` in this directory) — deliberately, so it can replace the bundled
GPLv3 `wimlib-imagex` that rufus4mac otherwise needs for this one operation.

## Why this is tractable

Splitting never decompresses anything. A WIM stores each distinct file's data as a *blob*, already
compressed, addressed by an explicit offset and length. Splitting distributes those blobs across
parts and copies their bytes **verbatim**, then rewrites three small structures per part: the
208-byte header, the blob table, and the XML. LZX / XPRESS / LZMS never enter the picture — which is
what makes an independent implementation reasonable rather than a multi-year project.

## Format, as verified against real WIMs

```
[header 208B] [blobs, concatenated] [blob table] [XML]
```

No padding, no alignment.

| Structure | Layout |
|---|---|
| Resource header (24 B) | `size` (7 B LE) · `flags` (1 B) · `offset` (u64) · `uncompressedSize` (u64) |
| Blob table entry (50 B) | resource header (24 B) · `partNumber` (u16) · `refCount` (u32) · SHA-1 (20 B) |

Header fields used here: magic `MSWIM\0\0\0`, `cbSize` 208, `version`, `flags`, `chunkSize`, `guid`
(16 B), `partNumber`/`totalParts` (u16 each), `imageCount`, and the resource headers for the blob
table, XML data and boot metadata, plus `bootIndex`.

Splitting rules, each confirmed by splitting real WIMs and parsing the output:

- `SPANNED` (0x08) is set in every part's header flags.
- All parts share a **newly generated** GUID, different from the source's — that is what binds a set.
- Every part carries a byte-identical copy of the XML and the source's `imageCount`.
- Each part's blob table lists **only the blobs that part holds**; blobs are partitioned, never
  duplicated. Each entry's `partNumber` is its own part's number.
- Metadata blobs (resource flag 0x02) go in part 1.
- `refCount` is carried over unchanged.

## Not supported: solid (ESD-style) WIMs

Copying blobs verbatim works only while each blob is its own byte range of the file. A **solid** WIM
— header version `0x0E00`, LZMS, as produced by converting an ESD (`esd2iso` and friends) — packs
resources together into shared compression blocks, and a resource's offset then addresses a position
*inside* a block. Splitting there would require full decompression and repacking.

`WimSplitter` detects this (the `0x10` resource flag, or the version stamp) and throws. It does not
try, because parts built from solid resources would parse cleanly and contain nothing usable — the
kind of failure that only surfaces later, inside Windows Setup.

Retail `install.wim` files are version `0x0001_0D00` with LZX and are not solid.

## Scope

Splitting only. This is not a WIM reader, writer, or extractor, and it does not verify blob hashes
against their contents (that would require decompression).

## Verification

Unit tests cover the structures and the partitioning. Beyond those, wimlib is used as an *oracle* —
never as a source — to check the output:

- Generated WIMs (uncompressed and LZX) are split by `WimSplitter`, then `wimlib-imagex verify`
  accepts the set and `wimlib-imagex apply` restores every file byte-identical to the input.
- A real Microsoft `boot.wim` (601 MB, LZX, 2 images, boot index 2) split into four 200 MB parts:
  wimlib reports `Part Number: 1/4`, preserves `Boot Index: 2`, and verifies all 1423 MiB of file
  data against the stored SHA-1s. Applying image 2 from the split produced 17,738 files and
  2.63 GB byte-identical to applying it from the original.
- A real 5.75 GB solid `install.wim` (95,700 of 95,703 resources solid) is refused, writing nothing.

Real-hardware Windows Setup remains the last unverified step, which is why rufus4mac still splits
with wimlib by default.

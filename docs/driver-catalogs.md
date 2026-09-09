# Driver catalogs

A catalog is a JSON file listing devices and the driver packages they need. rufus4mac ships one for
Samsung Galaxy Books; anyone can write another for their own machines and share it as a file or a
link.

Installed catalogs live in `~/Library/Application Support/rufus4mac/Catalogs/`, one file each.
**Add from catalog… → Manage…** installs them from a file or an https link, updates them, and
removes them; you can also drop files into that folder yourself.

## Why entries look the way they do

A catalog names **executables that will be run on a freshly installed machine**. Once catalogs come
from other people, that is the whole of the trust story, so the format requires what makes an entry
checkable and rufus4mac refuses anything that is missing:

- `url` must be **https**.
- `sha256` must be the publisher's real hash, 64 hex characters. The download is checked against it
  and **discarded on mismatch** — it is never kept, and never run unverified.
- `sizeBytes` must be present, so the user sees what they are about to fetch.

A catalog that fails validation does not load, and it is reported rather than silently skipped. One
publisher's broken file does not cost you every other device.

## Format

```json
{
  "formatVersion": 1,
  "name": "Example — Dell Latitude",
  "maintainer": "you",
  "updatedAt": "2026-09-09",
  "updateURL": "https://example.com/latitude.json",

  "packages": [
    {
      "id": "intel-wifi",
      "name": "Intel Wi-Fi driver",
      "vendor": "Intel",
      "version": "24.70.0",
      "url": "https://downloadmirror.intel.com/926939/WiFi-24.70.0-Driver64-Win10-Win11.exe",
      "sha256": "fb7f764a2b95a691b0b4825a6c60572c067c258d41958b378c5ed02f0f010ad4",
      "sizeBytes": 54400872,
      "covers": "Intel Wi-Fi 6/6E/7 and Wireless-AC",
      "sourcePage": "https://www.intel.com/content/www/us/en/download/19351/"
    }
  ],

  "models": [
    { "name": "Latitude 7440", "modelNumbers": "P167G", "packageIDs": ["intel-wifi"] }
  ]
}
```

| Field | | |
|---|---|---|
| `formatVersion` | optional | Defaults to `1`. A catalog from a newer format is refused, not half-read. |
| `name` | optional | Shown in the UI and used for the installed file's name. |
| `maintainer`, `updatedAt` | optional | Shown so users can tell whose list this is and how old. |
| `updateURL` | optional | Where **Update** re-fetches from. rufus4mac fills this in for catalogs added by link. |
| `packages[]` | required | The files. `id` must be unique within the catalog. |
| `models[]` | required | The devices. `packageIDs` must name packages in the same file. |
| `modelNumbers` | | Free text — print what is on the sticker, so people can match their machine. |

## Getting a package right

**Prefer the silicon vendor over the laptop maker.** Samsung, for one, builds its download links in
JavaScript and has no stable per-model URL, while Intel publishes a fixed URL *and* a SHA-256 for a
package that drives every Intel Wi-Fi adapter from Wireless-AC 9560 through Wi-Fi 7. So identify the
chipset, then fetch from whoever made it.

That also means **one package usually covers many machines**, which is what keeps a catalog small and
correct: the model list helps a user find themselves, it does not decide the file. A device you
forgot to list cannot hand anyone the wrong driver — they pick a catch-all entry instead.

Check the hash you publish:

```sh
shasum -a 256 WiFi-24.70.0-Driver64-Win10-Win11.exe
```

Do not list a device whose chipset the package does not cover. Samsung's Galaxy Book Go and
Galaxy Book4 Edge are Snapdragon, for instance, so they are absent from the bundled catalog — an
Intel package cannot drive Qualcomm Wi-Fi, and listing them would offer a driver that cannot work.

## What happens on the USB

Downloaded packages join the driver library as a profile named after the device. Tick it before
writing and the files are copied to `Drivers/<device>/` on the stick. **Windows Setup does not touch
them** — the folder is deliberately not `$WinPEDriver$` — so run the installer once Windows is up.

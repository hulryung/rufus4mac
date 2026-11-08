# Website artwork and publishing

The GitHub Pages site lives in `website/`. It is plain HTML, CSS, and JavaScript;
no package installation or application build is needed. Preview from the repository root:

```sh
python3 -m http.server 8765 --directory website
```

The site supports English and Korean, defaults to the browser language, and remembers
the visitor's explicit choice locally. Workflow tabs support up/down arrows, Home, and End.
The app screenshots are copied from the existing documentation; some task screenshots
are from earlier releases, as indicated on the page.

## Original 3D artwork

`usb-scene.blend` is the editable Blender scene. Recreate the scene and transparent PNG:

```sh
blender -b -t 4 --python scripts/website/render-usb.py
```

This overwrites `usb-scene.blend` and `website/assets/usb-render.png`.
The USB is a promotional illustration, not a physical product.
`website/assets/social.png` is the 1200 × 630 sharing graphic derived from the render.

## Publishing

`.github/workflows/pages.yml` deploys only `website/` when its files change on `main`.
GitHub Pages uses GitHub Actions as its build source.
Public URL: https://hulryung.github.io/rufus4mac/

When releasing an app update, refresh the version badge, both pinned DMG URLs,
app screenshot and copy in `website/index.html`. The all-downloads link always goes
to GitHub's latest release. Keep requirements and limitations aligned with README.md.

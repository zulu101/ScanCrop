# ScanCrop

**Automatically cut scanned photos out of flatbed scans on macOS.** Drop in hundreds of scans: ScanCrop finds every photo on each scan, straightens it and cuts away the white scanner background. Then you check the results at a glance, fix the few it got wrong, and save them all at once.

![App icon](Resources/AppIcon.iconset/icon_128.png)

## Features

| Area | What it does |
|---|---|
| **Detection** | Finds one or several photos per scan, also small ones such as passport photos. Measures the tilt of each photo and straightens it |
| **Pale edges** | Keeps photos whose edge is almost as light as the scanner lid, such as a bright sky. A plain threshold would cut those off |
| **Scanner edge** | Ignores the dark strip at the edge of the scanner bed, dust and small specks |
| **Print borders** | Optional: also removes the white border of old prints |
| **Correcting** | Click a photo to select it, drag it to move it, drag an edge or corner to resize it, fine-tune the tilt in 0.1° steps, turn it by 90°, delete it (⌫), or drag a rectangle on empty space to mark a photo by hand |
| **Preview** | Below each scan you see the photos exactly as they will be saved |
| **Export** | Same format as the scan, JPEG, HEIC, or lossless TIFF/PNG. Resolution (DPI), colour profile, bit depth and EXIF/IPTC data are kept. Upright photos are cut out pixel for pixel without resampling; tilted ones are resampled once in high quality. Existing files are never overwritten |
| **Batch** | Scans are analysed in parallel. Add single files or whole folders (with subfolders) |

**Languages:** English and German. The app follows your macOS language.

## Installation

1. Download the latest `ScanCrop-x.y.z.zip` from **Releases**.
2. Unzip it and drag `ScanCrop.app` into your **Applications** folder.
3. The app is not notarized by Apple. Before the first launch, run this once in Terminal:
   ```bash
   xattr -dr com.apple.quarantine /Applications/ScanCrop.app
   ```

Requires **macOS 14 (Sonoma) or later**, on Apple silicon or Intel.

## Tips for scanning

- Leave a little space (about 5 mm) between photos. Photos that touch each other are detected as one.
- Close the scanner lid: a white, even background works best.
- If a photo is not found completely, raise the **sensitivity** (for all scans in the toolbar under *Detection*, or for one scan below the preview).

## Building

```bash
swift test                 # runs the detection and cropping tests
./Scripts/build-app.sh     # builds build/ScanCrop.app
```

Or open `Package.swift` in Xcode. The app icon is generated from `Resources/AppIcon.svg` with `node Scripts/make-icon.mjs` (needs Playwright).

## How the detection works

1. **Background:** the median colour of a ring just inside the edge of the scan.
2. **Foreground:** every pixel that differs from the background by more than the lid's own noise.
3. **Clean-up:** close gaps, remove dust and thin lines, fill holes inside photos.
4. **Photos:** for each large area the smallest rectangle around it (rotating calipers on the convex hull), which also gives the tilt.

The code is in `Sources/ScanCropCore` and has no UI dependencies. Parts of it follow [PhotoCraft](https://github.com/storytold/photocraft)'s scan cropping (MIT), see [NOTICE](NOTICE).

## License

MIT, see [LICENSE](LICENSE).

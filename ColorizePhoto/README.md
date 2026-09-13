# Colorize Photo — iPhone / iPad
Native SwiftUI editor, iOS/iPadOS 17+. Apple Vision foreground extraction; full Real-ESRGAN Core ML upscale x2/x4; Core Image enhance and adjustments; crop/rotate/mirror; PNG Photos export and share sheet.

GitHub Actions downloads the full model, verifies its SHA-256 against Hugging Face LFS metadata, runs simulator unit/UI tests on iPhone and iPad, and packages an unsigned IPA only after those checks pass. An unsigned IPA requires signing with a sideloading tool or Apple distribution credentials; it cannot install by simply tapping the download.

Vision foreground segmentation quality, Photos permission flow, physical-device memory/thermal behavior and Neural Engine performance require an actual iPhone/iPad. The simulator Vision test explicitly skips when unsupported; this is not a passed device test. Input import is capped to 4096 pixels on the longest side; upscale output is capped at 24 MP / 8192 pixels per side. PNG retains transparency.

Build: install XcodeGen, run `python scripts/model.py` (requires coremltools and requests), `xcodegen generate`, then open ColorizePhoto.xcodeproj.

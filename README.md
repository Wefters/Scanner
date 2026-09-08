# @wefterjs/scanner

Official Wefter plugin for camera QR code and barcode scanning on Android and iOS.

## Features

- Real-time camera feed scanning using Google MLKit Barcode Scanning on Android and AVFoundation on iOS.
- Multi-format recognition: QR codes, EAN-13, EAN-8, Code 128, Code 39, UPC-A, and UPC-E.
- Optional gallery picker button allowing users to decode saved photos.
- Continuous scanning mode or single-shot match resolution.
- Configurable prompt text, zoom controls, tap to focus, and haptic feedback on scan success.
- Event listeners for matched codes and user cancellation.

## Installation and setup

Install the plugin package in your Wefter application:

```bash
wefter add @wefterjs/scanner
wefter sync
```

### Native permissions and dependencies

When synchronized:

- Android receives the `CAMERA` and `VIBRATE` permissions, along with AndroidX CameraX and Google MLKit barcode scanning dependencies and ProGuard keep rules.
- iOS configures `NSCameraUsageDescription` in `Info.plist`.

## JavaScript API reference

Import `Scanner` from `@wefterjs/scanner`:

```ts
import { Scanner } from "@wefterjs/scanner";
```

### Start scanning

Launches the camera scanner overlay:

```ts
// 1. Listen for scanned codes
const codeSub = Scanner.onCodeScanned(({ data, format }) => {
  console.log("Scanned code content:", data);
  console.log("Barcode format:", format);

  // Stop scanning after the first match if continuous is false
  Scanner.stop();
});

// 2. Listen for cancellation (back button or close button tapped)
const cancelSub = Scanner.onCancelled(({ reason }) => {
  console.log("Scanner closed:", reason);
});

// 3. Launch camera scanner
await Scanner.scan({
  prompt: "Align QR code inside the frame",
  formats: ["qr", "ean13", "code128"],
  continuous: false,  // Stop after first match when false
  allowGallery: true, // Display button to pick photos from album
  haptics: true,      // Play tactile feedback on match
  focusOnTap: true,
  zoomControl: true,
  timeout: 30,        // Automatically cancel after 30 seconds of inactivity
});
```

### Stop scanning

Closes the camera preview overlay programmatically:

```ts
await Scanner.stop();
```

### Clean up listeners

```ts
codeSub.remove();
cancelSub.remove();
```

## Barcode formats

Supported values in the `formats` array:

- `"qr"`: QR Code
- `"ean13"`: EAN-13 European Article Number
- `"ean8"`: EAN-8 European Article Number
- `"code128"`: Code 128 barcode
- `"code39"`: Code 39 barcode
- `"upca"`: UPC-A Universal Product Code
- `"upce"`: UPC-E Universal Product Code
- `"all"`: Match all supported formats

## Platform events

| Event | Payload | Platforms |
| --- | --- | --- |
| `scanner:codeScanned` | `{ data: string, format: string, id?: string }` | Android, iOS |
| `scanner:cancelled` | `{ reason: string, id?: string }` | Android, iOS |

## Platform implementation notes

### Android

- Uses Google MLKit Barcode Scanning (`com.google.mlkit:barcode-scanning:17.3.0`) integrated with AndroidX CameraX (`PreviewView`, `ImageAnalysis`).
- Runs image analysis on a background executor thread without blocking the user interface.
- Includes a gallery picker intent (`ActivityResultContracts.GetContent`) to decode images using `InputImage.fromFilePath`.

### iOS

- Uses `AVFoundation` with `AVCaptureSession`, `AVCaptureVideoPreviewLayer`, and `AVCaptureMetadataOutput`.
- Uses `UIImagePickerController` for optional photo gallery decoding using `CIDetector` or `VNImageRequestHandler`.

## License

[MIT](LICENSE) © 2026 Sandip Ghimire

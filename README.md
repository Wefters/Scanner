# @wefterjs/scanner

Official Wefter plugin for high-performance camera QR code & barcode scanning on Android & iOS.

---

## Features

- 📷 **Real-Time Camera Frame Processing**: Uses Google MLKit Barcode Scanning (Android) & AVFoundation `AVCaptureMetadataOutput` (iOS).
- 🏷️ **Multi-Format Support**: QR Code, EAN-13, EAN-8, UPC-A, UPC-E, Code 128, Code 39, ITF, Aztec, PDF417, Data Matrix.
- 🔦 **Torch & Camera Control**: Programmatically toggle torch and switch front/back cameras.
- 📡 **Event Streams**: Real-time barcode scan callbacks (`scanner:codeScanned`).

---

## Installation & Setup

1. Add the plugin to your Wefter project:

```bash
wefter add @wefterjs/scanner
```

2. Synchronize native projects:

```bash
wefter sync
```

---

## Native Permissions Configuration

- **Android**: Automatically requests `<uses-permission android:name="android.permission.CAMERA" />` and `<uses-permission android:name="android.permission.VIBRATE" />`.
- **iOS** (`Info.plist`): Automatically injects `NSCameraUsageDescription` ("Used to scan barcodes and QR codes.").

---

## JavaScript API Reference

Import `invokeNative` and `registerHook` from `@wefterjs/core`:

```ts
import { invokeNative, registerHook } from "@wefterjs/core";
```

### 1. `scan(options)`

Launches the camera barcode scanner overlay.

```ts
interface ScanOptions {
  formats?: string[]; // Allowed formats: ["QR_CODE", "EAN_13", "CODE_128"] (default: all)
  torch?: boolean; // Enable torch automatically (default: false)
  cameraDirection?: "back" | "front"; // Camera sensor (default: "back")
}

await invokeNative("scanner", "scan", {
  formats: ["QR_CODE", "EAN_13"],
  cameraDirection: "back",
});
```

### 2. `stop()`

Stops the active scanner and closes the camera preview overlay.

```ts
await invokeNative("scanner", "stop");
```

---

## Event Subscriptions

Listen to scanned codes via `registerHook`:

```ts
import { registerHook } from "@wefterjs/core";

interface ScannedCodePayload {
  rawValue: string;
  format: string;
}

// Subscribe to scanned code events
const scanSub = registerHook("scanner:codeScanned", (data: ScannedCodePayload) => {
  console.log("Scanned Value:", data.rawValue);
  console.log("Barcode Format:", data.format);
});

// Subscribe to scanner cancelled event
const cancelSub = registerHook("scanner:cancelled", () => {
  console.log("User dismissed scanner overlay");
});
```

---

## Complete Usage Example

```ts
import { invokeNative, registerHook } from "@wefterjs/core";

export async function startQrScan(): Promise<string> {
  return new Promise((resolve, reject) => {
    const codeSub = registerHook("scanner:codeScanned", (data: { rawValue: string }) => {
      codeSub.remove();
      cancelSub.remove();
      invokeNative("scanner", "stop");
      resolve(data.rawValue);
    });

    const cancelSub = registerHook("scanner:cancelled", () => {
      codeSub.remove();
      cancelSub.remove();
      reject(new Error("Scan cancelled"));
    });

    invokeNative("scanner", "scan", { formats: ["QR_CODE"] });
  });
}
```

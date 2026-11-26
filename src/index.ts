/**
 * Scans barcodes and QR codes with the camera in a full-screen native scanner. Results arrive as events,
 * so the scanner can keep scanning in continuous mode.
 */

import { definePlugin, registerHook } from "@wefterjs/core";

/** Barcode formats to look for; `all` accepts every format the platform can read. */
export type BarcodeFormat = "qr" | "ean13" | "ean8" | "code128" | "code39" | "upca" | "upce" | "all";

/**
 * Scanner settings.
 *
 * - `prompt`: text shown over the camera.
 * - `continuous`: keep scanning after a code is found (default `false`).
 * - `allowGallery`: offer scanning a code from a photo (default `true`).
 * - `formats`: formats to accept (default `["qr"]`).
 * - `haptics`: vibrate when a code is found (default `true`).
 * - `zoom`, `maxZoom`, `zoomControl`: starting zoom (default 1), maximum zoom (default 3), and whether to
 *   show a zoom slider (default `true`).
 * - `focusOnTap`: tap the preview to focus (default `true`).
 * - `timeout`: seconds before the scanner closes by itself; 0 waits forever.
 * - `id`: echoed back in events, to tell scans apart.
 */
export interface ScanOptions {
  prompt?: string;
  continuous?: boolean;
  allowGallery?: boolean;
  formats?: BarcodeFormat[];
  haptics?: boolean;
  zoom?: number;
  maxZoom?: number;
  zoomControl?: boolean;
  focusOnTap?: boolean;
  timeout?: number;
  id?: string;
}

/** Returned once the scanner is on screen. */
export interface ScanResult {
  started: true;
}

/** Which scan to stop, by the `id` it was started with. */
export interface StopOptions {
  id?: string;
}

/** Whether a scanner was open and has been closed. */
export interface StopResult {
  stopped: boolean;
}

/** A code was found: its content and format. */
export interface ScannerCodeScannedEvent {
  data: string;
  format: string;
  id?: string;
}

/** The scanner closed without a result (for example the user dismissed it, or it timed out). */
export interface ScannerCancelledEvent {
  reason: string;
  id?: string;
}

/** The Scanner plugin. */
export const Scanner = {
  ...definePlugin<{
    /** Opens the scanner. Requests camera permission if needed. */
    scan: (options?: ScanOptions) => Promise<ScanResult>;
    /** Closes the scanner. */
    stop: (options?: StopOptions) => Promise<StopResult>;
  }>("scanner", { scan: true, stop: true }),

  /**
   * Calls `callback` for each code found.
   *
   * @returns A handle whose `remove()` stops listening.
   */
  onCodeScanned(callback: (data: ScannerCodeScannedEvent) => void): { remove(): void } {
    return registerHook("scanner:codeScanned", callback as (data: unknown) => void);
  },

  /**
   * Calls `callback` when the scanner closes without a result.
   *
   * @returns A handle whose `remove()` stops listening.
   */
  onCancelled(callback: (data: ScannerCancelledEvent) => void): { remove(): void } {
    return registerHook("scanner:cancelled", callback as (data: unknown) => void);
  },
};

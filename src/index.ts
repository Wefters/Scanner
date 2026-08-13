import { definePlugin, registerHook } from "@wefterjs/core";

export type BarcodeFormat = "qr" | "ean13" | "ean8" | "code128" | "code39" | "upca" | "upce" | "all";

export interface ScanOptions {
  prompt?: string;
  /** Keep matching and emitting scanner:codeScanned instead of stopping after the first match. Defaults to `false`. */
  continuous?: boolean;
  /** Show a "Choose from Gallery" button that decodes a picked photo instead of the live camera. Defaults to `true`. */
  allowGallery?: boolean;
  /** Defaults to `["qr"]`. */
  formats?: BarcodeFormat[];
  haptics?: boolean;
  zoom?: number;
  maxZoom?: number;
  zoomControl?: boolean;
  focusOnTap?: boolean;
  /** Auto-cancel after this many seconds with no match. `0` (default) never times out. */
  timeout?: number;
  id?: string;
}

export interface ScanResult {
  started: true;
}

export interface StopOptions {
  id?: string;
}

export interface StopResult {
  stopped: boolean;
}

export interface ScannerCodeScannedEvent {
  data: string;
  format: string;
  id?: string;
}

export interface ScannerCancelledEvent {
  reason: string;
  id?: string;
}

export const Scanner = {
  ...definePlugin<{
    scan: (options?: ScanOptions) => Promise<ScanResult>;
    stop: (options?: StopOptions) => Promise<StopResult>;
  }>("scanner", { scan: true, stop: true }),

  onCodeScanned(callback: (data: ScannerCodeScannedEvent) => void): { remove(): void } {
    return registerHook("scanner:codeScanned", callback as (data: unknown) => void);
  },

  onCancelled(callback: (data: ScannerCancelledEvent) => void): { remove(): void } {
    return registerHook("scanner:cancelled", callback as (data: unknown) => void);
  },
};

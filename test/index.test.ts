// @vitest-environment jsdom
import { afterEach, describe, expect, it } from "vitest";
import { installMockBridge, uninstallMockBridge } from "@wefterjs/core/testing";
import { WefterBridgeError } from "@wefterjs/core";
import { Scanner } from "../src/index.js";

afterEach(() => {
  uninstallMockBridge();
});

describe("Scanner.scan", () => {
  it("forwards options and resolves with started", async () => {
    installMockBridge({
      scanner: (method, payload) => {
        expect(method).toBe("scan");
        expect(payload).toEqual({ prompt: "Scan it", formats: ["qr", "ean13"] });
        return { started: true };
      },
    });

    const result = await Scanner.scan({ prompt: "Scan it", formats: ["qr", "ean13"] });

    expect(result).toEqual({ started: true });
  });

  it("is callable with no arguments", async () => {
    installMockBridge({
      scanner: (method, payload) => {
        expect(method).toBe("scan");
        expect(payload).toEqual({});
        return { started: true };
      },
    });

    await Scanner.scan();
  });
});

describe("Scanner.stop", () => {
  it("forwards an id when given one", async () => {
    installMockBridge({
      scanner: (method, payload) => {
        expect(method).toBe("stop");
        expect(payload).toEqual({ id: "session-1" });
        return { stopped: true };
      },
    });

    const result = await Scanner.stop({ id: "session-1" });

    expect(result).toEqual({ stopped: true });
  });
});

describe("events", () => {
  it("onCodeScanned receives what the native side emits under scanner:codeScanned", () => {
    let received: unknown;
    const subscription = Scanner.onCodeScanned((data) => {
      received = data;
    });

    window.__wefterNative.emit("scanner:codeScanned", JSON.stringify({ data: "12345", format: "qr" }));

    expect(received).toEqual({ data: "12345", format: "qr" });
    subscription.remove();
  });

  it("onCancelled receives what the native side emits under scanner:cancelled", () => {
    let received: unknown;
    const subscription = Scanner.onCancelled((data) => {
      received = data;
    });

    window.__wefterNative.emit("scanner:cancelled", JSON.stringify({ reason: "user_cancelled" }));

    expect(received).toEqual({ reason: "user_cancelled" });
    subscription.remove();
  });

  it("stops calling a listener after remove()", () => {
    let callCount = 0;
    const subscription = Scanner.onCodeScanned(() => {
      callCount++;
    });
    subscription.remove();

    window.__wefterNative.emit("scanner:codeScanned", JSON.stringify({ data: "x", format: "qr" }));

    expect(callCount).toBe(0);
  });
});

describe("error propagation", () => {
  it("surfaces a native rejection as a WefterBridgeError", async () => {
    installMockBridge({
      scanner: () => {
        throw new Error("Camera permission was denied");
      },
    });

    const call = Scanner.scan();

    await expect(call).rejects.toBeInstanceOf(WefterBridgeError);
    await expect(call).rejects.toMatchObject({
      code: "MOCK_ERROR",
      message: "Camera permission was denied",
    });
  });
});

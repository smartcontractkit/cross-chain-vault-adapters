// Polyfill for setTimeout.unref() - Node.js API not available in browsers
// This allows libraries that use Node.js-specific setTimeout APIs to work in browsers
if (typeof window !== "undefined") {
  const originalSetTimeout = globalThis.setTimeout;
  const originalClearTimeout = globalThis.clearTimeout;
  
  (globalThis as any).setTimeout = function(
    callback: (...args: any[]) => void,
    delay?: number,
    ...args: any[]
  ) {
    const timerId = originalSetTimeout(callback, delay, ...args);
    // Create a wrapper object that mimics Node.js Timer with unref method
    const timerObj = {
      unref: () => timerObj, // Return self for chaining, no-op in browser
      ref: () => timerObj,
      hasRef: () => true,
      [Symbol.toPrimitive]: () => timerId, // Convert to number when needed
      valueOf: () => timerId,
      toString: () => String(timerId),
    };
    return timerObj as any;
  };
  
  // Patch clearTimeout to handle both numbers and our wrapper objects
  (globalThis as any).clearTimeout = function(timer: any) {
    if (timer && typeof timer.valueOf === "function") {
      return originalClearTimeout(timer.valueOf());
    }
    return originalClearTimeout(timer);
  };
}

import { createRoot } from "react-dom/client";
import App from "./App";
import "./index.css";

createRoot(document.getElementById("root")!).render(<App />);

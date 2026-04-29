import { createContext, useContext, useEffect, useRef } from "react";
import type { LiveViewBridge, Unsubscribe } from "@/lib/types";

export const LiveViewContext = createContext<LiveViewBridge | null>(null);

export function useLiveEvent(): LiveViewBridge {
  const bridge = useContext(LiveViewContext);
  if (!bridge) {
    throw new Error("useLiveEvent must be used within LiveViewContext.Provider");
  }
  return bridge;
}

/**
 * Subscribe to a server-pushed LiveView event for the lifetime of the component.
 *
 * The latest callback reference is captured via a ref so listeners never close
 * over stale state even though we only subscribe once per mount.
 */
export function useLiveEventSubscription(
  event: string,
  callback: (payload: unknown) => void,
): void {
  const bridge = useLiveEvent();
  const callbackRef = useRef(callback);

  // Keep the ref in sync with the latest callback on every render.
  useEffect(() => {
    callbackRef.current = callback;
  }, [callback]);

  useEffect(() => {
    const off: Unsubscribe = bridge.subscribe(event, (payload) => {
      callbackRef.current(payload);
    });
    return off;
  }, [bridge, event]);
}

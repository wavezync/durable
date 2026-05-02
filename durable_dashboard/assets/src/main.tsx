import "@fontsource-variable/geist";
import "@fontsource-variable/jetbrains-mono";
import "./index.css";
// @ts-expect-error phoenix has no type declarations
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import { createRoot, type Root } from "react-dom/client";
import { App } from "./App";
import { LiveViewContext } from "./hooks/useLiveEvent";
import type { LiveViewBridge, Unsubscribe } from "./lib/types";

// ============================================================================
// LiveView Hook
// ============================================================================

const PUSH_EVENT_TIMEOUT_MS = 10_000;

type Listener = (payload: unknown) => void;

interface HookThis {
  el: HTMLElement;
  pushEvent: (event: string, payload: unknown, callback?: (reply: unknown) => void) => void;
  handleEvent: (event: string, callback: Listener) => void;
  _root?: Root;
  _listeners?: Map<string, Set<Listener>>;
  _phoenixHandlerRegistered?: Set<string>;
}

const DurableDashboard = {
  mounted(this: HookThis) {
    const config = JSON.parse(this.el.dataset.config || "{}");
    const listeners: Map<string, Set<Listener>> = new Map();
    const phoenixHandlerRegistered = new Set<string>();

    this._listeners = listeners;
    this._phoenixHandlerRegistered = phoenixHandlerRegistered;

    const bridge: LiveViewBridge = {
      pushEvent: (event, payload) =>
        new Promise((resolve, reject) => {
          let settled = false;

          const timer = window.setTimeout(() => {
            if (!settled) {
              settled = true;
              reject(new Error(`Timed out waiting for reply to "${event}"`));
            }
          }, PUSH_EVENT_TIMEOUT_MS);

          this.pushEvent(event, payload, (reply) => {
            if (settled) return;
            settled = true;
            window.clearTimeout(timer);
            resolve(reply);
          });
        }),

      subscribe: (event: string, callback: Listener): Unsubscribe => {
        let bucket = listeners.get(event);
        if (!bucket) {
          bucket = new Set();
          listeners.set(event, bucket);
        }
        bucket.add(callback);

        // Register the Phoenix-side listener only once per event name.
        // It dispatches to every React subscriber currently in the bucket.
        if (!phoenixHandlerRegistered.has(event)) {
          phoenixHandlerRegistered.add(event);
          this.handleEvent(event, (payload) => {
            listeners.get(event)?.forEach((listener) => {
              try {
                listener(payload);
              } catch (err) {
                console.error(`[DurableDashboard] listener for "${event}" threw:`, err);
              }
            });
          });
        }

        return () => {
          listeners.get(event)?.delete(callback);
        };
      },
    };

    const root = createRoot(this.el);
    root.render(
      <LiveViewContext.Provider value={bridge}>
        <App
          basePath={config.base_path || ""}
          initialView={config.initial_view || "overview"}
          initialParams={config.initial_params || {}}
        />
      </LiveViewContext.Provider>,
    );
    this._root = root;
  },

  destroyed(this: HookThis) {
    if (this._root) {
      this._root.unmount();
      this._root = undefined;
    }
    this._listeners?.clear();
    this._phoenixHandlerRegistered?.clear();
  },
};

// ============================================================================
// LiveSocket Setup
// ============================================================================

const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content");

const liveSocketPath =
  document.querySelector("meta[name='live-socket-path']")?.getAttribute("content") || "/live";

const liveSocket = new LiveSocket(liveSocketPath, Socket, {
  hooks: { DurableDashboard },
  params: { _csrf_token: csrfToken },
});

liveSocket.connect();

// Expose for debugging
(window as unknown as Record<string, unknown>).liveSocket = liveSocket;

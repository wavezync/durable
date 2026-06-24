// Dashboard entry point — LiveSocket + the FlowGraph hook only.
//
// Pages render server-side via LiveView; React only shows up inside a
// `phx-hook="FlowGraph"` island for the workflow-graph view. Everything
// else is HEEx.

import "./index.css";

// @ts-expect-error — phoenix has no type declarations
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";

import { CommandPalette } from "./hooks/command_palette";
import { FlowGraph } from "./hooks/flow_graph";
import { localizeTime, localizeTimes } from "./hooks/local_time";

const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content");

const liveSocketPath =
  document.querySelector("meta[name='live-socket-path']")?.getAttribute("content") || "/live";

const liveSocket = new LiveSocket(liveSocketPath, Socket, {
  hooks: { FlowGraph, CommandPalette },
  params: { _csrf_token: csrfToken },
  dom: {
    // Render UTC `<time data-ts>` elements in the viewer's timezone — once for
    // streamed-in nodes, and again whenever LiveView re-renders one (which
    // would otherwise reset the text back to the server's UTC fallback).
    onNodeAdded(node: Node) {
      if (node instanceof HTMLElement) localizeTimes(node);
    },
    onBeforeElUpdated(_from: Element, to: Element) {
      if (to instanceof HTMLElement && to.matches("time[data-ts]")) localizeTime(to);
    },
  },
});

liveSocket.connect();

// The initial server-rendered DOM is already in place before any patch, so
// localize it directly.
localizeTimes(document);
document.addEventListener("phx:page-loading-stop", () => localizeTimes(document));

// Expose for debugging.
(window as unknown as Record<string, unknown>).liveSocket = liveSocket;

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

const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content");

const liveSocketPath =
  document.querySelector("meta[name='live-socket-path']")?.getAttribute("content") || "/live";

const liveSocket = new LiveSocket(liveSocketPath, Socket, {
  hooks: { FlowGraph, CommandPalette },
  params: { _csrf_token: csrfToken },
});

liveSocket.connect();

// Expose for debugging.
(window as unknown as Record<string, unknown>).liveSocket = liveSocket;

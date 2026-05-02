// V2 entry point — LiveSocket + the FlowGraph hook only. No React SPA.
//
// The dashboard's pages render server-side via LiveView; React only shows
// up inside a `phx-hook="FlowGraph"` island for the workflow-graph view.
// Everything else is HEEx.
//
// This file's bundle is loaded by `Layouts.root_v2/1` and is independent
// of the v1 React SPA (`src/main.tsx`).

// CSS is owned by the v1 entry (`src/main.tsx`) until phase 6 cutover —
// both layouts load the same `app.css`. Tailwind v4's Vite plugin can't
// emit a single CSS shared across multi-entry rollups, so we keep the
// import on one side only. Inter comes from the Google Fonts <link> in
// `Layouts.root_v2/1`.

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

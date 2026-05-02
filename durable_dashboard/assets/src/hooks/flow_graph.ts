/**
 * FlowGraph LiveView hook — bridges between Durable's `FlowGraph`
 * LiveComponent and a React-based ReactFlow island.
 *
 * The LC renders this element with:
 *
 *   <div id="flow-{id}" phx-hook="FlowGraph" phx-update="ignore"
 *        data-graph={JSON.stringify(graph)}>
 *   </div>
 *
 * On mount, the hook:
 *   1. Reads the initial graph from `data-graph`
 *   2. Lazy-imports React + ReactFlow + dagre (keeping the baseline JS
 *      payload small — the workflow detail page only pays the cost when
 *      actually viewed)
 *   3. Creates a React root inside the element and renders the island
 *
 * Subsequent updates come from the LC via `push_event/3`:
 *   - `flow:replace` { graph }                     full graph swap
 *   - `flow:patch-node` { id, patch }              partial node update
 *
 * Both events are scoped to the hook id (`flow-{id}:replace`) to avoid
 * collisions when multiple FlowGraphs render on the same page.
 */

import type { GraphData } from "../lib/types";

interface FlowIsland {
  setGraph(graph: GraphData): void;
  patchNode(id: string, patch: Record<string, unknown>): void;
  destroy(): void;
}

interface HookThis {
  el: HTMLElement;
  handleEvent: (event: string, callback: (payload: unknown) => void) => void;
  pushEventTo: (selectorOrTarget: string | HTMLElement, event: string, payload: unknown) => void;
  _island?: FlowIsland;
  _eventNames?: { replace: string; patchNode: string };
  _onStepClicked?: (event: Event) => void;
}

export const FlowGraph = {
  async mounted(this: HookThis) {
    const id = this.el.id || `flow-${Math.random().toString(36).slice(2, 8)}`;
    const replaceEvent = `${id}:replace`;
    const patchNodeEvent = `${id}:patch-node`;
    this._eventNames = { replace: replaceEvent, patchNode: patchNodeEvent };

    let initialGraph: GraphData = { nodes: [], edges: [] };
    try {
      const raw = this.el.dataset.graph;
      if (raw) initialGraph = JSON.parse(raw) as GraphData;
    } catch (err) {
      console.warn("[FlowGraph] failed to parse data-graph attribute:", err);
    }

    // Lazy-import the React island so the baseline JS bundle doesn't pull
    // in ReactFlow + dagre + react-dom for every page.
    const { mountFlowIsland } = await import("../react/flow_graph");

    this._island = mountFlowIsland(this.el, initialGraph);

    this.handleEvent(replaceEvent, (payload) => {
      const { graph } = payload as { graph: GraphData };
      if (graph) this._island?.setGraph(graph);
    });

    this.handleEvent(patchNodeEvent, (payload) => {
      const { id: nodeId, patch } = payload as {
        id: string;
        patch: Record<string, unknown>;
      };
      if (nodeId) this._island?.patchNode(nodeId, patch || {});
    });

    // Bridge React-side step clicks to the LV. Listening on `el` (rather
    // than window) keeps multiple FlowGraphs on the same page isolated;
    // each only sees its own descendants' bubbled CustomEvents.
    this._onStepClicked = (event: Event) => {
      const ce = event as CustomEvent<{
        stepName: string;
        stepExecutionId: string | null;
        childWorkflowId: string | null;
      }>;
      if (!ce.detail?.stepName) return;
      this.pushEventTo(this.el, "step-clicked", {
        step_name: ce.detail.stepName,
        step_execution_id: ce.detail.stepExecutionId,
        child_workflow_id: ce.detail.childWorkflowId,
      });
    };
    this.el.addEventListener("durable:step-clicked", this._onStepClicked);
  },

  destroyed(this: HookThis) {
    this._island?.destroy();
    this._island = undefined;
    if (this._onStepClicked) {
      this.el.removeEventListener("durable:step-clicked", this._onStepClicked);
      this._onStepClicked = undefined;
    }
  },
};

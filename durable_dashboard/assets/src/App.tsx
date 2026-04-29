import { useCallback, useEffect, useMemo, useState } from "react";
import { Toaster } from "sonner";
import { AppSidebar } from "@/components/layout/AppSidebar";
import { CommandPalette } from "@/components/layout/CommandPalette";
import { TopBar } from "@/components/layout/TopBar";
import { RelativeTimeProvider } from "@/components/shared/RelativeTime";
import { SidebarInset, SidebarProvider } from "@/components/ui/sidebar";
import { TooltipProvider } from "@/components/ui/tooltip";
import { useLiveEvent } from "./hooks/useLiveEvent";
import type { NavigateFn, ViewName } from "./lib/types";
import { buildQueryString, parseQueryString } from "./lib/utils";
import { OverviewView } from "./views/OverviewView";
import { PendingInputsView } from "./views/PendingInputsView";
import { ScheduleListView } from "./views/ScheduleListView";
import { SettingsView } from "./views/SettingsView";
import { WorkflowDetailView } from "./views/WorkflowDetailView";
import { WorkflowListView } from "./views/WorkflowListView";
import { WorkflowLogsView } from "./views/WorkflowLogsView";

interface AppProps {
  basePath: string;
  initialView: string;
  initialParams: Record<string, string>;
}

type ParsedRoute = { view: ViewName; params: Record<string, string> };

// ============================================================================
// URL Routing
// ============================================================================

/** Query param keys that travel as URL query strings, not path segments. */
const QUERY_KEYS = new Set([
  "status",
  "search",
  "page",
  "queue",
  "sort_by",
  "sort_dir",
  "step",
  "attempt",
  "name",
]);

function pathFor(view: ViewName, params: Record<string, string>): string {
  const qp: Record<string, string | null | undefined> = {};
  for (const [k, v] of Object.entries(params)) {
    if (QUERY_KEYS.has(k)) qp[k] = v;
  }
  const qs = buildQueryString(qp);

  switch (view) {
    case "overview":
      return "/";
    case "workflows":
      return `/workflows${qs}`;
    case "workflow_detail": {
      if (!params.id) return "/workflows";
      const base = params.tab ? `/workflows/${params.id}/${params.tab}` : `/workflows/${params.id}`;
      return base + qs;
    }
    case "schedules":
      return "/schedules";
    case "inputs":
      return "/inputs";
    case "settings":
      return "/settings";
    default:
      return "/";
  }
}

function parsePath(path: string): ParsedRoute {
  const [pathname, rawSearch = ""] = path.split("?");
  const segments = pathname.split("/").filter(Boolean);
  const query = parseQueryString(rawSearch);

  if (segments.length === 0) return { view: "overview", params: {} };

  if (segments[0] === "workflows") {
    if (segments.length === 1) {
      return { view: "workflows", params: { ...query } };
    }
    if (segments.length === 2) {
      return {
        view: "workflow_detail",
        params: { id: segments[1], ...query },
      };
    }
    return {
      view: "workflow_detail",
      params: { id: segments[1], tab: segments[2], ...query },
    };
  }
  if (segments[0] === "schedules") return { view: "schedules", params: {} };
  if (segments[0] === "inputs") return { view: "inputs", params: {} };
  if (segments[0] === "settings") return { view: "settings", params: {} };
  return { view: "overview", params: {} };
}

function routeFromUrl(basePath: string): ParsedRoute {
  const pathname = window.location.pathname.startsWith(basePath)
    ? window.location.pathname.slice(basePath.length)
    : window.location.pathname;
  return parsePath(pathname + window.location.search);
}

// ============================================================================
// App Shell
// ============================================================================

export function App({ basePath }: AppProps) {
  // biome-ignore lint/correctness/useExhaustiveDependencies: boot route derived once from initial URL
  const bootRoute = useMemo<ParsedRoute>(() => {
    if (typeof window === "undefined") {
      return { view: "overview" as ViewName, params: {} };
    }
    return routeFromUrl(basePath);
  }, []);

  const [currentView, setCurrentView] = useState<ViewName>(bootRoute.view);
  const [viewParams, setViewParams] = useState<Record<string, string>>(bootRoute.params);
  const { pushEvent } = useLiveEvent();

  const navigate: NavigateFn = useCallback(
    (view: ViewName, params?: Record<string, string>) => {
      const safeParams = params || {};
      setCurrentView(view);
      setViewParams(safeParams);

      const newUrl = basePath + pathFor(view, safeParams);
      const currentUrl = window.location.pathname + window.location.search;
      if (currentUrl !== newUrl) {
        window.history.pushState({}, "", newUrl);
      }

      pushEvent("navigate", { view, params: safeParams }).catch(() => {});
    },
    [basePath, pushEvent],
  );

  useEffect(() => {
    const onPopState = () => {
      const { view, params } = routeFromUrl(basePath);
      setCurrentView(view);
      setViewParams(params);
      pushEvent("navigate", { view, params }).catch(() => {});
    };
    window.addEventListener("popstate", onPopState);
    return () => window.removeEventListener("popstate", onPopState);
  }, [basePath, pushEvent]);

  return (
    <TooltipProvider>
      <RelativeTimeProvider>
        <SidebarProvider>
          <AppSidebar navigate={navigate} currentView={currentView} />
          <SidebarInset>
            <TopBar currentView={currentView} viewParams={viewParams} navigate={navigate} />
            <main className="flex-1 overflow-auto p-4 sm:p-6">
              {renderView(currentView, viewParams, navigate)}
            </main>
          </SidebarInset>
        </SidebarProvider>
        <CommandPalette navigate={navigate} />
        <Toaster richColors position="top-right" closeButton />
      </RelativeTimeProvider>
    </TooltipProvider>
  );
}

function renderView(view: ViewName, params: Record<string, string>, navigate: NavigateFn) {
  switch (view) {
    case "overview":
      return <OverviewView navigate={navigate} />;
    case "workflows":
      return <WorkflowListView navigate={navigate} viewParams={params} />;
    case "workflow_detail":
      if (params.tab === "logs") {
        return (
          <WorkflowLogsView
            id={params.id}
            stepFilter={params.step}
            attemptFilter={params.attempt}
            navigate={navigate}
          />
        );
      }
      return <WorkflowDetailView id={params.id} navigate={navigate} viewParams={params} />;
    case "schedules":
      return <ScheduleListView />;
    case "inputs":
      return <PendingInputsView navigate={navigate} />;
    case "settings":
      return <SettingsView />;
    default:
      return <OverviewView navigate={navigate} />;
  }
}

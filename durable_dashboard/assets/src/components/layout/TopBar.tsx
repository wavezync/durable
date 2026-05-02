import { useMemo } from "react";
import {
  Breadcrumb,
  BreadcrumbItem,
  BreadcrumbLink,
  BreadcrumbList,
  BreadcrumbPage,
  BreadcrumbSeparator,
} from "@/components/ui/breadcrumb";
import { Separator } from "@/components/ui/separator";
import { SidebarTrigger } from "@/components/ui/sidebar";
import type { NavigateFn, ViewName } from "@/lib/types";

interface TopBarProps {
  currentView: ViewName;
  viewParams: Record<string, string>;
  navigate: NavigateFn;
}

type Crumb = {
  label: string;
  onClick?: () => void;
};

const VIEW_LABELS: Record<string, string> = {
  overview: "Overview",
  workflows: "Workflows",
  workflow_detail: "Workflows",
  schedules: "Schedules",
  inputs: "Inputs",
  settings: "Settings",
};

const TAB_LABELS: Record<string, string> = {
  summary: "Summary",
  flow: "Flow",
  topology: "Topology",
  logs: "Logs",
  io: "I/O",
  history: "History",
};

export function TopBar({ currentView, viewParams, navigate }: TopBarProps) {
  const crumbs = useMemo<Crumb[]>(() => {
    const items: Crumb[] = [];

    if (currentView === "workflow_detail") {
      items.push({
        label: "Workflows",
        onClick: () => navigate("workflows"),
      });

      const name = viewParams.name || viewParams.id?.slice(0, 8) || "Detail";
      items.push({
        label: name,
        onClick: viewParams.tab
          ? () =>
              navigate("workflow_detail", {
                id: viewParams.id,
              })
          : undefined,
      });

      if (viewParams.tab) {
        items.push({
          label: TAB_LABELS[viewParams.tab] || viewParams.tab,
        });
      }
    } else {
      items.push({
        label: VIEW_LABELS[currentView] || currentView,
      });
    }

    return items;
  }, [currentView, viewParams, navigate]);

  return (
    <header className="flex h-12 shrink-0 items-center gap-2 border-b border-border/60 px-4">
      <SidebarTrigger className="-ml-1" />
      <Separator orientation="vertical" className="mr-2 !h-4" />
      <Breadcrumb>
        <BreadcrumbList>
          {crumbs.map((crumb, i) => {
            const isLast = i === crumbs.length - 1;
            return (
              <BreadcrumbItem key={crumb.label}>
                {i > 0 && <BreadcrumbSeparator />}
                {isLast || !crumb.onClick ? (
                  <BreadcrumbPage>{crumb.label}</BreadcrumbPage>
                ) : (
                  <BreadcrumbLink onClick={crumb.onClick} className="cursor-pointer">
                    {crumb.label}
                  </BreadcrumbLink>
                )}
              </BreadcrumbItem>
            );
          })}
        </BreadcrumbList>
      </Breadcrumb>
    </header>
  );
}

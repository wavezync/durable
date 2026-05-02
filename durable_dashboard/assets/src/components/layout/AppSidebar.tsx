import { Clock, Inbox, LayoutDashboard, Settings, Workflow } from "lucide-react";
import { ThemeToggle } from "@/components/layout/ThemeToggle";
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarGroup,
  SidebarGroupContent,
  SidebarGroupLabel,
  SidebarHeader,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
  SidebarSeparator,
} from "@/components/ui/sidebar";
import type { NavigateFn, ViewName } from "@/lib/types";
import { Logo } from "./Logo";

interface AppSidebarProps {
  navigate: NavigateFn;
  currentView: ViewName;
}

const NAV_ITEMS: {
  view: ViewName;
  label: string;
  icon: typeof LayoutDashboard;
}[] = [
  { view: "overview", label: "Overview", icon: LayoutDashboard },
  { view: "workflows", label: "Workflows", icon: Workflow },
  { view: "schedules", label: "Schedules", icon: Clock },
  { view: "inputs", label: "Inputs", icon: Inbox },
];

function isActive(currentView: ViewName, itemView: ViewName): boolean {
  if (currentView === itemView) return true;
  if (itemView === "workflows" && currentView === "workflow_detail") return true;
  return false;
}

export function AppSidebar({ navigate, currentView }: AppSidebarProps) {
  return (
    <Sidebar collapsible="icon" variant="sidebar">
      <SidebarHeader>
        <SidebarMenu>
          <SidebarMenuItem>
            <SidebarMenuButton
              size="lg"
              onClick={() => navigate("overview")}
              className="cursor-pointer"
            >
              <Logo />
            </SidebarMenuButton>
          </SidebarMenuItem>
        </SidebarMenu>
      </SidebarHeader>

      <SidebarContent>
        <SidebarGroup>
          <SidebarGroupLabel>Navigation</SidebarGroupLabel>
          <SidebarGroupContent>
            <SidebarMenu>
              {NAV_ITEMS.map((item) => {
                const active = isActive(currentView, item.view);
                return (
                  <SidebarMenuItem key={item.view}>
                    <SidebarMenuButton
                      isActive={active}
                      onClick={() => navigate(item.view)}
                      tooltip={item.label}
                      className="cursor-pointer"
                    >
                      <item.icon />
                      <span>{item.label}</span>
                    </SidebarMenuButton>
                  </SidebarMenuItem>
                );
              })}
            </SidebarMenu>
          </SidebarGroupContent>
        </SidebarGroup>
      </SidebarContent>

      <SidebarFooter>
        <SidebarSeparator />
        <SidebarMenu>
          <SidebarMenuItem>
            <SidebarMenuButton
              isActive={currentView === "settings"}
              onClick={() => navigate("settings")}
              tooltip="Settings"
              className="cursor-pointer"
            >
              <Settings />
              <span>Settings</span>
            </SidebarMenuButton>
          </SidebarMenuItem>
        </SidebarMenu>
        <div className="flex items-center gap-2 px-2 py-1">
          <span className="h-1.5 w-1.5 rounded-full bg-[oklch(0.82_0.17_150)] led-dot" />
          <span className="truncate text-[11px] text-muted-foreground group-data-[collapsible=icon]:hidden">
            System online
          </span>
          <div className="ml-auto group-data-[collapsible=icon]:hidden">
            <ThemeToggle />
          </div>
        </div>
      </SidebarFooter>
    </Sidebar>
  );
}

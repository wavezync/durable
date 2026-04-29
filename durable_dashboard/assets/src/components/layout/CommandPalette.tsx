import {
  AlertCircle,
  Clock,
  Inbox,
  LayoutDashboard,
  Play,
  Search,
  Settings,
  Workflow,
} from "lucide-react";
import { useCallback, useEffect, useState } from "react";
import {
  CommandDialog,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
  CommandSeparator,
} from "@/components/ui/command";
import { useLiveEvent } from "@/hooks/useLiveEvent";
import type { NavigateFn, Workflow as WorkflowType } from "@/lib/types";

interface CommandPaletteProps {
  navigate: NavigateFn;
}

export function CommandPalette({ navigate }: CommandPaletteProps) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<WorkflowType[]>([]);
  const { pushEvent } = useLiveEvent();

  // Register Cmd+K / Ctrl+K keyboard shortcut.
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key === "k") {
        e.preventDefault();
        setOpen((prev) => !prev);
      }
    };
    document.addEventListener("keydown", handler);
    return () => document.removeEventListener("keydown", handler);
  }, []);

  // Search workflows when the user types a query.
  const handleSearch = useCallback(
    async (value: string) => {
      setQuery(value);
      if (value.trim().length < 2) {
        setResults([]);
        return;
      }
      try {
        const data = (await pushEvent("list_workflows", {
          search: value.trim(),
          per_page: 6,
        })) as { workflows: WorkflowType[] };
        setResults(data.workflows || []);
      } catch {
        setResults([]);
      }
    },
    [pushEvent],
  );

  const go = (view: Parameters<NavigateFn>[0], params?: Record<string, string>) => {
    setOpen(false);
    setQuery("");
    setResults([]);
    navigate(view, params);
  };

  return (
    <CommandDialog
      open={open}
      onOpenChange={setOpen}
      title="Command Palette"
      description="Search workflows or navigate the dashboard"
    >
      <CommandInput
        placeholder="Search workflows, navigate..."
        value={query}
        onValueChange={handleSearch}
      />
      <CommandList>
        <CommandEmpty>No results found.</CommandEmpty>

        {/* Workflow search results */}
        {results.length > 0 && (
          <CommandGroup heading="Workflows">
            {results.map((wf) => (
              <CommandItem key={wf.id} onSelect={() => go("workflow_detail", { id: wf.id })}>
                <Search className="mr-2 h-4 w-4 text-muted-foreground" />
                <div className="flex flex-1 items-center justify-between gap-2">
                  <span className="truncate">{wf.workflow_name}</span>
                  <span className="shrink-0 font-mono text-[10px] text-muted-foreground">
                    {wf.status}
                  </span>
                </div>
              </CommandItem>
            ))}
          </CommandGroup>
        )}

        {results.length > 0 && <CommandSeparator />}

        {/* Navigation */}
        <CommandGroup heading="Navigate">
          <CommandItem onSelect={() => go("overview")}>
            <LayoutDashboard className="mr-2 h-4 w-4" /> Overview
          </CommandItem>
          <CommandItem onSelect={() => go("workflows")}>
            <Workflow className="mr-2 h-4 w-4" /> Workflows
          </CommandItem>
          <CommandItem onSelect={() => go("schedules")}>
            <Clock className="mr-2 h-4 w-4" /> Schedules
          </CommandItem>
          <CommandItem onSelect={() => go("inputs")}>
            <Inbox className="mr-2 h-4 w-4" /> Inputs
          </CommandItem>
          <CommandItem onSelect={() => go("settings")}>
            <Settings className="mr-2 h-4 w-4" /> Settings
          </CommandItem>
        </CommandGroup>

        <CommandSeparator />

        {/* Quick actions */}
        <CommandGroup heading="Quick Actions">
          <CommandItem onSelect={() => go("workflows", { status: "failed" })}>
            <AlertCircle className="mr-2 h-4 w-4 text-destructive" />
            View failed workflows
          </CommandItem>
          <CommandItem onSelect={() => go("workflows", { status: "running" })}>
            <Play className="mr-2 h-4 w-4 text-[var(--primary)]" />
            View running workflows
          </CommandItem>
        </CommandGroup>
      </CommandList>
    </CommandDialog>
  );
}

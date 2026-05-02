import { ChevronLeft, ChevronRight, RotateCw, XCircle } from "lucide-react";
import { useCallback, useEffect, useMemo, useState } from "react";
import { toast } from "sonner";
import { RelativeTime } from "@/components/shared/RelativeTime";
import { StatusBadge } from "@/components/shared/StatusBadge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { useLiveEvent, useLiveEventSubscription } from "@/hooks/useLiveEvent";
import { useUrlParams } from "@/hooks/useUrlParams";
import type {
  NavigateFn,
  StatusCounts,
  Workflow,
  WorkflowListResponse,
  WorkflowStatus,
} from "@/lib/types";

interface WorkflowListViewProps {
  navigate: NavigateFn;
  viewParams?: Record<string, string>;
}

const FILTER_DEFAULTS = {
  status: "",
  search: "",
  page: 1,
};

const STATUSES: (WorkflowStatus | "")[] = [
  "",
  "pending",
  "running",
  "waiting",
  "completed",
  "failed",
  "cancelled",
];

export function WorkflowListView({ navigate, viewParams = {} }: WorkflowListViewProps) {
  const filters = useUrlParams(viewParams, FILTER_DEFAULTS);

  const [workflows, setWorkflows] = useState<Workflow[]>([]);
  const [total, setTotal] = useState(0);
  const [counts, setCounts] = useState<StatusCounts>({});
  const [loading, setLoading] = useState(true);
  const { pushEvent } = useLiveEvent();

  const perPage = 20;

  const applyList = useCallback((data: WorkflowListResponse) => {
    setWorkflows(data.workflows || []);
    setTotal(data.total || 0);
    setCounts(data.counts || {});
  }, []);

  // Fetch data whenever URL-driven filters change.
  const fetchPayload = useMemo(() => {
    const payload: Record<string, unknown> = {
      page: filters.page,
      per_page: perPage,
    };
    if (filters.status) payload.status = filters.status;
    if (filters.search) payload.search = filters.search;
    return payload;
  }, [filters.page, filters.status, filters.search]);

  // biome-ignore lint/correctness/useExhaustiveDependencies: fetch depends on serialized payload, not individual fields
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const data = (await pushEvent("list_workflows", fetchPayload)) as WorkflowListResponse;
        if (!cancelled) {
          applyList(data);
          setLoading(false);
        }
      } catch (err) {
        if (!cancelled) {
          toast.error(err instanceof Error ? err.message : "Failed to load workflows");
          setLoading(false);
        }
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [fetchPayload]);

  useLiveEventSubscription("workflows_data", (payload) => {
    applyList(payload as WorkflowListResponse);
  });

  // Navigation helpers that update URL params.
  const setFilter = (key: string, value: string | number) => {
    const next = { ...viewParams, [key]: String(value) };
    // Reset page when changing a filter.
    if (key !== "page") next.page = "1";
    // Remove empty values to keep URLs clean.
    for (const k of Object.keys(next)) {
      if (next[k] === "" || next[k] === "0") delete next[k];
    }
    navigate("workflows", next);
  };

  const totalPages = Math.ceil(total / perPage);

  if (loading) return <ListSkeleton />;

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <h1 className="text-heading text-2xl text-foreground">Workflows</h1>
        <span className="text-sm text-muted-foreground">{total} total</span>
      </div>

      {/* Filters */}
      <div className="flex flex-wrap gap-3">
        <Input
          type="text"
          placeholder="Search workflows..."
          value={filters.search}
          onChange={(e) => setFilter("search", e.target.value)}
          className="w-64"
        />
        <div className="flex gap-1">
          {STATUSES.map((s) => {
            const active = filters.status === s;
            return (
              <Button
                key={s || "all"}
                variant={active ? "default" : "outline"}
                size="sm"
                onClick={() => setFilter("status", s)}
              >
                {s || "All"}
                {s && counts[s] ? <span className="ml-1 opacity-70">({counts[s]})</span> : null}
              </Button>
            );
          })}
        </div>
      </div>

      {/* Table */}
      {workflows.length === 0 ? (
        <div className="border border-border bg-card p-12 text-center text-sm text-muted-foreground">
          No workflows found
        </div>
      ) : (
        <div className="overflow-hidden border border-border bg-card">
          <Table>
            <TableHeader>
              <TableRow className="bg-muted/30">
                <TableHead className="text-xs text-muted-foreground">Workflow</TableHead>
                <TableHead className="text-xs text-muted-foreground">Status</TableHead>
                <TableHead className="hidden text-xs text-muted-foreground md:table-cell">
                  Queue
                </TableHead>
                <TableHead className="hidden text-xs text-muted-foreground lg:table-cell">
                  Current Step
                </TableHead>
                <TableHead className="text-xs text-muted-foreground">Created</TableHead>
                <TableHead className="w-[100px] text-right text-xs text-muted-foreground">
                  Actions
                </TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {workflows.map((wf) => (
                <TableRow
                  key={wf.id}
                  onClick={() => navigate("workflow_detail", { id: wf.id })}
                  className="cursor-pointer"
                >
                  <TableCell className="py-3">
                    <div className="max-w-[200px] truncate font-medium">{wf.workflow_name}</div>
                    <div className="mt-0.5 max-w-[200px] truncate font-mono text-xs text-muted-foreground">
                      {wf.id.slice(0, 8)}...
                    </div>
                  </TableCell>
                  <TableCell className="py-3">
                    <StatusBadge status={wf.status} size="sm" />
                  </TableCell>
                  <TableCell className="hidden py-3 text-muted-foreground md:table-cell">
                    {wf.queue}
                  </TableCell>
                  <TableCell className="hidden py-3 text-muted-foreground lg:table-cell">
                    {wf.current_step || "—"}
                  </TableCell>
                  <TableCell className="py-3 text-muted-foreground">
                    <RelativeTime value={wf.inserted_at} className="text-xs" />
                  </TableCell>
                  <TableCell className="py-3 text-right">
                    <RowActions
                      workflow={wf}
                      onRetry={async (e) => {
                        e.stopPropagation();
                        try {
                          const result = (await pushEvent("retry_workflow", {
                            id: wf.id,
                          })) as { ok?: boolean; workflow_id?: string; error?: string };
                          if (result.ok && result.workflow_id) {
                            toast.success("New workflow started");
                            navigate("workflow_detail", { id: result.workflow_id });
                          } else {
                            toast.error(result.error || "Failed to retry");
                          }
                        } catch (err) {
                          toast.error(err instanceof Error ? err.message : "Failed to retry");
                        }
                      }}
                      onCancel={async (e) => {
                        e.stopPropagation();
                        try {
                          const result = (await pushEvent("cancel_workflow", {
                            id: wf.id,
                            reason: "Cancelled from workflow list",
                          })) as { ok?: boolean; error?: string };
                          if (result.ok) {
                            toast.success("Workflow cancelled");
                          } else {
                            toast.error(result.error || "Failed to cancel");
                          }
                        } catch (err) {
                          toast.error(err instanceof Error ? err.message : "Failed to cancel");
                        }
                      }}
                    />
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}

      {/* Pagination */}
      {totalPages > 1 && (
        <div className="flex items-center justify-between">
          <span className="text-xs text-muted-foreground">
            Page {filters.page} of {totalPages}
          </span>
          <div className="flex gap-1">
            <Button
              variant="outline"
              size="sm"
              onClick={() => setFilter("page", filters.page - 1)}
              disabled={filters.page <= 1}
            >
              <ChevronLeft className="mr-1 h-3 w-3" /> Prev
            </Button>
            <Button
              variant="outline"
              size="sm"
              onClick={() => setFilter("page", filters.page + 1)}
              disabled={filters.page >= totalPages}
            >
              Next <ChevronRight className="ml-1 h-3 w-3" />
            </Button>
          </div>
        </div>
      )}
    </div>
  );
}

const TERMINAL_STATUSES = new Set([
  "completed",
  "failed",
  "cancelled",
  "compensated",
  "compensation_failed",
]);
const CANCELLABLE_STATUSES = new Set(["pending", "running", "waiting"]);

function RowActions({
  workflow,
  onRetry,
  onCancel,
}: {
  workflow: Workflow;
  onRetry: (e: React.MouseEvent) => void;
  onCancel: (e: React.MouseEvent) => void;
}) {
  if (TERMINAL_STATUSES.has(workflow.status)) {
    return (
      <Button variant="ghost" size="xs" onClick={onRetry} className="gap-1">
        <RotateCw className="h-3 w-3" /> Retry
      </Button>
    );
  }
  if (CANCELLABLE_STATUSES.has(workflow.status)) {
    return (
      <Button
        variant="ghost"
        size="xs"
        onClick={onCancel}
        className="gap-1 text-destructive hover:text-destructive"
      >
        <XCircle className="h-3 w-3" /> Cancel
      </Button>
    );
  }
  return null;
}

function ListSkeleton() {
  return (
    <div className="space-y-4">
      <Skeleton className="h-8 w-40" />
      <div className="flex gap-3">
        <Skeleton className="h-9 w-64" />
        <Skeleton className="h-9 w-48" />
      </div>
      <div className="space-y-0.5">
        {Array.from({ length: 10 }).map((_, i) => (
          <Skeleton key={i} className="h-14" />
        ))}
      </div>
    </div>
  );
}

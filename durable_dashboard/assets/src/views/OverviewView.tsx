import { Activity, AlertTriangle, CheckCircle, Clock, TrendingUp } from "lucide-react";
import type { ReactNode } from "react";
import { useCallback, useEffect, useState } from "react";
import { Area, AreaChart, Bar, BarChart, CartesianGrid, XAxis, YAxis } from "recharts";
import { toast } from "sonner";
import { RelativeTime } from "@/components/shared/RelativeTime";
import { StatusBadge } from "@/components/shared/StatusBadge";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import {
  type ChartConfig,
  ChartContainer,
  ChartTooltip,
  ChartTooltipContent,
} from "@/components/ui/chart";
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
import type {
  MetricsResponse,
  NavigateFn,
  OverviewResponse,
  StatusCounts,
  Workflow,
} from "@/lib/types";
import { formatDurationMs } from "@/lib/utils";

interface OverviewViewProps {
  navigate: NavigateFn;
}

export function OverviewView({ navigate }: OverviewViewProps) {
  const [counts, setCounts] = useState<StatusCounts>({});
  const [recent, setRecent] = useState<Workflow[]>([]);
  const [metrics, setMetrics] = useState<MetricsResponse | null>(null);
  const [loading, setLoading] = useState(true);
  const { pushEvent } = useLiveEvent();

  const applyOverview = useCallback((data: OverviewResponse) => {
    setCounts(data.counts || {});
    setRecent(data.recent || []);
  }, []);

  const loadData = useCallback(async () => {
    try {
      const [overview, metricsData] = await Promise.all([
        pushEvent("get_overview", {}) as Promise<OverviewResponse>,
        pushEvent("get_metrics", {}) as Promise<MetricsResponse>,
      ]);
      applyOverview(overview);
      setMetrics(metricsData);
    } catch (err) {
      toast.error(err instanceof Error ? err.message : "Failed to load overview");
    } finally {
      setLoading(false);
    }
  }, [pushEvent, applyOverview]);

  useEffect(() => {
    loadData();
  }, [loadData]);

  useLiveEventSubscription("overview_data", (payload) => {
    applyOverview(payload as OverviewResponse);
  });

  if (loading) return <OverviewSkeleton />;

  const totalRunning = (counts.running || 0) + (counts.pending || 0) + (counts.waiting || 0);
  const totalCompleted = counts.completed || 0;
  const totalFailed = counts.failed || 0;
  const totalAll = Object.values(counts).reduce((a, b) => a + b, 0);
  const successRate = totalAll > 0 ? Math.round((totalCompleted / totalAll) * 100) : 0;

  return (
    <div className="space-y-6">
      <h1 className="text-heading text-2xl text-foreground">Overview</h1>

      {/* KPI Cards */}
      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <KpiCard
          title="Active"
          value={totalRunning}
          icon={<Activity className="h-4 w-4 text-[var(--primary)]" />}
          detail="running + pending + waiting"
        />
        <KpiCard
          title="Success Rate"
          value={`${successRate}%`}
          icon={<CheckCircle className="h-4 w-4 text-[oklch(0.82_0.17_150)]" />}
          detail="completed / total"
        />
        <KpiCard
          title="P95 Duration"
          value={metrics ? formatDurationMs(metrics.percentiles.p95) : "—"}
          icon={<Clock className="h-4 w-4 text-[oklch(0.78_0.13_210)]" />}
          detail="last 24h"
        />
        <KpiCard
          title="Failed (24h)"
          value={totalFailed}
          icon={<AlertTriangle className="h-4 w-4 text-destructive" />}
          detail={`${metrics?.top_failing?.length ?? 0} failing workflows`}
        />
      </div>

      {/* Charts row */}
      <div className="grid gap-6 lg:grid-cols-2">
        <Card>
          <CardHeader className="pb-2">
            <CardTitle className="flex items-center gap-2 text-sm font-medium">
              <TrendingUp className="h-4 w-4 text-muted-foreground" />
              Throughput
              <span className="ml-auto text-xs font-normal text-muted-foreground">last hour</span>
            </CardTitle>
          </CardHeader>
          <CardContent>
            <ThroughputChart data={metrics?.throughput ?? []} />
          </CardContent>
        </Card>

        <Card>
          <CardHeader className="pb-2">
            <CardTitle className="flex items-center gap-2 text-sm font-medium">
              Status Breakdown
              <span className="ml-auto text-xs font-normal text-muted-foreground">last 24h</span>
            </CardTitle>
          </CardHeader>
          <CardContent>
            <StatusBreakdownChart data={metrics?.breakdown ?? {}} />
          </CardContent>
        </Card>
      </div>

      {/* Bottom row */}
      <div className="grid gap-6 lg:grid-cols-2">
        <Card>
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium">Top Failing Workflows</CardTitle>
          </CardHeader>
          <CardContent>
            <TopFailingTable items={metrics?.top_failing ?? []} navigate={navigate} />
          </CardContent>
        </Card>

        <Card>
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium">Recent Executions</CardTitle>
          </CardHeader>
          <CardContent className="space-y-1">
            <RecentList items={recent} navigate={navigate} />
          </CardContent>
        </Card>
      </div>
    </div>
  );
}

/* -------------------------------------------------------------------------- */

function KpiCard({
  title,
  value,
  icon,
  detail,
}: {
  title: string;
  value: ReactNode;
  icon: ReactNode;
  detail: string;
}) {
  return (
    <Card>
      <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
        <CardTitle className="text-sm font-medium text-muted-foreground">{title}</CardTitle>
        {icon}
      </CardHeader>
      <CardContent>
        <div className="text-2xl font-bold">{value}</div>
        <p className="mt-1 text-xs text-muted-foreground">{detail}</p>
      </CardContent>
    </Card>
  );
}

const throughputConfig: ChartConfig = {
  count: { label: "Workflows", color: "var(--color-primary)" },
};

function ThroughputChart({ data }: { data: { time: string; count: number }[] }) {
  if (data.length === 0) {
    return <p className="py-12 text-center text-sm text-muted-foreground">No throughput data</p>;
  }

  const chartData = data.map((d) => ({
    time: new Date(d.time).toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" }),
    count: d.count,
  }));

  return (
    <ChartContainer config={throughputConfig} className="h-[200px] w-full">
      <AreaChart data={chartData}>
        <CartesianGrid vertical={false} strokeDasharray="3 3" />
        <XAxis dataKey="time" tickLine={false} axisLine={false} fontSize={10} />
        <YAxis tickLine={false} axisLine={false} fontSize={10} allowDecimals={false} />
        <ChartTooltip content={<ChartTooltipContent />} />
        <Area
          type="monotone"
          dataKey="count"
          fill="var(--color-primary)"
          fillOpacity={0.2}
          stroke="var(--color-primary)"
          strokeWidth={2}
        />
      </AreaChart>
    </ChartContainer>
  );
}

const breakdownConfig: ChartConfig = {
  completed: { label: "Completed", color: "oklch(0.82 0.17 150)" },
  failed: { label: "Failed", color: "oklch(0.68 0.2 22)" },
  running: { label: "Running", color: "var(--color-primary)" },
  pending: { label: "Pending", color: "oklch(0.68 0.015 80)" },
  cancelled: { label: "Cancelled", color: "oklch(0.5 0.01 70)" },
};

function StatusBreakdownChart({ data }: { data: Record<string, number> }) {
  const chartData = Object.entries(data)
    .filter(([, v]) => v > 0)
    .map(([status, count]) => ({ status, count }));

  if (chartData.length === 0) {
    return <p className="py-12 text-center text-sm text-muted-foreground">No data in window</p>;
  }

  return (
    <ChartContainer config={breakdownConfig} className="h-[200px] w-full">
      <BarChart data={chartData}>
        <CartesianGrid vertical={false} strokeDasharray="3 3" />
        <XAxis dataKey="status" tickLine={false} axisLine={false} fontSize={10} />
        <YAxis tickLine={false} axisLine={false} fontSize={10} allowDecimals={false} />
        <ChartTooltip content={<ChartTooltipContent />} />
        <Bar dataKey="count" radius={[4, 4, 0, 0]} fill="var(--color-primary)" />
      </BarChart>
    </ChartContainer>
  );
}

function TopFailingTable({
  items,
  navigate,
}: {
  items: { name: string; count: number }[];
  navigate: NavigateFn;
}) {
  if (items.length === 0) {
    return (
      <p className="py-8 text-center text-sm text-muted-foreground">No failures in the last 24h</p>
    );
  }

  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead className="text-xs">Workflow</TableHead>
          <TableHead className="text-right text-xs">Failures</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {items.map((item) => (
          <TableRow
            key={item.name}
            className="cursor-pointer"
            onClick={() => navigate("workflows", { status: "failed", search: item.name })}
          >
            <TableCell className="font-medium">{item.name}</TableCell>
            <TableCell className="text-right font-mono text-destructive">{item.count}</TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  );
}

function RecentList({ items, navigate }: { items: Workflow[]; navigate: NavigateFn }) {
  if (items.length === 0) {
    return <p className="py-8 text-center text-sm text-muted-foreground">No executions yet</p>;
  }

  return (
    <>
      {items.slice(0, 8).map((wf) => (
        <button
          key={wf.id}
          type="button"
          onClick={() => navigate("workflow_detail", { id: wf.id })}
          className="flex w-full items-center justify-between gap-3 rounded-sm px-2 py-2 text-left transition-colors hover:bg-accent/50"
        >
          <div className="min-w-0 flex-1">
            <div className="truncate text-sm font-medium">{wf.workflow_name}</div>
            <div className="truncate text-xs text-muted-foreground">{wf.workflow_module}</div>
          </div>
          <div className="flex shrink-0 items-center gap-2">
            <StatusBadge status={wf.status} size="sm" />
            <RelativeTime value={wf.inserted_at} className="text-xs text-muted-foreground" />
          </div>
        </button>
      ))}
    </>
  );
}

function OverviewSkeleton() {
  return (
    <div className="space-y-6">
      <Skeleton className="h-8 w-32" />
      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        {Array.from({ length: 4 }).map((_, i) => (
          <Skeleton key={i} className="h-28" />
        ))}
      </div>
      <div className="grid gap-6 lg:grid-cols-2">
        <Skeleton className="h-[280px]" />
        <Skeleton className="h-[280px]" />
      </div>
    </div>
  );
}

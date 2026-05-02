import { useCallback, useEffect, useState } from "react";
import { toast } from "sonner";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Separator } from "@/components/ui/separator";
import { Skeleton } from "@/components/ui/skeleton";
import { useLiveEvent, useLiveEventSubscription } from "@/hooks/useLiveEvent";
import type { Schedule, ScheduleListResponse } from "@/lib/types";

export function ScheduleListView() {
  const [schedules, setSchedules] = useState<Schedule[]>([]);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(true);
  const { pushEvent } = useLiveEvent();

  const applyList = useCallback((data: ScheduleListResponse) => {
    setSchedules(data.schedules || []);
    setTotal(data.total || 0);
  }, []);

  const loadData = useCallback(async () => {
    try {
      const data = (await pushEvent("list_schedules", {
        page: 1,
        per_page: 50,
      })) as ScheduleListResponse;
      applyList(data);
    } catch (err) {
      toast.error(err instanceof Error ? err.message : "Failed to load schedules");
    } finally {
      setLoading(false);
    }
  }, [pushEvent, applyList]);

  useEffect(() => {
    loadData();
  }, [loadData]);

  useLiveEventSubscription("schedules_data", (payload) => {
    applyList(payload as ScheduleListResponse);
  });

  const handleToggle = async (id: string, enabled: boolean) => {
    try {
      const result = (await pushEvent("toggle_schedule", {
        id,
        enabled: !enabled,
      })) as { ok?: boolean; error?: string };
      if (result.ok) {
        toast.success(enabled ? "Schedule disabled" : "Schedule enabled");
      } else {
        toast.error(result.error || "Failed to toggle schedule");
      }
    } catch (err) {
      toast.error(err instanceof Error ? err.message : "Failed to toggle schedule");
    }
  };

  const handleTrigger = async (id: string) => {
    try {
      const result = (await pushEvent("trigger_schedule", {
        id,
      })) as { ok?: boolean; error?: string };
      if (result.ok) {
        toast.success("Schedule triggered");
      } else {
        toast.error(result.error || "Failed to trigger schedule");
      }
    } catch (err) {
      toast.error(err instanceof Error ? err.message : "Failed to trigger schedule");
    }
  };

  if (loading) {
    return (
      <div className="space-y-4">
        <Skeleton className="h-7 w-40" />
        {Array.from({ length: 5 }).map((_, i) => (
          <Skeleton key={i} className="h-16 rounded-lg" />
        ))}
      </div>
    );
  }

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <h2 className="text-xl font-semibold">Schedules</h2>
        <span className="text-sm text-muted-foreground">{total} total</span>
      </div>

      {schedules.length === 0 ? (
        <Card className="py-12 text-center text-muted-foreground text-sm">
          No scheduled workflows
        </Card>
      ) : (
        <Card className="gap-0 py-0">
          {schedules.map((schedule, i) => (
            <div key={schedule.id}>
              {i > 0 && <Separator />}
              <div className="px-4 py-3 flex items-center justify-between">
                <div className="min-w-0 flex-1">
                  <div className="flex items-center gap-2">
                    <span className="text-sm font-medium">{schedule.name}</span>
                    <Badge
                      variant={schedule.enabled ? "default" : "secondary"}
                      className={schedule.enabled ? "bg-emerald-500/15 text-emerald-400" : ""}
                    >
                      {schedule.enabled ? "active" : "disabled"}
                    </Badge>
                  </div>
                  <div className="text-xs text-muted-foreground mt-0.5 flex gap-3">
                    <span className="font-mono">{schedule.cron_expression}</span>
                    <span>{schedule.workflow_name}</span>
                    <span>queue: {schedule.queue}</span>
                  </div>
                  <div className="text-xs text-muted-foreground mt-0.5">
                    {schedule.next_run_at && (
                      <span>Next: {new Date(schedule.next_run_at).toLocaleString()}</span>
                    )}
                    {schedule.last_run_at && (
                      <span className="ml-3">
                        Last: {new Date(schedule.last_run_at).toLocaleString()}
                      </span>
                    )}
                  </div>
                </div>

                <div className="flex items-center gap-2 ml-4">
                  <Button variant="outline" size="sm" onClick={() => handleTrigger(schedule.id)}>
                    Run Now
                  </Button>
                  <Button
                    variant="secondary"
                    size="sm"
                    onClick={() => handleToggle(schedule.id, schedule.enabled)}
                  >
                    {schedule.enabled ? "Disable" : "Enable"}
                  </Button>
                </div>
              </div>
            </div>
          ))}
        </Card>
      )}
    </div>
  );
}

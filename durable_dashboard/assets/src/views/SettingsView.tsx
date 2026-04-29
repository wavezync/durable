import { useCallback, useEffect, useState } from "react";
import { toast } from "sonner";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { useLiveEvent } from "@/hooks/useLiveEvent";
import { formatDurationMs } from "@/lib/utils";

interface DurableConfig {
  name: string;
  prefix: string;
  queue_enabled: boolean;
  stale_lock_timeout: number;
  heartbeat_interval: number;
  queues: { name: string; concurrency: number }[];
}

export function SettingsView() {
  const [config, setConfig] = useState<DurableConfig | null>(null);
  const [loading, setLoading] = useState(true);
  const { pushEvent } = useLiveEvent();

  const loadConfig = useCallback(async () => {
    try {
      const data = (await pushEvent("get_config", {})) as DurableConfig;
      setConfig(data);
    } catch (err) {
      toast.error(err instanceof Error ? err.message : "Failed to load config");
    } finally {
      setLoading(false);
    }
  }, [pushEvent]);

  useEffect(() => {
    loadConfig();
  }, [loadConfig]);

  if (loading) {
    return (
      <div className="space-y-6">
        <Skeleton className="h-8 w-40" />
        <Skeleton className="h-64" />
      </div>
    );
  }

  if (!config) {
    return (
      <div className="py-24 text-center text-muted-foreground">Could not load configuration</div>
    );
  }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-heading text-2xl text-foreground">Settings</h1>
        <p className="mt-1 text-sm text-muted-foreground">
          Read-only view of the Durable instance configuration.
        </p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-sm font-medium">Instance</CardTitle>
        </CardHeader>
        <CardContent>
          <dl className="grid gap-y-3 sm:grid-cols-2">
            <ConfigItem label="Instance Name" value={config.name} />
            <ConfigItem label="Schema Prefix" value={config.prefix} mono />
            <ConfigItem
              label="Queue Processing"
              value={config.queue_enabled ? "Enabled" : "Disabled"}
            />
            <ConfigItem
              label="Stale Lock Timeout"
              value={formatDurationMs(config.stale_lock_timeout * 1000)}
            />
            <ConfigItem
              label="Heartbeat Interval"
              value={formatDurationMs(config.heartbeat_interval)}
            />
          </dl>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-sm font-medium">Queues</CardTitle>
        </CardHeader>
        <CardContent>
          {config.queues.length === 0 ? (
            <p className="py-4 text-center text-sm text-muted-foreground">No queues configured</p>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead className="text-xs">Queue Name</TableHead>
                  <TableHead className="text-right text-xs">Concurrency</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {config.queues.map((q) => (
                  <TableRow key={q.name}>
                    <TableCell className="font-mono">{q.name}</TableCell>
                    <TableCell className="text-right font-mono">{q.concurrency}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>
    </div>
  );
}

function ConfigItem({
  label,
  value,
  mono = false,
}: {
  label: string;
  value: string;
  mono?: boolean;
}) {
  return (
    <div>
      <dt className="text-xs text-muted-foreground">{label}</dt>
      <dd className={`mt-0.5 text-sm ${mono ? "font-mono" : ""}`}>{value}</dd>
    </div>
  );
}

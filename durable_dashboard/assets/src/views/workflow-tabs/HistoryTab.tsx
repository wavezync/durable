import { Clock } from "lucide-react";

export function HistoryTab() {
  return (
    <div className="flex flex-col items-center justify-center gap-3 py-24 text-muted-foreground">
      <Clock className="h-8 w-8 opacity-40" />
      <p className="font-mono text-[10px] uppercase tracking-[0.22em]">Execution history</p>
      <p className="text-sm">Retry and attempt history will be available in a future update.</p>
    </div>
  );
}

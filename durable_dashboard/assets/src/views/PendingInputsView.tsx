import { useCallback, useEffect, useState } from "react";
import { toast } from "sonner";
import { InputForm } from "@/components/shared/InputForm";
import { StatusBadge } from "@/components/shared/StatusBadge";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { useLiveEvent, useLiveEventSubscription } from "@/hooks/useLiveEvent";
import type { NavigateFn, PendingInput, PendingInputListResponse } from "@/lib/types";

interface PendingInputsViewProps {
  navigate: NavigateFn;
}

export function PendingInputsView({ navigate }: PendingInputsViewProps) {
  const [inputs, setInputs] = useState<PendingInput[]>([]);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(true);
  const { pushEvent } = useLiveEvent();

  const applyList = useCallback((data: PendingInputListResponse) => {
    setInputs(data.inputs || []);
    setTotal(data.total || 0);
  }, []);

  const loadData = useCallback(async () => {
    try {
      const data = (await pushEvent("list_pending_inputs", {
        page: 1,
        per_page: 50,
      })) as PendingInputListResponse;
      applyList(data);
    } catch (err) {
      toast.error(err instanceof Error ? err.message : "Failed to load pending inputs");
    } finally {
      setLoading(false);
    }
  }, [pushEvent, applyList]);

  useEffect(() => {
    loadData();
  }, [loadData]);

  useLiveEventSubscription("inputs_data", (payload) => {
    applyList(payload as PendingInputListResponse);
  });

  const handleSubmit = async (workflowId: string, inputName: string, data: unknown) => {
    try {
      const result = (await pushEvent("provide_input", {
        workflow_id: workflowId,
        input_name: inputName,
        data,
      })) as { ok?: boolean; error?: string };

      if (result.ok) {
        toast.success("Input provided");
      } else {
        toast.error(result.error || "Failed to provide input");
      }
    } catch (err) {
      toast.error(err instanceof Error ? err.message : "Failed to provide input");
    }
  };

  if (loading) {
    return (
      <div className="space-y-4">
        <Skeleton className="h-7 w-48" />
        {Array.from({ length: 3 }).map((_, i) => (
          <Skeleton key={i} className="h-32 rounded-lg" />
        ))}
      </div>
    );
  }

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <h2 className="text-xl font-semibold">Pending Inputs</h2>
        <span className="text-sm text-muted-foreground">{total} pending</span>
      </div>

      {inputs.length === 0 ? (
        <Card>
          <CardContent className="py-12 text-center text-muted-foreground text-sm">
            No pending inputs
          </CardContent>
        </Card>
      ) : (
        <div className="space-y-3">
          {inputs.map((input) => (
            <Card key={input.id}>
              <CardContent className="space-y-3">
                <div className="flex items-start justify-between">
                  <div>
                    <div className="flex items-center gap-2">
                      <span className="text-sm font-medium">{input.input_name}</span>
                      <Badge variant="secondary" className="capitalize">
                        {input.input_type.replace("_", " ")}
                      </Badge>
                    </div>
                    <div className="text-xs text-muted-foreground mt-0.5">
                      Step: {input.step_name}
                      {input.workflow && (
                        <>
                          {" · "}
                          <Button
                            variant="link"
                            size="sm"
                            className="h-auto p-0 text-xs"
                            onClick={() =>
                              navigate("workflow_detail", {
                                id: input.workflow_id,
                              })
                            }
                          >
                            {input.workflow.workflow_name}
                          </Button>
                        </>
                      )}
                    </div>
                    {input.timeout_at && (
                      <div className="text-xs text-amber-400 mt-1">
                        Timeout: {new Date(input.timeout_at).toLocaleString()}
                      </div>
                    )}
                  </div>
                  {input.workflow && <StatusBadge status={input.workflow.status} />}
                </div>

                {input.prompt && <p className="text-sm text-foreground/80">{input.prompt}</p>}

                <InputForm
                  input={input}
                  onSubmit={(data) => handleSubmit(input.workflow_id, input.input_name, data)}
                />
              </CardContent>
            </Card>
          ))}
        </div>
      )}
    </div>
  );
}

import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Textarea } from "@/components/ui/textarea";
import type { PendingInput } from "@/lib/types";

interface InputFormProps {
  input: PendingInput;
  onSubmit: (data: unknown) => void;
}

export function InputForm({ input, onSubmit }: InputFormProps) {
  switch (input.input_type) {
    case "approval":
      return <ApprovalForm input={input} onSubmit={onSubmit} />;
    case "single_choice":
      return <SingleChoiceForm input={input} onSubmit={onSubmit} />;
    case "multi_choice":
      return <MultiChoiceForm input={input} onSubmit={onSubmit} />;
    case "free_text":
      return <FreeTextForm input={input} onSubmit={onSubmit} />;
    case "form":
      return <DynamicForm input={input} onSubmit={onSubmit} />;
    default:
      return <FreeTextForm input={input} onSubmit={onSubmit} />;
  }
}

function ApprovalForm({ onSubmit }: { input: PendingInput; onSubmit: (data: unknown) => void }) {
  const [submitting, setSubmitting] = useState(false);

  const handle = async (approved: boolean) => {
    setSubmitting(true);
    await onSubmit(approved ? "approved" : "rejected");
    setSubmitting(false);
  };

  return (
    <div className="flex gap-2">
      <Button
        variant="outline"
        size="sm"
        onClick={() => handle(true)}
        disabled={submitting}
        className="bg-emerald-500/15 text-emerald-400 border-emerald-500/30 hover:bg-emerald-500/25"
      >
        Approve
      </Button>
      <Button
        variant="outline"
        size="sm"
        onClick={() => handle(false)}
        disabled={submitting}
        className="bg-red-500/15 text-red-400 border-red-500/30 hover:bg-red-500/25"
      >
        Reject
      </Button>
    </div>
  );
}

function SingleChoiceForm({
  input,
  onSubmit,
}: {
  input: PendingInput;
  onSubmit: (data: unknown) => void;
}) {
  const [selected, setSelected] = useState<string>("");
  const [submitting, setSubmitting] = useState(false);
  const choices = input.fields || [];

  const handle = async () => {
    if (!selected) return;
    setSubmitting(true);
    await onSubmit(selected);
    setSubmitting(false);
  };

  return (
    <div className="space-y-2">
      <div className="flex flex-wrap gap-2">
        {choices.map((choice, i) => {
          const val = choice.value || choice.label || String(i);
          return (
            <Button
              key={i}
              variant={selected === val ? "default" : "outline"}
              size="sm"
              onClick={() => setSelected(val)}
            >
              {choice.label || choice.value || choice.name}
            </Button>
          );
        })}
      </div>
      <Button size="sm" onClick={handle} disabled={!selected || submitting}>
        Submit
      </Button>
    </div>
  );
}

function MultiChoiceForm({
  input,
  onSubmit,
}: {
  input: PendingInput;
  onSubmit: (data: unknown) => void;
}) {
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [submitting, setSubmitting] = useState(false);
  const choices = input.fields || [];

  const toggle = (value: string) => {
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(value)) next.delete(value);
      else next.add(value);
      return next;
    });
  };

  const handle = async () => {
    setSubmitting(true);
    await onSubmit(Array.from(selected));
    setSubmitting(false);
  };

  return (
    <div className="space-y-2">
      <div className="flex flex-wrap gap-2">
        {choices.map((choice, i) => {
          const val = choice.value || choice.label || String(i);
          return (
            <Button
              key={i}
              variant={selected.has(val) ? "default" : "outline"}
              size="sm"
              onClick={() => toggle(val)}
            >
              {choice.label || choice.value || choice.name}
            </Button>
          );
        })}
      </div>
      <Button size="sm" onClick={handle} disabled={selected.size === 0 || submitting}>
        Submit ({selected.size} selected)
      </Button>
    </div>
  );
}

function FreeTextForm({
  input,
  onSubmit,
}: {
  input: PendingInput;
  onSubmit: (data: unknown) => void;
}) {
  const [text, setText] = useState("");
  const [submitting, setSubmitting] = useState(false);

  const handle = async () => {
    if (!text.trim()) return;
    setSubmitting(true);
    await onSubmit(text);
    setSubmitting(false);
  };

  return (
    <div className="space-y-2">
      <Textarea
        value={text}
        onChange={(e) => setText(e.target.value)}
        placeholder={input.prompt || "Enter your response..."}
        className="min-h-[80px] resize-y"
      />
      <Button size="sm" onClick={handle} disabled={!text.trim() || submitting}>
        Submit
      </Button>
    </div>
  );
}

function DynamicForm({
  input,
  onSubmit,
}: {
  input: PendingInput;
  onSubmit: (data: unknown) => void;
}) {
  const fields = input.fields || [];
  const [values, setValues] = useState<Record<string, string>>({});
  const [submitting, setSubmitting] = useState(false);

  const setValue = (name: string, value: string) => {
    setValues((prev) => ({ ...prev, [name]: value }));
  };

  const handle = async () => {
    setSubmitting(true);
    await onSubmit(values);
    setSubmitting(false);
  };

  const allRequiredFilled = fields.filter((f) => f.required).every((f) => values[f.name]?.trim());

  return (
    <div className="space-y-3">
      {fields.map((field) => (
        <div key={field.name} className="space-y-1">
          <Label className="text-xs">
            {field.label || field.name}
            {field.required && <span className="text-destructive ml-0.5">*</span>}
          </Label>
          {field.type === "select" && field.options ? (
            <Select value={values[field.name] || ""} onValueChange={(v) => setValue(field.name, v)}>
              <SelectTrigger className="w-full">
                <SelectValue placeholder="Select..." />
              </SelectTrigger>
              <SelectContent>
                {field.options.map((opt) => (
                  <SelectItem key={opt} value={opt}>
                    {opt}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          ) : field.type === "textarea" ? (
            <Textarea
              value={values[field.name] || ""}
              onChange={(e) => setValue(field.name, e.target.value)}
              className="min-h-[60px] resize-y"
            />
          ) : (
            <Input
              type="text"
              value={values[field.name] || ""}
              onChange={(e) => setValue(field.name, e.target.value)}
            />
          )}
        </div>
      ))}
      <Button size="sm" onClick={handle} disabled={!allRequiredFilled || submitting}>
        Submit
      </Button>
    </div>
  );
}

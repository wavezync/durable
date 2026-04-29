import { cn } from "@/lib/utils";

interface LogoProps {
  className?: string;
}

/**
 * Durable masthead: a hexagonal bezel paired with a small-caps wordmark.
 * The slash and subtitle are treated as editorial metadata.
 */
export function Logo({ className }: LogoProps) {
  return (
    <div className={cn("flex items-center gap-2.5", className)}>
      <LogoGlyph className="h-[22px] w-[22px]" />
      <span className="flex items-baseline gap-2">
        <span className="text-base font-semibold tracking-tight text-foreground">Durable</span>
      </span>
    </div>
  );
}

function LogoGlyph({ className }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
      className={className}
      aria-hidden="true"
    >
      <title>Durable</title>
      <path
        d="M12 2.5L20.66 7.5V16.5L12 21.5L3.34 16.5V7.5L12 2.5Z"
        stroke="var(--color-primary)"
        strokeWidth="1.4"
        strokeLinejoin="round"
        opacity="0.9"
      />
      <path
        d="M12 7L16.33 9.5V14.5L12 17L7.67 14.5V9.5L12 7Z"
        fill="var(--color-primary)"
        fillOpacity="0.18"
        stroke="var(--color-primary)"
        strokeWidth="1.2"
        strokeLinejoin="round"
      />
      <circle cx="12" cy="12" r="1.4" fill="var(--color-primary)" />
      <line
        x1="1"
        y1="12"
        x2="3"
        y2="12"
        stroke="var(--color-primary)"
        strokeWidth="1"
        opacity="0.7"
      />
      <line
        x1="21"
        y1="12"
        x2="23"
        y2="12"
        stroke="var(--color-primary)"
        strokeWidth="1"
        opacity="0.7"
      />
    </svg>
  );
}

/**
 * Design-token resolver.
 *
 * Reads CSS custom properties off `<html>` so React code can stay in step
 * with the theme set by `Layouts.root/1`. Use this anywhere a tailwind
 * utility doesn't fit — e.g. SVG fill/stroke attributes, third-party
 * components that take colors as strings (ReactFlow MiniMap), inline
 * `style` properties.
 *
 * **Do not** hard-code OKLCH/hex/rgb in component files. See `DESIGN.md`
 * §2.1 for the forbidden list. If you find yourself wanting to, either
 * add the token to `index.css` first or call `resolveToken` here.
 */

export function resolveToken(name: `--${string}`, fallback = ""): string {
  if (typeof window === "undefined") return fallback;
  const value = getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  return value || fallback;
}

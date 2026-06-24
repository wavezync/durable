/**
 * Clipboard copy — a single delegated click listener for every
 * `<button data-copy="…">` (rendered by `Components.Core.copy_button`).
 *
 * Delegation means copy buttons need no `phx-hook` and no unique `id`: they're
 * plain markup. On click we write `data-copy` to the clipboard and set
 * `data-copied="true"` for ~1.4s; CSS (`.copy-btn[data-copied]` in index.css)
 * swaps the clipboard glyph for a check.
 */

const COPIED_MS = 1400;

async function writeClipboard(text: string): Promise<void> {
  try {
    await navigator.clipboard.writeText(text);
    return;
  } catch {
    // Fallback for non-secure contexts / older browsers.
    const ta = document.createElement("textarea");
    ta.value = text;
    ta.setAttribute("readonly", "");
    ta.style.position = "fixed";
    ta.style.opacity = "0";
    document.body.appendChild(ta);
    ta.select();
    try {
      document.execCommand("copy");
    } catch {
      /* give up silently — nothing actionable for the user here */
    }
    ta.remove();
  }
}

export function initClipboard(): void {
  document.addEventListener("click", (event) => {
    const target = event.target as HTMLElement | null;
    const btn = target?.closest<HTMLElement>("[data-copy]");
    if (!btn) return;

    void writeClipboard(btn.dataset.copy ?? "");

    btn.dataset.copied = "true";
    const prior = Number(btn.dataset.copyTimer);
    if (prior) window.clearTimeout(prior);
    btn.dataset.copyTimer = String(
      window.setTimeout(() => {
        delete btn.dataset.copied;
        delete btn.dataset.copyTimer;
      }, COPIED_MS),
    );
  });
}

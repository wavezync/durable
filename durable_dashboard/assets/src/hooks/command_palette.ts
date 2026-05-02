/**
 * CommandPalette LV hook — bridges keyboard events to LiveComponent
 * server events. The LC owns all state (open/closed, query, selected
 * index); the hook just forwards user intent.
 *
 * Listens for:
 *   - ⌘K / Ctrl+K           anywhere → "palette:open"
 *   - Esc when open         → "palette:close"
 *   - ArrowUp / ArrowDown   → "palette:move"
 *   - Enter                 → "palette:activate"
 *   - durable:open-palette  custom event on <html> (from the topbar button)
 *
 * The LC element exposes `data-open` so the hook knows whether to
 * intercept Enter / arrows / Esc.
 */

interface HookThis {
  el: HTMLElement;
  pushEventTo: (target: string | HTMLElement, event: string, payload: unknown) => void;
  _onKeyDown?: (e: KeyboardEvent) => void;
  _onOpenEvent?: () => void;
  _focusObserver?: MutationObserver;
}

export const CommandPalette = {
  mounted(this: HookThis) {
    const onKeyDown = (e: KeyboardEvent) => {
      const isOpen = this.el.dataset.open === "true";
      const isCmdK = (e.metaKey || e.ctrlKey) && (e.key === "k" || e.key === "K");

      if (isCmdK) {
        e.preventDefault();
        this.pushEventTo(this.el, "palette:open", {});
        return;
      }

      if (!isOpen) return;

      switch (e.key) {
        case "Escape":
          e.preventDefault();
          this.pushEventTo(this.el, "palette:close", {});
          break;
        case "ArrowDown":
          e.preventDefault();
          this.pushEventTo(this.el, "palette:move", { dir: "down" });
          break;
        case "ArrowUp":
          e.preventDefault();
          this.pushEventTo(this.el, "palette:move", { dir: "up" });
          break;
        case "Enter":
          e.preventDefault();
          this.pushEventTo(this.el, "palette:activate", {});
          break;
      }
    };

    const onOpenEvent = () => {
      this.pushEventTo(this.el, "palette:open", {});
    };

    document.addEventListener("keydown", onKeyDown);
    document.documentElement.addEventListener("durable:open-palette", onOpenEvent);

    this._onKeyDown = onKeyDown;
    this._onOpenEvent = onOpenEvent;

    // Auto-focus the input whenever the palette transitions to open.
    this._focusObserver = new MutationObserver(() => {
      if (this.el.dataset.open === "true") {
        const input = this.el.querySelector<HTMLInputElement>("[data-palette-input]");
        if (input && document.activeElement !== input) {
          input.focus();
        }
      }
    });
    this._focusObserver.observe(this.el, { attributes: true, attributeFilter: ["data-open"] });
  },

  destroyed(this: HookThis) {
    if (this._onKeyDown) document.removeEventListener("keydown", this._onKeyDown);
    if (this._onOpenEvent) {
      document.documentElement.removeEventListener("durable:open-palette", this._onOpenEvent);
    }
    this._focusObserver?.disconnect();
  },
};

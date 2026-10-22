// A toy Durable run, close enough to the real executor to teach it:
// - completed steps go in a journal; every resume walks the workflow from the
//   top and skips what the journal already has
// - a wait or sleep suspends the run; once answered, the run resumes and that
//   step runs again from its top (the wait now returns the answer)
// - a step that fails after its retries rolls back completed steps' compensations
// Drawn on the workflow graph from layout.ts: steps light up as they run.

type Action = { label: string; value: string; call: string };
export type Step = {
  step: string;
  ms?: number;
  retry?: number; // max attempts
  flaky?: number; // fail the first N attempts
  error?: string;
  compensate?: string;
  wait?: { says: string; actions: Action[]; auto?: number }; // auto: action picked after idling
  sleep?: string; // the call, e.g. "sleep(days(3))"
  as?: string; // context key a wait's answer is stored under
};
export type Node = Step | { parallel: Step[] } | { branch: string; clauses: Record<string, Node[]> };
export type Spec = {
  workflow: string;
  module: string;
  nodes: Node[];
  toggles?: { label: string; step: string }[];
  intro?: string;
};

type Status = 'running' | 'waiting' | 'completed' | 'failed' | 'compensating' | 'compensated';
type Row = { name: string; attempt: number; status: Status; t0: number; t1?: number; comp?: boolean; waited?: boolean };

const STOPPED = Symbol('stopped');
const PARKED = Symbol('parked');
class StepFailed extends Error {}

const LABEL: Record<string, string> = {
  pending: 'Pending', running: 'Running', waiting: 'Waiting', completed: 'Completed', failed: 'Failed',
  compensating: 'Compensating', compensated: 'Compensated',
};
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const fmt = (ms: number) => (ms < 1000 ? `${Math.round(ms)}ms` : `${(ms / 1000).toFixed(1)}s`);
const ids = (nodes: Node[]): string[] =>
  nodes.flatMap((n) => ('parallel' in n ? n.parallel.map((s) => s.step) : 'branch' in n ? [`branch:${n.branch}`, ...Object.values(n.clauses).flatMap(ids)] : [n.step]));

function h<K extends keyof HTMLElementTagNameMap>(tag: K, cls = '', text = '') {
  const el = document.createElement(tag);
  if (cls) el.className = cls;
  if (text) el.append(...rich(text));
  return el;
}
// `backticks` become <code>; everything else is text, never HTML.
function rich(text: string) {
  return text.split('`').map((part, i) => (i % 2 ? Object.assign(document.createElement('code'), { textContent: part }) : document.createTextNode(part)));
}

export class Sim {
  private steps = new Map<string, Step>();
  private lines = new Map<string, HTMLElement[]>();
  private failing = new Set<string>();
  private ui: Record<string, HTMLElement>;
  private gnodes = new Map<string, SVGGElement>();
  private gedges: SVGGElement[] = [];

  private gen = 0; // bumps on "Run again"; stale timers check it
  private epoch = 0;
  private t0 = 0;
  private tEnd = 0;
  private status: Status | 'pending' = 'pending';
  private rows: Row[] = [];
  private done = new Set<string>();
  private order: string[] = [];
  private answers = new Map<string, string>();
  private ctx: Record<string, string> = {};
  private parked: { step: Step; row: Row } | null = null;
  private failed = false;
  private seen = new Set<string>();
  private taken = new Map<string, string>(); // branch -> clause key
  private skipped = new Set<string>(); // node ids on branches not taken
  private runId = '';

  constructor(private root: HTMLElement, private spec: Spec) {
    const index = (nodes: Node[]) =>
      nodes.forEach((n) => ('parallel' in n ? n.parallel.forEach((s) => this.steps.set(s.step, s)) : 'branch' in n ? Object.values(n.clauses).forEach(index) : this.steps.set(n.step, n)));
    index(spec.nodes);
    this.ui = Object.fromEntries([...root.querySelectorAll<HTMLElement>('[data-ui]')].map((el) => [el.dataset.ui!, el]));
    root.querySelectorAll<SVGGElement>('[data-node]').forEach((g) => this.gnodes.set(g.dataset.node!, g));
    this.gedges = [...root.querySelectorAll<SVGGElement>('[data-from]')];
    this.mapLines();
    this.changed();
    this.frame();
  }

  // Each step's block in the code panel: from `step :name` to its `end`.
  private mapLines() {
    const lines = [...this.root.querySelectorAll<HTMLElement>('.code .line')];
    lines.forEach((line, i) => {
      const m = /^(\s*)(?:step|compensate) :(\w+)/.exec(line.textContent ?? '');
      if (!m) return;
      let j = i;
      if (!/\bend\s*$/.test(line.textContent!)) {
        while (j < lines.length - 1 && !(lines[++j].textContent!.startsWith(`${m[1]}end`)));
      }
      this.lines.set(m[2], lines.slice(i, j + 1));
    });
  }

  start() {
    this.gen++;
    this.epoch++;
    Object.assign(this, {
      t0: performance.now(), tEnd: 0, status: 'pending', rows: [], order: [], ctx: {}, parked: null, failed: false,
      runId: Math.random().toString(16).slice(2, 8),
    });
    this.done = new Set();
    this.answers = new Map();
    this.seen = new Set();
    this.taken = new Map();
    this.skipped = new Set();
    this.ui.log.replaceChildren();
    this.say(this.spec.intro ?? `\`Durable.start(${this.spec.module}, input)\` queued a run.`);
    this.later(400, () => this.resume(true));
  }

  private now() { return performance.now() - this.t0; }
  private later(ms: number, fn: () => void) {
    const g = this.gen;
    setTimeout(() => g === this.gen && fn(), ms);
  }

  private resume(first: boolean) {
    this.status = this.failed ? 'compensating' : 'running';
    this.say(first ? 'A worker picked up the run.' : 'The run resumed. Finished steps are skipped, not run again.');
    this.exec(this.epoch);
  }

  private async exec(e: number) {
    try {
      if (!this.failed) {
        await this.walk(this.spec.nodes, e);
        this.finish('completed', 'Run completed.');
        return;
      }
    } catch (x) {
      if (x === STOPPED || x === PARKED) return;
      if (!(x instanceof StepFailed)) throw x;
      this.failed = true;
    }
    try {
      await this.compensate(e);
    } catch (x) {
      if (x !== STOPPED) throw x;
    }
  }

  private async walk(nodes: Node[], e: number): Promise<void> {
    for (const n of nodes) {
      if ('parallel' in n) {
        const results = await Promise.allSettled(n.parallel.map((s) => this.run(s, e)));
        const err = results.find((r) => r.status === 'rejected') as PromiseRejectedResult | undefined;
        if (err) throw err.reason;
      } else if ('branch' in n) {
        const value = this.ctx[n.branch];
        const key = value in n.clauses ? value : '_';
        if (!this.taken.has(n.branch)) {
          this.taken.set(n.branch, key);
          for (const [k, clause] of Object.entries(n.clauses)) if (k !== key) ids(clause).forEach((id) => this.skipped.add(id));
          this.say(`Branch on \`${n.branch}\` matched \`${key === '_' ? `_ (${value})` : value}\`.`);
        }
        await this.walk(n.clauses[key], e);
      } else {
        await this.run(n, e);
      }
    }
  }

  private async run(s: Step, e: number) {
    if (this.done.has(s.step)) return;
    // Resuming after a wait: the wait is over, and the step body runs again.
    const waited = this.parked?.step === s ? this.parked.row : null;
    this.parked = null;
    let attempt = waited?.attempt ?? (this.rows.findLast((r) => r.name === s.step)?.attempt ?? 0) + 1;
    let row = waited ? Object.assign(waited, { status: 'running' as Status }) : this.row(s.step, attempt);
    if (waited) this.changed();

    for (;;) {
      await this.tick(waited ? 300 : (s.ms ?? 600) * (0.8 + Math.random() * 0.4), e);
      if ((s.wait || s.sleep) && !this.answers.has(s.step)) this.park(s, row);
      if (s.as) this.ctx[s.as] = this.answers.get(s.step)!;

      if (!this.failing.has(s.step) && attempt > (s.flaky ?? 0)) {
        Object.assign(row, { status: 'completed', t1: this.now() });
        this.done.add(s.step);
        this.order.push(s.step);
        this.changed();
        return;
      }

      Object.assign(row, { status: 'failed', t1: this.now() });
      const err = s.error ?? 'raised an error';
      if (attempt >= (s.retry ?? 1)) {
        this.say(`\`${s.step}\` failed: ${err}.${s.retry ? ` Out of retries (${s.retry} attempts).` : ''}`);
        throw new StepFailed();
      }
      const backoff = 1000 * 2 ** (attempt - 1);
      this.say(`\`${s.step}\` failed: ${err}. Retrying in ${backoff / 1000}s (attempt ${attempt + 1} of ${s.retry}).`);
      this.changed();
      await this.tick(backoff, e);
      row = this.row(s.step, ++attempt);
    }
  }

  // Suspend: the run waits as a row in the database until it's answered.
  private park(s: Step, row: Row): never {
    Object.assign(row, { status: 'waiting', waited: true, t0: this.now() });
    this.parked = { step: s, row };
    this.status = 'waiting';
    if (s.sleep) {
      this.say(`\`${s.step}\` called \`${s.sleep}\`. The run is suspended; no process holds it while it sleeps.`);
      this.later(2600, () => this.answer(s.step, 'woke', 'The wake-up time came (sped up here).'));
    } else {
      this.say(`\`${s.step}\` is waiting: ${s.wait!.says}. No process holds the run while it waits.`);
      const auto = s.wait!.auto;
      if (auto !== undefined) {
        const a = s.wait!.actions[auto];
        this.later(5000, () => this.answer(s.step, a.value, a.call));
      }
    }
    this.changed();
    throw PARKED;
  }

  private answer(step: string, value: string, said: string) {
    if (this.parked?.step.step !== step || this.answers.has(step)) return;
    this.answers.set(step, value);
    this.say(said);
    this.later(300, () => this.resume(false));
  }

  private async compensate(e: number) {
    const stack = this.order.map((n) => this.steps.get(n)!).filter((s) => s.compensate).reverse();
    if (!stack.length) return this.finish('failed', 'Run failed. No compensations to run.');
    if (!this.seen.has('comp')) {
      this.seen.add('comp');
      this.status = 'compensating';
      this.say(`Rolling back: ${stack.map((s) => `\`${s.compensate}\``).join(', then ')}.`);
    }
    for (const s of stack) {
      const name = s.compensate!;
      if (this.done.has(`comp:${name}`)) continue;
      const row = this.row(name, 1, true);
      await this.tick(700, e);
      Object.assign(row, { status: 'compensated', t1: this.now() });
      this.done.add(`comp:${name}`);
      this.changed();
    }
    this.finish('compensated', 'Run compensated. Everything it booked was undone.');
  }

  private finish(status: Status, said: string) {
    this.status = status;
    this.tEnd = this.now();
    this.say(said);
  }

  // Flipping a toggle starts a fresh run, so its effect shows right away.
  toggle(step: string, on: boolean) {
    if (on) this.failing.add(step);
    else this.failing.delete(step);
    this.start();
  }

  private async tick(ms: number, e: number) {
    await sleep(ms);
    if (e !== this.epoch) throw STOPPED;
  }

  private row(name: string, attempt: number, comp = false) {
    const r: Row = { name, attempt, status: comp ? 'compensating' : 'running', t0: this.now(), comp };
    this.rows.push(r);
    this.changed();
    return r;
  }

  private say(text: string) {
    const li = h('li');
    li.append(h('span', 'at', `+${(this.now() / 1000).toFixed(1)}s`), h('span', '', text));
    this.ui.log.append(li);
    this.ui.log.scrollTop = this.ui.log.scrollHeight;
    this.changed();
  }

  // The latest attempt of a graph node (a step, or a compensation as comp:name).
  private latest(id: string) {
    const comp = id.startsWith('comp:');
    const name = comp ? id.slice(5) : id;
    return this.rows.findLast((r) => r.name === name && !!r.comp === comp);
  }

  private stateOf(id: string): string {
    if (id === 'start') return this.status === 'pending' ? 'pending' : 'completed';
    if (id === 'end') return ['completed', 'failed', 'compensated'].includes(this.status) ? this.status : 'pending';
    if (id.startsWith('branch:')) return this.taken.has(id.slice(7)) ? 'completed' : 'pending';
    if (this.skipped.has(id)) return 'skipped';
    return this.latest(id)?.status ?? 'pending';
  }

  // Repaints header, graph, code gutter and controls. Timers are updated every frame.
  private changed() {
    const { ui } = this;
    ui.status.className = `pill st-${this.status}`;
    ui.status.replaceChildren(h('i', 'st'), document.createTextNode(LABEL[this.status]));
    ui.run.textContent = this.runId ? `run ${this.runId}` : '';

    for (const [id, g] of this.gnodes) g.setAttribute('class', `gn ${g.dataset.kind} st-${this.stateOf(id)}`);
    // An edge lights up when its source finished (or was undone) and its target ran.
    const ran = (st: string) => st !== 'pending' && st !== 'skipped';
    const finished = (st: string) => st === 'completed' || st === 'compensated';
    for (const g of this.gedges) {
      const from = this.stateOf(g.dataset.from!), to = this.stateOf(g.dataset.to!);
      g.classList.toggle('drawn', finished(from) && ran(to));
      g.classList.toggle('dim', from === 'skipped' || to === 'skipped');
    }
    // On a narrow screen the graph scrolls sideways; keep the active step in view.
    const active = [...this.gnodes].find(([id]) => ['running', 'waiting', 'compensating'].includes(this.stateOf(id)))?.[1];
    const wrap = active?.closest<HTMLElement>('.graph-wrap');
    if (active && wrap && wrap.scrollWidth > wrap.clientWidth) {
      const a = active.getBoundingClientRect(), w = wrap.getBoundingClientRect();
      if (a.left < w.left || a.right > w.right) wrap.scrollBy({ left: a.left + a.width / 2 - (w.left + w.width / 2) });
    }

    for (const [name, els] of this.lines) {
      const r = this.rows.findLast((x) => x.name === name);
      for (const el of els) el.className = `line${r ? ` on st-${r.status}` : ''}`;
    }

    const parked = this.parked?.step;
    const actions: HTMLElement[] = [];
    if (parked?.wait && !this.answers.has(parked.step)) {
      for (const a of parked.wait.actions) {
        const b = h('button', 'act', a.label);
        b.onclick = () => this.answer(parked.step, a.value, a.call);
        actions.push(b);
      }
    }
    if (parked?.sleep && !this.answers.has(parked.step)) {
      const b = h('button', 'act', 'Skip ahead');
      b.onclick = () => this.answer(parked.step, 'woke', 'Skipped ahead to the wake-up time.');
      actions.push(b);
    }
    if (['completed', 'failed', 'compensated'].includes(this.status)) {
      const b = h('button', 'act primary', 'Run again');
      b.onclick = () => this.start();
      actions.push(b);
    }
    ui.actions.replaceChildren(...actions);
  }

  // Live durations and notes under each node.
  private frame() {
    const now = this.tEnd || this.now();
    for (const [id, g] of this.gnodes) {
      const meta = g.querySelector('.meta');
      if (!meta) continue;
      const st = this.stateOf(id);
      const r = this.latest(id);
      let text = '';
      if (st === 'skipped') text = 'not run';
      else if (r) {
        const d = fmt((r.t1 ?? now) - r.t0);
        const attempt = r.attempt > 1 ? `attempt ${r.attempt}, ` : '';
        text =
          r.status === 'waiting' ? (this.steps.get(r.name)?.sleep ? `sleeping ${d}` : `waiting ${d}`)
          : r.status === 'failed' ? `${attempt}failed`
          : r.status === 'compensated' ? 'undone'
          : r.status === 'compensating' ? 'undoing'
          : `${attempt}${d}`;
      }
      if (meta.textContent !== text) meta.textContent = text;
    }
    requestAnimationFrame(() => this.frame());
  }
}

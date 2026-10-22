// Lays a workflow spec out as a left-to-right graph: sequential steps become
// columns, parallel steps stack in one column, a branch is a gate followed by
// one row per clause, and compensations sit in a lane underneath. Computed at
// build time; the engine only toggles classes on what this produces.
import type { Node, Spec, Step } from './engine';

export type GNode = { id: string; label: string; kind: 'start' | 'step' | 'gate' | 'end' | 'comp'; x: number; y: number; w: number };
export type GEdge = { from: string; to: string; d: string; label?: string; lx?: number; ly?: number; comp?: boolean };
export type Graph = { width: number; height: number; nodes: GNode[]; edges: GEdge[] };

type Cell = { id: string; label: string; kind: GNode['kind']; col: number; row: number; room?: number };
type Link = { from: string; to: string; label?: string };
type Block = { cols: number; rows: number; entry: string[]; exit: string[]; cells: Cell[]; links: Link[] };

const ROW = 96;
const PAD = 26;
const GAP = 48;
// A gate's column is as wide as its longest branch label, so the label chips fit
// between the gate and its clauses.
const pill = (c: Cell) => (c.kind === 'start' || c.kind === 'end' ? 64 : c.kind === 'gate' ? (c.room ?? 96) : Math.round(c.label.length * 7.5 + 40));

const single = (id: string, label: string, kind: Cell['kind']): Block => ({
  cols: 1, rows: 1, entry: [id], exit: [id], cells: [{ id, label, kind, col: 0, row: 0 }], links: [],
});
const shift = (b: Block, dc: number, dr: number): Block => ({ ...b, cells: b.cells.map((c) => ({ ...c, col: c.col + dc, row: c.row + dr })) });

// Blocks one after another, vertically centred on each other.
function seq(blocks: Block[]): Block {
  const rows = Math.max(1, ...blocks.map((b) => b.rows));
  const cells: Cell[] = [];
  const links: Link[] = [];
  let col = 0;
  blocks.forEach((b, i) => {
    cells.push(...shift(b, col, (rows - b.rows) / 2).cells);
    links.push(...b.links);
    if (i > 0) for (const from of blocks[i - 1].exit) for (const to of b.entry) links.push({ from, to });
    col += b.cols;
  });
  return { cols: col, rows, entry: blocks[0].entry, exit: blocks.at(-1)!.exit, cells, links };
}

// Blocks on top of each other (parallel steps, branch clauses).
function stack(blocks: Block[]): Block {
  const cells: Cell[] = [];
  const links: Link[] = [];
  let row = 0;
  for (const b of blocks) {
    cells.push(...shift(b, 0, row).cells);
    links.push(...b.links);
    row += b.rows;
  }
  return { cols: Math.max(...blocks.map((b) => b.cols)), rows: row, entry: blocks.flatMap((b) => b.entry), exit: blocks.flatMap((b) => b.exit), cells, links };
}

function block(n: Node): Block {
  if ('parallel' in n) return stack(n.parallel.map((s) => single(s.step, s.step, 'step')));
  if ('branch' in n) {
    const gate = `branch:${n.branch}`;
    const clauses = Object.entries(n.clauses).map(([key, nodes]) => ({ key, b: seq(nodes.map(block)) }));
    const body = stack(clauses.map((c) => c.b));
    const rows = Math.max(1, body.rows);
    const labeled: Link[] = clauses.flatMap((c) => c.b.entry.map((to) => ({ from: gate, to, label: c.key === '_' ? 'otherwise' : c.key })));
    return {
      cols: 1 + body.cols, rows, entry: [gate], exit: body.exit,
      cells: [{ id: gate, label: n.branch, kind: 'gate', col: 0, row: (rows - 1) / 2, room: Math.max(96, ...labeled.map((l) => l.label!.length * 7.2 + 64)) }, ...shift(body, 1, 0).cells],
      links: [...labeled, ...body.links],
    };
  }
  return single(n.step, n.step, 'step');
}

// Steps that declare a compensation, in the order they run.
function compensated(nodes: Node[]): Step[] {
  return nodes.flatMap((n) => ('parallel' in n ? n.parallel : 'branch' in n ? Object.values(n.clauses).flatMap(compensated) : [n])).filter((s) => s.compensate);
}

export function layout(spec: Spec): Graph {
  const main = seq([single('start', 'start', 'start'), ...spec.nodes.map(block), single('end', 'done', 'end')]);
  const comps = compensated(spec.nodes);
  const cells = [...main.cells];
  const links: Link[] = [...main.links];
  const compRow = main.rows;
  for (const s of comps) {
    const owner = cells.find((c) => c.id === s.step)!;
    cells.push({ id: `comp:${s.compensate}`, label: s.compensate!, kind: 'comp', col: owner.col, row: compRow });
  }

  // Column widths fit their widest node.
  const widths: number[] = [];
  for (const c of cells) widths[c.col] = Math.max(widths[c.col] ?? 0, pill(c));
  const xs: number[] = [];
  widths.reduce((x, w, i) => ((xs[i] = x + w / 2), x + w + GAP), PAD);
  // A gate sits at the left of its wide column; the space to its right holds the branch labels.
  const nodes: GNode[] = cells.map((c) => ({
    id: c.id, label: c.label, kind: c.kind, w: c.kind === 'gate' ? 40 : pill(c),
    x: c.kind === 'gate' ? xs[c.col] - widths[c.col] / 2 + 28 : xs[c.col], y: PAD + c.row * ROW + ROW / 2,
  }));
  const at = new Map(nodes.map((n) => [n.id, n]));

  const edges: GEdge[] = links.map(({ from, to, label }) => {
    const a = at.get(from)!, b = at.get(to)!;
    const sx = a.x + a.w / 2, tx = b.x - b.w / 2, mx = (sx + tx) / 2;
    // Branch labels ride on the middle of their edge.
    return { from, to, label, d: `M${sx} ${a.y} C${mx} ${a.y} ${mx} ${b.y} ${tx} ${b.y}`, lx: mx, ly: (a.y + b.y) / 2 };
  });
  // Compensation lane: each step points down to its undo, and the undos chain right to left.
  comps.forEach((s, i) => {
    const step = at.get(s.step)!, comp = at.get(`comp:${s.compensate}`)!;
    edges.push({ from: s.step, to: comp.id, comp: true, d: `M${step.x} ${step.y + 17} V${comp.y - 17}` });
    const prev = comps[i - 1];
    if (prev) {
      const left = at.get(`comp:${prev.compensate}`)!;
      edges.push({ from: comp.id, to: left.id, comp: true, d: `M${comp.x - comp.w / 2} ${comp.y} H${left.x + left.w / 2}` });
    }
  });

  const width = Math.round(xs.at(-1)! + widths.at(-1)! / 2 + PAD);
  const height = Math.round(PAD * 2 + (compRow + (comps.length ? 1 : 0)) * ROW);
  return { width, height, nodes, edges };
}

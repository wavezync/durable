// The CHANGELOG.md files are git-cliff output (see cliff.toml): a "## version - date"
// heading per release, "### Features"-style groups, and a commit link on every
// entry. This Sätteri plugin keeps the text and reshapes the markup into a release
// timeline (styled in styles/theme.css): a version heading with its date, a Latest
// or Pre-release badge and a compare link; colored groups; quiet commit chips.

const GROUPS: Record<string, string> = {
  Features: 'feat',
  'Bug fixes': 'fix',
  Performance: 'perf',
  Refactoring: 'refactor',
  Documentation: 'docs',
};
const COMMIT = /\/commit\/[0-9a-f]{7,40}$/;

type Node = { type: string; url?: string; value?: string; depth?: number; children?: Node[] };
type Ctx = {
  fileURL?: URL;
  data: Record<string, unknown>;
  textContent(node: Node): string;
  setProperty(node: Node, key: 'data', value: object): void;
  replaceNode(node: Node, next: object | object[]): void;
  removeNode(node: Node): void;
  parent(node: Node): { children: Node[] } | undefined;
  indexOf(node: Node): number | undefined;
};

const text = (value: string) => ({ type: 'text', value });
const el = (tag: string, className: string[], children: object[], props: Record<string, string> = {}) => ({
  type: 'changelog',
  data: { hName: tag, hProperties: { className, ...props } },
  children,
});
const inChangelog = (ctx: Ctx) => !!ctx.fileURL?.pathname.endsWith('/CHANGELOG.md');
const isCommit = (n?: Node) => n?.type === 'link' && COMMIT.test(n.url ?? '');
const day = (iso: string) =>
  new Date(`${iso}T00:00:00Z`).toLocaleDateString('en', { month: 'short', day: 'numeric', year: 'numeric', timeZone: 'UTC' });

// "[1.0.0](…/compare/durable-v0.1.0-rc...durable-v1.0.0) - 2026-10-21", "0.1.0-rc - 2026-06-24" or "Unreleased".
function release(node: Node, ctx: Ctx) {
  const [, version, date] = /^(.+?)(?: - (\d{4}-\d{2}-\d{2}))?$/.exec(ctx.textContent(node))!;
  const compare = node.children?.find((c) => c.type === 'link')?.url;
  const since = compare && /compare\/(.+?)\.\.\./.exec(compare)?.[1].split('-v').pop();
  // The first dated release on the page is the newest one.
  const latest = !!date && !ctx.data.sawRelease;
  if (date) ctx.data.sawRelease = true;

  const meta = [
    date ? el('time', ['cl-date'], [text(day(date))], { dateTime: date }) : el('span', ['cl-date'], [text('Not released yet')]),
    latest && el('span', ['cl-badge', 'cl-latest'], [text('Latest')]),
    version.includes('-') && el('span', ['cl-badge', 'cl-pre'], [text('Pre-release')]),
    since && { type: 'link', url: compare, data: { hProperties: { className: ['cl-compare'] } }, children: [text(`Changes since ${since}`)] },
  ].filter(Boolean) as object[];

  ctx.replaceNode(node, [
    { type: 'heading', depth: 2, data: { hProperties: { className: ['cl-version'] } }, children: [text(version)] },
    el('div', ['cl-meta'], meta),
  ]);
}

export const changelog = {
  name: 'changelog',
  heading(node: Node, ctx: Ctx) {
    if (!inChangelog(ctx)) return;
    if (node.depth === 2) return release(node, ctx);
    const kind = node.depth === 3 && GROUPS[ctx.textContent(node)];
    if (kind) ctx.setProperty(node, 'data', { hProperties: { className: ['cl-group', `cl-${kind}`] } });
  },
  link(node: Node, ctx: Ctx) {
    if (!inChangelog(ctx) || !isCommit(node)) return;
    const hash = ctx.textContent(node);
    ctx.setProperty(node, 'data', { hProperties: { className: ['cl-commit'], ariaLabel: `Commit ${hash} on GitHub` } });
  },
  // The chip replaces the parentheses around the commit link.
  text(node: Node, ctx: Ctx) {
    if (!inChangelog(ctx)) return;
    const kids = ctx.parent(node)?.children ?? [];
    const i = ctx.indexOf(node) ?? -1;
    const value = node.value ?? '';
    if (value.endsWith(' (') && isCommit(kids[i + 1])) ctx.replaceNode(node, text(value.slice(0, -1)));
    else if (value === ')' && isCommit(kids[i - 1])) ctx.removeNode(node);
  },
  strong(node: Node, ctx: Ctx) {
    if (inChangelog(ctx) && ctx.textContent(node) === 'Breaking:') {
      ctx.replaceNode(node, el('span', ['cl-badge', 'cl-breaking'], [text('Breaking')]));
    }
  },
};

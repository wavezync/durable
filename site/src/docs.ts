// The docs are the package markdown files themselves (the same ones HexDocs
// renders), read in place from the repo. This table is the only thing that
// knows about them: URL, sidebar label and group, in sidebar order.
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { glob, type Loader } from 'astro/loaders';

export const REPO = 'https://github.com/wavezync/durable';
// Astro runs from site/; import.meta.url would point into the build output.
const ROOT = resolve(process.cwd(), '..');

export const DOCS: { file: string; id: string; label: string; group: string; title?: string; description?: string }[] = [
  { file: 'durable/README.md', id: 'docs', label: 'Introduction', group: 'Start here', title: 'Getting started' },
  { file: 'durable/guides/waiting.md', id: 'docs/waiting', label: 'Waiting', group: 'Guides' },
  { file: 'durable/guides/branching.md', id: 'docs/branching', label: 'Branching', group: 'Guides' },
  { file: 'durable/guides/parallel.md', id: 'docs/parallel', label: 'Parallel', group: 'Guides' },
  { file: 'durable/guides/compensations.md', id: 'docs/compensations', label: 'Compensations', group: 'Guides' },
  { file: 'durable/guides/orchestration.md', id: 'docs/orchestration', label: 'Orchestration', group: 'Guides' },
  { file: 'durable/guides/ai_workflows.md', id: 'docs/ai-workflows', label: 'AI workflows', group: 'Guides' },
  { file: 'durable_dashboard/README.md', id: 'docs/dashboard', label: 'Dashboard', group: 'Dashboard', title: 'Durable Dashboard' },
  { file: 'durable/CHANGELOG.md', id: 'docs/changelog', label: 'durable', group: 'Changelog', description: 'Release history of durable, the workflow engine for Elixir: new features, fixes and breaking changes in every version on Hex.' },
  { file: 'durable_dashboard/CHANGELOG.md', id: 'docs/changelog/dashboard', label: 'durable_dashboard', group: 'Changelog', description: 'Release history of durable_dashboard, the Phoenix LiveView dashboard for Durable: new pages, fixes and changes in every version on Hex.' },
];

export const docHref = (id: string) => `/${id}/`;

// Pages that document a package get a header with its metadata (PackageHeader.astro),
// read from the package's own mix.exs and the shared metadata so it matches what's released.
const PACKAGE_PAGES: Record<string, string> = { docs: 'durable', 'docs/dashboard': 'durable_dashboard' };

export function packageMeta(id: string) {
  const name = PACKAGE_PAGES[id];
  if (!name) return null;
  const mix = readFileSync(join(ROOT, name, 'mix.exs'), 'utf8');
  const shared = readFileSync(join(ROOT, 'shared.exs'), 'utf8');
  const version = /@version "([^"]+)"/.exec(mix)![1];
  const [major, minor] = version.split('.');
  return {
    name,
    version,
    elixir: /elixir: "([^"]+)"/.exec(shared)![1],
    license: /licenses: \["([^"]+)"/.exec(shared)![1],
    dep: `{:${name}, "~> ${major}.${minor}"}`,
    hex: `https://hex.pm/packages/${name}`,
    hexdocs: `https://hexdocs.pm/${name}`,
    github: `${REPO}/tree/main/${name}`,
  };
}

const byFile = new Map(DOCS.map((d) => [d.file, d]));

// The files have no frontmatter. Starlight needs a title, so it comes from
// the H1; the first prose paragraph after it becomes the meta description.
function meta(path: string) {
  const doc = byFile.get(relative(ROOT, path))!;
  const src = readFileSync(path, 'utf8');
  const h1 = /^# (.+)$/m.exec(src)?.[1] ?? doc.label;
  const description = src
    .slice(src.indexOf(h1) + h1.length)
    .split('\n\n')
    .map((p) => p.trim().replace(/\s+/g, ' '))
    .find((p) => /^[A-Z]/.test(p))
    // Plain text for <meta>: keep link text, drop link targets, code ticks and bold markers.
    ?.replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')
    .replace(/`|\*\*/g, '');
  return {
    title: doc.title ?? (doc.group === 'Changelog' ? `${doc.label} changelog` : h1),
    description: doc.description ?? description,
    editUrl: `${REPO}/edit/main/${doc.file}`,
    // Release groups (Features, Bug fixes, …) repeat under every version; the outline lists versions only.
    ...(doc.group === 'Changelog' && { tableOfContents: { maxHeadingLevel: 2 } }),
  };
}

// Starlight's docs collection, fed from the package files instead of src/content/docs.
export function packageDocs(): Loader {
  const ids = new Map(DOCS.map((d) => [d.file, d.id]));
  const inner = glob({ base: ROOT, pattern: [...ids.keys()], generateId: ({ entry }) => ids.get(entry)! });
  return {
    name: 'package-docs',
    load: (ctx) =>
      inner.load({
        ...ctx,
        parseData: (entry) => ctx.parseData({ ...entry, data: { ...meta(resolve(entry.filePath!)), ...entry.data } }),
      }),
  };
}

// Public modules, so `Durable.Wait` in backticks links to HexDocs the way
// ExDoc autolinks it. Modules with `@moduledoc false` have no page there.
const MODULES = new Set<string>();
const lib = join(ROOT, 'durable/lib');
for (const f of readdirSync(lib, { recursive: true }) as string[]) {
  if (!f.endsWith('.ex')) continue;
  const src = readFileSync(join(lib, f), 'utf8');
  for (const m of src.matchAll(/defmodule ([\w.]+) do\n((?:.*\n){0,2})/g)) {
    if (!m[2].includes('@moduledoc false')) MODULES.add(m[1]);
  }
}

const REF = /^((?:Durable|Mix\.Tasks\.Durable)(?:\.[A-Z]\w*)*)(?:\.([a-z_]\w*[?!]?)\/(\d))?$/;

function hexdocs(code: string) {
  const m = REF.exec(code);
  if (!m || !MODULES.has(m[1])) return null;
  return `https://hexdocs.pm/durable/${m[1]}.html${m[2] ? `#${m[2]}/${m[3]}` : ''}`;
}

// Relative links point at files in the repo: other docs become site pages,
// anything else goes to GitHub.
function rewrite(url: string, from: string) {
  if (/^([a-z]+:|#|\/)/.test(url)) return url;
  const [path, hash] = url.split('#');
  const target = relative(ROOT, resolve(dirname(from), path));
  const doc = byFile.get(target);
  if (doc) return docHref(doc.id) + (hash ? `#${hash}` : '');
  return `${REPO}/blob/main/${target}${hash ? `#${hash}` : ''}`;
}

type Node = { type: string; url: string; value: string; depth: number; children?: Node[] };
type Ctx = {
  fileURL?: URL;
  setProperty(node: Node, key: 'url', value: string): void;
  replaceNode(node: Node, next: object): void;
  removeNode(node: Node): void;
  parent(node: Node): { type: string } | undefined;
  textContent(node: Node): string;
};
const relink = (node: Node, ctx: Ctx) => ctx.setProperty(node, 'url', rewrite(node.url, fileURLToPath(ctx.fileURL!)));

// A Sätteri mdast plugin (Astro 7's Markdown pipeline).
export const docLinks = {
  name: 'doc-links',
  link: relink,
  definition: relink,
  // Starlight renders the title (taken from this H1) itself.
  heading(node: Node, ctx: Ctx) {
    if (node.depth === 1) ctx.removeNode(node);
  },
  // The README's badge rows and its "Docs: … Dashboard: … API: …" line are for
  // GitHub and HexDocs readers; on the site, PackageHeader shows the same facts.
  paragraph(node: Node, ctx: Ctx) {
    const kids = node.children ?? [];
    const blank = (c: Node) => c.type === 'text' && !c.value.trim();
    const badge = (c: Node) => c.type === 'link' && !!c.children?.length && c.children.every((g) => g.type === 'image');
    const badges = kids.some(badge) && kids.every((c) => badge(c) || blank(c));
    const links = kids[0]?.type === 'strong' && ctx.textContent(kids[0]) === 'Docs:';
    if (badges || links) ctx.removeNode(node);
  },
  inlineCode(node: Node, ctx: Ctx) {
    const href = hexdocs(node.value);
    if (!href || ctx.parent(node)?.type === 'link') return;
    ctx.replaceNode(node, { type: 'link', url: href, children: [{ type: 'inlineCode', value: node.value }] });
  },
};

// First code block in `lang` (and the text before it) under a heading line such
// as "### Approval Workflow". Throws when the heading is gone, so a README edit
// can't silently empty a page.
export function section(body: string, heading: string, lang = 'elixir') {
  const start = body.indexOf(`\n${heading}\n`);
  if (start < 0) throw new Error(`README has no "${heading}" section`);
  const rest = body.slice(start + heading.length + 2);
  const end = rest.search(/\n##+ /);
  const text = end < 0 ? rest : rest.slice(0, end);
  const code = new RegExp('```' + lang + '\\n([\\s\\S]*?)```').exec(text)?.[1] ?? '';
  const intro = text.slice(0, text.indexOf('```')).trim();
  return { intro, code: code.trimEnd() };
}

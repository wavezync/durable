// llms.txt (https://llmstxt.org): the site's pages as a Markdown list for
// language models, built from the same tables as the sidebar and the examples.
import type { APIRoute } from 'astro';
import { getCollection, getEntry } from 'astro:content';
import { DOCS, REPO, docHref, packageMeta } from '../docs';
import { examples } from '../examples';

export const GET: APIRoute = async ({ site }) => {
  const url = (path: string) => new URL(path, site).href;
  const data = new Map((await getCollection('docs')).map((d) => [d.id, d.data]));
  const line = (title: string, href: string, about?: string) => `- [${title}](${url(href)})${about ? `: ${about}` : ''}`;
  const oneLine = (s?: string) => s?.replace(/\s+/g, ' ').trim();

  const groups = new Map<string, string[]>();
  for (const d of DOCS) {
    const group = d.group === 'Changelog' ? 'Optional' : d.group;
    const page = data.get(d.id)!;
    groups.set(group, [...(groups.get(group) ?? []), line(page.title, docHref(d.id), oneLine(page.description))]);
  }
  const optional = groups.get('Optional')!;
  groups.delete('Optional');

  const list = examples((await getEntry('docs', 'docs'))!.body!);
  groups.set('Examples', list.map((e) => line(e.heading, `/examples/${e.slug}/`, oneLine(e.intro))));

  const { dep } = packageMeta('docs')!;
  const body = [
    '# Durable',
    '> Resilient, reliable, resumable workflows for Elixir. An open-source workflow engine for Elixir apps and AI agents: retries, sleeps, approvals and sagas, saved step by step so runs resume after crashes.',
    `Durable is an Elixir library: add \`${dep}\` to your deps and start it in your supervision tree with your own Ecto repo. The docs pages are the package's own Markdown, the same files HexDocs renders.`,
    ...[...groups].map(([group, lines]) => `## ${group}\n\n${lines.join('\n')}`),
    [
      '## Optional',
      '',
      ...optional,
      `- [API reference](https://hexdocs.pm/durable): every module and function on HexDocs`,
      `- [Dashboard API reference](https://hexdocs.pm/durable_dashboard): the dashboard package on HexDocs`,
      `- [Source code](${REPO}): the durable and durable_dashboard packages on GitHub`,
      `- [Sitemap](${url('/sitemap-index.xml')}): every page on this site`,
    ].join('\n'),
  ].join('\n\n');

  return new Response(body + '\n', { headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
};

import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import { satteri } from '@astrojs/markdown-satteri';
import { DOCS, REPO, docLinks } from './src/docs.ts';
import { changelog } from './src/changelog.ts';
import { EXAMPLES } from './src/examples.ts';
import { macroCalls, night } from './src/code-theme.ts';

const doc = (d) => ({ label: d.label, slug: d.id });
const group = (name) => DOCS.filter((d) => d.group === name).map(doc);

export default defineConfig({
  site: 'https://durable.wavezync.com',
  trailingSlash: 'always',
  markdown: { processor: satteri({ mdastPlugins: [docLinks, changelog] }) },
  integrations: [
    starlight({
      title: 'Durable',
      description:
        'Open-source durable workflow engine for Elixir. Retries, sleeps, events, human approvals and sagas, saved step by step so runs resume after crashes.',
      logo: { src: './src/assets/logo.svg' },
      head: [
        { tag: 'meta', attrs: { property: 'og:image', content: 'https://durable.wavezync.com/og.png' } },
        { tag: 'meta', attrs: { property: 'og:image:width', content: '1200' } },
        { tag: 'meta', attrs: { property: 'og:image:height', content: '630' } },
        { tag: 'meta', attrs: { property: 'og:image:alt', content: 'Resilient, Reliable, Resumable workflows for Elixir' } },
        { tag: 'meta', attrs: { name: 'twitter:image', content: 'https://durable.wavezync.com/og.png' } },
      ],
      favicon: '/favicon.svg',
      social: [{ icon: 'github', label: 'GitHub', href: REPO }],
      customCss: ['./src/styles/fonts.css', './src/styles/theme.css'],
      components: {
        Head: './src/components/Head.astro',
        PageTitle: './src/components/PageTitle.astro',
        SocialIcons: './src/components/HeaderLinks.astro',
      },
      expressiveCode: {
        themes: [night, 'github-light'],
        shiki: { transformers: [macroCalls] },
        styleOverrides: { borderRadius: '12px', codeFontFamily: 'var(--sl-font-mono)', uiFontFamily: 'var(--sl-font)' },
      },
      sidebar: [
        { label: 'Start here', items: group('Start here') },
        { label: 'Guides', items: group('Guides') },
        { label: 'Examples', items: [{ label: 'All examples', link: '/examples/' }, ...EXAMPLES.map((e) => ({ label: e.heading, link: `/examples/${e.slug}/` }))] },
        { label: 'Dashboard', items: group('Dashboard') },
        { label: 'Changelog', items: group('Changelog') },
        {
          label: 'API reference',
          items: [
            { label: 'durable on HexDocs', link: 'https://hexdocs.pm/durable' },
            { label: 'durable_dashboard on HexDocs', link: 'https://hexdocs.pm/durable_dashboard' },
          ],
        },
      ],
    }),
  ],
});

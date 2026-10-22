// Code colors for the Night look. Used by the run simulator and as the dark
// Expressive Code theme in the docs.
import type { ShikiConfig } from '@astrojs/markdown-remark';

type ShikiTransformer = NonNullable<ShikiConfig['transformers']>[number];

const FG = '#cdd7ed';
const CALL = '#7cc4ff';

export const night = {
  name: 'durable-night',
  type: 'dark' as const,
  colors: { 'editor.background': '#0d1426', 'editor.foreground': FG },
  tokenColors: [
    { scope: ['comment', 'punctuation.definition.comment', 'comment.block.documentation'], settings: { foreground: '#677593', fontStyle: 'italic' } },
    { scope: ['keyword', 'storage', 'keyword.control', 'keyword.operator', 'punctuation.section.embedded'], settings: { foreground: '#ff86ad' } },
    { scope: ['punctuation', 'meta.module.elixir punctuation.separator'], settings: { foreground: '#8390ab' } },
    { scope: ['string', 'punctuation.definition.string'], settings: { foreground: '#b8e38a' } },
    { scope: ['string meta.embedded source'], settings: { foreground: FG } },
    { scope: ['constant.other.symbol', 'constant.other.symbol punctuation.definition.constant'], settings: { foreground: '#5fd4c4' } },
    { scope: ['constant.other.keywords', 'constant.other.keywords punctuation.definition.constant', 'variable.other.readwrite.module'], settings: { foreground: '#a9c1ff' } },
    { scope: ['constant.numeric', 'constant.language'], settings: { foreground: '#ff9e6b' } },
    { scope: ['entity.name.type', 'entity.other.inherited-class', 'variable.other.constant', 'support.type'], settings: { foreground: '#ffc27a' } },
    { scope: ['entity.name.function', 'support.function', 'variable.function'], settings: { foreground: CALL } },
    { scope: ['comment.wildcard'], settings: { foreground: '#8390ab', fontStyle: '' } },
  ],
};

// Elixir's grammar leaves calls without parentheses untagged, so Durable's DSL
// (`workflow "x" do`, `step :charge, ...`) would read like plain variables.
// Color a bare call at the start of a line as a call. Only touches Night tokens.
export const macroCalls: ShikiTransformer = {
  name: 'elixir-macro-calls',
  tokens(lines) {
    if (this.options.lang !== 'elixir') return;
    return lines.map((line) => {
      const m = /^(\s*)([a-z_]\w*[?!]?) (?=[:"'%{[@a-z])/.exec(line.map((t) => t.content).join(''));
      const t = line[0];
      if (!m || !t || t.color?.toLowerCase() !== FG || t.content.length < m[0].length - 1) return line;
      const [indent, word] = [m[1], m[2]];
      const rest = t.content.slice(indent.length + word.length);
      return [
        ...(indent ? [{ ...t, content: indent }] : []),
        { ...t, content: word, offset: t.offset + indent.length, color: CALL },
        ...(rest ? [{ ...t, content: rest, offset: t.offset + indent.length + word.length }] : []),
        ...line.slice(1),
      ];
    });
  },
};

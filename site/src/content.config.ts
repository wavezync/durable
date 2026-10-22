import { defineCollection } from 'astro:content';
import { docsSchema } from '@astrojs/starlight/schema';
import { packageDocs } from './docs';

export const collections = {
  docs: defineCollection({ loader: packageDocs(), schema: docsSchema() }),
};

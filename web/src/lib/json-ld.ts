import { SITE } from '../data/site';

export function webPageLd(name: string, description: string, path: string) {
  const url = `${SITE.url}${path}`;
  return {
    '@type': 'WebPage',
    '@id': `${url}#page`,
    name,
    description,
    url,
    inLanguage: 'en',
    isPartOf: { '@id': `${SITE.url}/#website` },
    about: { '@id': `${SITE.url}/#app` },
    breadcrumb: {
      '@type': 'BreadcrumbList',
      itemListElement: [
        { '@type': 'ListItem', position: 1, name: 'Hasala', item: SITE.url },
        { '@type': 'ListItem', position: 2, name, item: url },
      ],
    },
  };
}

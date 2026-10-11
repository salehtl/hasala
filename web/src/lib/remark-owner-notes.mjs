/**
 * The legal Markdown carries notes for the owner, written [[OWNER: ...]],
 * and placeholders like [OPERATOR LEGAL NAME]. While a page is a draft they
 * are shown as marked notes so reviewers can find them; this plugin turns
 * them into <mark> elements. (Pages with notes left must not be published:
 * the legal pages stay noindex while their status is "draft".)
 */
const NOTE = /\[\[OWNER:\s*([\s\S]*?)\]\]/g;
const PLACEHOLDER = /\[([A-Z][A-Z0-9 ,.'’&/()-]{3,})\]/g;

const escape = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

function transformText(value) {
  if (!NOTE.test(value) && !PLACEHOLDER.test(value)) return null;
  NOTE.lastIndex = 0;
  PLACEHOLDER.lastIndex = 0;
  const html = escape(value)
    .replace(NOTE, (_, note) => `<mark class="owner-note"><b>Owner:</b> ${note}</mark>`)
    .replace(PLACEHOLDER, (m) => `<mark class="placeholder">${m}</mark>`);
  return { type: 'html', value: html };
}

/**
 * A note can span several inline nodes: GFM turns an email address or URL
 * inside it into a link, which splits the text. Fold each such run (from the
 * text that opens "[[OWNER:" to the text that closes "]]") into one text node
 * first, so the whole note is marked. Links inside a note become plain text.
 */
function mergeSplitNotes(node) {
  const kids = node.children;
  for (let i = 0; i < kids.length; i++) {
    const start = kids[i];
    if (start.type !== 'text') continue;
    const open = start.value.lastIndexOf('[[OWNER:');
    if (open === -1 || start.value.indexOf(']]', open) !== -1) continue;
    let j = i + 1;
    while (j < kids.length && !(kids[j].type === 'text' && kids[j].value.includes(']]'))) j++;
    if (j >= kids.length) continue;
    const value = kids.slice(i, j + 1).map(textOf).join('');
    kids.splice(i, j - i + 1, { type: 'text', value });
  }
}

function walk(node) {
  if (!node.children) return;
  mergeSplitNotes(node);
  for (let i = 0; i < node.children.length; i++) {
    const child = node.children[i];
    if (child.type === 'text') {
      const replacement = transformText(child.value);
      if (replacement) node.children[i] = replacement;
    } else if (child.type !== 'code' && child.type !== 'inlineCode') {
      walk(child);
    }
  }
}

const slugify = (s) =>
  s
    .toLowerCase()
    .replace(/[^a-z0-9\s-]/g, '')
    .trim()
    .replace(/\s+/g, '-');
const textOf = (node) => (node.value ?? '') + (node.children ?? []).map(textOf).join('');

/** plainWords may also be a map of section slug -> summary: each one becomes an "In plain words" callout under its heading. */
function sectionCallouts(tree, plainWords) {
  if (!plainWords || typeof plainWords !== 'object') return;
  for (let i = tree.children.length - 1; i >= 0; i--) {
    const node = tree.children[i];
    if (node.type !== 'heading' || node.depth !== 2) continue;
    const summary = plainWords[slugify(textOf(node))];
    if (!summary) continue;
    tree.children.splice(i + 1, 0, {
      type: 'html',
      value: `<aside class="plain-words" aria-label="In plain words"><span class="plain-words__coin" aria-hidden="true"></span><div><p class="plain-words__title">In plain words</p><p>${escape(summary)}</p></div></aside>`,
    });
  }
}

export default function remarkOwnerNotes() {
  return (tree, file) => {
    walk(tree);
    sectionCallouts(tree, file.data?.astro?.frontmatter?.plainWords);
  };
}

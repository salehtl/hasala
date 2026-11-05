import { describe, expect, test } from 'bun:test';
import { FAQ, SITE } from './site';

const root = new URL('../../../', import.meta.url);
const read = (path: string) => Bun.file(new URL(path, root)).text();
const web = (path: string) => read(`web/src/${path}`);

describe('bank alerts come by email or text', () => {
  test('site facts name both ways in', () => {
    expect(SITE.description).toContain('text');
    expect(SITE.requirements).toContain('text');
    expect(SITE.requirements).toContain('personal Outlook');
  });

  test('the landing page and the invite page are not email only', async () => {
    for (const path of [
      'components/sections/Hero.astro',
      'components/sections/HowItWorks.astro',
      'components/sections/Banks.astro',
      'components/sections/Beta.astro',
      'components/Footer.astro',
      'pages/how-it-works.astro',
    ]) {
      expect(await web(path), path).toMatch(/\btexts?\b/);
    }
    const invite = await web('pages/i.astro');
    expect(invite).not.toContain('connect your email');
  });

  test('how it works and the FAQ explain bank texts', async () => {
    const page = await web('pages/how-it-works.astro');
    expect(page).toContain('id="texts"');
    expect(page).toContain('Shortcuts');
    const item = FAQ.find((f) => f.id === 'texts');
    expect(item).toBeDefined();
    expect(`${item!.short} ${item!.a}`).toContain('Shortcuts');
  });
});

describe('on-iPhone claims name Cloud suggestions', () => {
  test('Hero and the privacy points qualify the claim', async () => {
    expect(await web('components/sections/Hero.astro')).toContain('Cloud suggestions');
    expect(await web('components/sections/Privacy.astro')).toContain('Cloud suggestions');
  });
});

describe('the waitlist answer asks for the confirm tap', () => {
  test('the form and /joined say Check your email, not You are on the list', async () => {
    for (const path of ['components/WaitlistForm.astro', 'pages/joined.astro']) {
      const s = await web(path);
      expect(s, path).toContain('Check your email');
      expect(s, path).toContain('Confirm my email');
      expect(s, path).toContain('7 days');
      expect(s, path).not.toMatch(/You[’']re on the list\.<\/h/);
    }
  });
});

describe('the invite panel text reaches 4.5:1', () => {
  test('the pace wash starts at #3C62F0 and the panel text is solid white', async () => {
    const css = await web('styles/global.css');
    expect(css).toContain('--wash-pace: linear-gradient(in oklab 160deg, oklab(55.6% -0.01 -0.217) 0%');
    const beta = await web('components/sections/Beta.astro');
    expect(beta).toContain('background: rgb(20 38 89 / 24%)');
    expect(beta).not.toContain('rgb(255 255 255 / 88%)');
    expect(beta).not.toContain('rgb(255 255 255 / 92%)');
  });
});

describe('the invite steps agree', () => {
  test('the FAQ has the three steps', () => {
    const steps = FAQ.find((f) => f.id === 'testflight')!.steps!;
    expect(steps).toHaveLength(3);
    expect(steps[0]).toBe('Get TestFlight.');
    expect(steps[1]).toContain("Accept Apple's invitation and install Hasala");
    expect(steps[2]).toBe('Open Hasala and paste or type your invite.');
  });

  test('the invite page keeps Copy your invite first out of the numbered steps', async () => {
    const page = await web('pages/i.astro');
    const copyRow = page.indexOf('Copy your invite first');
    const list = page.indexOf('<ol class="isteps__list"');
    expect(copyRow).toBeGreaterThan(-1);
    expect(copyRow).toBeLessThan(list);
    expect(page).not.toContain('<span class="coin-badge">4</span>');
    expect(page).not.toContain('<span class="for-code">2</span>');
  });
});

describe('the legal pages match the app', () => {
  test('the export is named Export transactions', async () => {
    for (const path of ['docs/legal/support.md', 'docs/legal/terms.md', 'docs/legal/privacy.md']) {
      const s = await read(path);
      expect(s, path).not.toContain('Export your data');
      expect(s, path).toContain('Export transactions');
    }
  });

  test('the privacy policy describes removing a disconnected mailbox’s transactions', async () => {
    const s = await read('docs/legal/privacy.md');
    expect(s).toContain('Removing takes them out of your lists and totals.');
    expect(s).not.toContain('Transactions it has already brought in stay in Hasala, archived or not, until you delete your account.\n\n### Stopping Gmail');
  });
});

import { expect, test } from 'bun:test';

test('/testflight sends email readers to TestFlight on the App Store', async () => {
  const rules = (await Bun.file(new URL('../../public/_redirects', import.meta.url)).text())
    .split('\n')
    .filter((l) => l.trim() && !l.trim().startsWith('#'))
    .map((l) => l.trim().split(/\s+/));
  expect(rules).toContainEqual(['/testflight', 'https://apps.apple.com/app/testflight/id899247664', '302']);
});

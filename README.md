# Hasala · حصّالة

A private budgeting app for the UAE. Your bank alerts are read on your phone,
encrypted there, and synced as ciphertext — the server never sees your money.

Status: **QA / TestFlight beta.** See [CLAUDE.md](CLAUDE.md) for layout and
decisions.

## Website

The hasala.app website lives in [web/](web/) (Astro, built with Bun from the
Nix devShell): `bun install --frozen-lockfile`, then `bun run dev`, or
`bun run build` and `bun run preview`. The build checks the site's
Content-Security-Policy and JavaScript budget; CI also runs Lighthouse. Its
privacy policy, terms, security and support pages are drafts in
[docs/legal/](docs/legal/). Deploying is done by the owner only. See
[CLAUDE.md](CLAUDE.md), "Website".

## Licence

Hasala is source-available under the Functional Source License, Version 1.1,
ALv2 Future License (**FSL-1.1-ALv2**); see [LICENSE.md](LICENSE.md). Licensor:
Saleh Lootah. Software: Hasala. Each version becomes available under the Apache
License, Version 2.0 two years after it is released.

The name "Hasala", "حصّالة" and the Slot mark are not licensed; see
[TRADEMARKS.md](TRADEMARKS.md). Third-party notices are in [NOTICE](NOTICE) and
[LICENSES/](LICENSES/). Outside contributions are not accepted during the beta;
see [CONTRIBUTING.md](CONTRIBUTING.md). Report security issues to
security@hasala.app.

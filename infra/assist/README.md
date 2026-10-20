# hasala-assist

`hasala-assist` is a Cloudflare Worker. The iOS app calls it directly when the
user turns on cloud suggestions. The app sends one merchant name and the list
of the user's categories. The Worker asks the Workers AI model
`@cf/cloudflare/clef` which category fits, and returns the answer.

hasalad is not involved. The Worker does not know who calls it. It stores
nothing and it logs nothing.

## Contract

`POST /v1/category`

Request headers:

- `Hasala-Client: ios/<version>`, for example `ios/1.4.0`. The version is one
  to four groups of one to four digits, separated by dots. If it is missing or
  malformed, the answer is 400.
- `Content-Type: application/json` (`; charset=utf-8` is accepted).

The body is at most 8 KiB (8192 bytes). A larger body gets 413.

```json
{
  "subject": "CAFE EXAMPLE JBR",
  "categories": [
    { "id": "groceries", "name": "Groceries", "hint": "supermarkets and grocery stores" },
    { "id": "dining", "name": "Dining", "hint": null }
  ]
}
```

- No other fields are allowed, at the top level or in a category.
- `subject`: the Worker removes U+0000 to U+001F and U+007F, then trims. The
  result must have 1 to 128 Unicode scalars.
- `categories`: 1 to 32 entries.
  - `id`: matches `^[a-z][a-z0-9_]{0,31}$`, unique, and not `unknown`.
  - `name`: 1 to 64 scalars.
  - `hint`: `null` or 1 to 200 scalars. A missing `hint` is the same as
    `null`.
  - `name` and `hint` get the same clean-up as `subject` before the length
    check.
- A string with a lone UTF-16 surrogate, or a body that is not valid UTF-8,
  gets 400.

The Worker calls `env.AI.run("@cf/cloudflare/clef", body)` once and waits for
the answer. It does not use the queue, batches or AI Gateway. The body:

```json
{
  "model": "clef",
  "state": "The merchant name on a card payment from a bank in the United Arab Emirates: \"CAFE EXAMPLE JBR\"",
  "questions": {
    "category": {
      "type": "choice",
      "instructions": "Which spending category does a payment to this merchant belong to?",
      "criteria": {
        "groceries": "supermarkets and grocery stores",
        "dining": "Dining",
        "unknown": "the name alone does not say what kind of business this is"
      }
    }
  }
}
```

Each criterion is the category's `hint`, or its `name` when `hint` is `null`.

The 200 answer:

```json
{ "tag": "cf-clef/1", "choice": "dining", "probabilities": { "groceries": 0.0095, "dining": 0.9725, "unknown": 0.012 } }
```

- `choice` is one of the request ids, or `unknown`.
- `probabilities` has only request ids and `unknown`, in request order, then
  `unknown`. The Worker drops all other keys, and each value that is not a
  number from 0 to 1.
- The Worker reads `answers.category` from the model result, or from a
  `result` wrapper around it.

Errors are `{"error": "<code>"}`:

| Status | Code | When |
| --- | --- | --- |
| 400 | `bad_request` | A bad header, content type, JSON or field. |
| 403 | `client_refused` | The client is in `REFUSED_CLIENTS`. |
| 404 | `not_found` | Any other path. |
| 405 | `method_not_allowed` | A method other than POST on `/v1/category` (with `Allow: POST`). |
| 413 | `too_large` | The body is larger than 8 KiB. |
| 429 | `rate_limited` | The global limit or the per-IP limit, or a limiter error. |
| 502 | `bad_model_answer` | The model answer has no category, a `choice` outside the request, or no `probabilities`. |
| 503 | `model_unavailable` | The AI call threw. |

The checks occur in this sequence: path, method, `Hasala-Client`,
`REFUSED_CLIENTS`, content type, size, body, `GLOBAL`, `PER_IP`, the model.
Only a valid request uses a rate-limit token.

Each response has `cache-control: no-store` and
`content-type: application/json`. There are no CORS headers.

`REFUSED_CLIENTS` is a comma-separated list of exact `ios/<version>` values.
It is empty by default. Use it to stop a build that sends bad requests.

## No storage, no logging

`wrangler.jsonc` has only these bindings: `AI`, the rate limiters `PER_IP`
(30 per 60 s, key `cf-connecting-ip`) and `GLOBAL` (600 per 60 s, key
`global`), and the variable `REFUSED_CLIENTS`. The limits apply per Cloudflare
location. The Worker never logs or returns the IP address.

Observability and Logpush are off. `workers.dev` and preview URLs are off.

`test/fence.test.ts` fails when:

- `wrangler.jsonc` has KV, D1, R2, Durable Objects, Queues, Vectorize,
  Analytics Engine, service bindings, tail consumers, Hyperdrive, Workflows,
  an `env` override, or any other binding.
- `logpush` is not `false`, or `observability.enabled` is not `false`.
- `gateway` occurs in `wrangler.jsonc` or in `src/`.
- `src/` has a `console.` call, `queueRequest`, `batch`, an outbound `fetch`,
  or the Cache API.

## Tests

From this directory, in the devShell:

```sh
bun install --frozen-lockfile
bun run --bun typecheck
bun test
```

`scripts/check.sh` runs the same steps. The tests use a fake `env.AI` and
fake rate limiters. They do not use the network.

## Deployment (owner only)

Before the first deployment:

1. Make sure no other rate-limiting binding in the account uses the
   `namespace_id` values in `wrangler.jsonc` (41201 and 41202).
2. `wrangler deploy` makes `assist.hasala.app` a custom domain of the Worker,
   with its DNS record, because the route has `custom_domain: true`. The token
   must have Workers Scripts edit and Workers Routes edit on `hasala.app`.
3. Confirm the Workers AI data-usage terms for Clef in the dashboard. Do this
   before a tester who is not a developer uses cloud suggestions.

Deploy from the devShell. `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`
come from the environment. Do not put them in a file in this repository.

```sh
bun install --frozen-lockfile
bun run deploy
```

`bun run deploy` runs the typecheck and the tests first, then the pinned
wrangler. `bunx wrangler deploy` gives the same deployment without the tests.

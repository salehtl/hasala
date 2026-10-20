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

The Worker calls `env.AI.run("@cf/cloudflare/clef", body, options)` once and
waits for the answer. It does not use the queue or batches. `options` is always
`{ gateway: { id: <AI_GATEWAY>, skipCache: true, collectLog: false } }`: the
call goes through the AI Gateway named by the `AI_GATEWAY` variable, with its
cache and its log off for this request (refer to "Spend cap" below). The body:

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

The subject goes into `state` as a JSON string, so a `"` or a `\` in it is
escaped.

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
| 503 | `model_unavailable` | The AI call threw (also when the gateway refuses it because the spend limit is reached), or `AI_GATEWAY` is empty. |

The checks occur in this sequence: path, method, `Hasala-Client`,
`REFUSED_CLIENTS`, content type, size, body, `PER_IP`, `GLOBAL`, `AI_GATEWAY`,
the model.
Only a valid request uses a rate-limit token. A request that `PER_IP` refuses
does not use a `GLOBAL` token.

Each response has `cache-control: no-store` and
`content-type: application/json`. There are no CORS headers.

`REFUSED_CLIENTS` is a comma-separated list of exact `ios/<version>` values.
It is empty by default. Use it to stop a build that sends bad requests.

## No storage, no logging

`wrangler.jsonc` has only these bindings: `AI`, the rate limiters `PER_IP`
(30 per 60 s, keyed on the `cf-connecting-ip` address for IPv4 and on its
/64 for IPv6) and `GLOBAL` (60 per 60 s, key
`global`), and the variables `REFUSED_CLIENTS` and `AI_GATEWAY`. The limits
apply per Cloudflare location. The Worker never logs or returns the IP address.

Observability and Logpush are off. `workers.dev` and preview URLs are off.

`test/fence.test.ts` fails when:

- `wrangler.jsonc` has KV, D1, R2, Durable Objects, Queues, Vectorize,
  Analytics Engine, service bindings, tail consumers, Hyperdrive, Workflows,
  an `env` override, or any other binding.
- `logpush` is not `false`, or `observability.enabled` is not `false`.
- `gateway` occurs in `wrangler.jsonc` other than in the variable
  `"AI_GATEWAY": "hasala-assist"`.
- `gateway` occurs in `src/` other than in the exact allowed lines: the
  `AI_GATEWAY` variable, the empty-id check and the options
  `{ gateway: { id: gatewayId, skipCache: true, collectLog: false } }`.
- `src/` has `cacheTtl`, `cacheKey`, `metadata`, `eventId`, a `cf-aig-` header,
  `collectLog: true`, `skipCache: false` or the gateway id `"default"`.
- `src/` has a `console.` call, `queueRequest`, `batch`, an outbound `fetch`,
  or the Cache API.

## Spend cap

The rate limits count per Cloudflare location, so they do not cap the total
cost. The cap is the AI Gateway `hasala-assist` (`AI_GATEWAY`): a spend limit
on that gateway makes it refuse each request until the window resets. The
binding then throws, and the Worker answers 503 `model_unavailable`. The app
treats 503 as busy and stops the cloud stage of that sweep. The cap is
account-wide and fails closed. It is an estimate from token counts, and a burst
of concurrent requests can go a little over it.

The gateway is allowed only with its logs off and its cache off:

- Each request sends `collectLog: false` and `skipCache: true`. The request
  value has priority over the gateway setting, thus a gateway with logs on
  still keeps no log of these requests.
- The gateway setting is also off (refer to "Deployment"), so that nothing
  else that uses the gateway keeps a log.
- Do not use the gateway id `default`. Cloudflare makes that gateway on the
  first request, with logs on.

The gateway analytics keep counts, tokens, cost and errors for each model. They
do not keep the merchant name, the categories or the answer.

## Emergency stop

When spend spikes, remove the `assist.hasala.app` custom domain (or route) from
the `hasala-assist` Worker in the Cloudflare dashboard (Workers & Pages >
`hasala-assist` > Settings > Domains & Routes). Every request then fails, and
the phones fall back to Apple's model or to review, so no rows are lost. To
restore the service, add the custom domain again, or run `bun run deploy`.

`REFUSED_CLIENTS` does not stop abuse. It only stops an honest build that sends
bad requests, because any caller can forge the `Hasala-Client` header.

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
4. Make the AI Gateway before the deployment. Without it, each model call
   fails and the Worker answers 503.
   1. In the dashboard: AI > AI Gateway > Create gateway. Name it
      `hasala-assist` (the value of `AI_GATEWAY`).
   2. In its Settings: turn off Logs (collect logs), turn off Cache, and keep
      Authenticated Gateway off (the Worker binding needs no token).
   3. In its Settings: set Workers AI billing to Unified billing, so that spend
      limits count Workers AI requests.
   4. In Settings > Spend limits: add one rule with no dimensions (all
      traffic), for example $5 per day, fixed window. Spend limits count only
      models with known pricing: after the deployment, send one request and
      confirm that the gateway analytics show a cost for
      `@cf/cloudflare/clef`. To test the cap, set the limit to $0.01, send
      requests until the Worker answers 503, then set it back.
   5. Optional: keep the Workers AI billing alert as a second warning.

Deploy from the devShell. `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`
come from the environment. Do not put them in a file in this repository.

```sh
bun install --frozen-lockfile
bun run deploy
```

`bun run deploy` runs the typecheck and the tests first, then the pinned
wrangler. `bunx wrangler deploy` gives the same deployment without the tests.

# Suite API caller prototype

Question: does one catalog work naturally for reactive pages and imperative work across
Suite, Drive, and Mail, with the chosen error and cache behavior?

This is throwaway code. It is not a production client implementation.

## Open

Double-click `demo.html`. It contains the installed Vue runtime and needs no server or
network access. Use the caller-code tabs, free-play buttons, or guided walkthroughs.

To rebuild after editing, run from the repository root with its dependencies available:

```sh
node frontend/src/platform/server-state/suiteApi.prototype/build.mjs
```

The build checks `model.ts` and `callers.ts`, then emits the single HTML file. The alias
`@/api` exists only in this prototype's TypeScript config.

## Caller convention

```ts
import { api, client, useMutation, useQuery } from '@/api'

const account = useQuery(api.suite.account.get)
const inbox = useQuery(api.mail.inbox.summary)
const file = useQuery(api.drive.nodes.get, () => ({ node: selected.value }))
const rename = useMutation(api.drive.nodes.rename)
await rename.run({ node, title })

await client.query(api.suite.people.list, { q: text })
await client.mutation(api.drive.nodes.rename, { node, title })
```

`callers.ts` also covers a disabled read, Drive lists and link unlock, settings, cursor
pages, and a transfer. Inputs and outputs come from the existing generated contracts.
References and their executable mocks are fixture bindings; production references would
be generated and policies registered by their owners.

## Observed behavior

Checked in the shared browser on 2026-10-06:

- Refused rename showed the optimistic title and pending state, then rolled back, set
  the error, and rejected the promise. Code after the awaited call did not run.
- Successful rename updated the mock server and triggered the active file read.
- Cached people remained at v1 after the server changed to v2, without a request.
  A default imperative read returned v2. Two concurrent reads added one request.
- Disabling the file read detached its observer. Re-enabling displayed cached data
  and added one revalidation request. Disposal removed it; an imperative rename then
  added only the write request.
- Two cursor fetches appended both rows and exhausted the cursor. The simulated
  upload reached 100% through one caller method.
- The freshness guided walkthrough completed each step and offered a restart.
- Strict compilation accepted the valid callers and rejected all seven deliberately
  invalid call shapes: wrong operation kinds, missing/wrong inputs, an ordinary mutation
  passed to upload, and a mutation with no cache-policy declaration.

## Limits

Only the caller interface and these controlled behaviors were checked. No Frappe site
was contacted. Access-scope traces and link tickets are simulated. Real permission,
share-link scope, request headers, transport validation, error classification, realtime,
retry, cancellation, overlapping optimistic writes, eviction, and bundle cost are not
implemented or verified.

Visit and settings fixtures declare no effects because their dependent queries are absent
from this demo. This is not a recommendation for their production policies. The upload
fixture demonstrates progress and caller shape, not the actual create/chunk/finish protocol.

The prototype directly imports generated types across owners to keep it self-contained.
Production must follow the catalog ownership and import-boundary decisions in the map.
Only the prototype's types/build and browser behavior were checked; this is not evidence
that the full application's checks pass. Production source files were not changed.

The verdict is pending Faris's review of the caller convention.

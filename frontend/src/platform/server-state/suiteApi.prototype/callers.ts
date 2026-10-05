/** Compile-only caller examples. The alias points at the isolated prototype. */
import { ref } from 'vue'

import {
  api,
  client,
  defineMutation,
  useInfiniteQuery,
  useMutation,
  useQuery,
  useUpload,
} from '@/api'

export function useCrossProductExamples() {
  const selected = ref<string | null>(null)
  const account = useQuery(api.suite.account.get)
  const inbox = useQuery(api.mail.inbox.summary)
  const people = useInfiniteQuery(api.suite.people.list, { q: 'a' })
  const files = useInfiniteQuery(api.drive.views.list, { view: 'home' })
  const node = useQuery(api.drive.nodes.get, () =>
    selected.value ? { node: selected.value } : false,
  )
  const rename = useMutation(api.drive.nodes.rename)
  const saveSettings = useMutation(api.drive.settings.save)
  const upload = useUpload(api.drive.uploads.transfer)
  const unlockLink = useMutation(api.drive.links.unlock)
  return { selected, account, inbox, people, files, node, rename, saveSettings, unlockLink, upload }
}

export async function imperativeExamples(file: Blob) {
  const matches = await client.query(api.suite.people.list, { q: 'a' })
  const cached = await client.query(api.suite.people.list, { q: 'a' }, { cache: 'prefer' })
  const renamed = await client.mutation(api.drive.nodes.rename, {
    node: 'budget',
    title: 'Forecast.xlsx',
  })
  await client.mutation(api.drive.nodes.visit, { node: renamed.name })
  const upload = useUpload(api.drive.uploads.transfer)
  const uploaded = await upload.run({ parent_node: 'root', file })
  return { matches, cached, uploaded }
}

// These invalid callers must remain type errors as the sketch evolves.
function rejectedCallShapes() {
  // @ts-expect-error A mutation is not a query.
  useQuery(api.drive.nodes.rename, { node: 'budget', title: 'New.xlsx' })
  // @ts-expect-error A query is not a mutation.
  useMutation(api.mail.inbox.summary)
  // @ts-expect-error Required node arguments cannot be omitted.
  useQuery(api.drive.nodes.get)
  // @ts-expect-error Arguments are inferred from the generated server contract.
  client.query(api.drive.nodes.get, { node: 123 })
  // @ts-expect-error A required mutation field cannot be omitted.
  client.mutation(api.drive.nodes.rename, { node: 'budget' })
  // @ts-expect-error Transfer helpers reject ordinary mutations.
  useUpload(api.drive.nodes.rename)
  // @ts-expect-error Each mutation declares effects or explicitly none.
  defineMutation('missing_policy', async (_input: { value: string }) => ({}))
}
void rejectedCallShapes

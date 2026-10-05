/** Throwaway caller prototype. Real Vue observers, in-memory endpoint fixtures. */
import type {
  LinkUnlockInput,
  LinkUnlockOutput,
  NodeGetInput,
  NodeGetOutput,
  NodePatchRenameInput,
  NodeVisitInput,
  NodeVisitOutput,
  SettingsPatchInput,
  SettingsPatchOutput,
  ViewListInput,
  ViewListOutput,
} from '../../../apps/drive/client/generated'
import type { InboxSummaryOutput } from '../../../apps/mail/client/generated'
import type { AccountGetOutput, PeopleGetInput, PeopleGetOutput } from '../../transport/generated'

declare const Vue: typeof import('vue')
const { shallowRef, shallowReactive, watch, toValue, getCurrentScope, onScopeDispose } = Vue
type Source<I> = import('vue').MaybeRefOrGetter<I | false>
type ReadArgs<I> = {} extends I
  ? [input?: NoInfer<I>, options?: ReadOptions]
  : [input: NoInfer<I>, options?: ReadOptions]
type ObserveArgs<I> = {} extends I ? [source?: Source<NoInfer<I>>] : [source: Source<NoInfer<I>>]
interface ReadOptions {
  cache?: 'prefer' | 'fresh'
}
interface MockContext {
  progress(value: number): void
}
interface Reference<K, I, O> {
  kind: K
  id: string
  mock(input: I, context: MockContext): Promise<O>
}
interface Effects<I, O> {
  optimistic?(input: I): () => void
  committed(input: I, output: O): void
}
type Query<I, O> = Reference<'query', I, O>
type Mutation<I, O> = Reference<'mutation', I, O> & { effects: Effects<I, O> | 'none' }
type Transfer<I, O> = Mutation<I, O> & { transfer: true }
interface Entry<O> {
  id: string
  data: import('vue').ShallowRef<O | undefined>
  error: import('vue').ShallowRef<Error | null>
  pending: import('vue').ShallowRef<boolean>
  observers: number
  inflight: Promise<O> | null
  fetch(): Promise<O>
}

export class ApiError extends Error {
  constructor(
    readonly type: string,
    message: string,
  ) {
    super(message)
  }
}

export const server = shallowReactive({
  title: 'Budget.xlsx',
  unread: 3,
  peopleVersion: 1,
  visits: 0,
  requests: 0,
  events: [] as string[],
})
const log = (message: string) => server.events.unshift(message)
const wait = (ms = 160) => new Promise<void>((resolve) => setTimeout(resolve, ms))
const mockNode = (): NodeGetOutput => ({
  name: 'budget',
  title: server.title,
  kind: 'file',
  parent_node: 'root',
  root: 'root',
  state: 'Active',
  trash_root: null,
  size: 1024,
  mime: 'application/xlsx',
  url: null,
  content_doctype: null,
  content_docname: null,
  is_template: 0,
  owner: { id: 'faris', full_name: 'Faris', user_image: null },
  creation: null,
  modified: String(server.requests),
  content_modified: null,
  access: { role: 30 },
})

export function defineMutation<I, O>(
  id: string,
  mock: Mutation<I, O>['mock'],
  effects: Mutation<I, O>['effects'],
): Mutation<I, O> {
  return { id, kind: 'mutation', mock, effects }
}
function read<I, O>(id: string, mock: Query<I, O>['mock']): Query<I, O> {
  return { id, kind: 'query', mock }
}
const nodeRead = read<NodeGetInput, NodeGetOutput>('drive.node_get', async () => {
  await wait()
  log('Simulated Drive access scope for read')
  return mockNode()
})

export const api = {
  suite: {
    account: {
      get: read<Record<string, never>, AccountGetOutput>('suite.account_get', async () => {
        await wait()
        return {
          name: 'faris',
          email: 'faris@example.test',
          full_name: 'Faris',
          avatar: null,
          roles: { system_manager: false },
          is_jmap_configured: true,
        }
      }),
    },
    people: {
      list: read<PeopleGetInput, PeopleGetOutput>('suite.people_get', async (input) => {
        await wait()
        const second = input.cursor === 'next'
        return {
          rows: [
            {
              kind: 'user',
              name: second ? 'b' : 'a',
              email: second ? 'b@example.test' : 'a@example.test',
              full_name: `${second ? 'Ben' : 'Aisha'} v${server.peopleVersion}`,
              user_image: null,
            },
          ],
          next_cursor: second ? null : 'next',
        }
      }),
    },
  },
  mail: {
    inbox: {
      summary: read<Record<string, never>, InboxSummaryOutput>('mail.inbox_summary', async () => {
        await wait()
        return { unread: server.unread }
      }),
    },
  },
  drive: {
    views: {
      list: read<ViewListInput, ViewListOutput>('drive.view_list', async () => {
        await wait()
        return { rows: [mockNode()], next_cursor: null }
      }),
    },
    links: {
      unlock: defineMutation<LinkUnlockInput, LinkUnlockOutput>(
        'drive.link_unlock',
        async () => {
          await wait()
          log('Simulated link unlock: owner would retain the access ticket')
          return { ticket: 'demo-ticket', expires: 3600 }
        },
        'none',
      ),
    },
    nodes: {
      get: nodeRead,
      rename: defineMutation<NodePatchRenameInput, NodeGetOutput>(
        'drive.node_patch.rename',
        async ({ title }) => {
          await wait(650)
          if (title === 'REFUSED')
            throw new ApiError('DriveForbidden', 'You cannot rename this file.')
          server.title = title
          log('Simulated Drive access scope for write')
          return mockNode()
        },
        {
          optimistic: ({ node, title }) =>
            client.patch(nodeRead, { node }, (value) => ({ ...value, title })),
          committed: () => client.invalidate('drive.node_get'),
        },
      ),
      visit: defineMutation<NodeVisitInput, NodeVisitOutput>(
        'drive.node_visit',
        async () => {
          await wait()
          server.visits++
          return { count: 1 }
        },
        'none',
      ),
    },
    settings: {
      save: defineMutation<SettingsPatchInput, SettingsPatchOutput>(
        'drive.settings_patch',
        async (input) => {
          await wait()
          return { ...input, writer_settings: {} }
        },
        'none',
      ),
    },
    uploads: {
      transfer: {
        ...defineMutation<{ parent_node: string; file: Blob }, NodeGetOutput>(
          'drive.upload_transfer',
          async (_input, context) => {
            log('Owner transfer workflow: create upload')
            for (const progress of [25, 50, 75, 100]) {
              await wait(120)
              context.progress(progress)
              log(`Owner transfer workflow: ${progress}%`)
            }
            log('Owner transfer workflow: finish upload')
            return mockNode()
          },
          { committed: () => client.invalidate('drive.node_get') },
        ),
        transfer: true as const,
      },
    },
  },
}

class Client {
  private entries = new Map<string, Entry<unknown>>()
  private record<I, O>(reference: Query<I, O>, input: I): Entry<O> {
    const key = reference.id + JSON.stringify(input)
    const existing = this.entries.get(key)
    // The same reference and arguments always have the same output type.
    if (existing) return existing as Entry<O>
    const entry: Entry<O> = {
      id: reference.id,
      data: shallowRef<O>(),
      error: shallowRef<Error | null>(null),
      pending: shallowRef(false),
      observers: 0,
      inflight: null,
      fetch: () => {
        if (entry.inflight) {
          log(`Joined read: ${reference.id}`)
          return entry.inflight
        }
        entry.pending.value = true
        entry.error.value = null
        server.requests++
        log(`Server read: ${reference.id}`)
        entry.inflight = reference
          .mock(input, { progress() {} })
          .then(
            (output) => {
              entry.data.value = output
              return output
            },
            (error: unknown) => {
              entry.error.value = error instanceof Error ? error : new Error(String(error))
              throw error
            },
          )
          .finally(() => {
            entry.pending.value = false
            entry.inflight = null
          })
        return entry.inflight
      },
    }
    this.entries.set(key, entry)
    return entry
  }
  query<I, O>(reference: Query<I, O>, ...args: ReadArgs<I>): Promise<O> {
    const entry = this.record(reference, args[0] ?? ({} as I))
    if (args[1]?.cache === 'prefer' && entry.data.value !== undefined) {
      log(`Cached read: ${reference.id}`)
      return Promise.resolve(entry.data.value)
    }
    return entry.fetch()
  }
  observe<I, O>(reference: Query<I, O>, ...args: ObserveArgs<I>) {
    let current: Entry<O> | null = null
    const active = shallowRef<Entry<O> | null>(null)
    const detach = () => {
      if (current) current.observers--
      current = null
      active.value = null
    }
    const stop = watch(
      () => toValue(args[0] ?? ({} as I)),
      (input) => {
        if (input === false) {
          detach()
          return
        }
        const entry = this.record(reference, input)
        if (entry === current) return
        detach()
        current = entry
        entry.observers++
        active.value = entry
        void entry.fetch().catch(() => {})
      },
      { immediate: true, deep: true },
    )
    if (getCurrentScope())
      onScopeDispose(() => {
        stop()
        detach()
        log(`Disposed observer: ${reference.id}`)
      })
    return shallowReactive({
      get data() {
        return active.value?.data.value
      },
      get error() {
        return active.value?.error.value ?? null
      },
      get isFetching() {
        return active.value?.pending.value ?? false
      },
      async refetch() {
        return current?.fetch()
      },
    })
  }
  async mutation<I, O>(
    reference: Mutation<I, O>,
    input: NoInfer<I>,
    context: MockContext = { progress() {} },
  ): Promise<O> {
    const effects = reference.effects
    if (!effects) throw new TypeError('Mutation policy is missing')
    const rollback = effects === 'none' ? undefined : effects.optimistic?.(input)
    server.requests++
    log(`Server write: ${reference.id}`)
    try {
      const output = await reference.mock(input, context)
      if (effects !== 'none') effects.committed(input, output)
      return output
    } catch (error) {
      rollback?.()
      throw error
    }
  }
  patch<I, O>(reference: Query<I, O>, input: I, change: (value: O) => O): () => void {
    const entry = this.record(reference, input),
      snapshot = entry.data.value
    if (snapshot !== undefined) entry.data.value = change(snapshot)
    log('Optimistic change applied')
    return () => {
      entry.data.value = snapshot
      log('Optimistic change rolled back')
    }
  }
  invalidate(id: string) {
    for (const entry of this.entries.values())
      if (entry.id === id && entry.observers) void entry.fetch().catch(() => {})
  }
  observerCount() {
    return [...this.entries.values()].reduce((count, entry) => count + entry.observers, 0)
  }
}

export const client = new Client()
export function useQuery<I, O>(reference: Query<I, O>, ...args: ObserveArgs<I>) {
  return client.observe(reference, ...args)
}
export function useMutation<I, O>(reference: Mutation<I, O>) {
  const state = shallowReactive({
    isPending: false,
    error: null as Error | null,
    progress: null as number | null,
  })
  return Object.assign(state, {
    async run(input: NoInfer<I>): Promise<O> {
      state.isPending = true
      state.error = null
      try {
        return await client.mutation(reference, input, {
          progress(value) {
            state.progress = value
          },
        })
      } catch (error) {
        state.error = error instanceof Error ? error : new Error(String(error))
        throw error
      } finally {
        state.isPending = false
      }
    },
  })
}
export function useUpload<I, O>(reference: Transfer<I, O>) {
  return useMutation(reference)
}
export function useInfiniteQuery<
  I extends { cursor?: string },
  O extends { rows: unknown[]; next_cursor: string | null },
>(reference: Query<I, O>, input: I) {
  const state = shallowReactive({ rows: [] as O['rows'], hasNext: true, isFetching: false })
  let cursor: string | undefined
  return Object.assign(state, {
    async fetchNext() {
      if (!state.hasNext) return
      state.isFetching = true
      try {
        const page = await client.query(reference, { ...input, cursor })
        state.rows = [...state.rows, ...page.rows]
        cursor = page.next_cursor ?? undefined
        state.hasNext = page.next_cursor !== null
      } finally {
        state.isFetching = false
      }
    },
  })
}

Object.assign(globalThis, {
  suiteApiPrototype: {
    api,
    client,
    server,
    useQuery,
    useMutation,
    useUpload,
    useInfiniteQuery,
    Vue,
  },
})

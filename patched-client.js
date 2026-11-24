// 这个 chunk 可能在同一页面里被执行两次（插件改名后新旧包并存、或热更新重复注入），
// 第二次注册会让 client-modules 抛 duplicate factory registration，进而让整个 web 启动失败。
// 用一个页面级标记保证工厂只注册一次。
// ---------------------------------------------------------------------
// [patch:jump-to-latest] 本文件是外挂补丁版：右键打开工程时优先续接该工程
// 会话组内最近一条会话（而不是每次新建）。补丁的存档与重放脚本在
// github.com/voidobserve/dsh-explorer-open-patch 仓库里：插件或 DSH 升级后
// 运行其中的 apply-patch.ps1 即可重新打上；install-plugin.ps1 负责升级并自动重打。
// ---------------------------------------------------------------------
if (!window.__dshExplorerOpenClientRegistered) {
  window.__dshExplorerOpenClientRegistered = true
  window.__ModuleLoader__.load({
    // 这个 id 必须与 npm 包名完全一致：dsh 的 client-modules 加载完 chunk 后会按包名
    // 查找注册记录，对不上就报 "loaded without registering ... via __ModuleLoader__.load"，
    // 并把整个 web 启动判为失败。
    id: '@reed-io/dsh-explorer-open',
    factory(require) {
      const REQUEST_URL = '/api/plugins/dsh-explorer-open/request'
      const ACK_URL = '/api/plugins/dsh-explorer-open/ack'
      // 自定义请求头：跨站页面无法在不触发预检的情况下带上它，
      // 可以挡住别的网页偷偷 GET 掉排队中的请求。
      const REQUEST_HEADER = 'x-dsh-explorer-open'
      const POLL_MS = 1000

      return {
        inject: ['uiWorkspace', 'sessions', 'workspaces'],
        apply(ctx) {
          const log = (message, error) => {
            if (error === undefined) console.info(`[dsh-explorer-open] ${message}`)
            else console.warn(`[dsh-explorer-open] ${message}`, error)
          }

          /** 把处理进度回报给宿主（写 trace.log），失败不影响主流程。 */
          function ack(stage, detail) {
            try {
              const url = `${ACK_URL}?stage=${encodeURIComponent(stage)}&detail=${encodeURIComponent(detail ?? '')}`
              void fetch(url, { cache: 'no-store', headers: { [REQUEST_HEADER]: '1' } })
            } catch {
              // 忽略
            }
          }

          /**
           * 打开工作区（已存在则复用）；优先续接组内最近一条会话，没有可续接的才新建。
           * [patch:jump-to-latest]
           */
          async function handle(folder, file) {
            // create 对同一路径是幂等的：有就返回已有的，没有才新建
            const workspace = await ctx.workspaces.create({ path: folder })
            const workspaceId = workspace.workspaceId

            // [patch:jump-to-latest] 先找组内最近会话；任何异常都退回原"新建"逻辑，
            // 保证右键链路永不因本补丁中断。
            let sessionId
            let resumed = false      // 打开的是一条已有的非空会话
            let preexisting = false  // 本次操作前会话已存在（决定草稿追加策略）
            try {
              const found = await findWorkspaceSessions(workspaceId)
              if (found.openable !== undefined) {
                // 最近一条非空会话：直接续接
                sessionId = found.openable
                resumed = true
                preexisting = true
              } else if (found.blank !== undefined) {
                // 只剩草稿会话：按名复用，避免每次右键都多一条空行
                sessionId = await ctx.sessions.create({ workspaceId, cwd: workspace.path, sessionId: found.blank })
                preexisting = true
              }
            } catch (error) {
              log(`查找组内会话失败，改为新建: ${folder}`, error)
              sessionId = undefined
            }

            if (sessionId === undefined) {
              try {
                // 组内没有可续接的会话：新建一个
                sessionId = await ctx.sessions.create({ workspaceId, cwd: workspace.path })
              } catch (error) {
                log(`新建会话失败，改为打开工作区: ${folder}`, error)
                await ctx.uiWorkspace.openWorkspace(workspaceId)
                return
              }
            }

            try {
              ctx.uiWorkspace.openSession(sessionId)
            } catch (error) {
              log(`切换到会话失败，改为打开工作区: ${folder}`, error)
              await ctx.uiWorkspace.openWorkspace(workspaceId)
              return
            }
            log(`${resumed ? '已续接' : '已打开'}: ${folder} → 会话 ${sessionId}`)

            if (file !== undefined) await seedFileReference(workspace.path, sessionId, file, preexisting)
          }

          /**
           * [patch:jump-to-latest] 工作区内"最近一条可续接的非空会话"与"最近一条草稿会话"。
           * 读取官方客户端快照：workspace 成员关系 + 会话行（updatedAt/blank/origin），
           * 排除归档集合与子代理行，按 updatedAt（最近活动）取最新。
           * 快照未就绪时先 refresh 一次；任何异常向上抛给 handle() 退回新建逻辑。
           */
          async function findWorkspaceSessions(workspaceId) {
            try {
              if (ctx.sessions.list?.getSnapshot?.().phase !== 'ready') await ctx.sessions.refresh?.()
            } catch {
              // 刷新失败就用当前快照兜底
            }
            const wsSnap = ctx.workspaces.list.getSnapshot()
            const view = wsSnap.items.find((item) => item.workspaceId === workspaceId)
            if (view === undefined) return {}
            const archived = new Set(wsSnap.archivedSessionIds ?? [])
            const rows = ctx.sessions.list.getSnapshot().byId
            let openable
            let openableAt = Number.NEGATIVE_INFINITY
            let blank
            let blankAt = Number.NEGATIVE_INFINITY
            for (const id of view.sessionIds ?? []) {
              if (archived.has(id)) continue
              const row = rows[id]
              if (row === undefined || row.origin === 'subagent') continue
              const at = typeof row.updatedAt === 'number' ? row.updatedAt : 0
              if (row.blank === true) {
                if (at > blankAt) {
                  blankAt = at
                  blank = id
                }
              } else if (at > openableAt) {
                openableAt = at
                openable = id
              }
            }
            return { openable, blank }
          }

          /**
           * 把被点中的文件写成草稿里的 @引用。
           * 引用按会话 cwd 解析，所以只接受位于工作区之内的文件；含空格的路径用 @"..." 形式。
           * [patch:jump-to-latest] preexisting 为 true（续接已有会话）时改用
           * whenDraftExists:'append'，不覆盖那条会话里未发送的草稿。
           */
          function relativeMention(cwd, file) {
            const trim = (path) => path.replace(/[\\/]+$/u, '')
            const base = trim(cwd)
            const target = trim(file)
            const lower = (path) => path.toLowerCase()
            if (lower(target) === lower(base)) return undefined
            const prefix = lower(target).startsWith(`${lower(base)}\\`) || lower(target).startsWith(`${lower(base)}/`)
            if (!prefix) return undefined
            const relative = target.slice(base.length + 1)
            return `${/\s/u.test(relative) ? `@"${relative}"` : `@${relative}`} `
          }

          /** 新会话刚建好时，binding 可能还没就绪，短暂重试几次再写草稿。 */
          async function seedFileReference(cwd, sessionId, file, preexisting) {
            const mention = relativeMention(cwd, file)
            if (mention === undefined) {
              log(`文件不在工作区内，跳过引用: ${file}`)
              return
            }

            let input
            try {
              input = ctx.get('conversation')?.input
            } catch {
              input = undefined
            }
            if (input?.requestDraftInitialization === undefined) {
              log(`当前界面不支持预置草稿，跳过引用: ${file}`)
              return
            }

            for (let attempt = 0; attempt < 20; attempt += 1) {
              const binding = ctx.sessions.binding?.(sessionId)
              if (binding !== undefined) {
                try {
                  const result = input.requestDraftInitialization(binding, preexisting === true
                    ? { prompt: mention, whenDraftExists: 'append' }
                    : { prompt: mention, clearPreviousDraft: true })
                  if (result !== 'blocked') {
                    log(`已在草稿中引用: ${mention.trim()}`)
                    return
                  }
                } catch (error) {
                  log(`写入草稿失败: ${file}`, error)
                  return
                }
              }
              await new Promise((resolve) => setTimeout(resolve, 100))
            }
            log(`草稿未就绪，跳过引用: ${file}`)
          }

          async function poll() {
            let data
            try {
              const res = await fetch(REQUEST_URL, { cache: 'no-store', headers: { [REQUEST_HEADER]: '1' } })
              if (!res.ok) return
              data = await res.json()
            } catch {
              return
            }
            if (data?.status !== 'open' || !Array.isArray(data.requests)) return
            for (const request of data.requests) {
              if (request === null || typeof request.folder !== 'string') continue
              const file = typeof request.file === 'string' ? request.file : undefined
              ack('start', file ?? request.folder)
              try {
                await handle(request.folder, file)
                ack('ok', file ?? request.folder)
              } catch (error) {
                ack('fail', `${file ?? request.folder} :: ${error?.message ?? error}`)
                log(`打开失败: ${request.folder}`, error)
              }
            }
          }

          let busy = false
          async function tick() {
            if (busy) return
            busy = true
            try {
              await poll()
            } finally {
              busy = false
            }
          }

          ctx.effect(() => {
            void tick()
            const timer = setInterval(() => void tick(), POLL_MS)
            return () => clearInterval(timer)
          })
        },
      }
    },
  })
}

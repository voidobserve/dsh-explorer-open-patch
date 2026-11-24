# dsh-explorer-open 补丁：右键打开工程，续接最近一次会话

在 Windows 资源管理器里对文件夹右键「通过 dsh 打开」时，[`@reed-io/dsh-explorer-open`](https://github.com/ame-code/dsh-explorer-open)
原版会**每次都新建一条会话**。这个补丁把它改成：**打开该工程最近一条会话继续聊**，工程里确实没有会话时才新建。

补丁只改插件的页面侧 `client.js`；插件本体（资源管理器菜单、Win11 MSIX 原生组件、宿主侧 HTTP 路由）保持上游原样。
**本仓库不是上游的 fork**，只存放补丁、脚本和文档。

- 适用插件：`@reed-io/dsh-explorer-open` **0.1.6**
- 验证环境：DeepSeek Harness **0.2.2-rc.3**（desktop profile，Windows 11）
- 协议：MIT

## 为什么要它

DSH 的会话按工程（workspace）分组。原版每次右键都新开一条，同一个工程反复进出几次，侧栏里就堆出一串空会话，
想找上次的进度得翻半天。补丁把这个动作变成「回到上次那条」，更符合「打开工程接着干」的直觉。

## 补丁后的行为

| 场景 | 行为 |
| --- | --- |
| 工程里已有会话 | 续接 `updatedAt` 最新的那条**非空**会话（排除归档会话与子代理会话） |
| 只剩草稿（空）会话 | 按 id 复用那一条，不再每次多一行 |
| 一条会话都没有 | 新建（= 原版行为） |
| 右键的是**文件** | 照旧把 `@文件` 写进草稿；落到已有会话上时用 `whenDraftExists: 'append'`，**不覆盖**那里还没发出去的草稿 |
| 侧栏跳转 | 沿用 DSH 原生 `openSession`：分组展开、行高亮、水位线保可见；手动折叠过的分组保持折叠 |

工作区仍按完整路径复用（原行为不变）。

**兜底**：补丁新增的逻辑全部包在 `try/catch` 里。接口变动（快照字段改名、`sessions.refresh` 消失等）只会让这次右键
退回原版「新建会话」，右键链路不会因为补丁而中断。

## 快速开始

```powershell
cd dsh-explorer-open-patch

# 1) 装/升级插件，并自动打上补丁（脚本已处理死代理、dsh-diff-review 404 两个坑）
powershell -File install-plugin.ps1

# 2) 只检查补丁状态（0=在位，2=未打，3=锚点丢失需人工合并）
powershell -File apply-patch.ps1 -Check

# 3) 补打 / 还原
powershell -File apply-patch.ps1
powershell -File apply-patch.ps1 -Revert
```

打完补丁要**重启 DSH**（让宿主重新注册资源）并**刷新页面**（客户端 chunk 重新加载）。

脚本默认目标是 `%USERPROFILE%\.dsh\profiles\desktop`；用 `-ProfileDir` 参数或环境变量 `DSH_PROFILE_DIR`
可以指向别的 profile。

## 文件

| 文件 | 作用 |
| --- | --- |
| `patched-client.js` | 补丁后的完整 `client.js`，唯一事实来源 |
| `original-client.js` | 上游 0.1.6 原版 `client.js`，比对基准 + 还原兜底（SHA-256 `CB8A9334…`） |
| `apply-patch.ps1` | 幂等打补丁：已打→跳过；插件升级后→自动备份原版再重打；锚点丢失→`exit 3` 并给出合并步骤 |
| `install-plugin.ps1` | 安装/升级插件一条龙，装完自动重打补丁 |
| `LICENSE` | MIT（含上游版权行） |
| `README.md` | 本文 |

`apply-patch.ps1` 每次打补丁前会把当前原版存成 `original-client.<版本>.<时间戳>.js`；这类自动备份被
`.gitignore` 排除，`-Revert` 在没有备份时退回 `original-client.js` 基线。

## 升级之后

**升级 DSH 本体**：`client.js` 属于插件、不随 DSH 变；保险起见跑一次 `apply-patch.ps1 -Check`。

**升级 / 重装插件**：用 `install-plugin.ps1`，别手动 pnpm——它处理了两个已知坑（死代理、`dsh-diff-review`
不在任何 registry），装完会自动重打补丁。

**锚点丢失（`exit 3`）**：新版插件改了 `handle()` 的结构。用 `apply-patch.ps1` 备份下来的新原版和
`original-client.js` 对比，把差异合进 `patched-client.js`（保留所有 `[patch:jump-to-latest]` 标记），再重跑。

## 实现要点

- 补丁段落用 `[patch:jump-to-latest]` 标记，便于定位和重放；`apply-patch.ps1` 靠原版里的一句特征注释
  （`不关心有没有旧会话：每次都新建一个`）判断插件是否已升级到不兼容的版本。
- 续接判断只读官方客户端快照：`ctx.workspaces.list`（`sessionIds` / `archivedSessionIds`）与
  `ctx.sessions.list`（`byId[id].updatedAt / blank / origin`）；快照未就绪时先 `ctx.sessions.refresh()`。
- 文件引用按会话 `cwd` 求相对路径，只接受工作区内的文件，含空格的路径写成 `@"..."`。
- 新会话的 binding 可能晚一步就绪，写草稿时最多重试 20 次 × 100 ms。

## 已知限制

- 只在 Windows + DSH Desktop 上验证；所用快照字段属于客户端内部 API，DSH 大版本升级后可能失效
  （有兜底，不会报错，只是退回「新建」）。
- 只验证到插件 0.1.6；上游改版后需要按上面的「锚点丢失」流程合并。
- 补丁按 profile 生效；多 profile 各装一份时要各打一次（`-ProfileDir`）。

## 关于本仓库

本仓库的补丁代码、PowerShell 脚本和文档，是在 **DeepSeek Harness（DSH）** 的会话里编写完成的：由 DSH 中的
编码代理读取已安装插件的源码、定位 `handle()` 锚点、生成补丁与脚本，并在本机 DSH 0.2.2-rc.3 + 插件 0.1.6 上
验证「右键 → 续接会话 → `@文件`」整条链路。落库前的改动经人工复核；脚本按 Windows PowerShell 5.1 的实际
行为调整过（`.ps1` 带 UTF-8 BOM，无 BOM 会被按 GBK 解码）。

本仓库是给第三方插件打的外挂补丁，与上游无隶属关系；上游的 MIT 声明一并保留，见 `LICENSE`。

## 协议与致谢

MIT。原版插件与 `original-client.js` 的版权归 [ame-code/dsh-explorer-open](https://github.com/ame-code/dsh-explorer-open)
的贡献者所有；补丁、脚本与文档版权归本仓库作者所有。

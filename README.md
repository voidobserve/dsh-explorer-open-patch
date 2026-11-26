# dsh-explorer-open 补丁：右键打开工程续接最近会话，且不再闪 PowerShell 窗口

给 [`@reed-io/dsh-explorer-open`](https://github.com/ame-code/dsh-explorer-open) 打的两处外挂补丁：

1. **续接最近会话**：在资源管理器里右键「通过 dsh 打开」时，打开该工程最近一条会话继续聊，
   而不是每次都新建一条空会话。
2. **不闪窗口**：点菜单不再闪出一个 PowerShell 控制台窗口——那只是启动器，用户不需要看到它。

补丁只动插件的两个文件：页面侧 `client.js` 与宿主侧 `lib/registry.js`，另外放一个无窗口启动器
`launch.vbs`。插件本体（资源管理器菜单项、Win11 MSIX 原生组件、宿主侧 HTTP 路由）保持上游原样。
**本仓库不是上游的 fork**，只存放补丁、脚本和文档。

- 适用插件：`@reed-io/dsh-explorer-open` **0.1.6**
- 验证环境：DeepSeek Harness **0.2.2-rc.3**（desktop profile，Windows 11）
- 协议：MIT

## 为什么要它

**每次右键都新开一条会话。** DSH 的会话按工程（workspace）分组，原版每右键一次就多一条空会话，
同一个工程进出几次侧栏里就串起一串；补丁让这个动作变成「回到上次那条」。

**启动器会闪窗口。** 原版菜单命令直接调 `powershell.exe -WindowStyle Hidden`。资源管理器传给
子进程的启动信息是 `SW_SHOWNORMAL`，`-WindowStyle Hidden` 要等控制台窗口建好之后才生效，
所以每次点菜单都会闪一下——在慢一点的机器上还挺显眼。

## 补丁后的行为

| 场景 | 行为 |
| --- | --- |
| 工程里已有会话 | 续接 `updatedAt` 最新的那条**非空**会话（排除归档会话与子代理会话） |
| 只剩草稿（空）会话 | 按 id 复用那一条，不再每次多一行 |
| 一条会话都没有 | 新建（= 原版行为） |
| 右键的是**文件** | 照旧把 `@文件` 写进草稿；落到已有会话上时用 `whenDraftExists: 'append'`，**不覆盖**那里还没发出去的草稿 |
| 点菜单之后 | 不出现任何控制台窗口；dsh 没开时静默拉起它 |
| 侧栏跳转 | 沿用 DSH 原生 `openSession`：分组展开、行高亮、水位线保可见；手动折叠过的分组保持折叠 |

工作区仍按完整路径复用（原行为不变）。

**兜底**：两处补丁都只做增量改动，且都有退路——续接逻辑整段包在 `try/catch` 里，接口变动时退回
原版「新建会话」；`launch.vbs` 不在位时，菜单命令自动退回原版写法（会闪一下，但菜单不会失效）。

## 快速开始

```powershell
cd dsh-explorer-open-patch

# 1) 装/升级插件，并自动把两处补丁打上（脚本已处理死代理、dsh-diff-review 404 两个坑）
powershell -File install-plugin.ps1

# 2) 只检查补丁状态（0=都在位，2=有补丁没打，3=锚点丢失需人工合并）
powershell -File apply-patch.ps1 -Check

# 3) 补打 / 还原
powershell -File apply-patch.ps1
powershell -File apply-patch.ps1 -Revert
```

`apply-patch.ps1` 打完补丁会顺手把三处注册表命令切到 `launch.vbs`，**不用等下次启动 dsh**。
重启 dsh 并刷新页面，是为了让宿主侧的 `registry.js` 与新命令彻底生效。

脚本默认目标是 `%USERPROFILE%\.dsh\profiles\desktop`；用 `-ProfileDir` 参数或环境变量
`DSH_PROFILE_DIR` 可以指向别的 profile。

## 文件

| 文件 | 作用 |
| --- | --- |
| `patched-client.js` | 补丁后的页面侧 `client.js`（续接最近会话），唯一事实来源 |
| `original-client.js` | 上游 0.1.6 原版 `client.js`，比对基准 + 还原兜底（SHA-256 `CB8A9334…`） |
| `patched-registry.js` | 补丁后的宿主侧 `lib/registry.js`（菜单改经 `launch.vbs`） |
| `original-registry.js` | 上游 0.1.6 原版 `lib/registry.js`，比对基准 + 还原兜底 |
| `launch.vbs` | 无窗口启动器：`wscript` → 隐藏窗口的 PowerShell |
| `apply-patch.ps1` | 幂等打补丁：已打→跳过；插件升级后→备份原版再重打；锚点丢失→`exit 3` 给出合并步骤 |
| `install-plugin.ps1` | 安装/升级插件一条龙，装完自动重打补丁 |
| `LICENSE` | MIT（含上游版权行） |
| `README.md` | 本文 |

`apply-patch.ps1` 每次打补丁前会把当前原版存成 `original-<client|registry>.<版本>.<时间戳>.js`；
这类自动备份被 `.gitignore` 排除，`-Revert` 在没有备份时退回仓库归档的 `original-*.js`。

## 不闪窗口是怎么做到的

```
资源管理器 ──► wscript.exe "launch.vbs" "%V"        （GUI 子系统，本身不建控制台）
                    └─ WScript.Shell.Run(cmd, 0)    （SW_HIDE）
                           └─ powershell.exe … -WindowStyle Hidden -File launch.ps1
                                  └─ 写 pending.json，然后拉起/激活 dsh
```

关键在于**进程创建时**就告诉 Windows「不要显示窗口」：`wscript.exe` 没有控制台，`WScript.Shell.Run`
的第二个参数 `0` 让 PowerShell 的控制台以隐藏状态创建。直接调 `powershell.exe` 时，窗口已经按
`SW_SHOWNORMAL` 建好，脚本里的 `-WindowStyle Hidden` 只能事后把它藏起来——那一瞬间就是用户看到的闪光。

`launch.vbs` 故意保持纯 ASCII：Windows Script Host 会把无 BOM 的脚本按 ANSI 代码页解码，
写中文会变成乱码（`.ps1` 那份则相反，必须是 UTF-8 **带** BOM，否则 PowerShell 5.1 同样按 GBK 读）。

## 升级之后

**升级 DSH 本体**：这两个文件属于插件、不随 DSH 变；保险起见跑一次 `apply-patch.ps1 -Check`。

**升级 / 重装插件**：用 `install-plugin.ps1`，别手动 pnpm——它处理了两个已知坑（死代理、
`dsh-diff-review` 不在任何 registry），装完会自动重打补丁。`launch.vbs` 放在
`~/.dsh/dsh-explorer-open/`，不在插件目录里，升级不会把它删掉。

**锚点丢失（`exit 3`）**：新版插件改了被补丁的那段代码。用 `apply-patch.ps1` 备份下来的新原版和
对应的 `original-*.js` 对比，把差异合进 `patched-*.js`（保留 `[patch:jump-to-latest]` /
`[patch:hidden-console]` 标记），再重跑。

## 实现要点

- 补丁段落分别用 `[patch:jump-to-latest]`、`[patch:hidden-console]` 标记，便于定位和重放；
  `apply-patch.ps1` 靠原版里的特征行判断插件是否已升级到不兼容的版本——`client.js` 里是那句
  「不关心有没有旧会话：每次都新建一个」，`lib/registry.js` 里是那条直接拼 `POWERSHELL` 命令的
  `return` 语句。
- 续接判断只读官方客户端快照：`ctx.workspaces.list`（`sessionIds` / `archivedSessionIds`）与
  `ctx.sessions.list`（`byId[id].updatedAt / blank / origin`）；快照未就绪时先 `ctx.sessions.refresh()`。
- 文件引用按会话 `cwd` 求相对路径，只接受工作区内的文件，含空格的路径写成 `@"..."`。
- 新会话的 binding 可能晚一步就绪，写草稿时最多重试 20 次 × 100 ms。
- 注册表只改插件自己那三处 `shell\OpenWithDsh\command` 的默认值，不动菜单文字和图标，也不新建键。

## 已知限制

- 只在 Windows + DSH Desktop 上验证；所用快照字段属于客户端内部 API，DSH 大版本升级后可能失效
  （有兜底，不会报错，只是退回「新建」）。
- 只验证到插件 0.1.6；上游改版后需要按上面的「锚点丢失」流程合并。
- 补丁按 profile 生效；多 profile 各装一份时要各打一次（`-ProfileDir`）。
- 如果组策略禁用了 Windows Script Host，`launch.vbs` 跑不起来——`apply-patch.ps1` 的 `-Revert`
  可以退回原版命令（会闪窗口，但至少能用）。
- Win11 **新式精简菜单**走的是 MSIX 里的原生组件，不经过这条命令，本补丁不覆盖它；目前它需要
  先信任自签证书，未启用时经典菜单是唯一入口。

## 关于本仓库

本仓库的补丁代码、PowerShell 脚本和文档，是在 **DeepSeek Harness（DSH）** 的会话里编写完成的：
由 DSH 中的编码代理读取已安装插件的源码、定位被补丁的代码段、生成补丁与脚本，并在本机
DSH 0.2.2-rc.3 + 插件 0.1.6 上逐项验证。落库前的改动经人工复核；脚本按 Windows PowerShell 5.1
的实际行为调整过（`.ps1` 带 UTF-8 BOM，无 BOM 会被按 GBK 解码）。

「不闪窗口」这处补丁是用 Win32 接口实测过的：同样参数下，直接启动 `powershell.exe` 会留下一个
可见的控制台窗口，经 `wscript` + `SW_HIDE` 启动则没有窗口。

本仓库是给第三方插件打的外挂补丁，与上游无隶属关系；上游的 MIT 声明一并保留，见 `LICENSE`。

## 协议与致谢

MIT。原版插件、`original-client.js` 与 `original-registry.js` 的版权归
[ame-code/dsh-explorer-open](https://github.com/ame-code/dsh-explorer-open) 的贡献者所有；
补丁、脚本与文档版权归本仓库作者所有。

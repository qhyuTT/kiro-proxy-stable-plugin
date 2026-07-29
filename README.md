# kiro-proxy-stable

面向 **Kiro 反向代理** 的 Claude Code **插件**。当 Claude Code 通过 Kiro 反代访问 Anthropic 时，长回合、大 Write 载荷、密集串行工具调用容易触发中途断流和 `tool_use` 不完整。本插件把「小批次 + 原生工具 + 断点续跑」的行为规范注入到每个会话与子代理，降低断连率与断连后的进度损失。

## 项目组成

| 组成 | 位置 | 作用 |
|------|------|------|
| 插件元信息 | `.claude-plugin/plugin.json` | 声明插件名、版本、作者、仓库 |
| Marketplace 清单 | `.claude-plugin/marketplace.json` | 让 `/plugin marketplace add` 能识别并列出本插件 |
| Hooks 配置 | `hooks/hooks.json` | 注册 `SessionStart` / `SubagentStart` 两个钩子 |
| 规则注入脚本 | `scripts/emit-rules.sh` | 钩子触发时把规则以 `additionalContext` 形式喂给模型 |
| 规则正文 | `scripts/kiro-proxy-rules.txt` | Kiro 反代下的工具、批次、续跑约束（v1 标记） |
| 完整 Skill | `skills/kiro-proxy-stable/SKILL.md` | 预防 + 恢复 + 子代理交接的完整手册，通过 `/kiro-proxy-stable` 触发 |
| 子代理 | `agents/kiro-proxy-worker.md` | 反代友好的实现型子代理，自带原生工具白名单 |

### 各部分具体做什么

- **SessionStart 钩子**：会话开始时把简版规则注入一次，整场会话有效，避免每回合重复发送、节省 token。
- **SubagentStart 钩子**：子代理默认是空上下文，此钩子确保子代理也拿到同一份规则。
- **`kiro-proxy-stable` Skill**：完整版手册。断连、`继续`、`任务中断`、`tool call failed` 等关键词会自动召回；也可以手动 `/kiro-proxy-stable` 触发。
- **`kiro-proxy-worker` 子代理**：主代理把实现类任务拆给它时，它已经带好原生工具白名单（`Read/Write/Edit/Bash/Glob/Grep/Skill`）和小批次工作习惯。

## 为什么有用

Kiro 反代把 Anthropic 的流式协议和工具协议翻译成 Kiro 自己的格式，失败集中在：

- 单回合过长
- 密集**串行**工具调用
- 单次 Write 过大 / `tool_use` 分片不全

Claude Code 的 **`/goal`** 在同一条代理下更稳，因为它把工作切成很多短回合、每回合结束后自动续跑。本插件把同样的形状变成日常回合的默认行为：小批次、只用原生工具、以「resume 锚点」续跑，并在任务有可验证完成条件时推荐 `/goal`。

**取舍**：用速度换稳定。回合更短更多，长任务墙钟时间可能变长；换来的是断连率与每次断连的损失下降。如果你到 Kiro 的网络本身很稳，或者你用的是原生 Anthropic，就不需要装。

## 为什么容易中断（触发点拆解）

核心原因：**协议转换不完美 + 工具调用映射脆弱**，再叠上长流式回合，容易在传输中途断掉。常见触发点：

- **工具 schema / 参数不匹配**。Claude Code 的 `Read/Write/Edit/Bash/Glob/Grep` 使用的字段（`file_path`, `old_string`, `new_string` 等）跟 Kiro 内置工具（`path`, `oldStr`, `newStr` 等）不完全一致。转换出错时上游会返回异常或截断，客户端就会收到不完整的 SSE 事件（缺字段、`index` 乱、`tool_use` 标签开着却没内容），任务因此中断或反复重试。→ 对应规则：只用 Claude Code 原生工具与字段名。
- **流式分块处理脆弱**。Thinking 块、长输出、大工具参数经常被拆成多个 chunk，反代的过滤 / 拼接逻辑一旦过严，就会丢内容或破坏状态机，最终连接被关掉或客户端判定失败。→ 对应规则：Write/Edit 单次 8–12k 字符上限，每回合 4–6 次工具调用。
- **上游本身的连接限制**（经验判断）。Kiro / AWS 侧对长连接、输出长度、空闲超时更敏感，中途掐流比原生 Anthropic API 更常见；再叠一层反代和网络缓冲，断流概率进一步放大。→ 对应规则：短回合优先、每批留 resume 锚点。
- **隐性系统提示与会话状态**（观察项）。走 Kiro 通道时，请求可能被注入 Kiro / Cursor 风格的系统提示或身份，会话状态管理也和纯 Claude Code 不完全一致，会放大转换误差。这一条依赖具体反代实现，仅作经验参考。

结果就是：普通聊天通常没问题，一旦进入真实 Agent 工作流（连读文件、连改代码、跑命令、多轮工具），就容易在某一回合突然断掉，需要手动「继续」。本插件把「小批次 + 原生工具 + 断点续跑」当默认行为，就是为了压低这类断连的发生率与单次损失。

## 提速原理（为什么 `继续` 有时反而更快）

插件把「打断 + 继续更快」这个现象变成正常回合的模式：

- **无前置铺垫**。在反代上，第一次工具调用前的长段「让我先规划……」是最慢的部分，规则里明确禁止。
- **独立工具调用并行**。多个互不依赖的 Read / Grep 放进同一批，一次代理往返完成，绝不串行。
- **Resume 锚点**。每批结尾输出 `[resume] done=... next=...`，`Esc` + `继续` 能直接跳到下一步，不用重新规划。
- **短回合 > 巨型回合**。新回合命中 prompt cache 更干净；老化连接上的巨型回合越往后越慢。

其他可选加速手段：

- 长任务且有可验证条件 → `/goal <可验证条件>`
- 使用 Opus 5 / 4.8 / 4.7 时 → `/fast` 加快输出速率

## 安装

### 方式一：把仓库地址发给 Claude Code，让它自己装（推荐）

在 Claude Code 里直接说：

```text
帮我安装这个 Claude Code 插件：https://github.com/qhyuTT/kiro-proxy-stable-plugin
```

它会自行完成注册 marketplace、安装插件、重载三步。装完让它确认一下：钩子数应该是 **2 个**（`SessionStart` + `SubagentStart`）。

### 方式二：手动敲命令

想自己控制每一步，在 Claude Code 里依次输入：

```text
/plugin marketplace add https://github.com/qhyuTT/kiro-proxy-stable-plugin.git
/plugin install kiro-proxy-stable@kiro-proxy-stable
/reload-plugins
```

第一步会把本仓库注册为一个 marketplace；第二步安装名为 `kiro-proxy-stable` 的插件；第三步重载让钩子和 skill 生效。

注意两点：

- **用完整 HTTPS 地址，不要用 `owner/repo` 简写**。简写会被解析成 `git@github.com:...`，如果本机没有配置 GitHub SSH 密钥，会报 `Permission denied (publickey)`。
- **marketplace 名和插件名都是 `kiro-proxy-stable`**（来自 `marketplace.json`），跟仓库名 `kiro-proxy-stable-plugin` 不同，第二步不要跟着仓库名写成 `-plugin`。

### 方式三：命令行本地加载（只在当前会话生效）

先把仓库克隆到本地，再启动 Claude Code 时指定插件目录：

```bash
git clone https://github.com/qhyuTT/kiro-proxy-stable-plugin.git
claude --plugin-dir /path/to/kiro-proxy-stable-plugin
```

### 依赖 / 环境要求

钩子脚本 `scripts/emit-rules.sh` 使用 POSIX `sh + sed + awk + tr` 拼装 JSON 信封，不依赖 Python、Node、jq。

刻意不用 Node：Claude Code 现在主推原生二进制安装，安装目录里**不带** Node 运行时，机器上有没有 `node` 全看用户自己装过没有。`sh` 在 macOS / Linux 上是系统自带的，比 Node 更可靠。

**macOS**：系统自带 `sh` / `sed` / `awk` / `tr`，无需额外安装。

**Linux**：绝大多数发行版自带；极简镜像（Alpine 等）如果缺 `awk`，安装 `busybox` 或 `gawk` 即可。

**Windows**：**钩子在 Windows 上不工作，请用 WSL2。**

原生 `cmd` / PowerShell 里没有 `sh`，而且 `hooks.json` 里的 `${CLAUDE_PLUGIN_ROOT}` 是 POSIX 展开语法，`cmd` 也不认，两处都会失败。

- **WSL2（唯一推荐）**：在 WSL 里安装 Claude Code，在 WSL 终端里启动 `claude`，钩子按 Linux 方式工作。
- **Git Bash / MSYS2 / Cygwin**：这些环境**提供**了 `sh`，但 Claude Code 在 Windows 上是否会用它们来执行钩子，取决于它如何选择 shell，本项目未在 Windows 上实测过，不保证可用。

验证方法：在你实际启动 `claude` 的那个终端里执行 `sh -c 'echo ok'`，能输出 `ok` 是必要条件，但在 Windows 上不是充分条件。

## 更新到新版本

用方式一或方式二装的，在 Claude Code 里执行：

```text
/plugin marketplace update kiro-proxy-stable
/reload-plugins
```

一条 `marketplace update` 就够了，不需要再 `/plugin install`。因为 `marketplace.json` 里插件的 `source` 是 `./`，插件本体就是 marketplace 仓库本身（本地位于 `~/.claude/plugins/marketplaces/kiro-proxy-stable/`），更新 marketplace 就等于拉取插件文件。

`/reload-plugins` 之后可以顺手核对钩子数是否为 **2 个**，作为新版本已生效的客观信号。

注意：上面那个目录是一份 git 克隆，`marketplace update` 底层是 fetch 并更新到远端。如果你直接改过该目录里的文件，更新可能因冲突失败或丢掉你的改动——想改配置请改自己仓库的副本，别改这份缓存。

方式三（`--plugin-dir`）则是在你自己的克隆里 `git pull`，然后重启 `claude`。

## 不使用 Kiro 反代时

装了但暂时不想让它生效：

```text
/plugin disable kiro-proxy-stable@kiro-proxy-stable
```

想要彻底移除：

```text
/plugin uninstall kiro-proxy-stable@kiro-proxy-stable
```

重新启用：

```text
/plugin enable kiro-proxy-stable@kiro-proxy-stable
```

## 使用建议

1. **日常对话**：规则会在会话开始注入一次，之后整场会话都遵守，不需要额外操作。
2. **长任务且有可验证的完成条件**：

   ```text
   /goal 单测通过且 lint 无告警
   ```

3. **中途断连 / 想继续**：直接说 `继续`，或手动调出完整手册：

   ```text
   /kiro-proxy-stable
   ```

4. **拆分实现任务**：让主代理把实现型子任务交给 **kiro-proxy-worker** 子代理，它自带反代规则和 skill 引用。

## 验证插件已经生效

不依赖模型主观判断的方式：

```bash
claude --debug --plugin-dir /path/to/kiro-proxy-stable-plugin 2>&1 | grep -i "SessionStart"
```

应能看到钩子触发并打印 `hookSpecificOutput` / `additionalContext`。

也可以直接问模型：让它返回 Kiro 规则的第一行。应该看到：

```text
[Kiro proxy rules v1 — session/subagent]
```

在子代理里做同样的检查可以验证 `SubagentStart` 是否也注入成功。

## 调优

如果你所在的反代表现和默认经验值不太一样，改 `scripts/kiro-proxy-rules.txt` 即可：

- 「Write/Edit 单次 8–12k 字符上限」「每回合 4–6 次工具调用」是经验起点。
- 仍有断连 → 把两个上限都往下调。
- 从来没断连 → 要么其实不需要本插件，要么可以把上限往上调。

## 目录结构

```text
.claude-plugin/plugin.json
.claude-plugin/marketplace.json
hooks/hooks.json
scripts/emit-rules.sh
scripts/kiro-proxy-rules.txt
skills/kiro-proxy-stable/
agents/kiro-proxy-worker.md
README.md
LICENSE
```

## Changelog

- **1.1.2** — 修复 CRLF 检出导致钩子输出非法 JSON、规则静默不生效的问题（`emit-rules.sh` 先 `tr -d '\r'`）；新增 `.gitattributes` 把脚本与规则文件锁为 LF；订正 Windows 一节，说明 `cmd.exe` 下钩子不工作、Git Bash 方案未经验证。
- **1.1.1** — 真正删掉 `UserPromptSubmit` 钩子（1.1.0 的 changelog 声称去掉了，实际 `hooks.json` 里还在，规则每回合都在重复注入）；修正 README 与 `plugin.json` 里指向不存在仓库 `kiro-proxy-stable` 的地址，安装命令改用完整 HTTPS 避免走 SSH。
- **1.1.0** — 规则改为通过 `SessionStart` 的 `additionalContext` 注入；加上 `v1` 标记方便客观验证；规则要求无前置铺垫 + 独立调用并行 + resume 锚点；`kiro-proxy-worker` 通过 frontmatter `tools:` 拿到原生工具白名单。
- **1.0.0** — 首次发布。

## License

MIT

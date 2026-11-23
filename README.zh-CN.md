# DeepSeek Harness Docker 镜像

[English](README.md)

本仓库把上游 DeepSeek Harness（DSH）打包成 Docker 镜像，内置 nginx 和 Git、GitHub CLI（`gh`）、Python、Node.js 等常用工具。发布流程每天检查上游版本；所有上游 `dsh-v*` 版本都会发布对应版本标签并更新 `latest`，`latest` 始终跟随上游最新版本。

变更请求面板通过 `gh` 读取 GitHub；首次使用请在容器内执行 `gh auth login --hostname github.com`，凭据保存在持久化的 `/home/node/.config/gh` 目录。

## 插件兼容层

DSH 升级时可能删除或调整插件 API。为旧版 DSH 编写的第三方 Web 插件可能在新版 DSH 上出现通用 HTTP 错误，而 DSH 本身仍然正常。

`dsh-plugin-compat` 是面向旧版第三方 DSH Web 插件的通用兼容层，版本与 DSH 发布同步。它在 DSH 正常完成会话认证后，仅对插件处理请求时使用的旧版请求视图做兼容；不按具体插件或路由写死，也不会绕过认证。

DSH 现在支持直接把 Git 仓库作为插件安装源。在 DSH 插件页选择「添加插件」，粘贴仓库地址：

```text
https://github.com/SquirrelJimmy/dsh-plugin-compat
```

如需可复现安装，可在仓库地址中固定 tag 或 commit；DSH 升级后请使用与当前 DSH 版本匹配的兼容层版本。

## 快速启动

在 Docker 主机上运行：

```sh
mkdir -p workspace
docker run -d --name dsh \
  -p 127.0.0.1:3080:3080 \
  -v dsh-home:/data/dsh \
  -v "$PWD/workspace:/workspace" \
  ghcr.io/squirreljimmy/deepseek-harness-build:latest
docker logs dsh
```

从日志里找到带 `?token=...` 的启动链接。若日志显示容器内部端口 `13080`，在浏览器里换成宿主机映射的地址 `http://127.0.0.1:3080/`，保留 `?token=...` 部分。启动令牌会换取浏览器会话，随后页面会跳转到界面。

`/data/dsh` 保存 Harness 配置和状态，`/workspace` 是可供 Harness 使用的项目目录。更新或重建容器时保留这两个挂载。

## HTTPS 反向代理

- 将外部反向代理指向容器发布的端口（示例为 `3080`），限制后端端口只接受受信网络的访问。
- 可给容器设置 `DSH_PUBLIC_URL=https://你的域名/`，让启动日志和 Harness 使用对外地址。这个变量只设置对外显示的 URL，不会改变账号登录的回调限制。
- 如需使用新版远程登录，再设置 `DSH_TRUSTED_HOST=你的域名`（可写多个，空格分隔）；它会启用外部 authority 模式并给 `dsh` 传 `--trusted-host`。不设置时仍保持默认的 loopback 改写，任意域名/IP 访问行为不变。
- 容器内置 nginx 已负责转发到 Harness，无需在外层代理重复改写 `Host` 或 `Origin`。

### 点击「登录」后立即失败

启动令牌用于打开 Harness 界面；界面里的「登录」用于授权 DeepSeek 账号。上游账号授权只接受带显式端口的本机 HTTP 地址，例如 `http://127.0.0.1:3081/`。通过 HTTPS 反代域名访问时，点击「登录」会在打开授权页之前失败。

- **继续用域名：** 在界面选择「添加 API Key」。
- **需要 DeepSeek 账号授权：** 如果容器发布的端口可通过 SSH 服务端的 `127.0.0.1:3080` 访问，在浏览器所在的电脑运行 `ssh -N -L 127.0.0.1:3081:127.0.0.1:3080 user@docker-host`。按实际配置替换 SSH 登录地址和转发目标。用同一容器的启动令牌打开 `http://127.0.0.1:3081/`，然后点击「登录」并完成授权。之后可以回 HTTPS 域名页刷新。

## 更新与验证

拉取新版后，用相同的端口、环境变量和挂载重建容器。`docker pull` 不会自动更新正在运行的容器。

```sh
docker pull ghcr.io/squirreljimmy/deepseek-harness-build:latest
```

如需本地构建并验证，可在仓库根目录运行：

```sh
docker build -t deepseek-harness:test .
bash scripts/smoke-test.sh deepseek-harness:test 3081
```

冒烟测试覆盖启动令牌、浏览器会话、API 转发和容器工具；它不执行 DeepSeek 账号授权。

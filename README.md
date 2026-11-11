# Jellyfin 媒体库插件

开发流程见[插件开发指南](https://github.com/wontonapp/wonton-docs/blob/main/develop.md)。

Jellyfin 把共享文件夹里的电影、剧集和音乐整理成网页媒体库，配置、缓存和元数据放在插件自己的数据目录；共享文件夹以只读方式挂载。

本插件使用 Jellyfin 官方 `jellyfin/jellyfin:12.4` 镜像，经云吞网关打开网页。

Jellyfin 12.4 稳定版没有调研中提到的原生 OIDC；首次打开仍需完成 Jellyfin 自己的初始化向导并创建管理员。这个限制和不做自研侧车的取舍见“首次启动与登录”。

## 图标与许可

`icon.svg` 使用 Jellyfin UX 仓库的官方 `jellyfin-icon--color-on-light.svg`，仅按插件规范加白色满幅底色；来源、Creative Commons BY-SA 4.0 许可全文、Jellyfin GPL-2.0-only 和商标说明见 [NOTICE](NOTICE)。本插件不代表 Jellyfin 官方出品、合作或背书。

## 先跑起来

```bash
scripts/dev.sh up
```

```bash
scripts/dev.sh install
```

`up` 在本机起一套云吞，打印它的地址。示例（实例名取自目录名加 4 位随机数，端口随机）是
`http://jellyfin3f2a.wonton.localhost:21234/`。浏览器打开，用 `scripts/dev.sh token` 输出的用户令牌登录。`install` 先列出
插件要的权限，确认后打印 Jellyfin 网页地址。

Jellyfin 12.4 稳定版没有调研中提到的原生 OIDC，因此清单使用 `sso: none`：云吞网关保护网页，Jellyfin 保留自己的管理员登录。

首次打开 Jellyfin 会进入上游初始化向导：创建用户自己的管理员账号，媒体目录填写 `/media`，元数据语言默认预置为中文。网页界面语言跟随浏览器语言，完成向导后即可扫描和播放共享文件夹里的媒体。
Chrome、Firefox 和 curl 把 `*.localhost` 直接解析到本机，不用改 hosts。

## 首次启动与登录

插件第一次创建数据目录时，用同一个官方 Jellyfin 镜像复制 `config/system.xml`，只预置中文元数据和中国地区；网页界面语言跟随浏览器语言，已有配置不会覆盖。首次管理员账号和密码仍由 Jellyfin 上游初始化向导创建，插件不写默认密码、不改数据库。

这不是遗漏：Jellyfin `v12.4` 标签树没有上游调研里提到的 OIDC 实现，反向代理请求头也不是 Jellyfin 核心支持的登录方式。为避免自研认证侧车和把用户的凭据交给插件，本版保留 `sso: none`。原生客户端、DLNA 和转码显卡不在本 PR 范围内。

## 仓库里有什么

| 路径 | 内容 |
| --- | --- |
| `docker-compose.yml` | 插件本身：Jellyfin compose 加上 `x-wonton` 清单 |
| `config/system.xml` | 首次创建配置目录时复制的中文元数据默认配置 |
| `icon.svg` | Jellyfin 官方图标 |
| `scripts/check.sh` | 检查插件包，规则和安装时一样 |
| `scripts/dev.sh` | 开发环境：起一套云吞，装、重装、卸载插件，看日志 |
| `scripts/smoke-probes.sh` | `scripts/dev.sh smoke` 对这个插件逐项的探测 |
| `scripts/publish.sh` | 发布一个版本：打 tag、推送；`images/` 里有自己构建的镜像时先构建、推送并按摘要写回（示例没有） |
| `AGENTS.md` | 给人和 AI 编程代理的规则 |
| `LICENSE` | 插件包自己的许可证；从模板新建时换成作者自己的名字和年份 |
| `NOTICE` | 图标等第三方素材的许可和声明；图标是自己画的就写原创和插件许可证，见[插件规范](https://github.com/wontonapp/wonton-docs/blob/main/plugin-spec.md) |
| `.wonton/` | 开发环境的设置、密钥和数据，不提交 |

插件包是 `docker-compose.yml` 加上它引用的文件：`icon`、`settings`、`bot.avatar`、`notices` 和顶层 `configs` 的 `file`。README、
截图、Dockerfile、源码都不在插件包里，核心不取。引用的路径相对仓库根目录，不能是绝对路径、不能含 `..`、不能用变量，
也不能经过软链接；单个文件不超过 1 MiB，整个插件包不超过 2 MiB。安装时插件包以 tar 归档上传，归档里只能有普通文件和
目录，最多 256 项。


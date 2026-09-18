# ssh-reverse-proxy 安装与卸载

本目录包含两个可安装的文件。用户只有在主动运行 `ssh-reverse-proxy` 时才会初始化，无需修改系统级 Bash 启动文件。

服务器端口固定为**用户 UID + 10000**。UID 为 `1234` 时，端口即 `11234`。不需要共享端口登记、管理员分配程序或 sudoers 规则。

## 安装前检查

- 目标用户的 UID 不得大于 `55535`，以保证计算出的端口不超过 `65535`。用户可运行 `id -u` 自查。若两个账号故意共用同一 UID，它们也会共用同一端口。
- 若某用户的 `~/.bashrc` 已有独立的 `http_proxy` 等导出语句，或手动设置过 `SRP_SERVER_PORT`，需由该用户先备份并迁移旧配置。正式版会拒绝覆盖，使用固定端口的旧配置同样如此。
- 仅支持 Bash，使用 `flock` 管理同一用户的并发配置写入。

## 安装或更新

在本目录执行：

```bash
sudo install -o root -g root -m 755 ssh-reverse-proxy.sh ssh-reverse-proxy /usr/local/bin/
```

两个文件必须位于同一目录，因为 `ssh-reverse-proxy` 会调用同目录下的 `ssh-reverse-proxy.sh`。检查命令是否可用：

```bash
command -v ssh-reverse-proxy
```

安装后，让两个不同 UID 的普通用户分别运行 `ssh-reverse-proxy`，确认端口分别等于各自的 UID 加 `10000`，再测试 `ssh-reverse-proxy off` 与 `ssh-reverse-proxy on`。首次运行或切换状态后，需新开远程终端，使 `~/.bashrc` 中的代理环境变量生效。`ssh-reverse-proxy` 不会自动建立本地 SSH 隧道。

若用户希望使用更短的命令名，可参考 [README](README.md) 中的别名做法，自行设置，例如 `alias ssrep='ssh-reverse-proxy'`。

## 卸载

需要停止使用代理的用户，先运行 `ssh-reverse-proxy off`，再新开终端。随后由管理员移除命令：

```bash
sudo rm /usr/local/bin/ssh-reverse-proxy /usr/local/bin/ssh-reverse-proxy.sh
```

卸载命令不会删除用户 `~/.bashrc` 中的管理块或家目录中的首次配置状态。若要清除这些数据，请先逐个核对用户的配置与仍在运行的 SSH 隧道。

## 限制

端口按 UID 固定计算，不检查是否被其他程序占用。若已有程序监听该端口，SSH 反向转发将失败，需由管理员处理端口占用。使用其他 shell 的用户需要对应版本。

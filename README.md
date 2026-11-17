# OpenLogReplicator-Windows

基于官方 **v1.9.0 / 1a83a769e05eefd81fe5397205554f78290fa4f9** 的原生 Windows x64 移植。
目标系统是 Windows Server 2012 R2 及以上。已在真实 Server 2012 R2 与 Oracle 11.2.0.4 完成基础 CDC 和服务验证；
这不代表所有数据类型、负载及数据库版本均已完成生产认证。

保留上游 Redo 解析器、OpCode、事务重组、JSON 构建和字符集解码。
只在操作系统、编译器和产品运行层适配；不通过忽略数据错误或关闭块校验规避问题。
上游说明见 [docs/README.upstream.md](docs/README.upstream.md)，审计及验收门禁见
[docs/windows-portability-audit.md](docs/windows-portability-audit.md)。

## 构建最小版本

本轮连接器发布包为 `OpenLogReplicator-Windows-v1.9.0-connectors-x64.zip`，
启用 OCI、文件输出、Kafka（含 SCRAM）、TCP Stream、ZeroMQ 和 Protobuf；Prometheus 仍关闭。
包内包含 `bin/StreamClient.exe`、两份流输出模板和 `proto/OraProtoBuf.proto`。
使用方式、协议和目标服务器实测见 [流输出说明](docs/windows-streams.md)。
下述最小构建命令继续生成不带可选连接器的基础版本。

构建主机安装 Visual Studio C++ x64 工具链与 CMake（不要求在 Server 2012 R2 上编译）。
准备 RapidJSON v1.1.0 头文件和合法取得、适用于目标系统的 Oracle Windows x64 OCI SDK/运行库。
SDK 布局为 `sdk/include/oci.h` 和 `sdk/lib/msvc/oci.lib`。Oracle DLL 不包含在本产品中。

```powershell
./scripts/build-windows.ps1 -OracleSdk C:/deps/oci-11.2 -RapidJson C:/deps/rapidjson
./scripts/verify-upstream-core.ps1
```

最小构建关闭 Kafka、ZeroMQ、Prometheus 和 Protobuf；保留 OCI 在线采集与 JSON 文件输出。
使用静态 C/C++ 运行库、x64 和 NT 6.3 subsystem；这些编译选项不能替代目标系统实测。
构建脚本执行二进制 IO、超过 4 GiB 偏移、并发定位读写、互斥、时钟、内存和异常传递测试。
产物位于 `dist/OpenLogReplicator-Windows`，包括 bin、config、logs、scripts，另有 checkpoint、swap。

## 配置与启动

编辑 `config/OpenLogReplicator.json` 中的数据库连接、账号和表过滤器。
将真实凭据置于受 ACL 保护的 `*.local.json`，不要提交到 Git。
数据库需要 ARCHIVELOG、补充日志及上游 `scripts/grants.sql` 指定的字典读取权限。
运行账号必须能直接读取 Online/Archived Redo，并能写入 logs、checkpoint、swap 和配置锁文件。
数据库连接成功并不意味着可以读取数据库服务器磁盘上的 Redo；跨主机部署须提供真实路径映射。

```powershell
./scripts/start-olr.ps1 -OracleHome C:/app/Administrator/product/11.2.0/dbhome_2 -ConfigFile C:/OLR/config/site.local.json
```

工作目录固定在产品根目录。检查点存放在 `checkpoint/`，不可在重启时清空。
`logs/cdc-%t.json` 是 CDC 数据输出，按上游文件 writer 的大小限制轮转；不应当作诊断日志删除。
默认配置是示例，不包含真实口令。现阶段安装路径和 checkpoint 路径使用 ASCII，完整 Unicode 路径兼容性待验证。

## Windows 服务

以管理员身份运行 64 位 PowerShell。先复制模板为 `config/site.local.json` 并配置实际连接。
服务使用独立虚拟账号 `NT SERVICE/服务名`，不使用管理员账号。
`ReadPaths` 指定实际 redo 文件及归档目录；对禁用继承的 redo 文件应逐个指定。
安装脚本给该账号 Oracle Home 读取/执行、指定 redo/archive 读取以及产品运行目录写入权限。
受保护的实际配置文件保留 ACL 保护，并单独授予该账号读取权限。

```powershell
./scripts/check-environment.ps1 -OracleHome C:/Oracle/product/11.2.0/dbhome_2 -ConfigFile C:/OLR/config/site.local.json
./scripts/install-service.ps1 -OracleHome C:/Oracle/product/11.2.0/dbhome_2 -ConfigFile C:/OLR/config/site.local.json -ReadPaths @('C:/Oracle/oradata/ORCL/REDO01.LOG','C:/Oracle/oradata/ORCL/REDO02.LOG','C:/Oracle/oradata/ORCL/REDO03.LOG','C:/Oracle/archive') -Start
./scripts/get-status.ps1 -Json
Stop-Service OpenLogReplicator
Start-Service OpenLogReplicator
./scripts/uninstall-service.ps1
```

服务设置为自动启动；失败恢复按 5、15、60 秒重启，24 小时重置计数，包含非零错误停止。
SCM STOP/SHUTDOWN/PRESHUTDOWN 走正常停止流程并保留 checkpoint。不要用强制终止代替常规停止。
Windows 主机没有为测试而重启，因此“自动启动”已验证配置，未实际进行服务器重启测试。
OCI 延迟加载，服务通过 `--oracle-home` 使用自己的运行库目录，不要求修改系统 PATH。

诊断日志为 `logs/OpenLogReplicator.log`，默认 10 MiB、保留 5 个备份，可用安装参数
`-LogMaxBytes` / `-LogKeep` 调整。CDC 文件使用独立命名和轮转，不随诊断日志保留策略删除。
卸载保留配置、日志、CDC 和 checkpoint；针对服务 SID 的 ACL 保留，以便原名重装。
升级前正常停止服务、备份配置和 checkpoint，再替换 bin；实际凭据使用单独的 `.local.json`，避免覆盖模板。

`get-status.ps1` 输出 SCM 状态、PID、启动模式、checkpoint SCN/时间及最新 CDC 文件。
Running 仅代表服务进程，不能证明 CDC 正在前进；空闲数据库可能没有新事件，应结合源库活动比较 SCN。

## 验证与发布门禁

按审计、最小编译、真实 Oracle、Windows 服务四阶段推进。
Server 2012 R2 测试服务器当前查询版本为 **Oracle 11.2.0.4.0**；不能将其结果称为已验证 11.2.0.1。
版本横幅和单次启动只是 smoke test，不能证明 CDC 数据正确。
实测步骤和边界见 [Oracle 验证记录](docs/windows-oracle-validation.md) 与
[阶段状态](docs/windows-validation-status.md)。已验证 DML、online/archive、日志切换、
检查点重启、专用 OCI 会话重连、缺失归档及补回，以及服务停止/重启/崩溃恢复和诊断日志轮转。
四阶段验收通过后才创建里程碑 commit，再启用可选组件。

GPL-3.0-or-later，保留上游版权及 [LICENSE](LICENSE)。分发二进制时须同时提供对应完整源码及构建说明。
Oracle 库遵循 Oracle 自身许可，请从合法安装介质取得。

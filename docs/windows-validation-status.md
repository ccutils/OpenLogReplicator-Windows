# Windows 阶段验收状态

2026-11-16。官方基线 v1.9.0 / 1a83a769e05eefd81fe5397205554f78290fa4f9。

|阶段|状态|实测范围|
|---|---|---|
|1 源码审计|完成|先保存审计与全项目扫描，再改源码；见 windows-portability-audit.md|
|2 最小编译|通过|Release x64、静态 CRT、subsystem 6.03；OCI + JSON 文件；真实 Server 2012 R2 启动及适配层测试|
|3 Oracle CDC|通过本轮范围|11.2.0.4.0；配置/Schema、DML、中文/NULL/回滚、Online/Archived、日志切换、crash checkpoint、OCI 重连、归档缺失/补回|
|4 Windows 服务|通过本轮范围|原生 SCM、虚拟账号、自动启动配置、正常/早期停止、checkpoint 重启、真实崩溃自动恢复、日志轮转、状态输出、保留数据的卸载与重装|
|里程碑 commit|四阶段验收后创建|对应本文件和基础产品实现；用 git log 查阅|
|Kafka/ZeroMQ/Prometheus|后续工作|最小包关闭；在基线提交后单独开始|

## 核心保护与测试

verify-upstream-core.ps1 确认 parser、OpCode、事务重组、builder、locales、RedoLogRecord 和数据运算均保持官方原样。
Types.h 只加入平台内存接口头。改动限于系统/编译器兼容、构建、文件 IO、同步唤醒和应用运维层。

本地和 Server 2012 R2 的 WindowsAdapterContracts 通过：二进制字节保真、超过 4 GiB 的 pread/pwrite/stat/truncate、
8 线程并发 IO 与文件位置保持、配置互斥/允许重读/释放、无效描述符返回、内存对齐、64 位 UTC、bit scan、异常传递、目录遍历。
PowerShell 语法检查与 git diff --check 通过。

实测修正了 Windows 时间戳冒号、非继承 ACL 文件、MSVC 异常复制、无效描述符 fail-fast、
后台致命错误退出码、早期停止丢失唤醒，以及 PowerShell 5.1 虚拟账号/服务路径引号兼容问题。

## 服务实测

- OLRWindowsValidation 使用专属 NT SERVICE\OLRWindowsValidation，不以管理员身份运行。
- 服务账号实际读取 OCI、字典、Online/Archived Redo 并输出测试行。
- 正常 STOP 成功，重启捕获停机期间变更，未重复本轮已确认事件。
- 只终止测试服务后，SCM 依配置自动恢复，新 PID 继续 CDC。
- 测试日志上限 4096 字节、3 个备份，数量和大小检查通过；产品默认 10 MiB、5 个备份。
- 卸载后配置、CDC、checkpoint 的全部取样文件 SHA-256 保持一致。
- 最终安装脚本通过原生 CreateServiceW 保留路径引号，重装后实际采集成功。
- 启动后立即 STOP 没有挂起，再启动可读取停机期间新建的归档。
- get-status.ps1 返回状态、PID、启动模式、checkpoint SCN/时间及 CDC 文件信息。

## 最终验证部署

192.168.2.5：C:\OLR-Windows-validation-20261116。
服务 OLRWindowsValidation 保留为 Running / Auto，使用已有 Oracle 11.2.0.4 dbhome_2。
专用 Schema OLRW_20261116_7A32 和测试数据保留，凭据只在服务器受 ACL 保护的 .local.json。
Oracle 库与真实凭据不进入产品包或 Git。
服务只读指定 redo 文件、归档和 Oracle Home，写入产品运行目录。
原始归档未删除/移动，未停止或重启数据库/监听。

## 验证边界

11.2.0.1 按用户最新指示留待后续。未为测试重启整台服务器；自动启动验证了 SCM 配置。
已测试 Server 2012 R2 和本地 Windows 启动，不代表所有更高 Server 版本、全部 Oracle 类型、
LOB/大事务/压力负载、长路径和 Unicode 安装路径均已完成生产认证。
文件输出与 checkpoint 不提供任意故障下的原子 exactly-once 承诺；本轮明确验证的是稳定确认边界后的恢复。
SCM Running 不等于 CDC 有进展，应结合源库活动观察 SCN。

Oracle 详细证据见 windows-oracle-validation.md。原始证据在服务器 logs/test-results，本地副本在被忽略的 test-results。
复核脚本在 tests/windows，依赖来源和校验和在 dependencies.json。
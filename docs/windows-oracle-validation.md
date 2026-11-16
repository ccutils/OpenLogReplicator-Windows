# Oracle 11.2.0.4 实测记录

2026-11-16，Windows Server 2012 R2 Datacenter 6.3.9600，Oracle 11.2.0.4.0 x64。
连接与读取使用现有 dbhome_2 OCI。11.2.0.1 未测试。
测试 Schema `OLRW_20261116_7A32`、64 MiB USERS 配额和上游字典权限已获用户具体授权后创建。
业务表、数据库/监听服务、原始归档文件未被删除、移动或停止。

|项目|实测结果|
|---|---|
|数据库配置/Schema|OCI 读取版本、ARCHIVELOG、补充日志、ZHS16GBK/AL16UTF16 字符集、在线日志与表定义成功|
|Online Redo|直接共享读取正在使用的 REDO02.LOG，序列 3983；随后继续新序列|
|INSERT/UPDATE/DELETE|4 个提交事件按 c/u/c/d 输出；核对主键、before/after、NULL；中文按 Unicode U+4E2D U+6587 精确断言|
|ROLLBACK|插入后回滚的 ID=103 未产生输出事件|
|输出故障恢复|发现上游 `%F_%T` 时间戳冒号不合法；修正 Windows 默认及配置，原 checkpoint 补读四个未输出事件成功|
|Checkpoint crash 恢复|等待 writer checkpoint 确认后，仅终止验证 OLR；停机期间写入 ID=201 并更新 ID=102；重启捕获两项变更|
|Archived Redo|从实际序列 3983 `.ARC` 读取停机期间变更；随后继续 Online 序列 3984|
|重复与最终状态|本次已稳定 checkpoint 的恢复测试中输出 c_scn/c_idx 身份无重复；用 PL/SQL 核对最终两行数据和 CDC 一致。这不是全局 exactly-once 承诺|
|OCI 断开/重连|online-keep + ARCH_ONLY 归档轮询模式，只 kill 隔离账号的唯一 OLR 会话；检测 Oracle 错误、重新连接，SID 98 serial 从 2629 变为 2631；ID=302 捕获成功|
|缺失归档|复制 checkpoint，使用空 fixture 路径映射；重试 10 次后明确报错，实际进程退出码 1，未生成虚假 CDC|
|归档补回|只复制序列 3985/3986 到 fixture，SHA-256 与原文件一致；原 checkpoint 恢复唯一未确认的 ID=401，正常退出码 0|

在线尾读模式可以继续读取磁盘而不立即调用 OCI，因此“杀死 OCI 会话后仍有输出”本身不证明重连。
重连测试明确启用上游归档轮询模式，要求同时出现 ORA 错误、重连日志、新会话和正确 CDC 事件。

测试期间还修正 Windows 入口的后台致命错误退出码，以及检查点线程的条件变量等待谓词，
避免服务停止发生在 mainLoop 等待之前时丢失唤醒。这些修改属于应用生命周期/同步层。
parser、OpCode、事务重组、builder、字符解码和数据运算保持官方 v1.9.0 原样。

可复核步骤保存在 `tests/windows/remote-*.ps1`、`oracle-dml.sql`。
这些脚本记录本次隔离实例的路径、序列和测试 ID；准备脚本拒绝覆盖已存在 Schema，
不能当作对任意业务实例无条件重跑的脚本。
原始日志与结构化摘要存放在验证服务器 `test-results/`、`logs/`，本地取回副本放在被 Git 忽略的 `test-results/`。

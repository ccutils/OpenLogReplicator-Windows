# Windows TCP Stream / ZeroMQ

本轮连接器包启用 OCI、JSON 文件、Kafka/SCRAM、Protobuf、TCP Stream、ZeroMQ；Prometheus 关闭。
这是在基线 commit b9d8fc9b7d4200a0154325c0c94a39717d3d1bf2 之后的工作区快照，
对应源码及依赖源码随连接器 source.zip 提供。旧基线 ZIP 保留。
源码包 third-party/ 下包含五份官方依赖源码 ZIP 及 SOURCES.json；
将各 ZIP 的顶层目录解压到 vendor/，即可得到构建脚本预期的 vendor/protobuf、vendor/libzmq 等目录。
SDK 构建脚本目前通过 git rev-parse 校验固定 commit，使用源码 ZIP 时应先从对应官方 tag 创建
Git checkout，再将其作为 vendor 目录；ZIP 提供完整的对应源码备份，不伪造 Git 提交记录。
Oracle OCI SDK 和本机构建工具（包括构建 OpenSSL 所用原生 Windows Perl）需另外合法取得。

## 配置与客户端

从 config/OpenLogReplicator-network.json 或 OpenLogReplicator-zeromq.json 复制为受 ACL 保护的 site.local.json，
填写 Oracle 连接及表过滤器。模板使用 JSON 输出；将 source[0].format.type 改为 protobuf 可输出二进制 Protobuf。
按 README 的启动脚本或服务安装脚本选择该配置。默认主配置继续使用文件输出。
每份示例选择一种 writer；同一个 source 的这些模板不表示同时广播多个 sink。

两个模板默认绑定 loopback：

| writer.type | writer.uri | 客户端 transport |
|---|---|---|
| network | 127.0.0.1:15081 | network |
| zeromq | tcp://127.0.0.1:15082 | zeromq |

首次启动服务端等待客户端指定起点，尚未开始采集并不代表失败。产品根目录运行：

```powershell
./bin/StreamClient.exe network 127.0.0.1:15081 ORCL json now
./bin/StreamClient.exe zeromq tcp://127.0.0.1:15082 ORCL json now
```

服务端已经进入复制状态时，使用 `c:<scn>,<idx>` 指定应用持久化的确认位置；两个数都必须保留 64 位精度。
客户端可加 `--max-messages 12`，收到指定数量后发送 CONFIRM，并观察 INFO 的确认回复后退出。
未指定数量时持续接收，按上游策略每 1000 条或接收到消息且距上次确认超过 10 秒进行确认。
业务消费者应在业务持久化成功后确认，不能把示例客户端的打印行为当成业务交付保证。
重连时允许重放，业务消费者需按事务/检查点位置幂等处理。

TCP 是 OLR 消息流协议，需要 INFO/START/CONTINUE/CONFIRM 握手，不能直接接收裸 JSON 文本。
控制消息始终使用 proto/OraProtoBuf.proto，即使数据格式为 JSON。
TCP 每帧为小端 uint32 长度及消息体；长度 0xffffffff 后追加小端 uint64 长度。
READY 可序列化为空消息，其 TCP 帧长度为 0。
ZeroMQ 使用单个 PAIR 对等端和原生消息边界，不添加 TCP 长度头，不是 PUB/SUB，也不是多个独立消费者广播。
公开数据头 c_idx 比 writer 内部的确认索引大 1；发送 CONFIRM/CONTINUE 时使用 `c_idx - 1`。
随包客户端已处理该转换。

两种传输当前均未启用应用认证或传输加密；ZeroMQ CURVE 未编译。
本轮测试通过 SSH 隧道访问 loopback，没有更改服务器防火墙。
跨主机使用可优先沿用 SSH 隧道；如修改绑定地址，应配置实际网络访问控制。

## 构建

依赖固定为 Protobuf v21.12（与上游生成文件 3.21.12 匹配）及 libzmq v4.3.5，均静态 /MT。
libzmq 设置 NT 6.3、select 后端、关闭 Windows 10 AF_UNIX IPC、CURVE、WebSocket 和 drafts。
完整版本/commit 见 stream-dependencies.json；第三方许可在 licenses/。
先从官方仓库取得相应源码到 vendor/protobuf、vendor/libzmq，再运行：

```powershell
./tools/build-stream-sdk.ps1
./tools/build-windows-connectors.ps1 -OracleSdk C:/deps/oci-11.2 -RapidJson C:/deps/rapidjson -RdKafka C:/deps/kafka-scram -OpenSSLRoot C:/deps/openssl -Protobuf C:/deps/protobuf -ZeroMQ C:/deps/libzmq
```

Kafka/OpenSSL 的构建步骤见 windows-kafka-validation.md 和 tools/build-*-sdk.ps1。
Oracle DLL 不包含在任何发布包中。protobuf 生成文件保持上游原样。
仅将 Protobuf 数字输出中的 strtol 改为 strtoll，恢复 Windows LLP64 下预期的 64 位整数转换。
verify-upstream-core.ps1 对该单行差异精确校验；Redo 解析、事务重组和字符集解码无修改。

## 验证记录：2026-11-17

真实测试系统：192.168.2.5，Windows Server 2012 R2 6.3.9600，Oracle 11.2.0.4.0。
独立目录 experimental/streams，独立 checkpoint，未替换/重启基线 Windows 服务。

| 项目 | 结果 |
|---|---|
| 文件适配契约 | 本机及 Server 2012 R2 通过 |
| TCP 传输契约 | 分片、二进制、空帧、64 位长度、超长拒绝、关闭、重连、停止通过 |
| ZeroMQ 传输契约 | 二进制、空帧、超长拒绝、停止及析构通过 |
| TCP + JSON + 真实 OCI | 独立 Python socket 客户端核对 12 消息 / 4 DML，通过 |
| ZeroMQ + Protobuf + 真实 OCI | 独立 pyzmq/Protobuf 客户端核对 12 消息 / 4 DML，通过 |
| 内容核对 | INSERT/UPDATE/DELETE、中文、NULL、回滚未输出，通过 |
| 控制协议 | 错误数据库、START、CONFIRM、断线重连/CONTINUE，通过 |
| TCP 最终确认位置 | 65077217069 / 2，服务端回复一致 |
| ZeroMQ 最终确认位置 | 65077217250 / 2，服务端回复一致 |
| 原生 StreamClient | Server 2012 R2 上 ZeroMQ/Protobuf 接收 3 条、确认回复、退出 0 |
| 随包客户端独立协议测试 | 本机 Python TCP 对端核对空 READY、64 位 SCN、索引转换、最终确认及退出 0 |
| 基线服务 | Running，PID 5032，基线 EXE 哈希未变 |

原始消息和断言位于本地 test-results/streams（未分发测试数据/真实配置）。
停止测试时仅终止独立验证进程，保留 checkpoint、证据及测试表数据；不将其称为新流服务的正常停止验收。
本轮没有执行主机重启、长时间压力测试、所有 Oracle 类型矩阵、跨 Linux 客户端互通或 Oracle 11.2.0.1 验证。
Kafka 真实 broker 验证见 windows-kafka-validation.md；本次完整包包含同一 Kafka 实现，尚未对完整包重跑 broker DML。

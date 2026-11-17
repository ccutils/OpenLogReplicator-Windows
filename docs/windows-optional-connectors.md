# 可选组件对接 — 基线提交之后

基础产品已在 commit `b9d8fc9b7d4200a0154325c0c94a39717d3d1bf2` 完成四阶段验收。
该版本的二进制/源码包已冻结，可选组件工作不替换已运行的验证服务。

## Kafka：SASL/SCRAM 真实 broker 输出已验证

- 取得官方 librdkafka v2.8.0，commit `b4c608570f796c18ff2211a7af876046d264d392`，源码在忽略的 vendor 中。
- Windows 构建改为使用 SDK 导出的 `RdKafka::rdkafka`，不沿用 Linux `.a`/`rdkafka++` 链接名称。
  OLR 当前 writer 只使用 C API，无需为它额外链接 C++ wrapper。
- LibWriter 通过 imported target 继承静态库宏、头文件与系统依赖。
- 必须明确设置 `OLR_WINDOWS_EXPERIMENTAL_CONNECTORS=ON`，默认最小构建仍关闭 Kafka。
- 单独使用 build-kafka，初始 SDK 为 /MT、NT 6.3、静态库，关闭外部 TLS/SASL/压缩库依赖。
  初始配置仍可复现；本轮另建 OpenSSL 3.5.9 + kafka-scram SDK，启用 SSL/SASL 以支持 SCRAM。TLS、断连与队列满仍需分别验证。
- 复现入口：tools/build-kafka-experimental.ps1；不会安装到冻结的基线产品目录。
- SDK 的固定版本构建入口：tools/build-rdkafka-sdk.ps1；源码需先从官方仓库取得 v2.8.0，脚本检查 commit。
- Kafka 头引入 Winsock 后，发现 timeval 名称冲突；后续工作已改用独立的 64 位 Windows UTC 时钟接口，
  保留 POSIX 时钟分支与相同时间单位，避免假装替换 Winsock 的结构。
- 实验 EXE 已编译，适配层契约测试在本地和 Server 2012 R2 均通过。
  在旧服务器使用真实 OCI 运行库启动，模块横幅为 `Kafka OCI`，退出码 0。
  文件位于验证根目录 experimental/kafka，没有替换 bin 内的基线 EXE；基线服务 PID 与哈希保持不变。
- 已按用户提供的 SASL_PLAINTEXT / SCRAM-SHA-256 配置连接真实 broker，使用 app_user 投递并独立消费专用 topic 的 12 条消息，4 条 DML 全部通过核对；详见 windows-kafka-validation.md。

复现（先取得指定版本源码）：

```powershell
./tools/build-rdkafka-sdk.ps1
./tools/build-kafka-experimental.ps1 -OracleSdk C:/deps/oci-11.2 -RapidJson C:/deps/rapidjson -RdKafka C:/deps/kafka
```

连接器工作保留在基线 commit 之后的工作区中。现已打入独立 connectors 二进制/源码包，旧基线发布包保留。

已修复空 producer 析构检查，并增加正常停止时的 Kafka flush 和未确认消息失败处理；投递确认、磁盘 checkpoint 与短跑恢复已核对。持续故障与压力仍需专项测试。
不通过更改 Redo/事务解析器处理 sink 问题。

## TCP Stream / ZeroMQ：已启用并验证

已增加独立 Winsock 实现，使用指针宽度 SOCKET、非阻塞 IO、分片状态和错误码映射。
固定 Protobuf v21.12 与 libzmq v4.3.5，静态 /MT、NT 6.3。
TCP/JSON 与 ZeroMQ/Protobuf 均已在 Server 2012 R2 上连接真实 Oracle 11.2.0.4，
由独立客户端核对 DML、中文、NULL、回滚、确认与重连。
连接器包包含 StreamClient.exe、协议文件及配置模板，详见 [流输出说明](windows-streams.md)。

## Prometheus：已识别前置工作

需要 Windows 导出的 prometheus-cpp target 及 pull 依赖 CivetWeb，统一静态 CRT 与最低 OS。
后续先在 loopback 绑定，验证指标内容、采集并发、服务停止和 Server 2012 R2 运行。
此项目前保持构建门禁。

依赖接口依据官方仓库：
[librdkafka CMake](https://github.com/confluentinc/librdkafka/tree/v2.8.0/packaging/cmake)、
[prometheus-cpp](https://github.com/jupp0r/prometheus-cpp)、
[libzmq CMake](https://github.com/zeromq/libzmq/blob/master/CMakeLists.txt)。
这些文档和源码支持构建接口判断，不代表相关库已在本项目通过全部旧系统/协议验收。

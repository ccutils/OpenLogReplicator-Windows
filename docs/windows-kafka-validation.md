# Kafka 实际输出验证

2026-11-16，原生 Windows Server 2012 R2 6.3.9600 + Oracle 11.2.0.4 x64。
结果：本轮真实 broker 功能验证通过；不是仅验证 EXE 启动或客户端连通。

## 范围与配置

- Broker：192.168.3.165:9092。
- 协议：SASL_PLAINTEXT；机制：SCRAM-SHA-256。
- OLR producer 和独立 consumer 均使用 app_user。
- 管理员只用于创建本次专用 topic；没有修改其他 topic、Kafka ACL、broker 设置或已有消费组偏移。
- Topic：`olrw_win2012_cdc_20261116_18f19837`，1 分区、1 副本，保留期 86400000 ms。
- Oracle 源：已授权的隔离表 OLRW_20261116_7A32.CDC_TEST；使用独立 Kafka checkpoint。
- 本轮 Kafka 测试进程正常结束，topic 保留供复核。原文件输出服务保持 Running，基础 EXE 哈希不变。

原生运行依赖为 librdkafka 2.8.0 + OpenSSL 3.5.9，静态 /MT、NT 6.3 目标。
独立验证工具使用 confluent-kafka Python 2.16.1。源码 commit 与最终二进制哈希见 kafka-dependencies.json。
密码仅位于忽略且受 ACL 保护的 .local.json，不进入源码、报告或命令行参数。

## 数据核对

|Oracle 操作|期望 Kafka 事件|结果|
|---|---|---|
|INSERT ID=8096341，VALUE=kafka-first，OPTIONAL_VALUE=NULL|c，完整 after|通过|
|UPDATE ID=8096341，VALUE=中文，OPTIONAL_VALUE=kafka-updated|u，准确 before/after 和 Unicode U+4E2D U+6587|通过|
|INSERT ID=8096342，VALUE=kafka-retained|c，完整 after 与 NULL|通过|
|DELETE ID=8096341|d，准确 before|通过|
|INSERT ID=8096343 后 ROLLBACK|不产生 DML 事件|通过|

独立消费者从专用分区 offset 0 读到 11，共 **12 条消息**：
4 个 begin、4 个 DML（c/u/c/d）、4 个 commit。
所有 c_scn/c_idx 身份唯一，顺序、值、Schema、中文、NULL、回滚和事务边界均通过断言。
SQL 端同时断言此范围最终只保留 ID=8096342，VALUE=kafka-retained。
消费者使用 assign，不订阅其他 topic，不自动提交或保存 offset。

## 确认、停止和短跑恢复

- 正常停止前 Kafka flush 完成，进程退出码 0，未发现投递失败或未确认消息。
- 首轮末条消息 c_scn=65077114283、c_idx=3；持久 writer checkpoint 为同一 SCN、idx=2。
  这是上游计数语义：Builder::builderBegin 保存 lwnIdx 后自增，JSON appendHeader 写出自增后的值；
  内部 checkpoint 为零基，JSON 计数比它大 1。没有为匹配断言而修改解析器。
- 保留原 checkpoint 做短跑重启，日志精确加载 65077114283/2；再次独立消费，仍只有原 12 条，没有重发。
- 随后磁盘水位推进到 65077114440/1。上游会本地确认不对外发布的 CHECKPOINT 消息，因此磁盘水位可高于最后一条 Kafka DML；
  验证器检查覆盖关系，并检查重启日志中载入的原始确认点。
- 短跑使用上游 debug 事务计数，可能计入重放或回滚事务；没有将此结果称为长期重启可靠性或全局 exactly-once 证明。

## 实现与测试边界

已补齐 SCRAM/OpenSSL 构建；Kafka writer 初始化失败时不再对空 producer 查询错误；
正常停止会等待投递确认，flush 超时或仍有未确认消息时报告失败，不冒充成功。
旧无 SCRAM 构建的负向初始化测试返回 1，没有空句柄崩溃。
适配层契约测试通过，Redo 解析器、OpCode、事务重组、builder 和字符解码保持官方原样。

首轮 1 MiB builder 限制触发了上游预留 TransactionChunk 空间的 60015 分段提示；本轮每个提交事务只有一条 DML，
消费结果与源事务一致。短跑配置改为 10 MiB；没有修改分段逻辑。
大型事务、broker 消息大小边界、持续压力、TLS、网络中断与 broker 故障仍需单独验证。

复核工具：tools/kafka-validation.py、tests/windows/remote-*kafka*.ps1。
本地原始证据：test-results/kafka/consumed.jsonl、verification.json、SQL 结果与原生日志；均被 Git 忽略。
Kafka 后续改动尚未单独 commit，已提交的 b9d8fc9 基线发行包未被替换。

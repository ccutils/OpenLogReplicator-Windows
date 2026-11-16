# Windows 移植审计 — v1.9.0

审计日期：2026-11-16。基线：官方 tag `v1.9.0`，commit
`1a83a769e05eefd81fe5397205554f78290fa4f9`。
审计完成时未修改任何上游源码。原始全项目扫描证据保存在 `audit-*.json`；
覆盖所有 C/C++ 文件，另外人工检查根目录及 src 的 CMake、配置模板、README、OCI 封装。
扫描结果是静态证据，不等于运行验证。

## 产品边界与不可突破项

目标：原生 x64 Windows Server 2012 R2（NT 6.3）及以上；不是 WSL/Cygwin 产品。
不修改 parser、OpCode、事务重组、字符集解码、字段布局或 redo 校验。
不得为消除错误而关闭块校验或忽略数据错误。适配层必须保持原始字节和 64 位偏移。
依赖应满足同一最低系统版本，不能用 EXE 的 PE subsystem 版本代替实机验证。
发布遵循上游 GPL-3.0-or-later，保留版权、许可证和对应源码。

## 工作量清单

以下人日是工程估算，不是已完成承诺；不包含发现 redo 数据差异后的调查时间。

|领域|具体证据与问题|适配方案与验收|估算人日/风险|
|---|---|---|---|
|构建|CMakeLists.txt：GCC flags、Linux OCI 库名、静态 .a、ZeroMQ Linux 路径；config.h 生成在源码根|隔离 MSVC flags；x64、C++17、/MT；Windows OCI import lib；可选模块默认关闭；可重现构建与依赖清单|2–3/中|
|POSIX 头|main.cpp 的 pthread.h、sys/utsname.h；Ctx.cpp 的 execinfo.h；多处 unistd.h、dirent.h、sys/time.h、sys/file.h|Windows 专用适配头/实现，仅在 WIN32 生效，保持 Linux 构建入口|1–2/中|
|文件与锁|OpenLogReplicator.cpp:139–153 open/flock/stat/read；Checkpoint.cpp:61–81 重载配置|二进制模式；CreateFile 共享读写/删除；LockFileEx 实现非阻塞进程互斥；故障不能假成功|2–3/高|
|定位读写|ReaderFilesystem.cpp:58–110 stat/open/pread；Reader.cpp pwrite；MemoryManager.cpp:248–397 swap|64 位 stat/seek；定位读写需并发安全；短读/短写和 errno 不隐藏；验证 >4 GiB 偏移、在线 redo 共享访问、swap 往返|3–5/高|
|目录与路径|ReaderFilesystem、Replicator、WriterFile、StateDisk、MemoryManager 的 DIR/readdir/S_ISDIR|FindFirstFile/FindNextFile；明确 UTF-8/UTF-16、分隔符、绝对路径、服务工作目录；测试中文路径和空目录|2–3/中|
|内存|Ctx.cpp、Reader.cpp aligned_alloc/free；项目扫描未发现 mmap/munmap|_aligned_malloc 与 _aligned_free 成对；保持块对齐/尺寸；大内存、swap、分配失败验证|1–2/高|
|线程/同步|Ctx.cpp pthread_create/join/self/kill；Thread.h pthread_t；主要同步已使用 std::mutex/condition_variable/atomic|仅移植线程启动/回收和诊断接口；不改变事务线程模型；压力、停止、重启与死锁验证|2–3/高|
|时钟/时区|ClockHW.cpp gettimeofday；Ctx.cpp tzset/timezone；usleep 分布多处|64 位 UTC 时钟、Windows 时区与微秒等待；避免 Windows long=32 位的乘法溢出|1–2/中|
|信号/诊断|main.cpp SIGINT/SIGPIPE/SIGSEGV/SIGUSR1；Ctx.cpp backtrace、pthread_kill|控制台处理器与 SCM stop 触发正常关闭；Windows 栈诊断；不能把不支持的信号伪装为已支持|2–3/中|
|编译扩展|Types.h likely/unlikely；Builder/Writer prefetch；unused attributes 多处|编译器兼容定义保留表达式求值；只适配编译器语法；逐文件比对 parser 与数据结构未改|1–2/中|
|OCI|DatabaseEnvironment/Connection/Statement、ReplicatorOnline；上游默认 OCI 23|使用 Windows x64 OCI SDK 与 oci.lib；头文件/运行库一致；核实 11g 数据库与旧 OS 支持；不提交/再分发未获许可的 Oracle 库|2–4/高|
|依赖|RapidJSON 必需；OCI 在线模式必需；Kafka=librdkafka、Protobuf、ZeroMQ、prometheus-cpp 可选|阶段二仅 RapidJSON + OCI；记录来源、版本、校验和与许可；后续逐个启用及故障测试|1–2 基线；可选组件另计|
|服务产品化|上游仅控制台程序；文件 writer 已有轮转逻辑|原生 SCM 生命周期/自动启动/失败恢复、诊断日志轮转、ACL、配置与状态检查、可卸载；不得强杀冒充正常 checkpoint|4–6/高|

基线适配及服务约 24–40 人日；真实 Oracle 验证与差异调查另预留 5–10 人日。
各项可重叠，估算须随编译和实机证据调整。

## 分阶段验收门禁

1. 本审计和全项目原始扫描先落盘；再进入代码修改。
2. 编译产物必须明确包含 OCI、JSON/文件 writer；Kafka、ZeroMQ、Prometheus、Protobuf 关闭。
   在 Server 2012 R2 实机检查依赖并启动；版本输出仅证明启动，不证明 CDC 正确。
3. 对专用测试表核对数据库行和输出事件的 INSERT/UPDATE/DELETE，另测提交/回滚、NULL/中文、日志切换、
   online/archive、checkpoint 重启边界、断开/重连、缺失归档；保存 SQL、日志、输出和判定依据。
   不停止共享数据库/监听、不删除真实归档。异常测试须隔离到 OLR 进程或归档副本。
4. 验证服务控制、正常停止、自动启动、异常恢复、日志轮转、配置错误、运行状态及卸载。
5. 阶段 1–4 全部通过后才制作用户要求的里程碑 commit；之后对接可选组件。
   未通过项目必须明确标为未验证，不能以 smoke test 代替。

## 已确认环境

通过用户授权 SSH 只读查询：192.168.2.5 是 Windows Server 2012 R2 Datacenter 6.3.9600，
OracleServiceORCL 与 home1 监听运行。PATH 中 SQLPlus 来自 dbhome_2；实际服务 Oracle Home、
数据库版本、ARCHIVELOG、补充日志、数据文件/redo 路径及 OCI SDK 需进一步核实。
本地有 Visual Studio 18 Professional 和 Instant Client 23_26；后者不能据此认定满足目标 OS。

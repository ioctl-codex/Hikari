# Hikari-LLVM22

Out-of-tree LLVM 混淆 Pass 插件，可在 **opt / rustc nightly** 上动态加载，无需重编 LLVM 或 rustc。

提取自 [Hikari-LLVM15](https://github.com/61bcdefg/Hikari-LLVM15) By 61bcdefg。

> **平台说明**：目前仅在 **macOS arm64** 上编译并验证过（C + Rust）。其他平台未完整测试。  
> 若混淆后运行异常，可先将优化级别设为 **`-C opt-level=0`**（Rust）或 **`-O0`**（C）。

## 版本对齐

| 组件 | 版本 |
|------|------|
| 本插件目标 LLVM | **22** |
| Homebrew `llvm` | 22.1.x（`brew install llvm`） |
| rustc stable | 1.97.x（LLVM 22） |
| rustc nightly | 1.99.x-nightly（LLVM 22） |

**rustc 的 LLVM 主版本必须与编译本插件时使用的 LLVM 一致**，否则 `-Zllvm-plugins` 可能无法加载。

## 编译

### 依赖

- CMake ≥ 3.20、Ninja
- LLVM 22 开发包（含 headers / cmake 配置）
- macOS：`brew install llvm ninja cmake`

### 构建

```bash
cmake -G "Ninja" -S . -B ./build \
      -DCMAKE_CXX_STANDARD=17 \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_SHARED_LIBS=ON \
      -DLT_LLVM_INSTALL_DIR=/opt/homebrew/opt/llvm
cmake --build ./build
```

将 `LT_LLVM_INSTALL_DIR` 换成你的 LLVM 22 安装前缀（CMake 默认值同样是 `/opt/homebrew/opt/llvm`）。

| 平台 | 产物路径 |
|------|----------|
| macOS | `build/obfuscation/libHikari.dylib` |
| Linux | `build/obfuscation/libHikari.so` |

## 使用

### Rust（nightly 动态加载）

```bash
rustup toolchain install nightly

cargo new helloworld --bin
cd helloworld
cargo +nightly rustc --release -- \
  -C opt-level=0 \
  -Zllvm-plugins="/绝对路径/libHikari.dylib" \
  -Cpasses="hikari(enable-bcfobf,enable-cffobf,enable-strcry)"
```

### opt（C/C++ 等）

```bash
clang -O0 -emit-llvm -c input.c -o input.bc

opt -load-pass-plugin="/绝对路径/libHikari.dylib" \
    --passes="hikari(enable-bcfobf,enable-cffobf,enable-strcry)" \
    input.bc -o output.bc

llc -filetype=obj output.bc -o output.o
clang output.o -o output
```

流水线名字必须是 **`hikari(...)`**，内部再写具体开关。

## 开关一览

| 开关 | 说明 |
|------|------|
| `hikari(...)` | 启用调度（**必须**作为外层 pass 名） |
| `enable-allobf` | 打开大部分混淆（见下方说明） |
| `enable-bcfobf` | 虚假控制流 |
| `enable-cffobf` | 控制流平坦化 |
| `enable-subobf` | 指令替换 |
| `enable-splitobf` | 基本块分割 |
| `enable-strcry` | 字符串加密（C 字符串 / Rust 字符串数据） |
| `enable-constenc` | 常量加密 |
| `enable-indibran` | 间接跳转 |
| `enable-fco` | 函数调用混淆（`dlopen`/`dlsym` 风格） |
| `enable-funcwra` | 函数包装（已知不稳定） |
| `enable-antihook` | AntiHook（AArch64 inline / antirebind） |
| `enable-adb` | AntiDebugging |
| `enable-vmp` | **IR 虚拟化（VMP）**：将函数译为自定义 bytecode + 解释器 |

`enable-allobf` 会打开：`bcf`、`cff`、`sub`、`split`、`strcry`、`indibran`、`fco`、`funcwra`。  
**不会**打开：`constenc`、`antihook`、`adb`、`vmp`（需单独指定）。

也可用环境变量（非 `hikari()` 参数时）：`BCFOBF`、`CFFOBF`、`SUBOBF`、`SPLITOBF`、`STRCRY`、`INDIBRAN`、`FCO`、`FUNCWRA`、`ANTIHOOK`、`ADB`、`CONSTENC`、`ALLOBF`、`VMP`。

### VMP（`enable-vmp`）

IR 级虚拟机保护：将函数译为自定义 bytecode + 栈上可重入解释器。

| 方式 | 说明 |
|------|------|
| 函数标注 | `__attribute__((annotate("vmp")))`；排除 `novmp` |
| 管线 | `hikari()` 仅处理标注；`hikari(enable-vmp)` 尝试模块内所有可译函数 |
| 环境变量 | `VMP=1` 等同 `enable-vmp` |
| 加密 | 默认开启 L1 双 seed（opcode + 整 BB）；`VMPNOENC=1` / 标注 `novmpenc` 关闭；`VMPENCRYPT=1` / 标注 `vmpenc` 强制开 |
| 与平坦化结合 | `hikari(enable-vmp,enable-cffobf)`：**先 VMP、再 CFF**（自动跳过 VMP 目标上的前置 CFF，避免「平坦化后再整段虚拟化」体积爆炸） |
| 加固 | `VMPHARDEN=1` / 标注 `vmpharden`：等同对虚拟化后函数+辅助函数跑 CFF（无 enable-cffobf 时也可单独开） |

**支持的 IR（-O0 友好）**

- 内存：`alloca` / `load` / `store`（alloca 结果为真实 VA，可外传指针）
- 整数：binop / icmp（含有符号）/ cast / select
- 控制流：`br` / `ret` / `unreachable`
- `gep`：常量偏移、单索引、常见 `[0, i]` 数组形态
- `call`：直接/间接，经 `vmp_ch_*` handler 出站
- 全局变量 / 函数指针：启动器写入 data 槽

**运行时模型**

- 每调用独立：`data` / `ip` / 解密状态均在栈上 → **默认可重入**（含递归 VMP 函数）
- 字节码：`@vmp_code_<fn>`；BB seed 表：`@vmp_seeds_<fn>`
- 不支持则 **整函数 skip**（可观测 `[VMP] skip/translate fail` 日志），不损坏 Module

**明确不支持（hard-fail skip）**

- 变参、异常/EH、浮点、向量、复杂多动态索引 GEP

建议目标函数 `-O0` / `optnone`。验收：`./samples/run_vmp.sh`。

**完整文档**（架构 / 字节码 / 开关 / 与 CFF 混合 / 排障）：[`docs/VMP.md`](docs/VMP.md)。

### 已移除

- **Objective-C** 相关能力已全部去掉（无测试环境）：
  - `enable-acdobf` / AntiClassDump
  - FCO 的 class/sel 改写
  - strcry 的 CFString / NSString
  - antihook 的 ObjC runtime 检测

本仓库面向 **C / Rust / 普通 LLVM IR**。

## 示例

仓库内带对比脚本：

```bash
# 先按上文编译插件，再：
./samples/run_demo.sh
./samples/run_vmp.sh    # VMP 正确性验收
```

详见 [`samples/README.md`](samples/README.md)。

## 注意

1. **动态加载**需要 host（`opt` / `rustc`）与插件 LLVM **主版本一致**。
2. `enable-strcry` 在部分 Rust 代码上仍可能不稳；出问题可先关掉 strcry 或降 opt level。
3. `enable-funcwra` 历史注释为 Broken，不建议默认开启。
4. 控制流类 pass（尤其 `indibran` + `bcf`）会明显增大体积与编译时间。

## 感谢

- [Hikari-LLVM15](https://github.com/61bcdefg/Hikari-LLVM15) By 61bcdefg
- [ollvm-rust](https://github.com/0xlane/ollvm-rust) By 0xlane

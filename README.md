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

`enable-allobf` 会打开：`bcf`、`cff`、`sub`、`split`、`strcry`、`indibran`、`fco`、`funcwra`。  
**不会**打开：`constenc`、`antihook`、`adb`（需单独指定）。

也可用环境变量（非 `hikari()` 参数时）：`BCFOBF`、`CFFOBF`、`SUBOBF`、`SPLITOBF`、`STRCRY`、`INDIBRAN`、`FCO`、`FUNCWRA`、`ANTIHOOK`、`ADB`、`CONSTENC`、`ALLOBF`。

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

# Hikari-LLVM22

~~**enable-strcry在rust中可能存在问题，其他自行测试**~~

经过修复，strcry**可能**可以使用

编译后运行出现错误请设置opt level为0


> Warning: 仅在mac arm64上编译通过，仅测试过rust语言下的表现，未经过完全测试

混淆插件提取自 [Hikari-LLVM15](https://github.com/61bcdefg/Hikari-LLVM15) By 61bcdefg 项目。

本仓库已移植到 **LLVM 22**（与当前 rustc 1.97 stable / 1.99 nightly 所带 LLVM 版本一致）。

## 编译

### 环境
- macOS (arm64)
- LLVM 22.1.x（Homebrew: `brew install llvm`）

```bash
cmake -G "Ninja" -S . -B ./build \
      -DCMAKE_CXX_STANDARD=17 \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_SHARED_LIBS=ON \
      -DLT_LLVM_INSTALL_DIR=/opt/homebrew/opt/llvm
cmake --build ./build
```
**注意要将 `LT_LLVM_INSTALL_DIR` 换为自己的 LLVM 22 安装路径；CMake 默认值是 `/opt/homebrew/opt/llvm`。**

产物：`build/obfuscation/libHikari.dylib`（Linux 上为 `libHikari.so`）

## rust 动态加载

动态加载 llvm pass 插件需切换到 nightly 通道（或使用动态链接 LLVM 的 rustc 构建）。

> rustc 的 LLVM **主版本**需与编译本插件时使用的 LLVM 一致（当前为 22）。

```bash
rustup toolchain install nightly
```

生成一个示例项目，通过 `-Zllvm-plugins` 参数加载 pass 插件，并通过 `-Cpasses` 参数指定混淆开关：

```bash
cargo new helloworld --bin
cd helloworld
cargo +nightly rustc --release -- \
  -C opt-level=0 \
  -Zllvm-plugins="path/to/libHikari.dylib" \
  -Cpasses="hikari(enable-fco,enable-strcry)..."
```

## opt 动态加载

```bash
# 使用 clang 编译源代码并生成 IR
clang -emit-llvm -c input.c -o input.bc

# 使用 opt 工具加载和运行自定义 Pass
opt -load-pass-plugin="path/to/libHikari.dylib" \
    --passes="hikari(enable-fco,enable-strcry)..." \
    input.bc -o output.bc

# 将 IR 文件编译为目标文件
llc -filetype=obj output.bc -o output.o

# 链接目标文件生成可执行文件
clang output.o -o output
```

## 常用开关

| 开关 | 含义 |
|------|------|
| `hikari(...)` | 启用混淆调度（必须） |
| `enable-allobf` | 开启大部分混淆 |
| `enable-bcfobf` | 虚假控制流 |
| `enable-cffobf` | 控制流平坦化 |
| `enable-subobf` | 指令替换 |
| `enable-splitobf` | 基本块分割 |
| `enable-strcry` | 字符串加密 |
| `enable-constenc` | 常量加密 |
| `enable-indibran` | 间接跳转 |
| `enable-fco` | 函数调用混淆 |
| `enable-funcwra` | 函数包装 |
| `enable-acdobf` | AntiClassDump |
| `enable-antihook` | AntiHooking |
| `enable-adb` | AntiDebugging |

## LLVM 22 移植说明

相对早期版本的主要变更：

- 目标 LLVM：**22**（对齐 rustc 1.97+）
- `Module::getTargetTriple()` 现返回 `const Triple &`，打印需 `.str()`
- `Attribute::NoCapture` 移除，改走 `CallBase::doesNotCapture`
- `PassPlugin.h` 路径：`llvm/Plugins/PassPlugin.h`
- `PointerType::get(Type*, AS)` → `PointerType::get(Context, AS)`
- `CreateGlobalStringPtr` → `CreateGlobalString`
- iterator 插入点 / `getFirstNonPHIOrDbgOrLifetime` 等 API 适配
- Flattening / IndirectBranch 使用自带 `LegacyLowerSwitch`，避免 out-of-tree 插件与 host AnalysisKey 不匹配

## 感谢
[Hikari-LLVM15](https://github.com/61bcdefg/Hikari-LLVM15) By 61bcdefg

[ollvm-rust](https://github.com/0xlane/ollvm-rust) By 0xlane

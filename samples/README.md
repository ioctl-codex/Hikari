# Hikari Samples

对比混淆前后效果（体积、`strings`、反汇编、运行结果）。

## 前置条件

1. 已安装 LLVM 22 工具链（`opt` / `clang` / `llc` 在 `PATH`，或设置 `LLVM_BIN`）
2. 已编译插件，产物为下列之一：
   - `build/obfuscation/libHikari.dylib`
   - `build-llvm22/obfuscation/libHikari.dylib`
3. Rust 样本需要 `cargo +nightly`

## 运行

```bash
# 在仓库根目录
./samples/run_demo.sh      # 经典混淆对比
./samples/run_vmp.sh       # IR VMP 正确性验收

# 自定义插件路径 / LLVM / pass
PLUGIN=/path/to/libHikari.dylib \
LLVM_BIN=/opt/homebrew/opt/llvm/bin \
PASSES='hikari(enable-strcry,enable-bcfobf)' \
  ./samples/run_demo.sh
```

产物目录：`samples/out/`（已 gitignore）。

## 样本

| 样本 | 路径 | 内容 |
|------|------|------|
| C | `c/hello.c` | 明文密码串 + `switch` 分类 |
| C VMP | `c/vmp_add.c` | 标注 `vmp`：算术/分支/GEP/call/全局/递归/多次调用 |
| Rust | `rust/` | `fib` + license key 校验 |

## VMP 验收（`run_vmp.sh`）

- 默认 `PASSES=hikari()`：只虚拟化 `annotate("vmp")` 的函数
- 断言 clean 与 VMP **stdout 完全一致**
- 检查 `@vmp_code_*` / `@vmp_seeds_*` / `encrypt=1` / `vmp_fact` 递归样例
- 环境变量（可选）：`VMPNOENC=1` 关加密；`VMPHARDEN=1` 对解释器 CFF

## 默认 pass（`run_demo.sh`）

```
hikari(enable-bcfobf,enable-cffobf,enable-subobf,enable-splitobf,enable-strcry,enable-indibran)
```

脚本会：

1. 生成 clean / obfuscated bitcode 与可执行文件  
2. 对比 `strings`（验证 strcry）  
3. 打印部分反汇编与体积  

**不包含** Objective-C 样本（ObjC 支持已从插件中移除）。

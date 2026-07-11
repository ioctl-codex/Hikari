# Hikari Samples

对比混淆前后效果的示例工程。

## 快速跑

```bash
# 需要先编译插件到 build-llvm22/
./samples/run_demo.sh
```

产物在 `samples/out/`。

## 样本

| 样本 | 路径 | 说明 |
|------|------|------|
| C | `samples/c/hello.c` | 字符串密码 + switch 分类 |
| Rust | `samples/rust/` | fib + license key 校验 |

默认 pass：

```
hikari(enable-bcfobf,enable-cffobf,enable-subobf,enable-splitobf,enable-strcry,enable-indibran)
```

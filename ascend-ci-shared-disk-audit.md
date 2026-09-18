# Ascend CI 各集群共享盘盘点（/root/.cache 目录用途）

> 更新时间：2026-09-14（当日 250 个 90 天未访问模型目录已标记，9-15 定时任务物理删除：cn12 66 个 ≈3.1 TiB、hk 91 个、gy003 93 个、gy004 0 个）。统计方式：在 monitoring 命名空间起一次性 Job 挂载各共享 PVC/NFS，对 top-level 目录执行 `du -sk`（NFS 全量遍历，数字为实际占用）。单位 GiB/TiB 为二进制。
> 用途判定依据：目录名 + runner/pod-template 环境变量（`MODELSCOPE_CACHE`、`HF_HOME`、`PIP_CACHE_DIR`、`ASCEND_WORK_PATH` 等）+ CI 脚本约定。标注 (?) 的为推断。

## 0. 总览：物理盘 → 挂载关系

| 集群 | 物理盘（SFS Turbo share / NFS）| export 子目录 | 谁在用它 | 清理器覆盖 |
|---|---|---|---|---|
| hk-001 | `24dd126e` | `/ascend-ci-share-nv-action-vllm-benchmarks` | **vllm-project runner `/root/.cache`**（PVC `vllm-project-hk001`）| mcc `/mnt/nvbench` |
| hk-001 | `24dd126e` | `/ascend-ci-share` | 通用根（几乎空）| mcc `/mnt/share` |
| hk-001 | `24dd126e` | `/ascend-ci-share-vllm-ascend-ci-dev-vllm-ascend` | ci-dev（几乎空）| mcc `/mnt/cidev` |
| hk-001 | `9c241417` | `/ascend-ci-share-pkking-sglang` | **sgl-project runner `/root/.cache`**（PVC `sgl-project-sglang-hk001`）| mcc `/mnt/sglang` |
| hk-001 | `d5b643e2` | `/ascend-ci-share` | **verl/RL 训练 CI** 缓存（`sfs-system/cleanup-sfs-turbo-for-ascend-verl-ci` 管）| mcc `/mnt/d5share` |
| cn12 | `37cbefa6` | `/ascend-ci-share` | **vllm + sgl runner `/root/.cache`**（cn12 上的 PVC 复用了 `gy005-az5-vllm-ascend-v2` 命名但指向本集群 `37cbefa6`，勿望文生义）| mcc `/mnt/share` |
| gy003 | `b46afb97` | `/ascend-ci-share-nv-action-vllm-benchmarks` | **gy003+gy005 vllm runner `/root/.cache`**（`gy003-az5-vllm-ascend`、`gy005-az5-vllm-ascend{,-v2}` 同 export）| gy003 mcc `/mnt/b46nv` |
| gy003/005 | `23021270` | `/ascend-ci-share-nv-action-vllm-benchmarks` | 旧 benchmarks 盘（大量个人目录，含镜像副本）| gy003 mcc `/mnt/230nv` |
| gy003 | `39a33a00` | `/ascend-ci-share` | 旧 sglang 性能测试盘（基本停用）| gy003 mcc `/mnt/ci39a` |
| gy005 | `23021270` | `/ascend-ci-share-pkking-pytorch` | torch-npu 构建 ccache | gy005 mcc `/mnt/pytorch` |
| gy005 | `23021270` | `/ascend-ci-share-vllm-ascend-ci-dev-vllm-ascend` | ci-dev plog 日志 | gy005 mcc `/mnt/cidev` |
| gy004 | `1b51fb58` | `/ascend-ci-share-pkking-sglang` | **sgl runner `/root/.cache`**（`sglang-guiyang004`）| gy004 mcc `/mnt/share` |
| gy006 | - | - | 无共享缓存盘（runner 不挂 `/root/.cache` 共享卷）| - |
| sh-001 | NFS `suzblue.server:/share`（lab 物理 NAS）| 整盘（hostPath）| **vllm-project runner `/root/.cache` = 整块 `/mnt/share`**（317T，与人共用）| ❌ 无清理器 |
| sh-001 | NFS `suzblue.server:/weight` | 整盘 | 模型权重（82T 已用，当前 pod-template 未挂载，历史遗留）| ❌ 无清理器 |

**要点**
- `model-cache-cleanup` cronjob（每集群每周二 19:00 CST，90 天未访问先标 `.deleteable` 一周后物理删）的 MOUNTS 与上表一一对应；gy005 的模型盘由 gy003 清单代管（同 export 不双跑），gy006/sh-001 **没有**清理器。
- 各盘占用大头都是 `modelscope/` + `huggingface/` 模型缓存；日志类（`log/`、`ascend-logs/`）在 cn12 也到了 TiB 级，是清理器覆盖不到的（只清模型 marker 路径）。

## 1. 香港 hk-001

### 1.1 `24dd126e:nv-action-vllm-benchmarks` — vllm-project runner `/root/.cache`（合计 23.1 TiB）

| 目录 | 大小 | 用途 |
|---|---|---|
| modelscope/ | 20.2 TiB | ModelScope 模型下载缓存（清理器主战场）|
| huggingface/ | 2.6 TiB | HF 模型缓存 |
| weights/ | 162 GiB | 手工放置的模型权重 |
| uv/ | 97 GiB | uv 包缓存 |
| ascend-ci-share-nv-action-vllm-benchmarks/ | 76 GiB | 异常嵌套目录 (?)（历史上误把 share 根挂成子目录产生的副本）|
| vllm/ | 28 GiB | vLLM torch.compile 缓存 |
| ascend-logs/ | 11 GiB | CI 测试日志收集 |
| wxs/、mnj/、pta/、wl/、lwj/ | 约 1.1 TiB | 个人目录（未归属）|
| pip/ | 3.5 GiB | pip wheel 缓存 |
| evalscope/ | 2.1 GiB | EvalScope 评测产物 |
| datasets/ | 1.2 GiB | HF datasets 缓存 |
| go-build/ | 0.98 GiB | Go 构建缓存 |
| main2main-pre-commit(-x86_64)/、pre-commit/ | 约 2.3 GiB | lint/nightly pre-commit hook 缓存 |
| whisper/ | 0.45 GiB | whisper 模型下载 |
| miniconda/、virtualenv/ | 0.24 GiB | Python 环境 |
| buildkit/、ccache/、torch_extensions/、tvm-ffi/、pybind11/ 等 | 均 <1 GiB | 各类编译缓存 |
| 其余 30+ 个小目录 | 零散 | 工具缓存（opencode、claude、YAPF、matplotlib…）、输出（upload_perf、benchmark_results、profile_output、nightly_bisect）、个人 |

### 1.2 `9c241417:pkking-sglang` — sgl-project runner `/root/.cache`（合计 8.3 TiB）

| 目录 | 大小 | 用途 |
|---|---|---|
| modelscope/ | 8.0 TiB | 模型缓存 |
| huggingface/ | 136 GiB | HF 缓存 |
| z30065769/、wl/、d00662834/、l30079981/、dzc/、memelin/、swx1199799/、c30044170/ | 约 118 GiB | 个人目录 |
| log/ | 50 GiB | 运行日志 |
| sglang/ | 13 GiB | SGLang 缓存 |
| pip/ | 11 GiB | pip 缓存 |
| tests/ | 5 GiB | 测试产物 |
| ccache/、uv/、torch_extensions/、tvm-ffi/、outlines/、YAPF/ | 均小 | 编译/工具缓存 |
| ascend_all_logs/ | 7 MiB | SGLang 全量日志 |

### 1.3 `d5b643e2:/ascend-ci-share` — verl/RL CI 缓存（合计 528 GiB）

| 目录 | 大小 | 用途 |
|---|---|---|
| huggingface/ | 265 GiB | RL 训练用模型缓存 |
| models/ | 158 GiB | RL 模型权重 |
| offload_cache/ | 61 GiB | verl 训练 offload |
| uv/、pip/、modelscope/ | 27 / 9 / 7 GiB | 包缓存 |
| datasets/ | 219 MiB | 训练数据集 |
| go-build/ | 1.3 GiB | Go 缓存 |
| 根目录 grpo_*.log / ppo_*.log | 几百 KB | RL 测试日志散落根目录（垃圾）|
| lockers/、.lock/、swift-web-ui/ | ~0 | 锁文件/残留 |

### 1.4 其余：`24dd126e:/ascend-ci-share`（仅 huggingface 379 MiB）、`/ascend-ci-share-vllm-ascend-ci-dev-...`（仅 uv 28 KiB）——基本空置。

## 2. CN12（37cbefa6:/ascend-ci-share — vllm+sgl 共用 `/root/.cache`，合计 59.9 TiB）

| 目录 | 大小 | 用途 |
|---|---|---|
| modelscope/ | 55.9 TiB | 模型缓存（**今天已标 3.1 TiB / 66 个 `.deleteable`，明晚删除**）|
| huggingface/ | 2.4 TiB | HF 缓存 |
| log/ | 812 GiB | 运行日志/plog（清理器不覆盖，需另行治理）|
| tests/ | 619 GiB | 测试产物/数据（清理器不覆盖）|
| vllm/ | 66 GiB | torch.compile 缓存 |
| areal-ci-tmp/ | 57 GiB | AReaL RL CI 临时（清理器不覆盖）|
| ascend-logs/ | 53 GiB | CI 测试日志 |
| uv/、pip/、pip-cache/ | 30+17 GiB | 包缓存 |
| sglang/ | 14 GiB | SGLang 缓存 |
| ccache/ | 5 GiB | 编译缓存 |
| pre-commit/ | 557 MiB | hook 缓存 |
| whisper/、datasets/、buildkit/、sgl_diffusion/、torch/、torch_extensions/、sgl_eval/、virtualenv/、deepep/ | 均 <500 MiB | 各类缓存/产物 |
| 个人目录（d00662834 等）| ~0 | 空 |

> CN12 盘已写入约 60 TiB（声明 1200Gi 的 SFS Turbo 按量爆发）。模型占比 97%，日志+测试产物约 1.5 TiB 属于清理盲区。

## 3. 贵阳 003 / 005

### 3.1 `b46afb97:nv-action-vllm-benchmarks` — **gy003+gy005 的 runner `/root/.cache`**，合计 41.9 TiB

| 目录 | 大小 | 用途 |
|---|---|---|
| modelscope/ | 35.0 TiB | 模型缓存（gy003/gy005 vllm CI 共用；**今天已标 93 个，明晚删**）|
| gdy2/ | 1.6 TiB | 个人目录 |
| lbw/ | 1.3 TiB | 个人目录 |
| log/ | 1.1 TiB | 运行日志（清理盲区）|
| openmind/ | 1.0 TiB | 项目/个人数据目录 (?) |
| huggingface/ | 0.9 TiB | HF 缓存 |
| weights/ | 432 GiB | 模型权重 |
| vllm/ | 227 GiB | torch.compile 缓存 |
| ascend-logs/ | 190 GiB | CI 日志 |
| lby_vllm/、zym/、lwm_omni/、zxy/、cmh/、lby_qwen/、wxs/、puccinialin/、gdy/ 等 | 约 180 GiB | 个人目录 |
| vllm-omni/ | 62 GiB | 缓存/产物 |
| uv/ | 22 GiB、pip_cache/ 3.6 GiB、pre-commit/ 2.5 GiB、ccache/ 0.6 GiB | 包/编译缓存 |
| bazel/ 11 GiB、bazelisk/、mooncake-wheelhouse-ascend/ 0.6 GiB | | triton/mooncake 构建缓存 |
| tmp/ | 4.1 GiB | 临时 |
| 其余工具/环境小目录 | | conda、vscode-cpptools、jedi、opencode、gh、claude… |

### 3.2 `23021270:nv-action-vllm-benchmarks` — 旧 benchmarks 盘，合计 32.6 TiB

结构与 3.1 高度重合（gdy2/lbw/openmind/weights 数值几乎一致，**疑似整盘迁移/镜像的旧副本，可评估退役**）：modelscope 25.7 TiB、huggingface 2.2 TiB、gdy2 1.6 TiB、lbw 1.3 TiB、openmind 1.0 TiB、weights 432 GiB、vllm 68 GiB、vllm-omni 62 GiB、vime-checkpoints 57 GiB（个人训练 checkpoint）、其余个人目录约 2.5 TiB。根目录还有大量 `_*.py` 调试脚本散落（2025-2026 遗留）。

### 3.3 `39a33a00:/ascend-ci-share` — 旧 sglang 测试盘，合计 123 GiB
vllm-ascend/ 117 GiB（旧构建缓存）、ShareGPT_Vicuna_unfiltered 4.0 GiB、SmolLM2-135M 1.8 GiB、sccache/ccache 缓存、9 月 report 目录若干。**基本停用，可整体清理。**

### 3.4 gy005 自有两个挂载
`23021270:pkking-pytorch`：仅 ccache 4.3 GiB（torch-npu C++ 编译缓存）。
`23021270:vllm-ascend-ci-dev`：仅 log 264 KiB（plog）。

## 4. 贵阳 004（1b51fb58:pkking-sglang — sgl runner `/root/.cache`，合计 26.7 TiB）

| 目录 | 大小 | 用途 |
|---|---|---|
| modelscope/ | 24.1 TiB | 模型缓存（本轮 90 天无 stale，清理器空转）|
| KVTC/ | 1.0 TiB | KV 压缩项目数据（个人/项目）|
| log/ | 806 GiB | 运行日志（清理盲区）|
| tests/ | 566 GiB | 测试产物（清理盲区）|
| huggingface/ | 214 GiB | HF 缓存 |
| d00662834/ | 29 GiB | 个人目录（工号）|
| pip/ | 18 GiB | pip 缓存 |
| sglang/、uv/、ccache/ | 6.9 / 5.0 / 4.8 GiB | SGLang 缓存、包/编译缓存 |
| aisbench/ | 2.5 GiB | 项目数据 |
| multi-node-test/ 144 MiB、coverage_data/ 87 MiB、sgl_diffusion/ 86 MiB、sgl_eval/ 15 MiB、pre-commit/ 221 MiB | | 测试/评测产物、hook 缓存 |
| torch_extensions/、deepep/、tvm-ffi/、black/、YAPF/、outlines/、matplotlib/、deep_gemm/、runs/ | ≈0 | 工具缓存 |
| 根目录散落 | | README.md、mp3/mp4 演示文件（Trump_WEF、bird_song、jobs*.mp4）等与 CI 无关；有 .gitattributes 痕迹，疑似仓库直接 clone 在盘根 |

## 5. 贵阳 006
无共享缓存卷（runner 不挂 `/root/.cache`），不参与模型清理体系。

## 6. 上海 sh-001（NFS `suzblue.server:/share` 317T/用 41T — runner `/root/.cache` = 整盘）

**特殊情况**：runner 的 `/root/.cache` 是 hostPath 整盘 `/mnt/share`（317T 物理 NAS），CI 缓存与实验室人员个人目录混在一起。CI 相关 top-level 目录 du 结果：

| 目录 | 大小 | 用途 |
|---|---|---|
| modelscope/ | 11.9 TiB | 模型缓存（**无清理器覆盖**）|
| huggingface/ | 1.5 TiB | HF 缓存 |
| weight/ | 1.1 TiB | 模型权重 |
| ascend-ci/ | 525 GiB | CI 工作产物 |
| conda_envs/ | 30 GiB | conda 环境 |
| log/ | 16 GiB | 日志 |
| vllm/ | 10.8 GiB | compile 缓存 |
| vllm-ascend/ | 1.3 GiB | 早期项目级缓存（uv 1.3 GiB 在此）|
| go-build/ 160 MiB、weights/ 181 MiB、ascend-logs/、virtualenv/、torch_extensions/、YAPF/、tests/、pip/、uv/ | 均 ≤200 MiB | 缓存杂项（pip/uv 实际只用了 KB 级——job 容器 PIP_CACHE_DIR 被重定向到 /tmp）|
| 其余 ~25 TiB | | 实验室个人目录（c008xxxx、l00xxxxx、w00xxxxx 工号目录、人名目录）、autotest/CANN 包、数百个 `postStart-*.log` 碎片等 |

另有 `suzblue.server:/weight`（358T/用 82T）整盘模型权重库（DeepSeek/Qwen 等），当前 vllm-project pod-template 已不再挂载它（改从 `/root/.cache/weight` 取），属历史遗留。

## 7. 清理盲区与建议

1. **日志/产物类无清理**：cn12 `log/` 812 GiB + `tests/` 619 GiB、b46nv `log/` 1.1 TiB、sglang 盘 `log/` 50 GiB —— model-cache-cleanup 只扫模型 marker 路径。建议增加按天数的日志轮转 cronjob。
2. **sh-001 无清理器**：11.9 TiB modelscope 无 TTL 治理；且 `/root/.cache` 直挂整块 317T 人用 NAS，建议为 CI 单独划 export 子目录（如 `/mnt/share/ci`）。
3. **230nv 旧盘疑似 b46nv 镜像**：gdy2/lbw/openmind/weights 尺寸逐项一致，若确认为迁移遗留，退役可释放 ~32 TiB。
4. **个人目录占比**：b46nv/230nv 个人目录合计约 2.5-3 TiB/盘；hk nvbench 约 1 TiB。建议在盘根 README/工单推动清理，或纳入 cleanup 的 `KEEP_REGEX` 白名单外的二级策略。
5. **gy005 runner PVC 命名误导**（`gy005-az5-vllm-ascend-v2` 实际 export 与 gy003 同名 share），跨集群同盘访问是刻意设计（见 ascend-ci-deployment 注释），排查时勿被名字迷惑。

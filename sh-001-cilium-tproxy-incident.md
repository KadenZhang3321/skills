# sh-001 集群 control-plane 宕机 —— Cilium TPROXY 黑洞事件记录

> 处理人:基础设施 / cc
> 时间:2026-08-26
> 集群:openmerlin-sh-001(3 master 华为云 ECS + 4 lab worker + admin123)
> 状态:**已定位根因,修复命令已备好,待审批执行**

---

## 0. 给 cc 的重要前置说明(双网卡,勿搞错)

每台 master 两张网卡,**角色固定**:

| 网段 | 网卡 | 角色 | 用途 |
|---|---|---|---|
| `10.254.9.0/24` | eth0 | **k8s 主机段(服务面)** | 节点 IP、etcd peer、Cilium pod 网络、ELB 后端 |
| `10.254.1.0/24` | eth1 | **管理段(外部 SSH)** | 外部 SSH、apiserver client endpoint(via 管理面 ELB) |

**铁律:加 iptables/路由规则、改 etcd peer 绑定时,务必按段区分,不要把 k8s 流量引到 eth1、也不要把管理流量引到 eth0。**

> ⚠️ 已发现的配置不一致(后续清理项,非本次救活必需):
> **master-01 的 etcd peer 绑错段** —— `--listen-peer-urls=https://10.254.1.187:2380` 绑在 **1 段(管理段)**,
> 而 master-02/03 都绑在 **9 段**(`10.254.9.229:2380` / `10.254.9.85:2380`)。
> 规范应统一到 9 段:`10.254.9.49:2380`。本次修完 TPROXY 后单独排期处理(需改 manifest + `etcdctl member update`)。

---

## 1. 现象

- 外部 `kubectl` 连管理面 ELB `115.175.0.82:6443` i/o timeout(非白名单 + 后续发现 apiserver 本身也没起)
- 登 master-01 本机 `kubectl get nodes` 卡死 → `dial tcp 10.254.1.187:6443: i/o timeout`
- `ss -ltnp | grep 6443` 为空 —— kube-apiserver 没监听
- `crictl ps`:kube-apiserver Exited(重启 259 次),etcd Running 但重启 227 次(crash-loop)
- etcd 日志:`starting a new election at term 3` 反复,`dial tcp 10.254.9.85:2380: i/o timeout` / `10.254.9.229:2380: i/o timeout` —— 连不上另两个 peer
- apiserver 日志:`dial tcp 127.0.0.1:2379: i/o timeout` → `Error creating leases: context deadline exceeded` → 退出

## 2. 根因(完整因果链)

1. 三台 master 的 **Cilium agent pod 都不在运行**(`crictl ps | grep cilium` 空),但 `mangle` 表里 Cilium 安装的 `CILIUM_PRE_mangle` 链规则**残留**。
2. 该链里有两条**裸匹配**规则(无端口/IP 限定):
   ```
   -A CILIUM_PRE_mangle -p tcp -j TPROXY --on-port <每台端口> --on-ip 127.0.0.1 --tproxy-mark 0x200/0xffffffff
   -A CILIUM_PRE_mangle -p udp -j TPROXY --on-port <每台端口> --on-ip 127.0.0.1 --tproxy-mark 0x200/0xffffffff
   ```
3. TPROXY 把所有入站 TCP/UDP 重定向到 `127.0.0.1:<端口>`,但该端口**无监听**(cilium-dns-egress proxy 随 agent 一起死了)→ **静默丢弃**。
4. 因此每台 master 对外的 2380/2379/6443 全部 `i/o timeout`(注意是 timeout 不是 refused = 静默 drop)。
5. 三个 etcd peer 互连 2380 全超时 → 无 2/3 法定人数 → 选不出 leader → etcd 不提供服务 → apiserver 连 etcd timeout → apiserver 退出 → 6443 无人监听 → 整个 control plane 宕。
6. SSH(22)此前也不通,后通过在 `PREROUTING` 里、`CILIUM_PRE_mangle` 之前插 `--dport 22 -j ACCEPT` 绕开 Cilium 救活——这反向印证了 `CILIUM_PRE_mangle` 是元凶。

**与历史经验文档(`sh-001-all-issues.md`)比对:无先例。**
文档 §四 4.1~4.4 的 Cilium 问题是路由/SNAT/隧道模式(旧 pod CIDR 死路由、pod 源 IP 未 SNAT、native→tunnel),均已修复,且症状(ping 全通、路由正确、只卡 2380/2379/6443)对不上。本次是 Cilium TPROXY 残留规则黑洞,属新问题,不能套用原有方式,需按本记录第 5 节处理。

## 3. 路由核对(华为云多网卡源地址策略路由)—— 结论:正确,非路由问题

master-01 实测:

```
eth0 = 10.254.9.49/24   (9段, k8s 主机段)
eth1 = 10.254.1.187/24  (1段, 管理段)

ip rule:
  from 10.254.9.49  lookup 10   -> default via 10.254.9.1 dev eth0
  from 10.254.1.187 lookup 20   -> default via 10.254.1.1  dev eth1

ip route get 10.254.9.85  -> dev eth0 src 10.254.9.49   ✓
ip route get 10.254.1.232 -> dev eth1 src 10.254.1.187  ✓

rp_filter: eth0=2 eth1=2 all=0 (loose, 不误杀) ✓
```

正是华为云多网卡源地址策略路由标准写法(参考 https://support.huaweicloud.com/vpc_faq/vpc_faq_0079.html )。回包走对应网卡,无误。**本次故障与路由无关。**

## 4. 当前规则快照(三台 master,执行前留档)

### master-01(mgmt 10.254.1.187 / svc 10.254.9.49 / tproxy-port **39367**)

```
# mangle PREROUTING
-P PREROUTING ACCEPT
-A PREROUTING -p tcp -m tcp --sport 22 -j ACCEPT          # 人工救 SSH 的 bypass
-A PREROUTING -p tcp -m tcp --dport 22 -j ACCEPT          # 人工救 SSH 的 bypass
-A PREROUTING -m comment --comment "cilium-feeder: CILIUM_PRE_mangle" -j CILIUM_PRE_mangle

# mangle CILIUM_PRE_mangle
-N CILIUM_PRE_mangle
-A CILIUM_PRE_mangle ! -o lo -m socket --transparent -m comment --comment "cilium: any->pod redirect proxied traffic to host proxy" -j MARK --set-xmark 0x200/0xffffffff
-A CILIUM_PRE_mangle -p tcp -m comment --comment "cilium: TPROXY to host cilium-dns-egress proxy" -j TPROXY --on-port 39367 --on-ip 127.0.0.1 --tproxy-mark 0x200/0xffffffff
-A CILIUM_PRE_mangle -p udp -m comment --comment "cilium: TPROXY to host cilium-dns-egress proxy" -j TPROXY --on-port 39367 --on-ip 127.0.0.1 --tproxy-mark 0x200/0xffffffff
```

### master-02(mgmt 10.254.1.232 / svc 10.254.9.229 / tproxy-port **33205**)

```
# mangle PREROUTING(同样有 22 bypass)
-P PREROUTING ACCEPT
-A PREROUTING -p tcp -m tcp --sport 22 -j ACCEPT
-A PREROUTING -p tcp -m tcp --dport 22 -j ACCEPT
-A PREROUTING -m comment --comment "cilium-feeder: CILIUM_PRE_mangle" -j CILIUM_PRE_mangle

# mangle CILIUM_PRE_mangle
-N CILIUM_PRE_mangle
-A CILIUM_PRE_mangle ! -o lo -m socket --transparent -m comment --comment "cilium: any->pod redirect proxied traffic to host proxy" -j MARK --set-xmark 0x200/0xffffffff
-A CILIUM_PRE_mangle -p tcp -m comment --comment "cilium: TPROXY to host cilium-dns-egress proxy" -j TPROXY --on-port 33205 --on-ip 127.0.0.1 --tproxy-mark 0x200/0xffffffff
-A CILIUM_PRE_mangle -p udp -m comment --comment "cilium: TPROXY to host cilium-dns-egress proxy" -j TPROXY --on-port 33205 --on-ip 127.0.0.1 --tproxy-mark 0x200/0xffffffff
```

### master-03(mgmt 10.254.1.25 / svc 10.254.9.85 / tproxy-port **38683**)

```
# mangle PREROUTING(同样有 22 bypass)
-P PREROUTING ACCEPT
-A PREROUTING -p tcp -m tcp --sport 22 -j ACCEPT
-A PREROUTING -p tcp -m tcp --dport 22 -j ACCEPT
-A PREROUTING -m comment --comment "cilium-feeder: CILIUM_PRE_mangle" -j CILIUM_PRE_mangle

# mangle CILIUM_PRE_mangle
-N CILIUM_PRE_mangle
-A CILIUM_PRE_mangle ! -o lo -m socket --transparent -m comment --comment "cilium: any->pod redirect proxied traffic to host proxy" -j MARK --set-xmark 0x200/0xffffffff
-A CILIUM_PRE_mangle -p tcp -m comment --comment "cilium: TPROXY to host cilium-dns-egress proxy" -j TPROXY --on-port 38683 --on-ip 127.0.0.1 --tproxy-mark 0x200/0xffffffff
-A CILIUM_PRE_mangle -p udp -m comment --comment "cilium: TPROXY to host cilium-dns-egress proxy" -j TPROXY --on-port 38683 --on-ip 127.0.0.1 --tproxy-mark 0x200/0xffffffff
```

> 注:三台 cilium agent pod 均不在运行(`crictl ps | grep cilium` 空),上述为**残留规则**;39367/33205/38683 均无监听。
> 另:`raw` 表 `CILIUM_PRE_raw` 有一条无限制 `--notrack`(不丢包,本次不动),`nat`/`filter` 无异常 DROP。

## 5. 修复命令(待审批执行)—— 删除两条裸 TPROXY 规则

**原则:每台只删 `CILIUM_PRE_mangle` 里那两条 `-p tcp/udp -j TPROXY`(元凶),保留 MARK 规则与 feeder 跳转,最小侵入、可回滚。三台都要做(否则 etcd 凑不齐法定人数)。**

### 方案 A(推荐,精确按规则删除,保留 MARK)

在每台 master 上(端口替换为本机值):

**master-01(port 39367):**
```bash
iptables -t mangle -D CILIUM_PRE_mangle -p tcp  -m comment --comment 'cilium: TPROXY to host cilium-dns-egress proxy' -j TPROXY --on-port 39367 --on-ip 127.0.0.1 --tproxy-mark 0x200/0xffffffff
iptables -t mangle -D CILIUM_PRE_mangle -p udp  -m comment --comment 'cilium: TPROXY to host cilium-dns-egress proxy' -j TPROXY --on-port 39367 --on-ip 127.0.0.1 --tproxy-mark 0x200/0xffffffff
```

**master-02(port 33205):**
```bash
iptables -t mangle -D CILIUM_PRE_mangle -p tcp  -m comment --comment 'cilium: TPROXY to host cilium-dns-egress proxy' -j TPROXY --on-port 33205 --on-ip 127.0.0.1 --tproxy-mark 0x200/0xffffffff
iptables -t mangle -D CILIUM_PRE_mangle -p udp  -m comment --comment 'cilium: TPROXY to host cilium-dns-egress proxy' -j TPROXY --on-port 33205 --on-ip 127.0.0.1 --tproxy-mark 0x200/0xffffffff
```

**master-03(port 38683):**
```bash
iptables -t mangle -D CILIUM_PRE_mangle -p tcp  -m comment --comment 'cilium: TPROXY to host cilium-dns-egress proxy' -j TPROXY --on-port 38683 --on-ip 127.0.0.1 --tproxy-mark 0x200/0xffffffff
iptables -t mangle -D CILIUM_PRE_mangle -p udp  -m comment --comment 'cilium: TPROXY to host cilium-dns-egress proxy' -j TPROXY --on-port 38683 --on-ip 127.0.0.1 --tproxy-mark 0x200/0xffffffff
```

> 若 `-D` 因 comment 精确匹配失败,**回退方案 B**:按位置删(链内规则顺序固定为 socket-MARK / tcp-TPROXY / udp-TPROXY,先删高序号防位移):
> ```bash
> iptables -t mangle -D CILIUM_PRE_mangle 3   # 删 udp TPROXY
> iptables -t mangle -D CILIUM_PRE_mangle 2   # 删 tcp TPROXY
> ```
> **最暴力的方案 C**(整链清空,含 MARK;cilium agent 没在跑,不会被重新加回,但更激进):
> ```bash
> iptables -t mangle -F CILIUM_PRE_mangle
> ```

> 三台都做完后**无需重启任何组件**,etcd 自动重连恢复 2/3 法定人数、选 leader,apiserver 自启动,集群自愈。

## 6. 回滚 / 恢复命令(万一要还原 Cilium 原状)

恢复 Cilium 规则的正道是**把 cilium agent 拉起来**(见第 7 节),agent 重启后会按当前配置重建 `CILIUM_PRE_mangle` 与对应端口监听,TPROXY 即恢复正常工作(不再黑洞)。

若需**手工**把规则加回(应急),按第 4 节快照逐条 `-A` 回去即可(注意每台端口不同):
```bash
# master-01 示例
iptables -t mangle -A CILIUM_PRE_mangle -p tcp -m comment --comment 'cilium: TPROXY to host cilium-dns-egress proxy' -j TPROXY --on-port 39367 --on-ip 127.0.0.1 --tproxy-mark 0x200/0xffffffff
iptables -t mangle -A CILIUM_PRE_mangle -p udp -m comment --comment 'cilium: TPROXY to host cilium-dns-egress proxy' -j TPROXY --on-port 39367 --on-ip 127.0.0.1 --tproxy-mark 0x200/0xffffffff
```
master-02/03 把端口换成 33205 / 38683。

## 7. 后续:救活控制面后,修 Cilium

1. 控制面恢复后,先 `kubectl get nodes`、`kubectl -n kube-system get pods -l k8s-app=cilium` 确认 cilium daemonset 状态。
2. 三台 master 的 cilium pod 都不在 → 检查 daemonset 是否被删 / 是否因某种原因没调度到 master( tolerations / nodeSelector )。
3. `kubectl -n kube-system rollout restart ds/cilium` 拉起;pod Running 后,它会重建 `CILIUM_PRE_mangle` 规则并监听对应端口,TPROXY 转入正常工作(此时规则可加回,**不要永久删**)。
4. 本次"删 TPROXY 规则"是**救活控制面的临时手段**,根因是 cilium agent 没在 master 上跑。Cilium 恢复后规则会自动回来,届时端口有监听,不再黑洞。

## 8. 后续清理项(独立排期,非本次救活)

- **master-01 etcd peer 绑段纠正**:`10.254.1.187:2380` → `10.254.9.49:2380`,与 02/03 对齐(9 段 k8s 主机段)。
  步骤:改 `/etc/kubernetes/manifests/etcd.yaml` 的 `--listen-peer-urls` / `--initial-advertise-peer-urls` / advertise-client 相关 → `etcdctl member update f77494e70d68bec --peer-urls=https://10.254.9.49:2380` → 重启 etcd。**需单独窗口操作,做完验证 etcd 健康。**
- 评估为何 cilium agent 在三台 master 同时消失(是否某次操作误删 daemonset / 节点 taint 变化),避免复发。

## 9. 救活后验证清单

```bash
# 在 master-01
ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint health -w table          # 期望全 true

ss -ltnp | grep 6443                 # 期望 kube-apiserver 在听
kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes   # 期望出 8 节点

# 确认 TPROXY 已删
iptables -t mangle -S CILIUM_PRE_mangle   # 不应再有 -p tcp/udp -j TPROXY
```

---

## 附:本次诊断全程的关键命令留档

```bash
# 1) 三台 master 入站端口探测(22 OPEN,2379/2380/6443 BLOCKED)
for ip in 10.254.1.232 10.254.1.25; do
  for p in 22 2379 6443; do
    echo -n "$ip:$p -> "; timeout 4 bash -c "exec 3<>/dev/tcp/$ip/$p" 2>/dev/null && echo OPEN || echo BLOCKED
  done
done

# 2) 看 etcd peer 互连 + 选主日志
crictl ps --name etcd -q | head -1 | xargs -I{} crictl logs --tail=60 {} 2>&1 | tail -60

# 3) 看 Cilium 残留规则 + 端口监听
iptables -t mangle -S CILIUM_PRE_mangle
ss -ltnp | grep -E '39367|33205|38683' || echo NO LISTENER

# 4) 双网卡策略路由核对
ip -br -4 addr show; ip rule show; ip route get 10.254.9.85; ip route get 10.254.1.232
```

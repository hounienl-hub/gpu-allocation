# Webhook 修改 Pod，不修改 Node

## ❌ 常見誤解

**誤解**: Webhook 會把 Node 裡面的 Allocatable MIG 從 2g.20gb 換成 1g.10gb

**事實**:
- ❌ Webhook **不會**修改 Node.Status.Allocatable
- ✅ Webhook **只會**修改 Pod.Spec.Containers[].Resources.Requests
- ✅ Node.Status.Allocatable 由 **Device Plugin + Kubelet** 設定

---

## 🎯 兩個完全不同的對象

### 1. Node.Status.Allocatable（節點的資源容量）

**由誰設定**: Device Plugin → Kubelet → API Server → etcd

**何時改變**:
- 節點啟動時
- MIG 配置變更時
- Device Plugin 重啟時

**如何改變 Node 的 Allocatable**:

```bash
# 步驟 1: 修改 MIG 配置
kubectl annotate node gpu-worker run.ai/mig.config='
version: v1
mig-configs:
  selected:
  - devices: [0]
    mig-enabled: true
    mig-devices:
    - 2g.20gb    # 改成 2g.20gb
    - 2g.20gb
' --overwrite

# 步驟 2: Device Plugin 檢測到配置變更
# 步驟 3: Device Plugin 重新掃描 GPU
# 步驟 4: Device Plugin 向 Kubelet 報告新的資源
# 步驟 5: Kubelet 更新 Node.Status.Allocatable
# 步驟 6: API Server 保存到 etcd

# 查看結果
kubectl get node gpu-worker -o jsonpath='{.status.allocatable}'
# 輸出:
# {
#   "nvidia.com/mig-2g.20gb": "8"  ← 從配置計算得出
# }
```

**範例**（來自 configure-mig-profiles.sh）:

```yaml
# Medium Node 配置: 2× 2g.20gb + 1× 3g.30gb per card
mig-devices:
- 2g.20gb
- 2g.20gb
- 3g.30gb

# Device Plugin 計算:
# 4 cards × (2× 2g.20gb + 1× 3g.30gb) = 8× 2g.20gb + 4× 3g.30gb

# Kubelet 設定 Node.Status.Allocatable:
{
  "nvidia.com/mig-2g.20gb": "8",
  "nvidia.com/mig-3g.30gb": "4"
}
```

---

### 2. Pod.Spec.Containers[].Resources.Requests（Pod 的資源請求）

**由誰修改**: Webhook (在 Admission 階段)

**何時修改**: Pod 創建時（`kubectl apply -f pod.yaml`）

**如何修改**:

```go
// Webhook 代碼: webhook/cmd/main.go

// 原始 Pod YAML:
// resources:
//   requests:
//     nvidia.com/mig-2g.20gb: 1

// Webhook 檢查 Node 的 Allocatable
available, _ := w.checkMIGAvailability("nvidia.com/mig-2g.20gb")

if !available {
    // Node 沒有 2g.20gb 類型 → 降級
    fallback1g, _ := w.checkMIGAvailability("nvidia.com/mig-1g.10gb")

    if fallback1g {
        // 修改 Pod 的 requests（不是修改 Node！）
        patches = append(patches, map[string]interface{}{
            "op":   "remove",
            "path": "/spec/containers/0/resources/requests/nvidia.com~1mig-2g.20gb",
        })
        patches = append(patches, map[string]interface{}{
            "op":    "add",
            "path":  "/spec/containers/0/resources/requests/nvidia.com~1mig-1g.10gb",
            "value": "1",
        })
    }
}

// 修改後的 Pod:
// resources:
//   requests:
//     nvidia.com/mig-1g.10gb: 1  ← 只改這個！
```

---

## 📊 完整流程對比

### 場景 1: 只有 1g.10gb 的集群（Node 沒有 2g.20gb）

```
┌────────────────────────────────────────────────────────────┐
│ 集群狀態（Device Plugin 已配置）                            │
├────────────────────────────────────────────────────────────┤
│                                                             │
│ Node: gpu-worker                                           │
│   Status.Allocatable:                                      │
│     nvidia.com/mig-1g.10gb: "28"  ← Device Plugin 設定     │
│     nvidia.com/mig-2g.20gb: "0"   ← 沒有配置 2g.20gb       │
│                                                             │
└────────────────────────────────────────────────────────────┘
                    ↑
                    │ Webhook 只讀取，不修改
                    │
┌───────────────────┴─────────────────────────────────────────┐
│ 用戶創建 Pod                                                │
├────────────────────────────────────────────────────────────┤

apiVersion: v1
kind: Pod
metadata:
  name: training-job
spec:
  containers:
  - name: trainer
    resources:
      requests:
        nvidia.com/mig-2g.20gb: 1  ← 用戶請求 2g.20gb
                    ↓
                    │ kubectl apply -f pod.yaml
                    ↓
┌────────────────────────────────────────────────────────────┐
│ Webhook 處理                                                │
├────────────────────────────────────────────────────────────┤
│                                                             │
│ 1. 檢查 Node.Status.Allocatable                            │
│    nodes, _ := clientset.Nodes().List()                   │
│    for _, node := range nodes.Items {                     │
│      allocatable := node.Status.Allocatable               │
│      if allocatable["nvidia.com/mig-2g.20gb"] >= 1 {      │
│        return true  // 有這種類型                         │
│      }                                                     │
│    }                                                       │
│    return false  // ❌ 沒有 2g.20gb 類型                   │
│                                                             │
│ 2. 決定降級                                                 │
│    檢查 1g.10gb: allocatable["nvidia.com/mig-1g.10gb"] = 28│
│    ✅ 有 1g.10gb → 可以降級                                │
│                                                             │
│ 3. 修改 Pod 的 requests（不修改 Node！）                    │
│    patches = [                                             │
│      {op: "remove", path: ".../mig-2g.20gb"},             │
│      {op: "add", path: ".../mig-1g.10gb", value: "1"}     │
│    ]                                                       │
│                                                             │
└────────────────────────────────────────────────────────────┘
                    ↓
                    │ 返回修改後的 Pod
                    ↓
┌────────────────────────────────────────────────────────────┐
│ 實際創建的 Pod（etcd 中）                                   │
├────────────────────────────────────────────────────────────┤

apiVersion: v1
kind: Pod
metadata:
  name: training-job
  annotations:
    gpu-webhook.k8s.io/fallback: "2g.20gb->1g.10gb"  ← 標記
spec:
  containers:
  - name: trainer
    resources:
      requests:
        nvidia.com/mig-1g.10gb: 1  ← Webhook 修改了這個
                    ↓
                    │ Scheduler 調度
                    ↓
                調度到 gpu-worker
                使用 1g.10gb MIG
```

---

### 場景 2: 有 2g.20gb 的集群（Node 有配置 2g.20gb）

```
┌────────────────────────────────────────────────────────────┐
│ 集群狀態（Device Plugin 已配置）                            │
├────────────────────────────────────────────────────────────┤
│                                                             │
│ Node: gpu-worker                                           │
│   Status.Allocatable:                                      │
│     nvidia.com/mig-2g.20gb: "8"   ← Device Plugin 設定     │
│     nvidia.com/mig-3g.30gb: "4"                            │
│                                                             │
└────────────────────────────────────────────────────────────┘
                    ↑
                    │ Webhook 只讀取，不修改
                    │
┌───────────────────┴─────────────────────────────────────────┐
│ 用戶創建 Pod                                                │
├────────────────────────────────────────────────────────────┤

apiVersion: v1
kind: Pod
metadata:
  name: training-job
spec:
  containers:
  - name: trainer
    resources:
      requests:
        nvidia.com/mig-2g.20gb: 1  ← 用戶請求 2g.20gb
                    ↓
                    │ kubectl apply -f pod.yaml
                    ↓
┌────────────────────────────────────────────────────────────┐
│ Webhook 處理                                                │
├────────────────────────────────────────────────────────────┤
│                                                             │
│ 1. 檢查 Node.Status.Allocatable                            │
│    allocatable["nvidia.com/mig-2g.20gb"] = 8               │
│    ✅ 8 >= 1 → 有這種類型                                  │
│                                                             │
│ 2. 決定不降級                                               │
│    Node 支持 2g.20gb → 保持原始請求                         │
│                                                             │
│ 3. 不修改 Pod                                               │
│    return AdmissionResponse{Allowed: true, Patch: nil}    │
│                                                             │
└────────────────────────────────────────────────────────────┘
                    ↓
                    │ 返回原始 Pod（無修改）
                    ↓
┌────────────────────────────────────────────────────────────┐
│ 實際創建的 Pod（etcd 中）                                   │
├────────────────────────────────────────────────────────────┤

apiVersion: v1
kind: Pod
metadata:
  name: training-job
  # ✅ 沒有 fallback annotation
spec:
  containers:
  - name: trainer
    resources:
      requests:
        nvidia.com/mig-2g.20gb: 1  ← 保持原始請求
                    ↓
                    │ Scheduler 調度
                    ↓
                調度到 gpu-worker
                使用 2g.20gb MIG
```

---

## 🔄 Node Allocatable 何時改變？

### 方法 1: 修改 MIG 配置 annotation

```bash
# 當前配置: 2× 2g.20gb + 1× 3g.30gb per card
kubectl get node gpu-worker2 -o jsonpath='{.metadata.annotations.run\.ai/mig\.config}'

# 修改為: 7× 1g.10gb per card
kubectl annotate node gpu-worker2 run.ai/mig.config='
version: v1
mig-configs:
  selected:
  - devices: [0,1,2,3]
    mig-enabled: true
    mig-devices:
    - 1g.10gb
    - 1g.10gb
    - 1g.10gb
    - 1g.10gb
    - 1g.10gb
    - 1g.10gb
    - 1g.10gb
' --overwrite

# 等待 Device Plugin 重新配置（幾秒鐘）
sleep 10

# 查看變更後的 Allocatable
kubectl get node gpu-worker2 -o jsonpath='{.status.allocatable}' | jq .

# 輸出（變化了！）:
{
  "nvidia.com/mig-1g.10gb": "28",  # ← 從 0 變成 28
  "nvidia.com/mig-2g.20gb": "0",   # ← 從 8 變成 0
  "nvidia.com/mig-3g.30gb": "0"    # ← 從 4 變成 0
}
```

**流程**:
```
1. kubectl annotate (修改 annotation)
   ↓
2. Device Plugin watch 到 annotation 變更
   ↓
3. Device Plugin 重新配置 MIG
   ↓
4. Device Plugin 向 Kubelet 報告新資源
   ↓
5. Kubelet 更新 Node.Status.Allocatable
   ↓
6. API Server 保存到 etcd
   ↓
7. Webhook 下次查詢時會看到新的 Allocatable
```

### 方法 2: 重新運行配置腳本

```bash
# 修改 scripts/configure-mig-profiles.sh
vim scripts/configure-mig-profiles.sh

# 將 medium node 改為全部 1g.10gb
# mig-devices:
# - 1g.10gb
# - 1g.10gb
# - 1g.10gb
# - 1g.10gb
# - 1g.10gb
# - 1g.10gb
# - 1g.10gb

# 重新執行
./scripts/configure-mig-profiles.sh

# Node.Status.Allocatable 會更新
```

---

## 📝 關鍵總結

### Webhook 的職責

```go
// ✅ Webhook 做的事
func (w *GPUAllocationWebhook) handleMutate() {
    // 1. 讀取 Node.Status.Allocatable
    hasResource := w.checkMIGAvailability(resourceName)

    // 2. 決定是否需要修改 Pod
    if !hasResource {
        // 3. 修改 Pod.Spec.Containers[].Resources.Requests
        modifyPodRequests(pod, fallbackResource)
    }
}

// ❌ Webhook 不做的事
// - 不修改 Node.Status.Allocatable
// - 不修改 Node.Metadata.Annotations
// - 不配置 MIG
// - 不管理硬件
```

### Device Plugin 的職責

```
// ✅ Device Plugin 做的事
1. 讀取 MIG 配置 (Node.Metadata.Annotations["run.ai/mig.config"])
2. 掃描硬件 (真實 GPU) 或模擬 (fake-gpu-operator)
3. 計算可用資源量
4. 向 Kubelet 報告資源
5. Kubelet 更新 Node.Status.Allocatable

// ❌ Device Plugin 不做的事
// - 不處理 Pod 創建
// - 不修改 Pod 請求
```

### 對照表

| 組件 | 修改對象 | 何時執行 | 修改什麼 |
|------|---------|---------|---------|
| **Device Plugin + Kubelet** | `Node.Status.Allocatable` | 節點啟動/配置變更時 | MIG 資源類型和數量 |
| **Webhook** | `Pod.Spec.Containers[].Resources.Requests` | Pod 創建時 | Pod 請求的資源類型 |
| **Scheduler** | `Pod.Spec.NodeName` | 調度時 | Pod 分配到哪個節點 |

---

## 🎯 回答你的問題

**問**: "那 node 裡面的 allocatable mig 從 2g 換 1g 的條件是什麼？"

**答**:

**誤解**: Webhook 不會把 Node 的 Allocatable 從 2g 換成 1g

**正確理解**:

1. **Node.Status.Allocatable 由 Device Plugin 設定**
   - 條件：修改 `run.ai/mig.config` annotation
   - 方法：`kubectl annotate node ... run.ai/mig.config='...'`
   - 結果：Device Plugin 重新配置，Kubelet 更新 Allocatable

2. **Webhook 只修改 Pod 的 requests**
   - 條件：Node 沒有 Pod 請求的資源類型
   - 方法：檢查 `Node.Status.Allocatable[resourceName]`
   - 結果：修改 `Pod.Spec.Containers[].Resources.Requests`

**示例**:

```bash
# 場景: Node 有 8× 2g.20gb, 沒有 1g.10gb
# Node.Status.Allocatable:
#   nvidia.com/mig-2g.20gb: "8"
#   nvidia.com/mig-1g.10gb: "0"

# 用戶創建 Pod 請求 1g.10gb
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test
spec:
  containers:
  - name: test
    resources:
      requests:
        nvidia.com/mig-1g.10gb: 1  # 請求 1g.10gb
EOF

# Webhook 處理:
# 1. 檢查 Node.Status.Allocatable["nvidia.com/mig-1g.10gb"] = 0
# 2. 發現沒有 1g.10gb
# 3. 檢查 Node.Status.Allocatable["nvidia.com/mig-2g.20gb"] = 8
# 4. 發現有 2g.20gb
# 5. 修改 Pod: mig-1g.10gb → mig-2g.20gb（向上升級！）

# 結果: Pod 使用 2g.20gb (因為 Node 只有這個)
```

**Node Allocatable 本身不變，Webhook 只是讀取它來決定如何修改 Pod！**

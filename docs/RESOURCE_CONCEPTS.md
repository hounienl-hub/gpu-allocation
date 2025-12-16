# Kubernetes 資源概念詳解：Available vs Allocated vs Allocatable

## 🎯 核心問題

**問題**: Webhook 如果不問 Scheduler 或 Kubelet，那是直接查詢最鄰近的 etcd data？

**答案**: **是的**，通過 client-go → API Server → etcd 這個鏈路查詢。但重點是：
- ✅ **Allocatable** 直接存儲在 etcd 的 Node 對象中
- ❌ **Allocated** 和 **Available** 不存儲，需要實時計算

---

## 📊 數據流架構

```
┌────────────────────────────────────────────────────────────────┐
│                          etcd (鍵值數據庫)                        │
├────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Key: /registry/nodes/gpu-sim-cluster-worker                  │
│  Value:                                                         │
│  {                                                              │
│    "kind": "Node",                                              │
│    "metadata": { "name": "gpu-sim-cluster-worker" },          │
│    "status": {                                                  │
│      "capacity": {                    ← 硬件總量（Kubelet 上報）│
│        "nvidia.com/gpu": "4"                                    │
│      },                                                         │
│      "allocatable": {                 ← ✅ Webhook 查這個       │
│        "nvidia.com/gpu": "4"          ← 存儲在 etcd 中          │
│      }                                                          │
│    }                                                            │
│  }                                                              │
│                                                                 │
│  Key: /registry/pods/default/pod-gpu-1                        │
│  Value:                                                         │
│  {                                                              │
│    "kind": "Pod",                                               │
│    "metadata": { "name": "pod-gpu-1" },                        │
│    "spec": {                                                    │
│      "nodeName": "gpu-sim-cluster-worker",  ← 綁定節點          │
│      "containers": [{                                           │
│        "resources": {                                           │
│          "requests": {                ← ✅ 需要累加這些          │
│            "nvidia.com/gpu": "1"      ← 每個 Pod 存儲在 etcd   │
│          }                                                      │
│        }                                                        │
│      }]                                                         │
│    }                                                            │
│  }                                                              │
│                                                                 │
│  Key: /registry/pods/default/pod-gpu-2                        │
│  Key: /registry/pods/default/pod-gpu-3                        │
│  ... (更多 Pods)                                                │
│                                                                 │
└────────────────────────────────────────────────────────────────┘
                            ↑
                            │ gRPC/Protobuf
                            │ (高效的二進制協議)
                            │
┌───────────────────────────┴─────────────────────────────────────┐
│                      API Server                                  │
│                                                                   │
│  功能：                                                           │
│  1. RESTful API 接口 (HTTP/JSON)                                │
│  2. 驗證和授權 (RBAC)                                            │
│  3. 從 etcd 讀取數據                                             │
│  4. Watch 機制（監聽變更）                                        │
│  5. 緩存熱數據（減少 etcd 壓力）                                  │
│                                                                   │
│  提供的 API：                                                     │
│  GET /api/v1/nodes                    ← Webhook 調用這個          │
│  GET /api/v1/pods                     ← Webhook 也可以調用這個    │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
                            ↑
                            │ HTTP + JSON
                            │ (client-go library)
                            │
┌───────────────────────────┴─────────────────────────────────────┐
│                  Webhook (Go 程序)                               │
│                                                                   │
│  使用 client-go 庫：                                              │
│  clientset.CoreV1().Nodes().List()    → 獲取 Allocatable        │
│  clientset.CoreV1().Pods().List()     → 獲取所有 Pod requests    │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
```

---

## 💡 三個概念詳解

### 1. Allocatable（可分配總量）

**定義**: 節點上可以分配給 Pod 的資源總量（扣除系統保留後）

**數據來源**:
```go
// 存儲在 etcd 中
Node.Status.Allocatable["nvidia.com/gpu"] = "4"
```

**計算公式**:
```
Allocatable = Capacity - Reserved
```

**示例**:
```
Capacity (硬件)      = 4 個 GPU
Reserved (系統保留)  = 0 個 GPU (通常 GPU 不保留)
Allocatable          = 4 個 GPU  ← 存儲在 etcd
```

**更新時機**:
- 節點啟動時（Kubelet 上報）
- 硬件配置變更時
- 幾乎是**靜態的**（很少變化）

---

### 2. Allocated（已分配量）

**定義**: 已經分配給所有 Pod 的資源總和

**數據來源**:
```go
// ❌ 不存儲！需要累加所有 Pod
allocated = Sum(Pod.Spec.Containers[].Resources.Requests["nvidia.com/gpu"])
```

**計算公式**:
```
Allocated = Σ (每個 Pod 的 requests)
```

**示例**:
```
Pod-1: requests 1 GPU
Pod-2: requests 1 GPU
Pod-3: requests 2 GPU
────────────────────
Allocated = 4 GPU  ← 需要實時計算，不存儲
```

**更新時機**:
- 每次 Pod 創建時（+1）
- 每次 Pod 刪除時（-1）
- **動態變化**（頻繁）

---

### 3. Available（實際可用量）

**定義**: 當前還可以分配的資源量

**數據來源**:
```go
// ❌ 不存儲！計算得出
available = allocatable - allocated
```

**計算公式**:
```
Available = Allocatable - Allocated
```

**示例**:
```
Allocatable = 4 GPU  (etcd 中存儲)
Allocated   = 3 GPU  (計算得出)
────────────────────
Available   = 1 GPU  ← 計算得出，不存儲
```

**更新時機**:
- 隨著 Allocated 變化而變化
- **實時動態**

---

## 📝 代碼示例

### 當前 Webhook 的代碼（只查 Allocatable）

```go
// 文件: webhook/cmd/main.go:263-278

func (w *GPUAllocationWebhook) checkMIGAvailability(resourceName string) (bool, error) {
    // 步驟 1: 通過 client-go 查詢所有節點
    // client-go → HTTP GET → API Server → etcd
    nodes, err := w.clientset.CoreV1().Nodes().List(context.Background(), metav1.ListOptions{})
    if err != nil {
        return false, err
    }

    // 步驟 2: 遍歷所有節點
    for _, node := range nodes.Items {
        // 步驟 3: 檢查 Allocatable (來自 etcd)
        // node.Status.Allocatable 存儲在 etcd: /registry/nodes/<node-name>
        if allocatable, exists := node.Status.Allocatable[corev1.ResourceName(resourceName)]; exists {
            // 步驟 4: 只要 >= 1，就認為有這種資源類型
            if allocatable.Cmp(resource.MustParse("1")) >= 0 {
                return true, nil  // ⚠️ 這是總量，不是可用量！
            }
        }
    }

    return false, nil  // 沒有節點有這種資源類型
}
```

**數據流**:
```
Webhook
  ↓ clientset.CoreV1().Nodes().List()
API Server
  ↓ 從 etcd 讀取 /registry/nodes/*
etcd
  ↓ 返回 Node 對象（包含 Status.Allocatable）
API Server
  ↓ 轉換為 JSON
Webhook
  ↓ 解析並檢查 node.Status.Allocatable
```

---

### 如果要計算 Available（Webhook 不這麼做）

```go
// ⚠️ 這是示例代碼，當前 Webhook 沒有實現

package main

import (
    "context"
    "fmt"
    corev1 "k8s.io/api/core/v1"
    metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
    "k8s.io/apimachinery/pkg/api/resource"
    "k8s.io/client-go/kubernetes"
)

// 計算節點的實際可用 GPU 資源
func calculateAvailableGPU(clientset *kubernetes.Clientset, nodeName, resourceName string) (int64, error) {
    // 步驟 1: 獲取節點的 Allocatable (來自 etcd)
    node, err := clientset.CoreV1().Nodes().Get(context.Background(), nodeName, metav1.GetOptions{})
    if err != nil {
        return 0, fmt.Errorf("failed to get node: %v", err)
    }

    allocatable, exists := node.Status.Allocatable[corev1.ResourceName(resourceName)]
    if !exists {
        return 0, nil  // 節點沒有這種資源
    }
    allocatableQty := allocatable.Value()  // 總可分配量

    // 步驟 2: 列出該節點上的所有 Pod (來自 etcd)
    // 這是昂貴的操作！需要查詢所有 Pod
    pods, err := clientset.CoreV1().Pods("").List(context.Background(), metav1.ListOptions{
        FieldSelector: fmt.Sprintf("spec.nodeName=%s", nodeName),  // 過濾：只要這個節點的 Pod
    })
    if err != nil {
        return 0, fmt.Errorf("failed to list pods: %v", err)
    }

    // 步驟 3: 累加所有 Pod 的 requests (計算 Allocated)
    var allocated int64 = 0
    for _, pod := range pods.Items {
        // 跳過已經終止的 Pod
        if pod.Status.Phase == corev1.PodSucceeded || pod.Status.Phase == corev1.PodFailed {
            continue
        }

        // 遍歷所有容器
        for _, container := range pod.Spec.Containers {
            if qty, exists := container.Resources.Requests[corev1.ResourceName(resourceName)]; exists {
                allocated += qty.Value()
            }
        }
    }

    // 步驟 4: 計算 Available
    available := allocatableQty - allocated

    fmt.Printf("Node: %s\n", nodeName)
    fmt.Printf("  Resource: %s\n", resourceName)
    fmt.Printf("  Allocatable: %d (來自 Node.Status.Allocatable)\n", allocatableQty)
    fmt.Printf("  Allocated:   %d (累加所有 Pod.Spec.Containers.Resources.Requests)\n", allocated)
    fmt.Printf("  Available:   %d (Allocatable - Allocated)\n", available)

    return available, nil
}

// 使用示例
func main() {
    // 假設已經有 clientset
    var clientset *kubernetes.Clientset

    available, err := calculateAvailableGPU(
        clientset,
        "gpu-sim-cluster-worker",
        "nvidia.com/gpu",
    )

    if err != nil {
        fmt.Printf("Error: %v\n", err)
        return
    }

    fmt.Printf("\n實際可用: %d 個 GPU\n", available)
}
```

**數據流**:
```
calculateAvailableGPU()
  ↓
1. clientset.Nodes().Get(nodeName)
   → API Server → etcd: /registry/nodes/gpu-worker
   → 返回 Allocatable = 4

2. clientset.Pods("").List(FieldSelector: nodeName)
   → API Server → etcd: /registry/pods/*
   → 返回所有 Pod 列表 (可能有幾千個！)

3. 本地計算（循環累加）
   for pod in pods:
       allocated += pod.requests
   → allocated = 3

4. 本地計算
   available = allocatable - allocated
   → available = 4 - 3 = 1
```

---

## 🔍 etcd 中的實際數據

### 查看 Node 的 Allocatable (存儲在 etcd)

```bash
# 通過 kubectl 查看（kubectl 也是通過 API Server → etcd）
kubectl get node gpu-sim-cluster-worker -o json | jq '.status.allocatable'

# 輸出（來自 etcd）:
{
  "cpu": "8",
  "memory": "16Gi",
  "nvidia.com/gpu": "4",           ← Allocatable: 4
  "nvidia.com/mig-1g.10gb": "28",
  "nvidia.com/mig-2g.20gb": "12",
  "pods": "110"
}
```

**etcd 中的存儲**（簡化）:
```json
{
  "key": "/registry/nodes/gpu-sim-cluster-worker",
  "value": {
    "kind": "Node",
    "metadata": {
      "name": "gpu-sim-cluster-worker"
    },
    "status": {
      "allocatable": {
        "nvidia.com/gpu": {
          "format": "DecimalSI",
          "s": "4"
        }
      }
    }
  }
}
```

---

### 查看 Pod 的 Requests (存儲在 etcd)

```bash
# 查看所有 Pod 的 GPU requests
kubectl get pods --all-namespaces -o json | \
  jq -r '.items[] |
    select(.spec.containers[].resources.requests["nvidia.com/gpu"]) |
    "\(.metadata.name): \(.spec.containers[0].resources.requests["nvidia.com/gpu"])"'

# 輸出（每個來自 etcd 的一條記錄）:
pod-gpu-1: 1
pod-gpu-2: 1
pod-gpu-3: 2
```

**etcd 中的存儲**（每個 Pod 一條）:
```json
{
  "key": "/registry/pods/default/pod-gpu-1",
  "value": {
    "kind": "Pod",
    "metadata": {
      "name": "pod-gpu-1"
    },
    "spec": {
      "nodeName": "gpu-sim-cluster-worker",
      "containers": [{
        "resources": {
          "requests": {
            "nvidia.com/gpu": {
              "format": "DecimalSI",
              "s": "1"
            }
          }
        }
      }]
    }
  }
}
```

---

### 計算 Available (不存儲在 etcd)

```bash
#!/bin/bash
# 這個腳本模擬計算 Available

NODE="gpu-sim-cluster-worker"

# 1. 從 etcd 獲取 Allocatable (通過 API Server)
ALLOCATABLE=$(kubectl get node $NODE \
  -o jsonpath='{.status.allocatable.nvidia\.com/gpu}')

echo "Allocatable (來自 etcd): $ALLOCATABLE"

# 2. 從 etcd 獲取所有 Pod 的 requests (通過 API Server)
ALLOCATED=$(kubectl get pods --all-namespaces \
  --field-selector spec.nodeName=$NODE \
  -o json | \
  jq '[.items[] |
      select(.status.phase=="Running" or .status.phase=="Pending") |
      .spec.containers[].resources.requests["nvidia.com/gpu"] // "0"] |
      map(tonumber) |
      add // 0')

echo "Allocated (計算得出):     $ALLOCATED"

# 3. 計算 Available
AVAILABLE=$((ALLOCATABLE - ALLOCATED))

echo "Available (計算得出):     $AVAILABLE"
```

**運行示例**:
```bash
$ ./calculate-available.sh
Allocatable (來自 etcd): 4
Allocated (計算得出):     3
Available (計算得出):     1
```

---

## ⚡ 性能對比

### Webhook 當前方法（只查 Allocatable）

```go
// 單次 API 調用
nodes, err := clientset.CoreV1().Nodes().List()

// 性能:
// - API 調用: 1 次
// - 返回數據: ~10 個節點 × ~10KB = 100KB
// - 耗時: ~10-20ms
// - 計算: O(N) 其中 N = 節點數 (通常 < 100)
```

**優點**:
- ✅ 快速（單次 API 調用）
- ✅ 數據量小
- ✅ 不影響性能

---

### 如果計算 Available（理論上的做法）

```go
// 需要 2 次 API 調用
nodes, err := clientset.CoreV1().Nodes().List()
pods, err := clientset.CoreV1().Pods("").List()

// 性能:
// - API 調用: 2 次
// - 返回數據:
//   - 10 個節點 × 10KB = 100KB
//   - 1000 個 Pod × 50KB = 50MB (!)
// - 耗時: ~500-1000ms
// - 計算: O(N × M) 其中 N = 節點數, M = Pod 數
```

**缺點**:
- ❌ 慢（大集群可能需要數秒）
- ❌ 數據量大（可能幾十 MB）
- ❌ 嚴重影響性能
- ❌ API Server 負載高

---

## 🎓 為什麼 Webhook 只查 Allocatable

### 架構設計原因

```
┌─────────────────────────────────────────────────────────┐
│              Kubernetes 設計哲學                         │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  每個組件有明確的職責邊界：                               │
│                                                          │
│  1. Admission Webhook (準入控制):                       │
│     職責: 資源類型轉換、驗證、默認值                     │
│     數據: Node.Status.Allocatable (靜態)                │
│     決策: 這種資源類型存在嗎？                           │
│                                                          │
│  2. Scheduler (調度器):                                 │
│     職責: 資源分配、節點選擇                            │
│     數據: 實時計算 Available (動態)                     │
│     決策: 哪個節點有足夠的可用資源？                     │
│                                                          │
│  3. Kubelet (節點代理):                                 │
│     職責: 容器運行、資源隔離                            │
│     數據: 實際物理資源                                  │
│     決策: 是否有足夠的物理資源運行？                     │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

### 數據特性

| 特性 | Allocatable | Available |
|------|-------------|-----------|
| 存儲位置 | etcd (Node 對象) | 不存儲，實時計算 |
| 變化頻率 | 幾乎不變（靜態） | 頻繁變化（動態） |
| 查詢成本 | 低（單次 API 調用） | 高（需要列出所有 Pod） |
| 數據一致性 | 強一致性 | 弱一致性（Race Condition） |
| 適用場景 | 類型檢查 | 調度決策 |

---

## 🔄 完整的 Pod 創建流程

```
用戶: kubectl apply -f pod.yaml
  ↓
  ↓ 1. API Server 接收請求
  ↓
API Server: 保存到 etcd
  ↓
  ↓ 2. 觸發 Admission Webhook
  ↓
Webhook:
  ↓ checkMIGAvailability("nvidia.com/mig-2g.20gb")
  ↓   → clientset.Nodes().List()
  ↓   → API Server → etcd: 讀取 Node.Status.Allocatable
  ↓   → 返回: allocatable["mig-2g.20gb"] = 12
  ↓   → 判斷: 12 >= 1 → true (有這種類型)
  ↓
  ✅ Webhook 決定: 不需要降級
  ↓
  ↓ 3. Webhook 返回 AdmissionResponse{Allowed: true}
  ↓
API Server: 更新 Pod 到 etcd (Pending 狀態)
  ↓
  ↓ 4. Scheduler Watch 到新 Pod
  ↓
Scheduler:
  ↓ 計算每個節點的 Available
  ↓   → 獲取 Allocatable (來自 etcd)
  ↓   → 列出所有 Pod (來自 etcd)
  ↓   → 計算 Allocated = Σ requests
  ↓   → 計算 Available = Allocatable - Allocated
  ↓
  ↓ Node-1: available = 12 - 10 = 2  ✅ 可以調度
  ↓ Node-2: available = 12 - 12 = 0  ❌ 資源不足
  ↓
  ✅ Scheduler 決定: 調度到 Node-1
  ↓
API Server: 更新 Pod.Spec.NodeName = Node-1 到 etcd
  ↓
  ↓ 5. Kubelet Watch 到 Pod 被調度到自己
  ↓
Kubelet:
  ↓ 檢查物理 GPU 是否可用
  ↓ 調用 Device Plugin (nvidia-device-plugin)
  ↓ 分配實際的 GPU
  ↓ 啟動容器
  ↓
  ✅ Pod Running
```

---

## 🎯 總結

### Webhook 的數據查詢路徑

```
Webhook (Go 代碼)
  ↓ client-go library
  ↓ HTTP GET /api/v1/nodes
  ↓
API Server (Kubernetes 組件)
  ↓ gRPC
  ↓
etcd (分布式鍵值數據庫)
  ↓ 返回 Node 對象（包含 Status.Allocatable）
  ↓
API Server (解析 + 轉換為 JSON)
  ↓ HTTP Response (JSON)
  ↓
Webhook (解析 JSON → node.Status.Allocatable)
```

### 三個資源概念

| 概念 | 存儲位置 | 查詢方式 | 用途 |
|------|---------|---------|------|
| **Allocatable** | ✅ etcd (Node 對象) | `node.Status.Allocatable` | Webhook 用於類型檢查 |
| **Allocated** | ❌ 不存儲 | 累加所有 `pod.Spec.Containers.Resources.Requests` | Scheduler 計算使用 |
| **Available** | ❌ 不存儲 | `Allocatable - Allocated` | Scheduler 調度決策 |

### 為什麼 Webhook 不查 Available

1. **職責分離**: Webhook 負責類型轉換，Scheduler 負責資源分配
2. **性能**: 查 Allocatable 快（1次API），查 Available 慢（需要列出所有Pod）
3. **一致性**: Allocatable 靜態穩定，Available 動態變化（Race Condition）
4. **設計哲學**: 符合 Kubernetes 的分層架構

### Webhook 的正確定位

✅ **Webhook 的價值**:
- 智能的**資源類型適配**（跨環境、異構集群）
- 檢查集群是否**支持**某種 GPU 類型
- 自動降級策略（3g → 2g → 1g → gpu）

❌ **Webhook 不做的事**:
- 不檢查**實際可用量**（Scheduler 的工作）
- 不做調度決策（Scheduler 的工作）
- 不保證資源立即可用（可能 Pending）

**這是正確且高效的設計！** 🎉

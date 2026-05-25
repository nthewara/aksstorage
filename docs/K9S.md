# k9s — Terminal UI for AKS

[k9s](https://k9scli.io) is a terminal UI for Kubernetes that gives you a live,
filterable, keystroke-driven view of every resource in your cluster. Strongly
recommended for this lab — watching Cassandra bootstrap, PVCs binding to NVMe,
and failure scenarios play out is *much* nicer in k9s than in `kubectl -w` loops.

---

## Install

### macOS
```bash
brew install k9s
```

### Linux
```bash
curl -sS https://webi.sh/k9s | sh
# or
wget https://github.com/derailed/k9s/releases/latest/download/k9s_Linux_amd64.tar.gz
tar -xzf k9s_Linux_amd64.tar.gz k9s
sudo mv k9s /usr/local/bin/
```

### Windows
```powershell
winget install --id Derailed.k9s
# or
choco install k9s
```

Verify:
```bash
k9s version
```

---

## Launch against the lab cluster

Make sure kubeconfig is set first:

```bash
az aks get-credentials -g rg-acstor-lab -n aks-acsl-3dntcpfgfndgw --overwrite-existing
k9s
```

That's it — k9s reads `~/.kube/config` and lands on the default namespace pod view.

---

## Cheatsheet

### Navigation
| Keys | What it does |
|---|---|
| `:` | Command mode — `:pods`, `:pvc`, `:sts`, `:nodes`, `:storagepool` |
| `/` | Filter the current view (regex) |
| `Esc` | Back out / clear filter |
| `Ctrl-c` / `q` | Quit |
| `?` | Help for current view |
| `:ns` | Switch namespace; `:ns all` for cross-namespace |
| `:ctx` | Switch kubecontext |

### On any resource row
| Keys | What it does |
|---|---|
| `l` | View logs (tails live) |
| `s` | Shell into the pod (defaults to `sh`, prompts for container) |
| `d` | Describe |
| `e` | Edit (opens `$EDITOR`) |
| `Ctrl-d` | Delete (prompts) |
| `Ctrl-k` | Kill (no grace period) |
| `y` | Show YAML |
| `Shift-f` | Port-forward |

### Logs view
| Keys | What it does |
|---|---|
| `f` | Toggle full screen |
| `w` | Toggle wrap |
| `s` | Save to file |
| `/` | Filter log lines |
| `0`–`9` | Time range (last N min) |

### Cluster-wide
| Keys | What it does |
|---|---|
| `:events` | Live event stream (great for debugging) |
| `:popeye` | Cluster sanity scan |
| `:pulses` | Cluster pulse dashboard |
| `:xray pods` | Resource hierarchy view |

---

## Lab walkthrough — what to watch in k9s

### 1. Initial bring-up
- `:nodes` — confirm 5 nodes Ready (2 syspool + 3 storagepool)
- Filter `/storagepool` to see just the Lsv3 nodes
- `d` on a storagepool node — confirm `kubernetes.azure.com/agentpool=storagepool` label

### 2. Enable ACS
- `:ns kube-system` (ACS v2 lives here — filter `/acstor`)
- `:pods` — watch the ACS extension installer, CSI driver, node agent come up
- Filter `/local-csi` to see the local NVMe CSI driver pods rolling out
- Wait until all pods are `Running` before applying any StorageClass

### 3. Cassandra bootstrap
- `:ns default`
- `:sts` then `d` on `cassandra` — see the rolling startup
- `:pods` filter `/cassandra` — watch pod-0 → pod-1 → pod-2 come up sequentially
- Tail pod-0 logs (`l`) — see Cassandra start the gossip, join the ring

### 4. PVC binding
- `:pvc` — watch each PVC go `Pending → Bound`
- `d` on a bound PVC — confirm `volume.kubernetes.io/selected-node` matches a storagepool node
- `:pv` — confirm `provisioner: localdisk.csi.acstor.io`

### 5. Load test
- Apply `nosqlbench-loadgen` or `cassandra-loadgen`
- `:jobs` then `l` on the loadgen pod — watch ops/sec stream in
- Split-screen: open k9s in one terminal showing `:pods` filtered to `/cassandra`,
  watch CPU/mem pressure in real time while loadgen runs

### 6. Failure scenarios
- `:pods`, find a Cassandra pod, hit `Ctrl-k` (kill -9 it)
- Watch the STS controller spawn a replacement
- Tail logs (`l`) on the new pod — see it rejoin the ring
- `:events` in parallel — see the Pod evicted / Pod scheduled / Volume reattach events

---

## Optional tweaks

### Theme
`~/.config/k9s/skins/<name>.yaml` — community themes at
[github.com/derailed/k9s/tree/master/skins](https://github.com/derailed/k9s/tree/master/skins).
Set in `~/.config/k9s/config.yaml`:

```yaml
k9s:
  ui:
    skin: "dracula"
```

### Resource limit indicators
k9s shows CPU/mem usage out of the box if `metrics-server` is installed. AKS
ships metrics-server by default, so this just works on our cluster.

### Plugins
`~/.config/k9s/plugins.yaml` — custom keyboard shortcuts for things like
`stern` log streaming, `kubectl debug`, etc. See
[k9scli.io/topics/plugins](https://k9scli.io/topics/plugins/).

---

## When NOT to use k9s

- Scripting / CI — use `kubectl` directly, it's deterministic
- Bulk operations across many clusters — `kubectl` + `kubectx` is faster
- Producing artifacts (yaml dumps, etcd snapshots) — k9s is read-mostly UX

For day-to-day interactive cluster work though, it's hard to beat.

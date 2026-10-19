#!/usr/bin/env python3
"""只读扫描 /root/ascend-ci-deployment/argocd 下所有 Application，聚合 服务×集群 与 业务×集群 两张表。"""
import os, json, collections, yaml

ROOT = "/root/ascend-ci-deployment/argocd"
apps = []
for dirpath, _, files in os.walk(ROOT):
    for fn in files:
        if not fn.endswith((".yaml", ".yml")):
            continue
        p = os.path.join(dirpath, fn)
        try:
            docs = list(yaml.safe_load_all(open(p, encoding="utf-8")))
        except Exception as e:
            print("PARSE_FAIL", p, e)
            continue
        for d in docs:
            if not isinstance(d, dict) or d.get("kind") != "Application":
                continue
            spec = d.get("spec", {}) or {}
            src = spec.get("source", {}) or {}
            srcs = spec.get("sources", []) or []
            dst = spec.get("destination", {}) or {}
            paths = [src.get("path") or ""] + [s.get("path") or "" for s in srcs if isinstance(s, dict)]
            for pp in paths:
                if pp:
                    apps.append({
                        "file": os.path.relpath(p, ROOT),
                        "name": (d.get("metadata") or {}).get("name"),
                        "cluster": dst.get("name") or "?",
                        "namespace": dst.get("namespace") or "",
                        "path": pp,
                        "repo": src.get("repoURL") or "",
                    })
            if not any(paths):
                apps.append({
                "file": os.path.relpath(p, ROOT),
                "name": (d.get("metadata") or {}).get("name"),
                "cluster": dst.get("destination_name") or dst.get("name") or "?",
                "namespace": dst.get("namespace") or "",
                "path": src.get("path") or "",
                "repo": src.get("repoURL") or "",
            })

INFRA_TOKENS = ("manifests/", "monitoring/", "controllers/")
svc_cluster = collections.defaultdict(set)
biz_cluster = collections.defaultdict(set)
other_cluster = collections.defaultdict(set)
for a in apps:
    path = a["path"]
    cl = a["cluster"]
    if path.startswith("projects/"):
        parts = path.split("/")
        biz = "/".join(parts[1:3]) if len(parts) >= 3 else parts[-1]
        biz_cluster[biz].add(cl)
    elif path.startswith("other/"):
        parts = path.split("/")
        biz = "/".join(parts[1:3]) if len(parts) >= 3 else parts[-1]
        other_cluster[biz].add(cl)
    elif path.startswith("manifests/"):
        svc = path.split("/")[1]
        svc_cluster[svc].add(cl)
    elif path.startswith("monitoring/"):
        svc = "monitoring/" + (path.split("/")[1] if len(path.split("/")) > 1 else "")
        svc_cluster[svc].add(cl)
    elif path.startswith("argocd/controllers") or path == "controllers":
        svc_cluster["arc-controller(controllers/)"].add(cl)
    else:
        svc_cluster["OTHER:" + (path or a["repo"])].add(cl)

out = {
    "total_apps": len(apps),
    "clusters": sorted({a["cluster"] for a in apps}),
    "infra": {k: sorted(v) for k, v in sorted(svc_cluster.items())},
    "projects": {k: sorted(v) for k, v in sorted(biz_cluster.items())},
    "other": {k: sorted(v) for k, v in sorted(other_cluster.items())},
}
json.dump(out, open("/tmp/opencode/apps_matrix.json", "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print("apps:", out["total_apps"], "clusters:", len(out["clusters"]))
print("\nCLUSTERS:", ", ".join(out["clusters"]))
for k, v in out["infra"].items():
    print(f"INFRA {k:45s} n={len(v):2d} :: {', '.join(v)}")

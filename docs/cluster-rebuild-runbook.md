# 클러스터 재구축 런북 — 단일 노드 Clean Install

이 문서는 개인 OCI 단일 노드(2 OCPU / 12GB — Always Free 축소 반영, ADR-0004)에 `platform-infra` 스택을 **새 시크릿으로 깨끗하게** 재구축하는 절차입니다. 토폴로지 결정 근거는 `docs/adr/0002-single-node-cluster-topology.md`, 자원 리핏은 `docs/adr/0004-refit-platform-for-12gb-free-tier.md`를 참조합니다.

> 이전 2-node 구성과는 별개의 새 클러스터입니다. 기존 SealedSecret은 옛 클러스터 공개키로 암호화되어 있어 그대로 쓸 수 없고, 새 비밀번호를 생성해 reseal합니다.

## 플레이스홀더

아래 명령 예시는 절차 템플릿이라 `<NODE_IP>` 표기를 유지한다. 현재 클러스터의 확정값은 표에 함께 기재한다.

| 표기 | 의미 | 현재 클러스터 값 |
|---|---|---|
| `<NODE_IP>` | 새 OCI 단일 노드 공인 IP | `158.179.169.201` |

---

## Phase 0 — OCI 노드 준비 (콘솔, 수동) — ✅ 완료

- 기존 2 인스턴스 정리 → **2 OCPU / 12GB 단일 인스턴스** 재구성 (Always Free 축소 반영, ADR-0004. 주의: 2026-06-15부 정책 확정으로 **terminate한 4/24 인스턴스는 상위 사양으로 재생성 불가** — 재구축은 반드시 2/12를 전제하고, 현 노드가 4/24 grandfather라도 그 shape는 일회성 자산으로 취급)
- 부트 볼륨 용량 확인 (local-path PV가 노드 디스크를 사용 — 실제 사용량이 디스크를 넘지 않도록 주의)
- 산출물: `<NODE_IP>` = `158.179.169.201` (발급 완료), SSH 접속 확인 (포트 22, `~/.ssh/id_rsa`)

---

## Phase 1 — 노드 사전 준비 (SSH)

```bash
ssh ubuntu@<NODE_IP>
# 자원 확인
free -h; nproc; df -h /
# inotify 한계 상향 (Pod 많은 스택 대비)
sudo sysctl -w fs.inotify.max_user_instances=512
sudo sysctl -w fs.inotify.max_user_watches=524288
# 영구 반영
echo -e "fs.inotify.max_user_instances=512\nfs.inotify.max_user_watches=524288" | sudo tee /etc/sysctl.d/99-k3s.conf
```

방화벽 메모:
- **지금 단계**: SSH 22만 외부 개방. k3s API 6443은 노드 로컬 유지(접근은 `docs/cluster-access-kubeconfig.md` 방식 B = SSH 터널).
- **Grafana 등 노출 시**: OCI Security List에 80/443 인바운드 추가 + Ubuntu 이미지 기본 iptables `REJECT` 룰 손봐야 Traefik 트래픽이 들어옴. (단일 노드라 노드 간 트래픽 이슈는 없음)

---

## Phase 2 — k3s 설치 (단일 서버)

```bash
# 버전 핀 고정 권장 (예시: v1.32 stable 계열, 설치 시점 최신 stable 확인 후 고정)
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.32.x+k3s1" sh -
```

- **내장 컴포넌트 유지**: Traefik(ingress) + ServiceLB(klipper) + local-path-provisioner
  - 근거: 별도 ingress 컨트롤러 없이 k3s 내장 Traefik 전제(향후 Grafana/Keycloak 노출도 동일), 전 컴포넌트 PVC는 `storageClass: local-path` 전제.
- 검증(운영 PC에서, SSH 터널 기동 후):

```bash
# k3s.yaml 가져오기 (root:600 이므로 노드에서 사용자 소유 임시본 경유)
ssh ubuntu@<NODE_IP> 'sudo cp /etc/rancher/k3s/k3s.yaml /tmp/k3s.yaml && sudo chown ubuntu /tmp/k3s.yaml'
scp ubuntu@<NODE_IP>:/tmp/k3s.yaml ~/.kube/oci-platform.yaml
ssh ubuntu@<NODE_IP> 'rm -f /tmp/k3s.yaml'
kubectl --kubeconfig ~/.kube/oci-platform.yaml config rename-context default oci-platform
# server: https://127.0.0.1:6443 그대로 유지 (인증서 SAN 일치)

# 터널 기동
ssh -N -L 6443:127.0.0.1:6443 ubuntu@<NODE_IP> &
export KUBECONFIG=~/.kube/oci-platform.yaml
kubectl get nodes   # 노드 1개 Ready
```

---

## Phase 3 — GitOps 부트스트랩 (핵심)

### 3.1 repoURL 전환 — ✅ 완료

**(2026-06 완료)** Git repoURL 14곳은 GitHub(`https://github.com/yhsk9200/gitops-infra.git`) 기준으로 정리 완료(커밋 `4d239a2`). Bitnami 차트 repoURL(postgres/keycloak)도 `charts.bitnami.com` 폐쇄(403)에 따라 `oci://registry-1.docker.io/bitnamicharts`로 전환했고, 이미지 태그는 `bitnamilegacy/*` 고정 태그로 핀 고정했다 (`helm-values/database/postgres-values.yaml` 주석 참조). 공용 redis는 ADR-0003으로 제거됨.

확인 사항:
- GitHub 레포가 **public이면** ArgoCD 익명 clone 가능. **private이면** ArgoCD에 repo credential(PAT) 등록 필요.
- 모든 앱 `targetRevision: main` → GitHub 기본 브랜치 `main`과 일치.
- 차트 repoURL은 스킴 없는 `registry-1.docker.io/bitnamicharts` + `chart:` 필드 형식 — `oci://` 스킴은 ArgoCD 3.x에서 401을 유발한다(3.2의 주의 참조, 2026-07 수정).

### 3.2 ArgoCD 설치

```bash
kubectl create namespace argocd
kubectl apply --server-side -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server
# 초기 admin 비번
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

> `--server-side` 필수: applicationsets CRD가 client-side apply의 last-applied 주석 한도(256KB)를 초과한다 (2026-07-02 재구축 실측).
>
> **주의 (ArgoCD 3.x)**: OCI 차트 Application의 `repoURL`에 `oci://` 스킴을 쓰지 말 것 — v3.4 네이티브 OCI 경로가 chart명이 누락된 digest 조회(`/v2/<네임스페이스>/manifests/<차트버전>`)를 날려 401이 난다. 스킴 없는 `registry-1.docker.io/bitnamicharts` + `chart:` 필드 형식을 사용한다 (익명 접근 가능, repo secret 불필요 — 2026-07-02 실측).

### 3.3 sealed-secrets 컨트롤러 기동 + 새 cert 확보

Root App을 적용하면 wave -2에서 컨트롤러가 뜨며 **새 키쌍을 자동 생성**한다. (또는 reseal을 먼저 하려면 이 단계에서 차트만 선설치해도 됨.) 컨트롤러가 뜬 뒤 새 공개키를 받는다:

```bash
kubeseal --fetch-cert \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=platform-system \
  > pub-cert.pem
```

> `controller-name`은 `helm-values/system/sealed-secrets-values.yaml`의 `fullnameOverride: sealed-secrets-controller`를 따름 — 실제 배포된 서비스명으로 재확인.

### 3.4 새 시크릿 생성 + reseal

**값 생성** (특수문자 이슈 회피 위해 영숫자 권장):

```bash
gen() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "${1:-32}"; echo; }  # LC_ALL=C: macOS UTF-8 로케일에서 tr 실패 방지
POSTGRES_PW=$(gen 32)
KEYCLOAK_PW=$(gen 32)      # postgres-db-secret + keycloak-db-secret 공유
KEYCLOAK_ADMIN_PW=$(gen 32)
GRAFANA_PW=$(gen 32)
```

**시크릿 ↔ 파일 ↔ 키 매핑** (★ = 값 공유):

| 파일 | Secret / NS | 키 |
|---|---|---|
| `postgres-sealed-secret.yaml` | `postgres-db-secret` / platform-db | `postgres-password`, ★`keycloak-password` |
| `keycloak-db-sealed-secret.yaml` | `keycloak-db-secret` / platform-iam | ★`keycloak-password` (= 위 keycloak-password) |
| `keycloak-sealed-secret.yaml` | `keycloak-admin-secret` / platform-iam | `admin-password` |
| `grafana-sealed-secret.yaml` | `grafana-admin-secret` / platform-monitoring | `admin-user`(=admin), `admin-password` |

**reseal 명령** (각 파일 헤더 주석과 동일 패턴, `--cert pub-cert.pem`):

```bash
# postgres-db-secret (2키)
kubectl create secret generic postgres-db-secret --namespace=platform-db \
  --from-literal=postgres-password="$POSTGRES_PW" \
  --from-literal=keycloak-password="$KEYCLOAK_PW" \
  --dry-run=client -o yaml | kubeseal --cert pub-cert.pem --format=yaml \
  > manifests/security/postgres-sealed-secret.yaml

# keycloak-db-secret (공유값)
kubectl create secret generic keycloak-db-secret --namespace=platform-iam \
  --from-literal=keycloak-password="$KEYCLOAK_PW" \
  --dry-run=client -o yaml | kubeseal --cert pub-cert.pem --format=yaml \
  > manifests/security/keycloak-db-sealed-secret.yaml

# keycloak-admin-secret
kubectl create secret generic keycloak-admin-secret --namespace=platform-iam \
  --from-literal=admin-password="$KEYCLOAK_ADMIN_PW" \
  --dry-run=client -o yaml | kubeseal --cert pub-cert.pem --format=yaml \
  > manifests/security/keycloak-sealed-secret.yaml

# grafana-admin-secret (user+password)
kubectl create secret generic grafana-admin-secret --namespace=platform-monitoring \
  --from-literal=admin-user='admin' \
  --from-literal=admin-password="$GRAFANA_PW" \
  --dry-run=client -o yaml | kubeseal --cert pub-cert.pem --format=yaml \
  > manifests/security/grafana-sealed-secret.yaml
```

> 생성한 평문 비밀번호는 안전한 비밀번호 관리자에 1회 보관(특히 grafana/keycloak admin, postgres superuser). 이후 셸 변수는 정리.

reseal 결과를 **commit & push (GitHub)** 한다 → ArgoCD가 wave -1 재sync.

### 3.5 Root App 적용 + sync wave 확인

```bash
kubectl apply -f bootstrap/platform-root-infra.yaml
# wave 순서로 자동 배포; 모니터링
kubectl -n argocd get applications -w
```

- 3.4의 reseal/push가 끝나야 wave -1(SealedSecret)이 정상 sync → wave 0~5 진행.
- Postgres가 **새 비밀번호로 initdb** 하며 keycloak 계정을 생성(최초 빈 PVC 기준).

---

## Phase 4 — IP 교체 + 문서 갱신 — ✅ 완료 (`158.179.169.201`)

노드 IP가 `158.179.169.201`로 확정되어, 동작에 영향을 주는 config와 운영 문서·README의 호스트/주소를 실제 IP로 치환했다. 본 런북은 재사용 가능한 절차 템플릿이므로 명령 예시에는 `<NODE_IP>` 표기를 그대로 둔다(상단 플레이스홀더 표에 확정값 기재).

### config (동작 영향) — 치환 완료
- ~~`helm-values/registry/harbor-values.yaml`~~ — 당시 치환 완료했으나 Harbor는 이후 [ADR-0006](adr/0006-remove-harbor-registry-off-cluster.md)으로 제거됨

### 문서 — 치환 완료

README, `docs/cluster-access-kubeconfig.md`, `docs/platform-backup-restore-runbook.md`의 호스트/주소를 실제 IP로 치환하고 CLAUDE.md 상태도 갱신했다. (`docs/harbor-push-pull-checklist.md`는 Harbor와 함께 제거됨)

> 향후 노드 IP가 다시 바뀌면 위 운영 문서의 호스트를 새 IP로 갱신한다 (`grep -rln '158.179.169.201'`로 범위 확인 후 sed).

---

## 검증 체크리스트

- [ ] `kubectl get nodes` → 1 Ready
- [ ] `kubectl -n argocd get applications` → 전부 Synced/Healthy
- [ ] Postgres/Keycloak Pod Ready, Keycloak 콘솔 port-forward 접속
- [ ] Grafana 접속(새 admin 비번), 메트릭 대시보드 표시
- [ ] Prometheus 타깃 전부 up (kube-state-metrics 등)
- [ ] (선택, on-demand) `kubectl apply -f apps-ondemand/` 후 Grafana Explore에서 Loki 로그 조회 → 확인 후 `kubectl delete -f apps-ondemand/`

## 리스크 / 주의

- **단일 노드 자원(12GB)**: ADR-0004로 이미 리핏됨 — Prometheus retention 5d·limit 1Gi, 로그(Loki/Alloy)는 `apps-ondemand/` on-demand. 추가 압박 시 keycloak requests 추가 조정 검토. on-demand 컴포넌트는 동시 부하 시간대를 피해 기동.
- **디스크**: local-path PV는 노드 디스크 공유. PVC 사용량 모니터링.
- **백업**: 단일 노드 단일 장애점 → `docs/platform-backup-restore-runbook.md` 백업 주기 준수.

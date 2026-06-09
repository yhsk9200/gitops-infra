# CLAUDE.md — dgtp-infra 세션 컨텍스트

이 파일은 Claude Code 세션 간 컨텍스트를 이어받기 위한 작업 메모입니다.

## 프로젝트 개요

대구테크노파크 제조데이터플랫폼 공용 인프라를 ArgoCD App of Apps 패턴으로 관리하는 GitOps 레포입니다.
동시에 **개인 포트폴리오 레포**로도 관리됩니다 (GitHub: yhsk9200/gitops-infra).

- **회사 원격**: `origin` → `https://gitlab.am.micube.dev/daegu-tp/mfg-data-platform/gitops/platform-infra.git`
- **개인 원격**: `github` → `https://github.com/yhsk9200/gitops-infra.git`

## 클러스터 환경

| 항목 | 값 |
|---|---|
| 클러스터 | OCI ARM 2-node k3s |
| 서버 IP | `210.113.225.245` |
| SSH 포트 | `22222` |
| SSH 유저 | `ubuntu` |
| k3s API 포트 | `6443` (노드 로컬 바인딩, 공인 미노출) |
| Harbor 외부 URL | `http://harbor.210.113.225.245.nip.io` |

## 배포된 컴포넌트

ArgoCD sync wave 순서로 전부 배포 완료 상태:

| Wave | 컴포넌트 | 네임스페이스 | 상태 |
|---|---|---|---|
| -10 | appproject-platform-infra | argocd | 정상 |
| -3 | platform-infra-namespaces | — | 정상 |
| -2 | platform-system-sealed-secrets | platform-system | 정상 |
| -1 | platform-infra-secrets | 각 ns | 정상 |
| 0 | platform-infra-storage, cert-manager | platform-system | 정상 |
| 1 | platform-db-postgres, platform-db-redis | platform-db | 정상 |
| 2 | platform-iam-keycloak | platform-iam | 정상 |
| 3 | platform-monitoring-prometheus | platform-monitoring | 정상 |
| 4 | platform-monitoring-loki, platform-registry-harbor | platform-monitoring/registry | 정상 |
| 5 | platform-monitoring-alloy | platform-monitoring | 정상 |

> Harbor는 chart 특성상 `Healthy + OutOfSync`로 남을 수 있음 — Harbor UI/push/pull/PostgreSQL 정상이면 known diff로 간주.

## 이전 세션(회사 PC)에서 완료한 작업

1. **Harbor external PostgreSQL 연동** — `platform-db-postgres` 사용, `harbor_admin` 유저 / `harbor_registry` DB 자동 생성(initdb 스크립트)
2. **Keycloak dev 구성 문서화** — dev values, RBAC plan, manual RBAC checklist, operations 가이드
3. **Platform observability 체크리스트** — Loki/Alloy 로그 수집, Grafana Explore 검증 절차
4. **Platform alerting TODO** — PrometheusRule + Alertmanager 설계 방향 문서화 (미착수)
5. **Platform backup/restore runbook** — 로컬 백업 세트 생성, NAS 수동 반출 정책
6. **ADR 0001** — AI 모델 시뮬레이터 플랫폼 (MLflow/MinIO 조합) 의사결정 기록
7. **클러스터 접근 가이드** — `docs/cluster-access-kubeconfig.md` (이번 세션 신규)

## 다음 세션(개인 PC)에서 할 작업 — 우선순위 순

### 즉시: 개인 PC 환경 셋업

```bash
# 1. 레포 클론
git clone https://github.com/yhsk9200/gitops-infra.git
cd gitops-infra

# 2. 개인 PC용 SSH 키 생성
ssh-keygen -t ed25519 -C "personal-pc" -f ~/.ssh/oci-personal-pc.key

# 3. OCI 서버에 개인 PC 키 등록 (회사 PC로 마지막 접속)
# ssh-copy-id -i ~/.ssh/oci-personal-pc.key -p 22222 ubuntu@210.113.225.245

# 4. ~/.ssh/config 추가
# Host oci-dgtp
#   HostName 210.113.225.245
#   Port 22222
#   User ubuntu
#   IdentityFile ~/.ssh/oci-personal-pc.key

# 5. kubeconfig 가져오기 (SSH 터널 방식, 상세는 docs/cluster-access-kubeconfig.md)
scp -i ~/.ssh/oci-personal-pc.key -P 22222 \
  ubuntu@210.113.225.245:/etc/rancher/k3s/k3s.yaml \
  ~/.kube/dgtp-oci.yaml
# → server: https://127.0.0.1:6443 그대로 유지 (인증서 SAN 일치)
# → context 이름 변경: kubectl --kubeconfig ~/.kube/dgtp-oci.yaml config rename-context default dgtp-oci

# 6. kubectl 검증 (터널 기동 후)
ssh -i ~/.ssh/oci-personal-pc.key -p 22222 -N -L 6443:127.0.0.1:6443 ubuntu@210.113.225.245 &
export KUBECONFIG=~/.kube/dgtp-oci.yaml
kubectl get nodes
```

자세한 접근 모델 설명 → `docs/cluster-access-kubeconfig.md`

---

### 작업 1: Platform Alerting (가장 준비된 항목)

문서: `docs/platform-alerting-todo.md`

시작 조건이 충족됐는지 먼저 확인:
- Harbor push/pull 검증 완료 여부
- Loki/Alloy 로그 수집 정상 여부
- 알림 채널 확정 여부 (Email/Slack/Teams/Mattermost)

할 일:
```
manifests/monitoring/rules/          ← 새로 만들 디렉토리
  platform-rules.yaml                ← PrometheusRule 리소스
apps/platform-monitoring-rules.yaml  ← ArgoCD Application
```

v1 rule 후보: `PlatformPodCrashLooping`, `PlatformPodNotReady`, `PlatformPVAlmostFull`,
`PlatformTargetDown`, `HarborExporterDown`, `KeycloakDown`, `PostgreSQLDown`, `RedisDown`, `LokiDown`, `AlloyDown`

---

### 작업 2: Harbor 외부 push/pull 최종 검증

체크리스트: `docs/harbor-push-pull-checklist.md`

외부 Docker 클라이언트에서 `harbor.210.113.225.245.nip.io`를 insecure registry로 등록 후 push/pull.

---

### 작업 3: 로컬 백업 스크립트화

런북: `docs/platform-backup-restore-runbook.md`

현재 수동 절차를 쉘 스크립트로 만들고, NAS 반출 리허설 수행.

---

### 작업 4: Keycloak 도메인/TLS 확정 시

- `helm-values/iam/keycloak-values-prod.yaml` TODO 값 채우기
- cert-manager issuer 연결
- Harbor / Grafana SSO client 설정

---

### 장기: AI 모델 시뮬레이터 플랫폼

ADR: `docs/adr/0001-ai-model-simulator-platform.md`

MLflow + MinIO 조합으로 배포 리소스 설계. 아직 미착수.

## 주요 파일 맵

```
CLAUDE.md                          ← 이 파일 (세션 컨텍스트)
README.md                          ← 전체 배포 구조, 부트스트랩, 컴포넌트 버전
docs/
  cluster-access-kubeconfig.md    ← kubeconfig/SSH 터널 접근 가이드 (신규)
  platform-alerting-todo.md       ← alerting 작업 TODO
  platform-observability-checklist.md
  platform-backup-restore-runbook.md
  keycloak-operations.md
  keycloak-rbac-plan.md
  keycloak-manual-rbac-checklist.md
  harbor-push-pull-checklist.md
  adr/0001-ai-model-simulator-platform.md
apps/                              ← ArgoCD Application 정의
helm-values/                       ← 컴포넌트별 Helm values
manifests/                         ← 네임스페이스, SealedSecret, 스토리지
bootstrap/platform-root-infra.yaml ← 최초 부트스트랩 진입점
```

## 참고: 회사 PC SSH 키 정리

개인 PC에서 새 키(`oci-personal-pc.key`)로 OCI 접근이 확인되면,
회사 PC의 `aporiax-oci-a1-lab.key`를 OCI `authorized_keys`에서 제거하고 로컬에서도 삭제하는 것을 권장합니다.

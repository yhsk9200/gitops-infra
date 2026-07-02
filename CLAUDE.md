# CLAUDE.md — gitops-infra 세션 컨텍스트

이 파일은 Claude Code 세션 간 컨텍스트를 이어받기 위한 작업 메모입니다.

## 프로젝트 개요

OCI Always Free 단일 노드(2 OCPU / 12GB — 구 4/24에서 축소, ADR-0004) k3s에 플랫폼 공용 인프라를 ArgoCD App of Apps로 배포·운영하는 **개인 포트폴리오 GitOps 레포**입니다. 전체 구조·컴포넌트·로드맵은 `README.md`가 단일 기준입니다.

- **원격**: `origin` → `git@github.com:yhsk9200/gitops-infra.git` (단일 원격)
- 포폴 핵심 가치: 제약(무료 티어·단일 노드·단독 운영) 하의 트레이드오프 기록 (ADR 0001~0004)

## 레포 전략 (구조·관리)

> 레포가 "GitOps 매니페스트"에서 "플랫폼 IaC(프로비저닝→설정→배포 3레이어)"로 확장되는 단계의 관리 원칙. 구조·전략 결정은 **ADR-0005(IaC 레이어링 + 레포 전략)** 로 정식화 예정이며, 이 섹션은 그 운영 요약이다.

### 1. 레포 경계 — 플랫폼 모노레포 + 제품 단위 분리

- **이 레포 = 플랫폼 IaC 모노레포.** 단독 운영·단일 클러스터라 멀티레포 인지비용이 정당화되지 않고, 리뷰어가 플랫폼 수명주기 전체를 한 곳에서 본다. 3레이어를 형제 디렉토리로:
  - 프로비저닝 → `terraform/` *(예정 — OCI VCN/Security List, 기존 인스턴스 import. 무료 A1 capacity 한계로 "한 방 생성"이 아니라 network+import 범위)*
  - 설정 → `ansible/` *(예정 — 런북 Phase 1~3 코드화, reseal은 제외=수동 경계)*
  - 배포 → `bootstrap/` + `apps/` + `apps-ondemand/` + `manifests/` + `helm-values/` *(현행 GitOps)*
- **경계는 제품 단위로 긋는다.** AI 시뮬레이터(ADR-0001)는 별도 레포 — 다른 수명주기·소유권. 이 레포는 "공용 플랫폼 인프라"에 집중.
- ArgoCD root app은 `apps/`만 스캔 → `terraform/`·`ansible/`를 같은 레포에 둬도 배포에 간섭 없음.

### 2. 브랜치/배포 — 트렁크 기반, main = 배포 대상

- **main이 곧 프로덕션** (ArgoCD auto-sync). main 머지 = 배포.
- 모든 변경: **짧은 수명 브랜치 → PR → CI(`validate.yaml`) 통과 → 머지.** 단독이어도 PR은 (a) CI 게이트 실행 지점이자 (b) 클러스터 반영 전 diff 점검 지점 — 의례가 아니라 유일한 사전 안전장치.
- 장수 dev/staging 브랜치 없음: 단일 클러스터 = 단일 환경, 승격 경로 없음(비목표). 두 번째 환경 생기면 재검토.
- push = 배포이므로 아래 **push 타이밍 주의** 항상 유효.

### 3. CI 진화

- 현행: kubeconform + helm template 8종 (`apps/` `apps-ondemand/` `bootstrap/` `manifests/`).
- IaC 추가 시: `terraform fmt -check`/`validate`(+tflint), `ansible-lint`/`--syntax-check` 잡 추가. 경로 필터로 변경 레이어만 검증.

### 4. 시크릿 정책 (불변)

- **Git에 평문 시크릿 절대 금지.** k8s 시크릿은 SealedSecret만. Terraform `.tfvars`/state·Ansible vars에 평문 비밀 금지(gitignore). reseal은 **수동 경계**(자동화 제외).

### 5. 문서 역할 분리

- **ADR** (`docs/adr/`): 구조·전략 결정의 *왜* (canonical). 구조적 결정은 반드시 ADR.
- **README**: 외부 독자용 *무엇* (포폴 입구).
- **CLAUDE.md** (이 파일): 세션 컨텍스트·현재 상태·다음 작업.
- **runbook/checklist** (`docs/`): 운영 절차.

### 6. 명명 규칙

- ArgoCD Application 파일·이름: `platform-<도메인>-<컴포넌트>` (예: `platform-iam-keycloak`)
- 네임스페이스: `platform-<도메인>` (예: `platform-iam`)

## 현재 상태 (2026-06-14) — 재구축 진행 중 (노드 IP 확정)

| 항목 | 상태 |
|---|---|
| 토폴로지 | **단일 노드** 2 OCPU / 12GB (ADR-0002, 자원 전제는 ADR-0004로 갱신) |
| 자원 리핏 | Always Free 4/24→2/12 축소 대응 (ADR-0004): Trivy off, Prometheus retention 5d·limit 1Gi, **로그(Loki/Alloy)는 `apps-ondemand/` on-demand**. 상시 추정 ~6Gi |
| 클러스터 | Phase 0 완료 — OCI 노드 발급(공인 IP `158.179.169.201`). k3s 미설치, Phase 1~3 진행 예정. 절차: `docs/cluster-rebuild-runbook.md` |
| Harbor 호스트 | `harbor.158.179.169.201.nip.io` — `<NODE_IP>` 치환 완료(런북 Phase 4). config·운영 문서·README 반영됨 |
| SealedSecret | 구 클러스터 키로 암호화된 상태 — 재구축 시 **새 비밀번호로 reseal 필수** (런북 3.4) |
| Bitnami | 차트 `oci://registry-1.docker.io/bitnamicharts`, 이미지 `bitnamilegacy` 핀 (postgres `17.6.0`, keycloak `26.3.3`, os-shell `12-r51`) — `charts.bitnami.com`은 403 폐쇄 |
| 공용 Redis | **제거됨** (ADR-0003) — harbor chart의 `lookup` 기반 existingSecret이 ArgoCD 렌더링과 비호환, Harbor는 internal Redis 유지 |
| Alerting | v1 PrometheusRule 작성 완료 (`platform-monitoring-rules` 앱, wave 5) — receiver는 채널 확정 후 |
| CI | `.github/workflows/validate.yaml` — kubeconform + helm template 8종 렌더링 (로컬 검증 통과) |

### ⚠️ push 타이밍 주의

구 2-node 클러스터가 아직 살아서 `main`을 auto-sync 중이라면, 현재 변경을 push 하는 순간:

- Harbor가 새 노드 호스트(`harbor.158.179.169.201.nip.io`)로 ingress를 갱신 → 구 노드에서는 외부 접속이 깨짐
- Postgres가 `latest`(PG 18.x)로 초기화된 기존 data 디렉토리에 PG 17.6 이미지로 기동 시도 → CrashLoop
- 공용 Redis 앱이 prune됨

→ **push는 구 클러스터 해체(또는 auto-sync 중지) 이후, 재구축 시점에** 할 것. 재구축은 빈 PVC에서 시작하므로 새 클러스터에는 문제없음.

## 다음 작업 — 우선순위 순

### 작업 0: 클러스터 재구축 (선행 필수)

`docs/cluster-rebuild-runbook.md` 실행. Phase 0(노드 발급)·Phase 4(`<NODE_IP>` 치환)는 완료. 남은 절차: k3s 설치 → ArgoCD → 새 시크릿 reseal → Root App. 완료 판정은 런북의 "검증 체크리스트". 완료 후 ArgoCD 앱 트리/Grafana 스크린샷을 README에 추가하면 포폴 증거가 완성됨.

### 작업 1: Alertmanager receiver 연결

`docs/platform-alerting-todo.md` — v1 rule은 작성 완료. 채널(Email/Slack 등) 확정 → receiver/route 설정 → firing 검증.

### 작업 2: Harbor 외부 push/pull 최종 검증

`docs/harbor-push-pull-checklist.md` (호스트는 실제 IP로 치환 완료 — 클러스터 기동 후 진행)

### 작업 3: 백업 스크립트화

`docs/platform-backup-restore-runbook.md` — 수동 절차 스크립트화 + 반출 리허설.

### 작업 4: Keycloak 도메인/TLS 확정 시

- `helm-values/iam/keycloak-values-prod.yaml` TODO 값 채우기, cert-manager issuer 연결
- Harbor/Grafana SSO client 설정 — "IAM을 배포했다"에서 "IAM으로 통합했다"로 스토리를 닫는 마지막 마일
- 참고: keycloak values는 `metrics.enabled: false` — SSO/운영 단계에서 metrics + ServiceMonitor 활성화 검토

### 장기: AI 모델 시뮬레이터 플랫폼

ADR-0001 — MLflow + MinIO, 별도 레포로 분리. 미착수.

## 주요 파일 맵

```
CLAUDE.md                          ← 이 파일 (세션 컨텍스트)
README.md                          ← 포폴 입구: 목적, ADR 하이라이트, 다이어그램, 구조, 로드맵
.github/workflows/validate.yaml    ← CI 검증 게이트
docs/
  cluster-rebuild-runbook.md      ← 재구축 절차 (작업 0)
  adr/0001-ai-model-simulator-platform.md
  adr/0002-single-node-cluster-topology.md
  adr/0003-remove-shared-redis.md
  adr/0004-refit-platform-for-12gb-free-tier.md
  adr/0005-iac-layering-and-repo-strategy.md  ← (제안됨) IaC 3레이어 + 모노레포 전략
  cluster-access-kubeconfig.md    ← SSH 터널 접근 가이드 (노드 158.179.169.201 기준)
  platform-alerting-todo.md       ← receiver 연결 TODO (rule은 완료)
  platform-observability-checklist.md
  platform-backup-restore-runbook.md
  keycloak-operations.md / keycloak-rbac-plan.md / keycloak-manual-rbac-checklist.md
  harbor-push-pull-checklist.md
apps/                              ← ArgoCD Application 10개 + AppProject 1개 (root 자동 동기화, 상시)
apps-ondemand/                     ← on-demand Application (loki, alloy — ADR-0004)
helm-values/                       ← 컴포넌트별 Helm values (트레이드오프 주석 포함)
manifests/                         ← 네임스페이스, SealedSecret, 스토리지, PrometheusRule
bootstrap/platform-root-infra.yaml ← 최초 부트스트랩 진입점
```

## 참고: 구 클러스터 해체 시 함께 정리할 것

- OCI 구 인스턴스 2개 삭제 (런북 Phase 0)
- 구 클러스터용 SSH 키들을 OCI `authorized_keys`와 로컬에서 정리 — 새 클러스터는 포트 22 + `~/.ssh/id_rsa` 기준
- ~~새 노드 IP 확정 후 레포 전체 `<NODE_IP>` 일괄 치환~~ → 완료 (158.179.169.201, 런북 Phase 4)

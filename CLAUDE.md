# CLAUDE.md — gitops-infra 세션 컨텍스트

이 파일은 Claude Code 세션 간 컨텍스트를 이어받기 위한 작업 메모입니다.

## 프로젝트 개요

OCI Always Free 단일 노드 k3s에 플랫폼 공용 인프라를 ArgoCD App of Apps로 배포·운영하는 **개인 포트폴리오 GitOps 레포**입니다. 전체 구조·컴포넌트·로드맵은 `README.md`가 단일 기준입니다.

- **원격**: `origin` → `git@github.com:yhsk9200/gitops-infra.git` (단일 원격)
- 포폴 핵심 가치: 제약(무료 티어·단일 노드·단독 운영) 하의 트레이드오프 기록 (ADR 0001~0006)
- **자원 전제**: 설계는 worst-case **2 OCPU / 12GB**(ADR-0004) 기준. 실제 발급 노드는 grandfather로 **4 OCPU / 24GB 실측**(2026-07-02) — Oracle 정책 불확실성 때문에 re-fatten은 정책 확정까지 보류하기로 결정. 어느 shape가 와도 같은 레포로 재배포 가능

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
- **main 머지 = 즉시 배포** (새 클러스터가 auto-sync 중, 2026-07-02부터). 구 클러스터 push 인터록은 해제됨.

### 3. CI 진화

- 현행: kubeconform + helm template 7종 (`apps/` `apps-ondemand/` `bootstrap/` `manifests/` — Harbor 렌더는 ADR-0006으로 제거).
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

## 현재 상태 (2026-07-02) — ✅ 재구축 완료, 클러스터 그린

| 항목 | 상태 |
|---|---|
| 클러스터 | **가동 중** — 노드 `144.24.81.104`(reserved public IP, 2026-07-03 전환. 구 IP `158.179.169.201`은 release됨) (4 OCPU/24GB arm64, k3s v1.32.13), ArgoCD v3.4.4, **앱 10/10 Synced/Healthy**, Prometheus 타깃 13 up/0 down, 상시 메모리 ~4Gi |
| 도메인 | `aporiax.duckdns.org` → `144.24.81.104` (2026-07-03 연결, PSL 등재라 Let's Encrypt 발급 가능). OCI Security List 80/443 인바운드 개방 완료 — 노드 iptables는 별도 수정 불필요(k8s hostPort 트래픽은 FORWARD 체인을 타서 INPUT REJECT 룰 영향 밖) |
| 토폴로지 | **단일 노드** (ADR-0002), 설계 전제는 2/12 worst-case (ADR-0004) — 실측 4/24, re-fatten은 Oracle 정책 확정까지 보류 |
| 자원 리핏 | ADR-0004: Prometheus retention 5d·limit 1Gi, **로그(Loki/Alloy)는 `apps-ondemand/` on-demand** |
| Harbor | **제거됨** (ADR-0006) — goharbor 공식 이미지가 amd64 전용이라 arm64 노드에서 기동 불가 + 실수요 부재. 레지스트리는 GHCR, self-hosted 필요 시 zot on-demand 재검토 |
| SealedSecret | 2026-07-02 새 키로 **reseal 완료** (4파일: postgres/keycloak-db/keycloak-admin/grafana). postgres-db-secret의 `harbor-password`는 고아 키(다음 reseal 때 제거). **reseal 평문은 비밀번호 관리자 이관 확인 후 로컬 임시본 삭제할 것** |
| Bitnami | 차트 `registry-1.docker.io/bitnamicharts` (**스킴 없는 repoURL — `oci://`는 ArgoCD 3.x에서 401**, 런북 3.2 주의), 이미지 `bitnamilegacy` 핀 (postgres `17.6.0`, keycloak `26.3.3`, os-shell `12-debian-12-r51` — 전부 arm64 확인됨). sealed-secrets 차트는 `bitnami.github.io/sealed-secrets`(구 bitnami-labs 호스트는 404) |
| 공용 Redis | 제거됨 (ADR-0003) — 이후 Harbor 자체도 ADR-0006으로 제거 |
| Alerting | v1 PrometheusRule 가동 중 (`platform-monitoring-rules`, wave 5) — receiver는 채널 확정 후 |
| CI | `validate.yaml` — kubeconform + helm template 7종. PR #1~#4 전부 CI 통과 후 머지 |
| gh CLI | 설치됨, **미인증** — PR 생성/머지는 GitHub 웹(폰 가능)으로. `gh auth login`은 브라우저 필요 |

## 다음 작업 — 우선순위 순

### 작업 0 잔여: 재구축 마무리 (수동 2건)

재구축 자체는 완료(검증 체크리스트 통과, 2026-07-02). 남은 것:
- Grafana 실제 로그인 확인 (reseal 새 비밀번호) + Loki on-demand 선택 테스트
- ArgoCD 앱 트리/Grafana **스크린샷을 README에 추가** — 포폴 증거 완성

### 작업 1: Alertmanager receiver 연결

`docs/platform-alerting-todo.md` — v1 rule은 가동 중. 채널(Email/Slack 등) 확정 → receiver/route 설정 → firing 검증.

### 작업 2: 백업 런북 전면 개정 + 스크립트화

`docs/platform-backup-restore-runbook.md` — Harbor 제거(ADR-0006)로 문서 상단에 무효 표기된 상태. 백업 대상을 postgres(keycloak_db)·SealedSecret 원본·컨트롤러 키 기준으로 재정의 → 스크립트화 + 반출 리허설.

### 작업 3: 도메인/TLS → Grafana SSO

- ✅ OCI reserved IP 전환 완료 (`144.24.81.104`), ✅ DuckDNS `aporiax.duckdns.org` 연결 완료, ✅ OCI Security List 80/443 개방 완료 (2026-07-03)
- ✅ cert-manager ClusterIssuer(`letsencrypt-prod`, HTTP-01, Traefik) 추가, ✅ Grafana ingress 활성화(`aporiax.duckdns.org`) — 이번 PR
- 잔여: Keycloak을 dev → prod values 전환 (`helm-values/iam/keycloak-values-prod.yaml` TODO 값 채우기 — hostname/cluster-issuer는 이제 확정값 있음, 나머지는 redirect URI 등 검토 필요)
- Grafana SSO client 설정 — "IAM을 배포했다"에서 "IAM으로 통합했다"로 스토리를 닫는 마지막 마일
- 참고: keycloak values는 `metrics.enabled: false` — SSO/운영 단계에서 metrics + ServiceMonitor 활성화 검토
- 참고: Keycloak을 노출하려면 DuckDNS에 별도 서브도메인 추가 등록 필요 (같은 계정에서 도메인 여러 개 등록 가능, 예: `auth-aporiax.duckdns.org`) — 같은 도메인 하위 경로(subpath)로 붙이면 redirect URI/cookie path 이슈가 있어 비추천

### 백로그: CI에 arm64 아치 검증 잡

ADR-0006 교훈 — 핀 고정 이미지 전수의 `linux/arm64` manifest 존재를 CI에서 검증 (Docker Hub manifest 조회). Harbor 재발 방지.

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
  adr/0005-iac-layering-and-repo-strategy.md  ← IaC 3레이어 + 모노레포 전략
  adr/0006-remove-harbor-registry-off-cluster.md  ← Harbor 제거 (arm64 제약 + GHCR)
  cluster-access-kubeconfig.md    ← SSH 터널 접근 가이드 (노드 144.24.81.104 기준)
  platform-alerting-todo.md       ← receiver 연결 TODO (rule은 완료)
  platform-observability-checklist.md
  platform-backup-restore-runbook.md  ← ⚠️ Harbor 절차 무효 — 작업 2에서 전면 개정
  keycloak-operations.md / keycloak-rbac-plan.md / keycloak-manual-rbac-checklist.md
apps/                              ← ArgoCD Application 9개 + AppProject 1개 (root 자동 동기화, 상시)
apps-ondemand/                     ← on-demand Application (loki, alloy — ADR-0004)
helm-values/                       ← 컴포넌트별 Helm values (트레이드오프 주석 포함)
manifests/                         ← 네임스페이스, SealedSecret, 스토리지, PrometheusRule
bootstrap/platform-root-infra.yaml ← 최초 부트스트랩 진입점
```

## 참고: 잔여 정리 항목

- ~~OCI 구 인스턴스 2개 삭제~~ → 완료 (런북 Phase 0)
- ~~새 노드 IP 확정 후 레포 전체 `<NODE_IP>` 일괄 치환~~ → 완료 (158.179.169.201, 런북 Phase 4)
- ~~ephemeral → reserved public IP 전환 후 레포 IP 재치환~~ → 완료 (2026-07-03, `144.24.81.104`. ADR-0005/`cluster-rebuild-runbook.md`의 Phase 4 서술은 당시 시점 기록이라 의도적으로 미변경)
- 구 클러스터용 SSH 키들을 OCI `authorized_keys`와 로컬에서 정리 — 새 클러스터는 포트 22 + `~/.ssh/id_rsa` 기준
- postgres 현 PVC 세대의 고아 객체(`harbor_admin` 롤, `harbor_registry` DB) — 무해, 다음 재구축 때 자연 소멸 (ADR-0006 이행 메모)

# CLAUDE.md — gitops-infra 세션 컨텍스트

이 파일은 Claude Code 세션 간 컨텍스트를 이어받기 위한 작업 메모입니다.

## 프로젝트 개요

OCI Always Free 단일 노드 k3s에 플랫폼 공용 인프라를 ArgoCD App of Apps로 배포·운영하는 **개인 포트폴리오 GitOps 레포**입니다. 전체 구조·컴포넌트·로드맵은 `README.md`가 단일 기준입니다.

- **원격**: `origin` → `git@github.com:yhsk9200/gitops-infra.git` (단일 원격)
- 포폴 핵심 가치: 제약(무료 티어·단일 노드·단독 운영) 하의 트레이드오프 기록 (ADR 0001~0006)
- **자원 전제**: 설계는 worst-case **2 OCPU / 12GB**(ADR-0004) 기준. 실제 발급 노드는 grandfather로 **4 OCPU / 24GB 실측**(2026-07-02). **정책 확정됨**(2026-07-10 확인): Oracle이 2026-06-15부로 A1 무료 한도를 2/12로 반토막(무통보, 문서만 변경). 기존 4/24 노드는 회색지대(Always Free 계정 초과분은 향후 중지 가능, 삭제는 아님)이고 **terminate 시 상위 사양 재생성 불가 명시** → re-fatten은 영구 기각, 12GB 리핏 유지가 유일한 안전 설계. 어느 shape가 와도 같은 레포로 재배포 가능

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

## 현재 상태 (2026-07-05) — ✅ 재구축 완료, 클러스터 그린

| 항목 | 상태 |
|---|---|
| 클러스터 | **가동 중** — 노드 `144.24.81.104`(reserved public IP, 2026-07-03 전환. 구 IP `158.179.169.201`은 release됨) (4 OCPU/24GB arm64, k3s v1.32.13), ArgoCD v3.4.4, **앱 14/14 Synced/Healthy**(2026-07-09 실측), 상시 메모리 ~4.4Gi/24Gi(18%) |
| Grafana 배포 전략 | **Recreate + initChownData 비활성** (PR #7~#11, 2026-07-05 인시던트): ① init-chown-data가 root여도 capabilities drop ALL이라 Grafana 자신이 만든 0700 디렉토리(png/pdf/csv)를 순회 못해 2번째 롤아웃부터 전부 교착 → init 비활성. ② RWO PVC+SQLite라 Recreate 전환 — 단 전이가 SSA(null 무시)·CSA(last-applied 부재) 모두로 불가, 1회성 `Replace=true`로 전이 후 SSA 복귀. ③ admission webhook TLS는 hook Job이 ArgoCD 훅 엔진과 교착해 **cert-manager 발급으로 전환** (`certManager.enabled: true`) |
| HTTP 리다이렉트 | **전역 HTTPS 강제** (PR #12~#13): k3s 번들 Traefik을 GitOps 관리 `HelmChartConfig`(`manifests/traefik/`)로 오버라이드. 주의: 차트 39.x 스키마는 `ports.web.http.redirections`(http 단계 누락 시 조용히 무시됨). 실측(2026-07-09)은 `308 Permanent Redirect`(Traefik 기본값 — 문서상 "301"은 표현일 뿐 기능은 동일) |
| 도메인 | `aporiax.duckdns.org`(Grafana)·`aporiax-auth.duckdns.org`(Keycloak) → `144.24.81.104` (PSL 등재라 Let's Encrypt 발급 가능). OCI Security List 80/443 인바운드 개방 완료 — 노드 iptables는 별도 수정 불필요(k8s hostPort 트래픽은 FORWARD 체인을 타서 INPUT REJECT 룰 영향 밖) |
| 외부 노출 | Grafana `https://aporiax.duckdns.org` (LE 인증서 확인 2026-07-03), Keycloak `https://aporiax-auth.duckdns.org` (prod values 전환). ArgoCD/Prometheus/Alertmanager는 **의도적 비노출** — SSH 터널 전용 |
| 토폴로지 | **단일 노드** (ADR-0002), 설계 전제는 2/12 worst-case (ADR-0004) — 실측 4/24, re-fatten은 Oracle 정책 확정까지 보류 |
| 자원 리핏 | ADR-0004: Prometheus retention 5d·limit 1Gi, **로그(Loki/Alloy)는 `apps-ondemand/` on-demand** |
| Harbor | **제거됨** (ADR-0006) — goharbor 공식 이미지가 amd64 전용이라 arm64 노드에서 기동 불가 + 실수요 부재. 레지스트리는 GHCR, self-hosted 필요 시 zot on-demand 재검토 |
| SealedSecret | 2026-07-02 새 키로 **reseal 완료** (4파일: postgres/keycloak-db/keycloak-admin/grafana). postgres-db-secret의 `harbor-password`는 고아 키(다음 reseal 때 제거). **reseal 평문은 비밀번호 관리자 이관 확인 후 로컬 임시본 삭제할 것** |
| Bitnami | 차트 `registry-1.docker.io/bitnamicharts` (**스킴 없는 repoURL — `oci://`는 ArgoCD 3.x에서 401**, 런북 3.2 주의), 이미지 `bitnamilegacy` 핀 (postgres `17.6.0`, keycloak `26.3.3`, os-shell `12-debian-12-r51` — 전부 arm64 확인됨). sealed-secrets 차트는 `bitnami.github.io/sealed-secrets`(구 bitnami-labs 호스트는 404) |
| 공용 Redis | 제거됨 (ADR-0003) — 이후 Harbor 자체도 ADR-0006으로 제거 |
| Alerting | v1 PrometheusRule 가동 중 (`platform-monitoring-rules`, wave 5) + **Alertmanager receiver 연결 완료** (2026-07-09, PR #23): 채널 Telegram, 봇 토큰은 SealedSecret(`alertmanager-telegram-token`)으로 격리. synthetic alert로 firing/resolved 메시지 모두 실 수신 확인. Watchdog은 계속 `null` 라우팅(영구 firing이라 텔레그램 노이즈 방지) |
| CI | `validate.yaml` — kubeconform + helm template 7종 + **arm64 manifest 가드**(핀 이미지 3종 `docker buildx imagetools inspect`, ADR-0006 재발 방지). **브랜치 보호 설정 완료** (2026-07-07): main은 PR 필수 + required status checks 3종(`kubeconform (raw manifests)`·`helm template (pinned charts x values)`·`arm64 manifest (pinned images)`) + admin 우회 불가 + force-push/삭제 금지. required 데드락 방지를 위해 `pull_request` paths 필터 제거 → 모든 PR에서 validate 실행. pulse 레포도 동일 보호(required: `lint-typecheck-build`·`validate-manifests`) |
| gh CLI | **인증 완료** (2026-07-03, yhsk9200) — PR 생성·CI 확인·머지까지 CLI로 가능 (`gh pr create` → `gh pr checks --watch` → `gh pr merge --squash --delete-branch`) |

## 다음 작업 — 우선순위 순

### 작업 0 잔여: 재구축 마무리 (수동 2건)

재구축 자체는 완료(검증 체크리스트 통과, 2026-07-02). 남은 것:
- Grafana 실제 로그인 확인 (reseal 새 비밀번호) + Loki on-demand 선택 테스트
- ArgoCD 앱 트리/Grafana **스크린샷을 README에 추가** — 포폴 증거 완성

### 작업 1: Alertmanager receiver 연결 — ✅ 완료 (2026-07-09)

`docs/platform-alerting-todo.md` — 채널은 Telegram으로 확정(1인 운영에서 폰 푸시가 가장 빠르고, 봇 토큰 하나만 격리하면 되어 Email/Slack보다 설정 표면이 작음). 봇 토큰은 SealedSecret(`manifests/security/alertmanager-telegram-sealed-secret.yaml`)으로 격리해 `alertmanagerSpec.secrets`로 마운트, `chat_id`는 토큰 없이는 무의미해 git 평문(PR #23). Helm이 values를 맵 단위로 병합하는 걸 로컬 `helm template`으로 실측 확인해 `route`/`receivers`만 지정하고 차트 기본 `inhibit_rules`(critical→warning/info 억제)는 그대로 살렸다. Watchdog(상시 firing 메타 알림)은 텔레그램 노이즈 방지를 위해 계속 `null` 라우팅. 머지 후 synthetic alert(`TelegramWireTest`)로 firing/resolved 메시지 실 수신까지 검증 완료 — v1 룰 6종은 아직 전부 inactive(정상)라 노이즈 조정은 실제 firing 데이터가 쌓이면 진행.

### 작업 2: 백업 런북 전면 개정 + 스크립트화 — 문서·스크립트 ✅ 완료 (2026-07-07), 리허설 잔여

`docs/platform-backup-restore-runbook.md` 전면 재작성(PR #21) — Harbor 절차 전량 삭제, 구 IP 제거. **핵심 판단**: Harbor 제거로 재구성 불가능한 stateful 자산은 `keycloak_db` 하나로 좁혀짐(GitOps·SealedSecret=GitHub, 평문=비번관리자 reseal 경로, product-pulse=무상태). 컨트롤러 키는 최고위험 파일이라 루틴 백업에서 빼 **옵션·암호화·수동** 단계로 격리(원본보다 나은 노출 표면). 루틴은 `scripts/platform-backup.sh`로 스크립트화(keycloak_db dump→pg_restore --list 검증→GitOps commit→manifest→checksum→retention, 클러스터 read-only, bash -n 통과). **잔여(수동/SSH)**: k3s 서버에서 스크립트 실행 + 임시 DB로 pg_restore 리허설("복구 테스트 안 한 백업은 신뢰 불가") + NAS 반출 리허설.

### 작업 3: 도메인/TLS → Grafana SSO — ✅ 배포 완료 (2026-07-06)

- ✅ 도메인/TLS 인프라 (2026-07-03, PR #5), ✅ Keycloak prod 전환 (PR #6)
- ✅ Keycloak `platform` realm 구성 (2026-07-06, 파드 내 kcadm 멱등 스크립트): role 4종·group 3종·client `grafana`(PKCE, direct grant 비활성)·realm-roles mapper·테스트 사용자 3명 — `keycloak-rbac-plan.md` 수동 변경 기록 참조
- ✅ SealedSecret `grafana-oidc-secret` + Grafana `auth.generic_oauth`(role_attribute_path로 platform-admin→Admin, operator→Editor, 기타→Viewer) — PR B
- **잔여 (수동 1건)**: 브라우저에서 `platform-admin-test`로 SSO 로그인 실측 (임시 비밀번호는 로컬 `~/.keycloak-sso-20260706.txt`, 첫 로그인 시 변경 강제. **비밀번호 관리자 이관 후 파일 삭제**)
- 참고: keycloak values는 `metrics.enabled: false` — 운영 안정화 후 metrics + ServiceMonitor 활성화 검토

### ~~백로그: CI에 arm64 아치 검증 잡~~ → ✅ 완료 (2026-07-07)

ADR-0006 교훈 코드화. `validate.yaml`에 `arm64-manifest` 잡 추가: 우리가 helm-values에서 명시적으로 핀한 이미지 3종(`bitnamilegacy/keycloak`·`postgresql`·`os-shell`)을 `docker buildx imagetools inspect`로 조회해 `linux/arm64` manifest 부재 시 빌드 실패. 차트 기본 이미지는 범위 밖(우리 핀만 대상). required 체크로 승격 — advisory면 arm64 없는 핀을 빨간 X 무시하고 머지 가능해 가드 목적이 무력화되고, Docker Hub는 이미 `helm template` 잡의 필수 의존성이라 flakiness 증분이 한계적이기 때문. 첫 실행에서 3종 전부 amd64+arm64 멀티아치 확인.

### ~~백로그: main 브랜치 보호~~ → ✅ 완료 (2026-07-07)

PR #8에서 CI 체크 등록 전 `gh pr merge` 통과 갭을 실증했던 "전략의 마지막 구멍"을 닫음. 두 레포(gitops-infra·aporiax-pulse) main에 브랜치 보호 적용: PR 필수(승인 0 — 단독 운영이라 셀프 승인 불가로 데드락 방지) + required status checks + `enforce_admins`(소유자도 우회 불가) + force-push/삭제 금지. GitHub "required + paths 필터" 데드락을 피하려 `validate.yaml`의 `pull_request` paths 필터 제거(docs/ADR/CLAUDE.md-only PR도 이제 검증됨).

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
  platform-alerting-todo.md       ← rule + receiver 연결 완료 (Telegram), 남은 건 노이즈 조정
  platform-observability-checklist.md
  platform-backup-restore-runbook.md  ← 전면 개정 완료 (keycloak_db 중심, scripts/platform-backup.sh)
  keycloak-operations.md / keycloak-rbac-plan.md / keycloak-manual-rbac-checklist.md
apps/                              ← ArgoCD Application 13개 + AppProject 2개 (platform-infra + product-pulse 테넌트, root 자동 동기화, 상시)
apps-ondemand/                     ← on-demand Application (loki, alloy — ADR-0004)
helm-values/                       ← 컴포넌트별 Helm values (트레이드오프 주석 포함)
manifests/                         ← 네임스페이스, SealedSecret, 스토리지, PrometheusRule, ClusterIssuer, Traefik HelmChartConfig
scripts/                           ← 운영 스크립트 (platform-backup.sh — keycloak_db 루틴 백업, 클러스터 read-only)
bootstrap/platform-root-infra.yaml ← 최초 부트스트랩 진입점
```

## 참고: 잔여 정리 항목

- ~~OCI 구 인스턴스 2개 삭제~~ → 완료 (런북 Phase 0)
- ~~새 노드 IP 확정 후 레포 전체 `<NODE_IP>` 일괄 치환~~ → 완료 (158.179.169.201, 런북 Phase 4)
- ~~ephemeral → reserved public IP 전환 후 레포 IP 재치환~~ → 완료 (2026-07-03, `144.24.81.104`. ADR-0005/`cluster-rebuild-runbook.md`의 Phase 4 서술은 당시 시점 기록이라 의도적으로 미변경)
- 구 클러스터용 SSH 키들을 OCI `authorized_keys`와 로컬에서 정리 — 새 클러스터는 포트 22 + `~/.ssh/id_rsa` 기준
- postgres 현 PVC 세대의 고아 객체(`harbor_admin` 롤, `harbor_registry` DB) — 무해, 다음 재구축 때 자연 소멸 (ADR-0006 이행 메모)

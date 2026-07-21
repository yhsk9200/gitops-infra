# ADR-0008: AI 시뮬레이터 → MLOps 플랫폼 피봇

## 상태

승인됨 — **ADR-0001을 대체**

## 날짜

2026-07-10

## 맥락

ADR-0001(2026-05-03)은 "AI 모델 시뮬레이터"(모델을 소비하는 검증 UI/Backend 제품)를 별도 App-of-Apps 레포로 계획했다. 두 달 사이 그 전제가 대부분 바뀌었다:

- **레포 전략이 정식화됨** — ADR-0005(플랫폼 모노레포 + 제품 단위 분리)와 ADR-0007(첫 테넌트 온보딩으로 경계 패턴 실증). ADR-0001의 "AI 영역 전체를 별도 App-of-Apps 레포로"는 이 원칙들보다 앞서 쓰인 권고다.
- **arm64 제약이 실증됨** — ADR-0006(Harbor 제거). 컴포넌트 선정 전 arm64 manifest 검증이 의무가 됐고 CI 가드로 코드화됐다.
- **자원 전제가 확정됨** — Oracle이 2026-06-15부로 A1 무료 한도를 2 OCPU/12GB로 무통보 반토막(PR #25 기록). ADR-0004의 12GB worst-case 설계가 공식 한도가 됐고, 동시에 **무료 티어 정책은 언제든 무통보 축소될 수 있음이 실증**됐다.
- **보유 하드웨어가 반영 안 돼 있었음** — 운영자가 Synology DS920+(amd64 J4125, RAM ~20GB, Docker 가능)를 보유. 백업 런북의 반출 대상이기도 한 이 NAS가 ADR-0001의 스토리지 판단에 빠져 있었다.
- **설계 목적 재평가** — 시뮬레이터는 "모델을 소비하는 제품" 하나에 그치지만, MLOps는 학습→추적→등록→승격→서빙→모니터링→재학습 루프가 이 레포가 이미 구축한 자산(GitOps 파이프라인, Keycloak IAM, Prometheus/Grafana 관측, Telegram 알림, 백업 규율)을 **전부 소비**한다. 도구 나열이 아니라 "플랫폼 위에 플랫폼을 얹는 판단"으로 방향을 잡는다.

## 검토한 대안

### 방향: 시뮬레이터 유지 vs MLOps 피봇

| 대안 | 기각/채택 사유 |
|---|---|
| 시뮬레이터 유지 (ADR-0001) | UI/Backend 제품 하나가 산출물의 중심 — 프론트 역량 증명은 aporiax-pulse가 이미 수행 중이라 중복. 검증(validation) 역할은 파이프라인 단계 + MLflow tag로 흡수 가능 |
| MLOps 피봇 (채택) | 라이프사이클 루프 자체가 산출물 — 기존 플랫폼 자산 전부를 소비자로 연결. 신규 상시 컴포넌트는 최소(아래 자원 예산) |

### 레포 경계

| 대안 | 기각/채택 사유 |
|---|---|
| AI 영역 전체를 별도 App-of-Apps 레포로 (ADR-0001 원안) | 1인 운영·단일 클러스터에서 두 번째 App-of-Apps 레포는 인지비용만 추가(ADR-0005 논리). ADR-0007이 기각한 중첩 App-of-Apps 구조를 되살리는 방향이기도 함 |
| 전부 이 레포에 | 학습/서빙 코드는 수명주기·소유권이 플랫폼과 다름 — ADR-0005의 "경계는 제품 단위" 원칙 위반 |
| **공용 서비스는 이 레포, ML 제품은 테넌트 레포 (채택)** | MLflow는 Keycloak·Postgres와 같은 멀티테넌트 공용 서비스 → `platform-mlops-*` 앱. 학습/서빙은 pulse와 같은 제품 테넌트(ADR-0007 경계 패턴 재사용). 실조직의 "ML 플랫폼팀 vs ML 제품팀" 경계를 재현 |

### 아티팩트 스토어

| 대안 | 기각/채택 사유 |
|---|---|
| MinIO를 클러스터에 (ADR-0001 원안) | 상시 ~0.5Gi — 12GB 확정 예산에서 유의미. 아티팩트가 노드 로컬 디스크에 놓여 DB와 **동일 장애 도메인**(단일 노드 유실 = 데이터+아티팩트 동시 유실) |
| OCI Object Storage | Always Free 20GB + 월 5만 API 요청, 이번 축소에서 무변경(2026-07-10 공식 문서 확인). 그러나 2026-06-15 무통보 반토막 전례로 **무료 티어의 정책 내구성 신뢰가 하락** — 스토리지에 상태를 맡기는 결정의 근거로 삼기 약함. 오프사이트 사본 후보로만 보류 |
| **MinIO on DS920+ via Tailscale (채택)** | 노드 자원 0, 정책 리스크 0(보유 하드웨어), 백업 반출 대상과 동일 위치. NAS는 amd64라 arm64 제약 무관. **조건: MinIO는 tailnet에만 바인딩, 공인 인터넷 노출 금지.** WAN/집 회선 의존이 약점이나, 승격 모델(아래)이 서빙을 아티팩트 스토어에서 런타임 디커플링해 영향 범위를 학습 시점으로 격리 |

### 모델 승격(배포) 경로

| 대안 | 기각/채택 사유 |
|---|---|
| 서빙 파드가 champion alias를 런타임 pull | 배포 상태가 git 밖으로 나감 — "main = 배포" 불변식 위반, 롤백 경로가 git과 레지스트리로 이원화, ArgoCD가 드리프트를 볼 수 없음 |
| **이미지 베이킹 PR (채택)** | 승격 시 CI가 champion 아티팩트를 서빙 이미지에 베이킹 → GHCR(digest 핀) → 태그 범프 PR → 기존 브랜치 보호·CI 3종·ArgoCD 경로. **모델 배포가 코드 배포와 동일한 감사·롤백 경로**를 가짐. 부수 효과: 서빙이 런타임에 아티팩트 스토어를 보지 않음 → NAS 장애 시 학습 run 업로드(재시도 가능)와 MLflow UI 조회만 영향, 서비스 중인 모델 무관 |

### 오케스트레이션

| 대안 | 기각/채택 사유 |
|---|---|
| Kubeflow | ADR-0001의 보류 판단 유지 — 12GB 확정으로 더 강화. 도입 조건도 ADR-0001 것을 승계 |
| Argo Workflows | 보류 — 단계별 재시도·병렬 DAG·단계 간 아티팩트 전달이 **실수요**로 등장하면 도입 (GitOps 정합성은 좋음) |
| **k8s CronJob (채택, v1)** | 추출→학습→검증→등록을 단일 컨테이너 순차 실행으로 시작 — 소비자 없는 오케스트레이터를 먼저 들이지 않는다(ADR-0003/0006/0007과 동일 원칙) |

### MLflow UI 노출

| 대안 | 기각/채택 사유 |
|---|---|
| oauth2-proxy + Keycloak으로 외부 노출 | 소비자가 운영자 1인뿐인 시점에 인증 프록시 상시 컴포넌트를 추가할 근거 없음 |
| **비노출 — 터널/tailnet 전용 (채택)** | ArgoCD/Prometheus/Alertmanager와 동일 원칙(컨트롤 플레인성 UI 비노출). 외부 노출이 필요해지는 시점에 oauth2-proxy(v7.13.0 arm64 확인됨) + Keycloak client 추가로 전환 |

## 결정

1. **ADR-0001을 대체한다.** 시뮬레이터 UI/Backend는 만들지 않는다 — 검증 역할은 학습 파이프라인의 validation 단계 + MLflow tag(`validation_status` 등, ADR-0001의 tag 모델 승계)로 흡수.
2. **공용 서비스** (이 레포, `platform-mlops` 네임스페이스, `platform-mlops-*` 명명):
   - MLflow (tracking + model registry) — backend store는 기존 `platform-db` PostgreSQL에 `mlflow_db` 추가. **백업 런북·스크립트의 대상 확장 필수** (keycloak_db 단독 전제가 깨짐).
   - artifact store는 MinIO@NAS. 접근은 **MLflow proxied artifacts**(`--serve-artifacts`)로 수렴 — S3 자격증명을 MLflow 서버 하나로 격리, 학습 잡은 NAS 직접 접근 불필요.
   - UI는 비노출(터널/tailnet 전용).
3. **ML 제품**: 별도 테넌트 레포(ADR-0007 경계 그대로 — 전용 AppProject·네임스페이스·평면 리프). 첫 유스케이스는 **클러스터 자기 텔레메트리 예측/이상탐지** — Prometheus에 이미 흐르는 데이터, CPU-only 학습, Grafana 예측-실측 대시보드, 드리프트 알림은 기존 Telegram 라인.
4. **승격 = 이미지 베이킹 PR** (digest 핀, 기존 CI·브랜치 보호 게이트 통과).
5. **Tailscale 도입**: 노드+NAS를 tailnet에 편입. 부수 효과로 kubeconfig 접근을 방식 B(SSH 터널)에서 방식 C(tailnet)로 승격(`cluster-access-kubeconfig.md`의 예정 경로).
6. **자원 예산**: 상시 증가 +0.7Gi 이내(MLflow ~0.4Gi + 서빙 ~0.3Gi), 학습은 burst 전용(CronJob limit으로 상한). 12GB 기준 상시 ~5.2Gi 유지.
7. **arm64 검증 기록** (2026-07-10, `docker buildx imagetools inspect`): `ghcr.io/mlflow/mlflow:v3.6.0` ✓ arm64, `quay.io/oauth2-proxy/oauth2-proxy:v7.13.0` ✓ arm64(도입 시점 대비 선검증), MinIO ✓(NAS amd64라 무관하나 확인). 핀 확정 시 CI arm64 가드에 추가.

## 근거

- **자산 소비의 완결성**: GitOps(승격 PR)·IAM(노출 시 Keycloak)·관측(ServiceMonitor+Grafana)·알림(드리프트→Telegram)·백업(mlflow_db 확장)·테넌트 경계(ADR-0007) — 기존 투자 전부가 MLOps 루프의 소비자가 된다.
- **절제**: 신규 상시 컴포넌트는 MLflow 하나(+서빙 파드). 오케스트레이터·인증 프록시·셀프호스팅 스토리지는 전부 "실수요 등장 시" 조건부로 연기 — ADR-0003/0006/0007의 "소비자 없는 컴포넌트를 먼저 만들지 않는다" 원칙 일관.
- **리스크 격리**: 유일한 신규 외부 의존(NAS)은 이미지 베이킹 설계로 학습 시점에만 영향. 무료 티어 정책 변동(실증됨)은 보유 하드웨어로 회피.

## 비목표 / 미해결

- 모델 알고리즘·피처 설계, 재학습 트리거 기준(스케줄 vs 드리프트) — 제품 레포 몫
- NAS MinIO 상세 구성(버킷 정책, 버전닝, 디스크 배치), tailnet ACL 설계 — Phase A에서 확정
- 제품 레포 이름
- 구현 메모: 공식 MLflow 이미지에 PostgreSQL 드라이버(psycopg2) 부재 시 커스텀 이미지를 GHCR로 베이킹(pulse와 동일한 buildx 멀티아치 경로)

## 단계

- **Phase A (사전, 수동 포함)**: Tailscale tailnet에 노드+NAS 편입 → NAS에 MinIO 기동·버킷 생성 → 클러스터에서 tailnet 경유 S3 접근 실측. kubeconfig 방식 C 전환 동반.
- **Phase B**: `platform-mlops` 공용 서비스 — MLflow 배포(mlflow_db·SealedSecret·proxied artifacts), 백업 스크립트/런북 확장.
- **Phase C**: 제품 테넌트 레포 온보딩(ADR-0007 패턴) + 학습 CronJob → 첫 모델 등록.
- **Phase D**: 서빙 + 이미지 베이킹 승격 플로우 + ServiceMonitor + Grafana 예측-실측 대시보드.
- **Phase E**: 드리프트/staleness PrometheusRule → Telegram, 재학습 자동화. Argo Workflows는 도입 조건 발동 시.

## 재검토 조건

- NAS(집 회선) 가용성이 학습 파이프라인 실패의 반복 원인이 되면 — OCI Object Storage 병행(오프사이트 사본) 또는 이중화 재검토.
- 파이프라인이 다단계 DAG·단계별 재시도를 실수요로 요구하면 — Argo Workflows 도입.
- GPU·분산 학습·두 번째 ML 제품 등장 — Kubeflow 부분 도입 재평가(ADR-0001 기준 승계).

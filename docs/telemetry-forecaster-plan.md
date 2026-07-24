# Telemetry Forecaster — MLOps 제품 테넌트 계획 (ADR-0008 Phase C/D)

> 상태: **계획 확정 (2026-07-21)**. 레포=`aporiax-forecast`, ADR-0010 신규, 드리프트 룰=gitops-infra 소유. C1부터 실행 가능.
> 근거: [ADR-0008](adr/0008-mlops-platform-pivot.md)(MLOps 피봇·이미지 베이킹 승격)·[ADR-0007](adr/0007-first-product-tenant-onboarding.md)(테넌트 경계 패턴).

---

## 개념 요약 (빠르게 이해하기)

### 한 문장
클러스터가 **스스로 자기 상태(메모리·CPU 등)를 예측하는 작은 모델**을 만들고, 그 모델을 **일반 코드와 똑같은 방식으로 안전하게 배포·교체·롤백**한다.

### 핵심 아이디어 (비유)
목표는 *모델을 바꾸는 일을 위험하지 않게* 만드는 것이다. 식당 레시피(=모델)를 주방에서 즉흥으로 바꾸면(=실행 중 교체) 뭐가 바뀌었는지 이력이 없고 되돌리기 어렵다. 대신 **"변경 신청서(=PR)"를 쓰고 승인받아 바꾸면** 이력이 남고 언제든 이전 버전으로 되돌아갈 수 있다. 이 프로젝트는 모델 배포를 후자 방식으로 한다 — 그래서 **모델 롤백이 `git revert` 한 줄**이 된다.

### 용어 사전
| 용어 | 뜻 | 왜 필요한가 |
|---|---|---|
| **서빙**(serving) | 모델을 "질문하면 답하는" 상태로 띄우기 | 모델을 실제로 쓰려면 |
| **이미지 베이킹** | 모델 파일을 배포 컨테이너에 미리 넣고 봉인 | 실행 중 몰래 안 바뀌게 |
| **승격**(promotion) | 후보 모델 중 "이걸 배포" 결정 | 검증된 모델만 내보내려고 |
| **GitOps / "main=배포"** | Git을 고치면 서버가 자동으로 그대로 반영 | 배포가 자동·기록됨 |
| **MLflow** | 모델의 실험 이력 + 버전 관리 시스템 | 어떤 모델이 얼마나 좋았는지 추적 |
| **레지스트리**(registry) | 모델 저장소 (버전별 보관) | 후보 모델 정리·승격 |
| **테넌트**(tenant) | 플랫폼에 얹혀 도는 독립 제품 | 제품끼리 격리 |
| **AppProject 경계** | 테넌트가 자기 리소스만 건드리게 하는 규칙 | 사고 범위 제한 |
| **CronJob** | 정해진 주기마다 자동 실행되는 작업 | 주기적 재학습 |
| **드리프트**(drift) | 예측이 현실과 점점 어긋남 | 낡은 모델 감지 → 알림 |
| **CI** | 코드 올리면 자동 검사·빌드하는 파이프라인 | PR 통과 게이트 |
| **tailnet / Tailscale** | 내 기기들만 연결되는 사설 VPN망 | 외부 노출 없이 기기끼리 연결 |
| **아티팩트**(artifact) | 학습이 만들어낸 결과물 파일(모델 등) | 저장·배포에 사용 |

---

## 왜 이 설계인가 (설계 근거)

이 저장소의 MLOps 방향(ADR-0008)이 세운 원칙 — "모델 배포가 코드 배포와 똑같은 감사·롤백 경로를 탄다(이미지 베이킹 PR)" — 은 아직 실물로 구현되지 않았다. 지금까지는 실험 추적(MLflow)·평가까지 갖춰졌고, **등록 → 승격 → 서빙 → 모니터링 → 재학습** 루프가 비어 있다. 이 단계가 그 루프를 닫는다:

- **기존 플랫폼 자산을 그대로 재사용한다**: Prometheus(데이터) → 학습 → MLflow(레지스트리) → 승격 PR이 기존 CI·브랜치 보호·ArgoCD를 통과 → 서빙 → Grafana(예측-실측) → 드리프트 시 Telegram. 새 상시 컴포넌트 추가를 최소화하고 이미 있는 것을 소비하는 방향.
- **배포 안전성**: 모델을 이미지에 구워 배포하면 실행 중 아티팩트 저장소를 보지 않아, 저장소(NAS) 장애가 서비스 중인 모델에 영향을 주지 않는다. 롤백은 코드와 동일하게 git으로 수렴한다.
- **제약 정합**: 소형 텔레메트리 모델(수 KB) → 12GB 단일 노드에서 무리 없고, 이미지 베이킹의 모델 크기 한계에도 걸리지 않는다.

## 제품 정의

- **클러스터 자기 텔레메트리 예측**(forecasting). 대상 Prometheus series는 **Phase C2에서 실제 데이터를 보고 확정**한다(패턴이 있는 것 — 후보: 노드 memory working set, CPU 사용률, 파드 수). 데이터가 타깃을 정한다.
- **모델**: scikit-learn 소형 회귀(lag/rolling feature 기반). CPU 학습, 모델 파일 <1MB → 이미지 베이킹에 이상적. 알고리즘 선택은 Phase C2 데이터 확인 후.
- **예측 지평**: 예: 30분 후 값. Grafana에서 예측 series를 실측 series에 겹쳐 보는 게 데모의 핵심.

## 레포 경계 (ADR-0007 패턴 계승)

- **새 제품 테넌트 레포** (이름 미정, 후보 아래). gitops-infra는 AppProject + Application + namespace만 소유하고, 워크로드 매니페스트·학습/서빙 코드는 테넌트 레포가 소유(pulse와 동일).
- **AppProject 화이트리스트 확장** — 이게 web 테넌트와 다른 지점이자 새 판단. pulse는 ServiceAccount/Service/Deployment/Ingress만 허용하는데, ML 테넌트는:
  | kind | 그룹 | 근거 |
  |---|---|---|
  | ServiceAccount | "" | 파드 실행 |
  | Service | "" | 서빙 노출(클러스터 내) |
  | Deployment | apps | 서빙 |
  | CronJob | batch | 학습 스케줄 |
  | Job | batch | CronJob이 생성 |
  | ConfigMap | "" | 학습/서빙 설정 |
  | ServiceMonitor | monitoring.coreos.com | 서빙 메트릭 스크레이프 |
  - **Ingress는 불허**(서빙 비노출 — 소비자가 클러스터 내부뿐, ADR-0008 UI 비노출 원칙 연장).
  - `clusterResourceWhitelist: []` 유지(cluster-scoped 불허). **드리프트 PrometheusRule은 namespaced라 테넌트가 가질 수 있으나**, 알림 라우팅은 플랫폼 관심사 → **gitops-infra의 `manifests/monitoring/rules`에 두는 걸 권장**(결정 필요, 아래).

## 핵심 난제 — CI→tailnet 갭 (ADR-0008 미해결 항목 해소)

**문제**: 승격 시 CI가 champion 모델 아티팩트를 서빙 이미지에 베이킹해야 하는데, GitHub Actions 러너는 **tailnet 밖**이고 MLflow/NAS는 tailnet 전용이라 아티팩트를 못 가져온다. (ADR-0008 리뷰에서 이미 식별한 갭.)

**해소(권장)**: 베이킹 워크플로우에서 `tailscale/github-action`으로 러너를 **ephemeral 노드로 tailnet에 임시 편입** → MLflow NodePort(`100.69.52.25:30500`)에서 champion 모델 pull → 베이킹 → GHCR push → 태그 범프 PR. ephemeral auth key는 GH secret(수동 발급).

**대안(fallback)**: in-cluster bake Job(클러스터 안에서 MLflow 접근·GHCR push·PR 생성). CI가 아니라 클러스터가 베이킹 주체가 되는 셈이라 "CI가 베이킹" 논지에서 살짝 벗어남 → 권장안이 막힐 때만.

## 승격 플로우 (이미지 베이킹 = git 경로)

```
학습 CronJob → MLflow run + model version 등록
  → (사람) champion alias 지정 (MLflow UI/API — 승격 판단)
  → 베이킹 워크플로우(Tailscale-in-CI): champion pull → 서빙 이미지에 모델 베이킹
     → GHCR(digest 핀) → 서빙 Deployment 태그 범프 PR
  → PR: 기존 CI 3종 + 브랜치 보호 통과 → 머지 → ArgoCD 서빙 롤아웃
  → 롤백 = git revert (그게 논지)
```
서빙은 런타임에 MLflow/NAS를 보지 않는다(모델이 이미지에 구워짐) → NAS 장애가 서빙에 무영향(ADR-0008 리스크 격리 설계 실증).

## 단계 (각 단계 검증 게이트)

- **C1 온보딩**: gitops-infra PR(AppProject 확장 + Application + namespace) + 새 테넌트 레포 스캐폴드(README·CLAUDE.md·구조). 게이트: root app이 테넌트 Application을 Synced로 인식(빈 상태라도).
- **C2 학습 파이프라인**: training 이미지(sklearn+mlflow+prometheus-api-client) + CronJob(Prometheus query_range → feature → 학습 → MLflow 등록). 게이트: MLflow 레지스트리에 model version이 metric(MAE/RMSE 등)과 함께.
- **D1 서빙 + 베이킹 승격**: 서빙 앱(FastAPI, baked 모델, `/predict`+`/metrics`) + 베이킹 워크플로우(Tailscale-in-CI). 게이트: champion 지정 → 베이킹 PR → 머지 → 서빙 파드가 baked 모델로 `/predict` 응답(런타임 MLflow 미접근 실측).
- **D2 모니터링 루프**: ServiceMonitor + 예측-실측 Grafana 대시보드 + 드리프트/staleness PrometheusRule → Telegram. 게이트: 대시보드에 예측 vs 실측 겹침, synthetic 드리프트 → Telegram 수신.

## 수동/시크릿 경계 (모델 불문 사용자 직접)

- Tailscale ephemeral auth key 발급 + GH secret 등록(베이킹 워크플로우용)
- champion alias 지정(승격 판단 — 사람)
- 각 PR 머지 게이트(프로덕션)

## 확정된 결정 (2026-07-21)

1. **레포 이름** = `aporiax-forecast` (명명 규칙 aporiax-pulse/aporiax-lab 계승, 확장 여지 있는 이름).
2. **ADR-0010 신규** — 첫 MLOps 제품 테넌트 + 승격 메커니즘(이미지 베이킹) + CI-tailnet 해소 + AppProject 화이트리스트 확장 근거. C1에서 작성.
3. **드리프트 룰 소유 = gitops-infra** `manifests/monitoring/rules`(알림 라우팅은 플랫폼 관심사, 기존 룰과 동거). 테넌트 레포는 학습/서빙 워크로드만.

## 비목표

- LLM 서빙(이건 텔레메트리 예측 — 소형 모델). LLM 실험은 aporiax-lab 트랙.
- 자동 승격(champion 자동 지정) — 초기엔 사람 판단. 기준 안정화 후 재검토(ADR-0008 승계).
- Argo Workflows/Kubeflow — 단일 컨테이너 CronJob으로 충분할 때까지 보류(ADR-0008).

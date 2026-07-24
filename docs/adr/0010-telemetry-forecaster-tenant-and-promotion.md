# ADR-0010: 첫 MLOps 제품 테넌트(telemetry-forecaster) + 이미지 베이킹 승격

## 상태

승인됨

## 날짜

2026-07-24

## 맥락

[ADR-0008](0008-mlops-platform-pivot.md)이 MLOps 방향을 확정하며 핵심 원칙을 세웠다 — **"모델 배포가 코드 배포와 똑같은 감사·롤백 경로를 탄다(이미지 베이킹 PR)"**. 그러나 그 원칙은 아직 실물로 구현되지 않았다. 지금까지 갖춰진 것은 공용 서비스(MLflow, [PR #37~#42])와 실험 트랙의 eval·모델 비교([ADR-0009](0009-isolated-ml-experiment-cluster.md), aporiax-lab)까지고, **등록 → 승격 → 서빙 → 모니터링 → 재학습** 루프는 비어 있다.

이 ADR은 그 루프를 닫는 첫 제품 테넌트를 정의하고, 승격 메커니즘을 확정한다. 유스케이스는 ADR-0008이 지목한 **클러스터 자기 텔레메트리 예측** — Prometheus에 이미 흐르는 데이터, CPU 학습, 소형 모델(수 KB)이라 12GB 단일 노드 제약 안에 든다.

두 가지가 [ADR-0007](0007-first-product-tenant-onboarding.md)(web 테넌트 pulse)과 다르고, 그래서 별도 ADR을 쓴다:
- **워크로드 종류가 넓다** — web 테넌트는 Deployment 하나였지만, ML 테넌트는 학습(CronJob)·서빙(Deployment)·관측(ServiceMonitor)이 함께다. 테넌트 경계(AppProject 화이트리스트)를 넓혀야 한다.
- **승격 경로에 미해결 난제가 있다** — ADR-0008이 "이미지 베이킹 PR"을 결정하면서도 *"승격 CI가 tailnet 안의 아티팩트에 어떻게 접근하는가"* 는 미해결로 남겼다. GitHub Actions 러너는 tailnet 밖이고 MLflow/NAS는 tailnet 전용이라, CI가 champion 모델을 못 가져온다.

## 검토한 대안

### 테넌트 경계 — AppProject 화이트리스트

| 대안 | 기각/채택 사유 |
|---|---|
| pulse와 동일 화이트리스트(ServiceAccount/Service/Deployment/Ingress) 재사용 | ML 워크로드가 못 뜬다 — 학습 CronJob·Job, 설정 ConfigMap, 서빙 ServiceMonitor가 전부 화이트리스트 밖이라 ArgoCD가 거부 |
| 화이트리스트 비우기(=모든 namespaced kind 허용) | ADR-0007이 명시한 함정 — 빈 화이트리스트는 "전부 허용"이라 테넌트가 `argoproj.io/Application`을 만들어 자기 project를 재선언하고 경계를 탈출할 수 있다 |
| **필요한 kind만 명시 추가 (채택)** | pulse 4종 + CronJob·Job(batch)·ConfigMap·ServiceMonitor(monitoring.coreos.com). **Ingress는 불허** — 서빙은 클러스터 내부 소비자(모니터링)뿐이라 노출 불필요(ADR-0008 UI 비노출 연장). 각 kind의 근거를 매니페스트 주석에 남긴다 |

### 승격 CI의 tailnet 접근 (ADR-0008 미해결 항목)

| 대안 | 기각/채택 사유 |
|---|---|
| MLflow/NAS를 공인 노출해 CI가 접근 | tailnet 전용 원칙(ADR-0008/0009) 정면 위반. 노출 표면 증가 |
| self-hosted runner를 OCI 노드(tailnet 편입됨)에 상주 | 상시 러너 프로세스가 프로덕션 노드 자원을 점유 + 유지보수 표면. "소비자 없는 상시 컴포넌트를 먼저 안 만든다" 원칙과 상충 |
| **Tailscale GitHub Action으로 러너를 ephemeral 편입 (채택)** | 베이킹 워크플로우에서만 `tailscale/github-action`(ephemeral auth key)으로 러너를 tailnet에 임시 편입 → MLflow NodePort(`100.69.52.25:30500`)에서 champion pull → 잡 종료 시 자동 이탈. 상시 컴포넌트 0, 노출 증가 0, 필요한 순간에만 접근 |
| in-cluster bake Job (fallback) | 클러스터 안에서 MLflow 접근·GHCR push·PR 생성. "CI가 베이킹" 논지에서 벗어나 fallback으로만 — Tailscale-in-CI가 막힐 때 |

### 학습 잡 배치 (실행 플레인)

| 대안 | 기각/채택 사유 |
|---|---|
| Mac 실험 클러스터(aporiax-lab)에서 학습 | 텔레메트리 예측은 **프로덕션 제품**이지 실험이 아니다. ADR-0009 경계상 실험 플레인에 상시 제품을 두지 않는다 |
| **OCI 클러스터 테넌트 namespace에서 CronJob (채택)** | 프로덕션 플레인. Prometheus·MLflow를 **클러스터 내부**(ClusterIP)로 접근 → 학습은 tailnet 불필요(tailnet은 승격 CI에서만). 데이터 소스에 가장 가깝다 |

## 결정

1. **새 제품 테넌트 레포 `aporiax-forecast`** — ADR-0007 경계 패턴 계승(전용 AppProject·namespace `product-forecast`, 평면 리프). gitops-infra는 AppProject + Application + namespace만 소유하고, 학습/서빙 코드·워크로드 매니페스트는 테넌트 레포가 소유.
2. **AppProject 화이트리스트 확장** — pulse의 ServiceAccount/Service/Deployment에 **CronJob·Job(batch)·ConfigMap·ServiceMonitor(monitoring.coreos.com)** 추가. **Ingress 불허, `clusterResourceWhitelist: []` 유지**. 각 kind 근거는 매니페스트 주석.
3. **승격 = 이미지 베이킹 PR** — champion 모델 아티팩트를 서빙 이미지에 베이킹 → GHCR(digest 핀) → 서빙 Deployment 태그 범프 PR → 기존 CI 3종·브랜치 보호·ArgoCD 통과. **모델 롤백 = git revert**. 서빙은 런타임에 MLflow/NAS를 보지 않아 NAS 장애가 서비스 중 모델에 무영향.
4. **CI-tailnet 해소 = Tailscale GitHub Action** — 베이킹 워크플로우가 ephemeral auth key로 러너를 tailnet에 임시 편입해 MLflow NodePort에서 champion을 pull. auth key는 GH secret(수동 발급, 시크릿 경계).
5. **champion 지정은 사람** — 학습이 model version을 등록하면, 운영자가 MLflow alias `champion`을 지정(승격 판단). 자동 승격은 기준 안정화 후(ADR-0008 승계).
6. **드리프트/staleness PrometheusRule은 gitops-infra 소유**(`manifests/monitoring/rules`) — 알림 라우팅은 플랫폼 관심사, 기존 룰·Telegram 라인과 동거. 테넌트 레포는 학습/서빙 워크로드만.
7. **유스케이스**: 클러스터 자기 텔레메트리 예측. 대상 Prometheus series는 실제 데이터를 보고 확정(패턴 있는 것). 모델은 scikit-learn 소형 회귀(CPU, <1MB).

## 근거

- **ADR-0008 원칙의 실증**: "모델 배포 = 코드 배포 경로"가 문서가 아니라 동작으로 닫힌다. 기존 CI·브랜치 보호·ArgoCD를 모델 배포가 그대로 소비.
- **자산 재사용**: Prometheus(데이터)·MLflow(레지스트리)·GitOps(승격)·Grafana(예측-실측)·Telegram(드리프트) — 새 상시 컴포넌트는 서빙 파드 하나(+학습은 burst CronJob). ADR-0008 자원 예산 내.
- **미해결 난제의 해소**: ADR-0008이 남긴 CI-tailnet 갭을 ephemeral 편입으로 푼다 — 상시 노출·상시 러너 없이 필요 순간에만.
- **경계 규율**: 화이트리스트를 넓히되 "왜 각 kind가 필요한가"를 명시 → 넓힘 자체가 아니라 넓힘의 근거가 남는다.

## 비목표 / 미해결

- 대상 series·모델 알고리즘·피처 설계 — C2에서 데이터 보고 확정(테넌트 레포 몫).
- 자동 승격(champion 자동 지정) — 초기엔 사람. 기준 안정화 후 재검토.
- LLM 서빙 — 이건 소형 텔레메트리 모델. LLM은 aporiax-lab 실험 트랙(ADR-0009).
- Argo Workflows/Kubeflow — 단일 컨테이너 CronJob으로 충분할 때까지 보류(ADR-0008).
- Tailscale ephemeral auth key 운영(만료·회전) 상세 — D1 착수 시 확정.

## 단계

- **C1 (온보딩)**: 이 ADR + gitops-infra 온보딩(AppProject·Application·namespace) + `aporiax-forecast` 스캐폴드. 게이트: root app이 테넌트 Application을 Synced 인식.
- **C2 (학습)**: training 이미지 + CronJob(Prometheus→feature→학습→MLflow 등록). 게이트: 레지스트리에 model version + metric.
- **D1 (서빙+승격)**: 서빙 앱(baked, `/predict`) + 베이킹 워크플로우(Tailscale-in-CI). 게이트: champion→PR→머지→서빙이 baked 모델로 응답.
- **D2 (모니터링)**: ServiceMonitor + 예측-실측 대시보드 + 드리프트 룰→Telegram. 게이트: 대시보드 예측 vs 실측, synthetic 드리프트→Telegram.

## 재검토 조건

- Tailscale-in-CI가 반복 실패(auth key 만료·네트워크)하면 — in-cluster bake Job(fallback)으로 전환.
- 학습이 다단계 DAG·단계별 재시도를 실수요로 요구하면 — Argo Workflows(ADR-0008 조건 승계).
- 두 번째 ML 제품 테넌트가 등장하면 — MLflow OSS의 테넌트 격리 부재(experiment/model 권한 분리 없음)를 재검토(ADR-0008 리뷰에서 식별한 한계).

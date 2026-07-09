# ADR-0004: Free-tier 자원 반감 대응 — 12GB 단일 노드 플랫폼 리핏

## 상태

승인됨

## 날짜

2026-06-14

## 맥락

OCI Always Free의 Arm Ampere A1 할당이 **4 OCPU / 24GB에서 2 OCPU / 12GB로 절반으로 축소**되었다. 공식 문서 기준 Always Free 테넌시는 월 1,500 OCPU-시간 / 9,000 GB-시간(= 상시 2 OCPU / 12GB 상당)으로 명시되어 있다. (출처: docs.oracle.com — Always Free Resources)

이 레포의 토폴로지 결정(ADR-0002)은 **4 OCPU / 24GB**를 전제했다. 전제가 무효화되었으므로, 단일 노드 구성은 유지하되(ADR-0002 본질은 유효) 그 위에 올리는 워크로드를 12GB에 맞게 다시 배치할 필요가 생겼다.

기존 스택의 현실 메모리 사용량은 정상 ~7–9Gi, 스파이크 시 10–11Gi로, 12GB에서는 OS/kubelet 몫(~1Gi)을 빼면 상시 압박 + OOM 위험 + 콜드스타트 시 2코어 경합으로 수렴 지연이 예상된다.

## 결정

**"통째로 제거"가 아니라 "lean하게 우선순위화"한다.** 포폴이 보여주려는 플랫폼 정체성(GitOps + IAM + 레지스트리 + 메트릭/알림)을 모두 라이브로 유지하되, 자원 비중이 크고 포폴 증거가 아티팩트(스크린샷·config·rule)로 충분히 확보되는 부분을 줄인다.

### 상시 가동 (lean)

- ArgoCD App-of-Apps, SealedSecrets, cert-manager
- PostgreSQL (외부 DB 패턴)
- Keycloak (dev 프리셋 512Mi/1Gi)
- Harbor — **단, Trivy는 비활성화**(`trivy.enabled: false`). Trivy는 DB 갱신+스캔 시 ~1Gi로 최대 스파이크 원인이고 GitOps 데모에 가장 비핵심
- 메트릭: Prometheus(**retention 15d→5d, limit 2Gi→1Gi, storage 50Gi→20Gi**) + Grafana + Alertmanager + kube-state-metrics + node-exporter + PrometheusRule(alerting v1)

추정 상시 사용량 **~6.0Gi / 12GB** → 실질 헤드룸 확보.

### On-demand (`apps-ondemand/`)

- **로그 스택(Loki + Alloy)** 을 root app-of-apps 스캔 대상(`apps/`)에서 제외해 `apps-ondemand/`로 분리. 평소 미가동, `kubectl apply -f apps-ondemand/`로 띄웠다 내린다.
  - 근거: 로그 스택은 ~0.8Gi로 비중이 크고, 평상시 로그는 `kubectl logs`로 충분하며, 파이프라인 증거는 일시 기동 후 스크린샷으로 확보 가능
  - Grafana의 Loki 데이터소스 배선은 유지 → 띄우면 추가 설정 없이 연결
  - Trivy 스캔도 같은 의미의 on-demand(필요 시 일시 enable)

## 근거

- 제약이 강해질수록 "무엇을 포기하지 않고 어떻게 맞추는가"가 이 레포의 핵심 가치다. 라이브 capability를 하나도 영구 삭제하지 않고 right-sizing으로 흡수한다.
- 24/7 가용성이 필요 없는 컴포넌트(로그 조회, 취약점 스캔)는 상시 자원을 차지할 이유가 없다. GitOps로 정의는 유지하되 기동만 on-demand로 둔다.
- on-demand 컴포넌트도 values는 그대로 두어 CI(`validate.yaml`)가 계속 렌더링/lint 검증한다 → "꺼져 있어도 망가지지 않음"을 보장.

## 결과 / 영향

- `apps/`(상시) = Application 10개 + AppProject 1개, `apps-ondemand/` = 2개(loki, alloy)
- sync wave: 상시 스택의 최대 wave는 5(PrometheusRule). Harbor는 wave 4
- ADR-0002는 이 ADR로 자원 전제(4/24)가 갱신됨을 명시하도록 보강

## 재검토 조건

- ~~노드 실제 shape가 grandfather로 4 OCPU/24GB로 확인되면, 로그 스택을 `apps/`로 되돌리고 Trivy를 다시 켜는 것을 검토~~ → **기각 (2026-07-10 추기)**: 실측은 4/24 grandfather가 맞았으나(2026-07-02), Oracle이 2026-06-15부로 A1 무료 한도 반토막(2/12)을 무통보 발효했고 공식 문서에 "기존 리소스를 terminate하면 갱신된 한도 초과 사양으로 재생성이 불가능할 수 있다"가 명시됨. 4/24는 재현 불가능한 일회성 자산이므로 그 위에 워크로드를 되돌리는 것은 단일 장애(인스턴스 손실) 시 복구 불가능한 설계가 된다. 12GB 리핏이 영구 기준.
- 유료 인스턴스/추가 노드로 확장하면 on-demand 컴포넌트를 상시로 승격

# 플랫폼 모니터링 서비스 점검 체크리스트

이 문서는 배포 또는 설정 변경 이후 플랫폼 모니터링 및 로깅 구성이 정상 동작하는지 확인하기 위한 점검표입니다.

> **on-demand 주의 (ADR-0004)**: 메트릭(Prometheus/Grafana)은 상시 가동입니다. **로그 스택(Loki/Alloy)은 `apps-ondemand/`로 분리된 on-demand 컴포넌트**라 평소엔 미가동입니다. 아래 Loki/Alloy 관련 섹션(4·5·6 등)은 `kubectl apply -f apps-ondemand/`로 띄운 뒤에만 적용되며, 점검 후 `kubectl delete -f apps-ondemand/`로 내립니다.

## 점검 범위

- Argo CD 애플리케이션 상태
- Prometheus / Grafana 기본 상태
- Loki 로그 저장소 상태
- Alloy 로그 수집 상태
- Grafana 로그 조회 검증
- 주요 서비스 로그 확인

## 점검 대상 애플리케이션

- `appproject-platform-infra`
- `platform-monitoring-prometheus`
- `platform-monitoring-loki`
- `platform-monitoring-alloy`

## 1. Argo CD 상태 확인

- [ ] 모니터링 관련 애플리케이션이 모두 존재하는지 확인한다.

```bash
kubectl get applications -n argocd
```

- [ ] 아래 애플리케이션이 모두 `Healthy` 상태인지 확인한다.
  - `platform-monitoring-prometheus`
  - `platform-monitoring-loki`
  - `platform-monitoring-alloy`

- [ ] `OutOfSync` 상태인 애플리케이션이 있는지 확인한다.
- [ ] `OutOfSync`가 있다면 즉시 수정하기 전에 diff 원인을 먼저 기록한다.

## 2. 네임스페이스 및 파드 상태 확인

- [ ] `platform-monitoring` 네임스페이스의 워크로드 상태를 확인한다.

```bash
kubectl get pods -n platform-monitoring -o wide
kubectl get svc -n platform-monitoring
kubectl get pvc -n platform-monitoring
```

- [ ] 아래 구성요소가 모두 실행 중인지 확인한다.
  - Grafana
  - Prometheus
  - Alertmanager
  - Loki
  - Loki gateway
  - Alloy

- [ ] PVC가 모두 `Bound` 상태인지 확인한다.
- [ ] 파드 재시작 횟수가 계속 증가하지 않는지 확인한다.

## 3. Prometheus / Grafana 기본 상태 확인

- [ ] Grafana 접속이 가능한지 확인한다.
- [ ] Grafana 로그인에 문제가 없는지 확인한다.
- [ ] 로깅 스택 배포 이후 Prometheus와 Alertmanager가 영향 없이 정상 상태인지 확인한다.

```bash
kubectl get pods -n platform-monitoring
```

## 4. Loki 상태 확인

- [ ] Loki 파드 로그에 기동 또는 스토리지 관련 오류가 없는지 확인한다.

```bash
kubectl logs -n platform-monitoring statefulset/platform-monitoring-loki --tail=100
kubectl logs -n platform-monitoring deploy/platform-monitoring-loki-gateway --tail=100
```

- [ ] 아래 유형의 오류가 반복되지 않는지 확인한다.
  - schema
  - filesystem storage
  - readiness
  - crash loop

- [ ] Loki용 PVC가 정상 생성되고 마운트되었는지 확인한다.

```bash
kubectl get pvc -n platform-monitoring
```

## 5. Alloy 상태 확인

- [ ] Alloy 파드 로그에 설정 파싱 오류나 전송 실패가 없는지 확인한다.

```bash
kubectl logs -n platform-monitoring deploy/platform-monitoring-alloy --tail=200
```

- [ ] 반복적인 오류 패턴이 있는지 빠르게 확인한다.

```bash
kubectl logs -n platform-monitoring deploy/platform-monitoring-alloy --tail=300 | findstr /I "error failed refused denied"
```

- [ ] 아래 유형의 오류가 반복되지 않는지 확인한다.
  - Loki push 실패
  - Kubernetes discovery 실패
  - 설정 파싱 오류
  - 인증 또는 연결 실패

## 6. Loki API 동작 확인

- [ ] Loki gateway에 port-forward를 연결한다.

```bash
kubectl port-forward -n platform-monitoring svc/platform-monitoring-loki-gateway 3100:80
```

- [ ] Loki API가 정상 응답하는지 확인한다.

```bash
curl "http://127.0.0.1:3100/loki/api/v1/labels"
```

- [ ] 예상한 라벨 값이 존재하는지 확인한다.

```bash
curl "http://127.0.0.1:3100/loki/api/v1/label/namespace/values"
curl "http://127.0.0.1:3100/loki/api/v1/label/app/values"
```

- [ ] 아래 네임스페이스가 응답에 포함되는지 확인한다.
  - `platform-db`
  - `platform-iam`
  - `platform-monitoring`
  - `platform-registry`

## 7. Grafana 데이터소스 확인

- [ ] Grafana에 접속한다.
- [ ] `Data sources` 화면으로 이동한다.
- [ ] `Loki` 데이터소스가 존재하는지 확인한다.
- [ ] `Save & test`가 성공하는지 확인한다.

## 8. Grafana Explore 조회 확인

- [ ] `Explore` 화면으로 이동한다.
- [ ] `Loki` 데이터소스를 선택한다.
- [ ] 아래 기본 쿼리를 실행한다.

```logql
{namespace="platform-db"}
```

```logql
{namespace="platform-iam"}
```

```logql
{namespace="platform-monitoring"}
```

```logql
{namespace="platform-registry"}
```

- [ ] 활성 네임스페이스마다 실제 로그가 조회되는지 확인한다.

## 9. 라벨 품질 확인

- [ ] Grafana에서 샘플 로그 한 줄을 열어 라벨을 확인한다.
- [ ] 아래 라벨이 기대한 대로 붙는지 확인한다.
  - `namespace`
  - `pod`
  - `container`
  - `app`
  - `job`
  - `cluster`

- [ ] `app` 라벨이 비어 있거나 불규칙한 서비스가 있으면 기록한다.

## 10. Kubernetes 이벤트 수집 확인

- [ ] 클러스터 이벤트 로그가 수집되는지 확인한다.

```logql
{kubernetes_cluster_events="job"}
```

- [ ] 최근 Kubernetes 이벤트가 Grafana Explore에서 조회되는지 확인한다.

## 11. 서비스별 샘플 로그 확인

- [ ] PostgreSQL 로그가 조회되는지 확인한다.

```logql
{namespace="platform-db", pod=~".*postgres.*"}
```

- [ ] Keycloak 로그가 조회되는지 확인한다.

```logql
{namespace="platform-iam", pod=~".*keycloak.*"}
```

## 12. 최종 점검 완료 여부

- [ ] Argo CD 애플리케이션이 정상 상태다.
- [ ] Loki가 로그를 정상 수신한다.
- [ ] Alloy가 반복적인 전송 오류 없이 로그를 전달한다.
- [ ] Grafana에서 Loki 조회가 정상 동작한다.
- [ ] 주요 플랫폼 네임스페이스 로그가 실제로 보인다.
- [ ] Prometheus / Grafana 기존 기능에 예상치 못한 이상이 없다.

## 기록

- 점검 일시:
- 점검자:
- 대상 환경:
- 주요 결과:
- 후속 조치:

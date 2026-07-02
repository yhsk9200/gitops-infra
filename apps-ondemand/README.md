# apps-ondemand — 온디맨드 컴포넌트

이 디렉토리의 ArgoCD `Application`은 **root app-of-apps(`bootstrap/platform-root-infra.yaml`)의 스캔 대상(`apps/`)에서 의도적으로 제외**되어 있습니다. 따라서 평소에는 클러스터에 배포되지 않으며, 필요할 때만 수동으로 띄웠다가 내립니다.

## 배경

12GB 단일 노드 리핏(ADR-0004)에서, 로그 수집 스택(Loki + Alloy)은 **상시 가동 대상에서 제외**했습니다.

- 메트릭/대시보드/알림은 lean하게 상시 가동 → "라이브 모니터링" 스토리 유지
- 로그 스택은 메모리 비중이 크고(~0.8Gi) 포폴 증거가 스크린샷으로 충분히 확보되므로 on-demand
- 평상시 로그는 `kubectl logs`로 확인

## 구성

| 앱 | chart | values |
|---|---|---|
| `platform-monitoring-loki` | loki 6.46.0 | `helm-values/monitoring/loki-values.yaml` |
| `platform-monitoring-alloy` | alloy 1.7.0 | `helm-values/monitoring/alloy-values.yaml` |

> values 파일은 그대로 `helm-values/monitoring/`에 있고 CI(`validate.yaml`)에서 계속 렌더링 검증됩니다. 앱 정의도 `apps-ondemand/`가 kubeconform 대상에 포함되어 lint됩니다.

## 띄우기 (on-demand)

```bash
# platform-monitoring 네임스페이스는 상시 스택이 이미 생성해 둠
kubectl apply -f apps-ondemand/

# ArgoCD가 동기화 → Pod Ready 확인
kubectl -n argocd get applications platform-monitoring-loki platform-monitoring-alloy
kubectl -n platform-monitoring get pods -l 'app.kubernetes.io/name in (loki,alloy)'
```

Grafana의 Loki 데이터소스 배선은 상시 유지되므로(`kube-prometheus-stack-values.yaml`), 띄우면 추가 설정 없이 Explore에서 바로 조회됩니다.

## 내리기

```bash
# Application 삭제 → prune으로 워크로드까지 정리됨
kubectl delete -f apps-ondemand/
```

## 주의

- 상시 가동 메트릭 스택과 합쳐 12GB를 넘지 않도록, on-demand로 띄우는 동안에는 동시 부하(이미지 대량 push, Trivy 스캔 등)를 피합니다.
- 영구적으로 상시 가동이 필요해지면 해당 파일을 `apps/`로 되돌리면 root가 자동 배포합니다(ADR-0004 재검토 조건).

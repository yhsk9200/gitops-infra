# Platform Alerting TODO

이 문서는 Grafana/Prometheus/Alertmanager 기반 위험 탐지 작업을 나중에 진행하기 위한 TODO 목록입니다.

현재 상태:

- Prometheus, Grafana, Alertmanager는 `kube-prometheus-stack`으로 배포되어 있습니다.
- 기본 Prometheus rule은 일부 활성화되어 있습니다.
- 플랫폼 서비스별 커스텀 `PrometheusRule`은 아직 없습니다.
- Alertmanager 수신처와 알림 라우팅 정책은 아직 정의하지 않았습니다.
- Grafana Alerting provisioning은 아직 사용하지 않습니다.

## 권장 방향

첫 단계는 Grafana Alerting보다 `PrometheusRule + Alertmanager` 중심으로 시작합니다.

이유:

- Kubernetes/인프라 위험 탐지는 PrometheusRule이 단순합니다.
- ArgoCD/GitOps로 관리하기 쉽습니다.
- 현재 `kube-prometheus-stack` 구조와 잘 맞습니다.
- 알림 채널이 정해지기 전에도 firing 여부를 먼저 검증할 수 있습니다.

Grafana Alerting은 로그 기반 탐지나 Grafana UI 중심 운영이 필요해질 때 검토합니다.

## TODO

- [ ] `manifests/monitoring/rules/` 디렉토리 추가
- [ ] `platform-monitoring-rules` ArgoCD Application 추가
- [ ] v1 `PrometheusRule` 작성
- [ ] Prometheus에서 rule 로딩 확인
- [ ] Alertmanager에서 firing alert 확인
- [ ] 알림 채널 결정
- [ ] Alertmanager receiver 및 route 설정
- [ ] 노이즈가 많은 rule 조정
- [ ] 필요 시 Grafana Alerting provisioning 검토

## v1 Alert Rule 후보

- `PlatformPodCrashLooping`
- `PlatformPodNotReady`
- `PlatformPersistentVolumeAlmostFull`
- `PlatformTargetDown`
- `HarborExporterDown`
- `KeycloakDown`
- `PostgreSQLDown`
- `RedisDown`
- `LokiDown`
- `AlloyDown`

## 알림 채널 결정 필요

아래 중 실제 운영 연락망에 맞는 방식을 선택해야 합니다.

- Email
- Slack
- Mattermost
- Teams
- Webhook
- SMS 또는 외부 관제 연동

## 보류 사유

지금 바로 alert rule과 notification route를 추가하지 않는 이유:

- 아직 실제 운영 알림 채널이 확정되지 않았습니다.
- 너무 많은 rule을 한 번에 넣으면 노이즈가 생길 수 있습니다.
- 먼저 Harbor, Keycloak, Loki/Alloy 기본 배포 안정화를 완료하는 편이 안전합니다.

## 시작 조건

아래 조건이 충족되면 이 TODO를 진행합니다.

- 주요 플랫폼 컴포넌트가 안정적으로 기동 중입니다.
- Harbor push/pull 검증이 완료되었습니다.
- Loki/Alloy 로그 수집 검증이 완료되었습니다.
- 알림을 받을 채널과 담당자가 정해졌습니다.

# Platform Alerting TODO

이 문서는 Grafana/Prometheus/Alertmanager 기반 위험 탐지 작업을 나중에 진행하기 위한 TODO 목록입니다.

현재 상태:

- Prometheus, Grafana, Alertmanager는 `kube-prometheus-stack`으로 배포되어 있습니다.
- 기본 Prometheus rule은 일부 활성화되어 있습니다.
- **v1 커스텀 `PrometheusRule`은 작성 완료** — `manifests/monitoring/rules/platform-rules.yaml` (`platform-monitoring-rules` 앱, wave 5).
- Alertmanager 수신처와 알림 라우팅 정책은 아직 정의하지 않았습니다 (채널 미확정).
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

- [x] `manifests/monitoring/rules/` 디렉토리 추가
- [x] `platform-monitoring-rules` ArgoCD Application 추가
- [x] v1 `PrometheusRule` 작성
- [ ] Prometheus에서 rule 로딩 확인 (클러스터 재구축 후)
- [ ] Alertmanager에서 firing alert 확인
- [ ] 알림 채널 결정
- [ ] Alertmanager receiver 및 route 설정
- [ ] 노이즈가 많은 rule 조정
- [ ] 필요 시 Grafana Alerting provisioning 검토

## v1 Alert Rule 구성

개별 컴포넌트 이름에 핀 고정한 룰(`PostgreSQLDown` 등) 대신, kube-state-metrics 기반의
이름 독립적 제네릭 룰로 `platform-*` 네임스페이스 전체를 커버합니다.
릴리스 이름이나 차트 버전이 바뀌어도 룰이 깨지지 않습니다.

| 룰 | 포괄 범위 |
| --- | --- |
| `PlatformPodCrashLooping` | 모든 platform-* pod 재시작 반복 |
| `PlatformPodNotReady` | Pending/Unknown/Failed 정체 |
| `PlatformDeploymentDegraded` | Alloy, Harbor 구성요소, Grafana 등 Deployment 계열 다운 |
| `PlatformStatefulSetDegraded` | PostgreSQL, Keycloak, Loki, Prometheus 등 StatefulSet 계열 다운 |
| `PlatformPVAlmostFull` | PVC 잔여 10% 미만 (단일 노드 디스크 직결) |
| `PlatformTargetDown` | Harbor exporter, kube-state-metrics 등 scrape 대상 다운 |

> Loki/Alloy는 on-demand(`apps-ondemand/`, ADR-0004)라 평소엔 scrape 대상이 아닙니다. on-demand로 띄운 동안에만 위 룰의 포괄 범위에 들어옵니다.

## 알림 채널 결정 필요

아래 중 실제 운영 연락망에 맞는 방식을 선택해야 합니다.

- Email
- Slack
- Mattermost
- Teams
- Webhook
- SMS 또는 외부 관제 연동

## receiver/route 보류 사유

rule은 작성했지만 notification route를 아직 추가하지 않는 이유:

- 아직 실제 운영 알림 채널이 확정되지 않았습니다.
- 채널 없이도 Prometheus rule 로딩과 Alertmanager firing은 검증할 수 있습니다.
- receiver 없이 rule을 먼저 운영하며 노이즈가 많은 rule을 조정한 뒤 연결하는 편이 안전합니다.

## receiver/route 시작 조건

아래 조건이 충족되면 receiver 설정을 진행합니다.

- 클러스터 재구축 후 주요 플랫폼 컴포넌트가 안정적으로 기동 중입니다.
- v1 rule의 firing/해소 동작이 Alertmanager UI에서 확인되었습니다.
- 알림을 받을 채널이 정해졌습니다.

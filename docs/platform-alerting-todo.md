# Platform Alerting TODO

이 문서는 Grafana/Prometheus/Alertmanager 기반 위험 탐지 작업의 진행 기록입니다.

현재 상태:

- Prometheus, Grafana, Alertmanager는 `kube-prometheus-stack`으로 배포되어 있습니다.
- 기본 Prometheus rule은 일부 활성화되어 있습니다.
- **v1 커스텀 `PrometheusRule`은 작성 완료** — `manifests/monitoring/rules/platform-rules.yaml` (`platform-monitoring-rules` 앱, wave 5).
- **rule 로딩 + firing 파이프라인 실측 완료** (2026-07-09, 클러스터 read-only 점검): `platform.availability`/`platform.capacity`/`platform.scrape` 3개 그룹 6개 룰 전부 Prometheus에 로딩됨(전부 `inactive` = 평상시 정상). 상시 firing 메타 알림인 `Watchdog`이 Alertmanager까지 전달되는 것을 확인 — Prometheus→Alertmanager 배선 자체가 검증됨(당시 receiver는 `null`).
- **알림 채널 확정: Telegram** (2026-07-09). 봇 토큰은 SealedSecret(`manifests/security/alertmanager-telegram-sealed-secret.yaml`)으로 격리, receiver/route는 `helm-values/monitoring/kube-prometheus-stack-values.yaml`의 `alertmanager.config`로 배선.
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
- [x] Prometheus에서 rule 로딩 확인 (2026-07-09, 클러스터 재구축 후 실측)
- [x] Alertmanager에서 firing alert 확인 (2026-07-09, Watchdog firing 실측)
- [x] 알림 채널 결정 — Telegram
- [x] Alertmanager receiver 및 route 설정 (`telegram-platform` receiver, Watchdog는 계속 `null`)
- [ ] 실제 텔레그램 수신 검증 (synthetic alert 주입, 머지 직후 1회성)
- [ ] 노이즈가 많은 rule 조정 (실제 firing 데이터 축적 후 판단)
- [ ] 필요 시 Grafana Alerting provisioning 검토

## v1 Alert Rule 구성

개별 컴포넌트 이름에 핀 고정한 룰(`PostgreSQLDown` 등) 대신, kube-state-metrics 기반의
이름 독립적 제네릭 룰로 `platform-*` 네임스페이스 전체를 커버합니다.
릴리스 이름이나 차트 버전이 바뀌어도 룰이 깨지지 않습니다.

| 룰 | 포괄 범위 |
| --- | --- |
| `PlatformPodCrashLooping` | 모든 platform-* pod 재시작 반복 |
| `PlatformPodNotReady` | Pending/Unknown/Failed 정체 |
| `PlatformDeploymentDegraded` | Alloy, Grafana 등 Deployment 계열 다운 |
| `PlatformStatefulSetDegraded` | PostgreSQL, Keycloak, Loki, Prometheus 등 StatefulSet 계열 다운 |
| `PlatformPVAlmostFull` | PVC 잔여 10% 미만 (단일 노드 디스크 직결) |
| `PlatformTargetDown` | kube-state-metrics 등 scrape 대상 다운 |

> Loki/Alloy는 on-demand(`apps-ondemand/`, ADR-0004)라 평소엔 scrape 대상이 아닙니다. on-demand로 띄운 동안에만 위 룰의 포괄 범위에 들어옵니다.

## 알림 채널: Telegram (확정)

1인 운영 환경에서 폰 푸시가 가장 빠르고, 봇 토큰 하나만 SealedSecret으로 격리하면 되어
Email(SMTP 자격증명)이나 Slack(워크스페이스 앱 등록)보다 설정 표면이 작다는 점을 근거로 선택했습니다.

- 수신: 개인 1:1 채팅(chat_id 양수) — 그룹이 아님
- 배선: `alertmanagerSpec.secrets`로 봇 토큰 파일 마운트 → `alertmanager.config`의
  `telegram_configs.bot_token_file`이 참조. `chat_id`는 토큰 없이는 무의미한 값이라 git 평문.
- Watchdog(상시 firing 메타 알림)은 텔레그램으로 보내면 `repeat_interval`마다 영구 노이즈가
  되므로 계속 `null` receiver로 라우팅합니다.
- inhibit_rule(같은 namespace+alertname의 critical이 warning/info를 억제)은 별도로 작성하지
  않았습니다 — Helm이 values를 맵 단위로 병합해서 `route`/`receivers`만 지정하면 그 두 키만
  차트 기본값을 대체하고, 건드리지 않은 `inhibit_rules`는 kube-prometheus-stack 차트 기본값이
  그대로 살아있습니다(`helm template`로 렌더링해 실측 확인). 현재 v1 룰셋은 룰마다 severity가
  고정 1개뿐이라 당장 억제될 대상은 없지만, 향후 같은 alertname이 여러 severity로 확장되면
  차트 기본값이 자동으로 커버합니다.

## receiver/route 시작 조건 — 충족 완료 (2026-07-09)

- [x] 클러스터 재구축 후 주요 플랫폼 컴포넌트가 안정적으로 기동 중입니다.
- [x] v1 rule의 firing 동작이 Alertmanager에서 확인되었습니다(Watchdog).
- [x] 알림을 받을 채널이 정해졌습니다(Telegram).

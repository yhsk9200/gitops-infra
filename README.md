# platform-infra

대구테크노파크 제조데이터플랫폼의 공용 인프라 컴포넌트를 ArgoCD App of Apps 패턴으로 관리하는 GitOps 저장소입니다.

이 저장소는 애플리케이션 서비스 코드가 아니라 Kubernetes 클러스터에 필요한 기반 서비스와 운영 설정을 선언적으로 관리합니다.

## 1. 배포 구조

최초 부트스트랩은 `bootstrap/platform-root-infra.yaml`을 수동 적용합니다. 이후 Root Application이 `apps/` 디렉토리의 자식 Application을 동기화합니다.

```text
platform-root-infra
└── apps/
    ├── appproject-platform-infra
    ├── platform-infra-namespaces
    ├── platform-system-sealed-secrets
    ├── platform-infra-secrets
    ├── platform-infra-storage
    ├── platform-db-postgres
    ├── platform-db-redis
    ├── platform-iam-keycloak
    ├── platform-monitoring-prometheus
    ├── platform-monitoring-loki
    ├── platform-monitoring-alloy
    ├── platform-registry-harbor
    └── platform-system-cert-manager
```

## 2. Sync Wave

| Wave | Application | 역할 |
| --- | --- | --- |
| `-10` | `appproject-platform-infra` | ArgoCD AppProject |
| `-3` | `platform-infra-namespaces` | 공용 네임스페이스 생성 |
| `-2` | `platform-system-sealed-secrets` | Sealed Secrets controller |
| `-1` | `platform-infra-secrets` | SealedSecret 리소스 |
| `0` | `platform-infra-storage`, `platform-system-cert-manager` | 기본 스토리지와 cert-manager |
| `1` | `platform-db-postgres`, `platform-db-redis` | 공용 데이터베이스 |
| `2` | `platform-iam-keycloak` | 인증/인가 |
| `3` | `platform-monitoring-prometheus` | Prometheus, Grafana, Alertmanager |
| `4` | `platform-monitoring-loki`, `platform-registry-harbor` | 로그 저장소, 이미지 레지스트리 |
| `5` | `platform-monitoring-alloy` | 로그 수집 |

## 3. 네임스페이스

| Namespace | 용도 |
| --- | --- |
| `platform-system` | Sealed Secrets, cert-manager |
| `platform-db` | PostgreSQL, Redis |
| `platform-iam` | Keycloak |
| `platform-monitoring` | Prometheus, Grafana, Loki, Alloy |
| `platform-registry` | Harbor, Trivy |
| `cert-manager` | cert-manager controller |

## 4. 디렉토리 구조

```text
platform-infra/
├── bootstrap/
│   └── platform-root-infra.yaml
├── apps/
│   ├── appproject-platform-infra.yaml
│   ├── platform-db-*.yaml
│   ├── platform-iam-keycloak.yaml
│   ├── platform-monitoring-*.yaml
│   └── platform-registry-harbor.yaml
├── manifests/
│   ├── namespaces/
│   ├── security/
│   └── storage/
├── helm-values/
│   ├── database/
│   ├── iam/
│   ├── monitoring/
│   ├── registry/
│   └── system/
└── docs/
```

## 5. 최초 부트스트랩

클러스터에 SealedSecret을 재암호화한 뒤 Root Application을 적용합니다.

```bash
kubectl apply -f bootstrap/platform-root-infra.yaml
```

ArgoCD는 이후 `apps/` 아래 Application을 sync wave 순서대로 배포합니다.

## 6. SealedSecret 재암호화

이 저장소의 SealedSecret은 대상 클러스터의 Sealed Secrets 공개키로 다시 암호화해야 합니다.

```bash
kubeseal --fetch-cert \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=platform-system \
  > pub-cert.pem
```

주요 Secret:

| Secret | Namespace | 주요 key | 비고 |
| --- | --- | --- | --- |
| `postgres-db-secret` | `platform-db` | `postgres-password`, `keycloak-password`, `harbor-password` | PostgreSQL superuser와 앱 DB 계정 |
| `redis-secret` | `platform-db` | `redis-password` | Redis 인증 |
| `keycloak-admin-secret` | `platform-iam` | `admin-password` | Keycloak 관리자 |
| `keycloak-db-secret` | `platform-iam` | `keycloak-password` | `postgres-db-secret`의 `keycloak-password`와 동일 값 |
| `grafana-admin-secret` | `platform-monitoring` | `admin-user`, `admin-password` | Grafana 관리자 |
| `harbor-admin-secret` | `platform-registry` | `admin-password` | Harbor 관리자 |
| `harbor-core-secret` | `platform-registry` | `secretKey` | Harbor core secret key |
| `harbor-db-secret` | `platform-registry` | `password` | `postgres-db-secret`의 `harbor-password`와 동일 값 |

## 7. 컴포넌트

| 컴포넌트 | Chart / Image | Version |
| --- | --- | --- |
| PostgreSQL | `bitnami/postgresql` | `18.5.19` |
| Redis | `bitnami/redis` | `25.3.11` |
| Keycloak | `bitnami/keycloak` | `25.2.0` |
| Sealed Secrets | `bitnami/sealed-secrets` | `2.18.4` |
| cert-manager | `jetstack/cert-manager` | `v1.17.0` |
| Prometheus Stack | `prometheus-community/kube-prometheus-stack` | `83.6.0` |
| Loki | `grafana-community/loki` | `6.46.0` |
| Alloy | `grafana/alloy` | `1.7.0` |
| Harbor | `goharbor/harbor` | `1.16.2` |

## 8. 운영 메모

### Keycloak

현재 Keycloak은 도메인이 없는 dev/internal 구성을 사용합니다. 실제 ArgoCD 앱은 `helm-values/iam/keycloak-values-dev.yaml`을 참조합니다.

도메인과 TLS가 확정되기 전까지는 Ingress, strict hostname, OIDC client redirect URI를 확정하지 않습니다. 80/443 외부 포트가 열려 있더라도 Keycloak 관리자 콘솔은 우선 port-forward로 검증합니다.

수동 RBAC 기준과 운영 절차는 아래 문서를 따릅니다.

- `docs/keycloak-operations.md`
- `docs/keycloak-rbac-plan.md`
- `docs/keycloak-manual-rbac-checklist.md`

### Harbor

현재 Harbor는 internal PostgreSQL 대신 `platform-db-postgres`의 external PostgreSQL을 사용합니다.

신규 클러스터에서 `postgres-pvc`가 비어 있는 최초 기동이라면 PostgreSQL `initdb` 스크립트가 `harbor_admin` 사용자와 `harbor_registry` DB를 자동 생성합니다. 이미 PostgreSQL PVC가 초기화된 환경에서는 수동 SQL 또는 별도 bootstrap Job으로 생성해야 합니다.

외부 접속 주소:

```text
http://harbor.210.113.225.245.nip.io
```

HTTP 레지스트리이므로 외부 Docker 클라이언트에서는 아래 주소를 insecure registry로 허용해야 합니다.

```text
harbor.210.113.225.245.nip.io
```

Harbor는 chart 특성상 `Healthy + OutOfSync`로 남을 수 있습니다. Harbor UI 접속, pod readiness, push/pull, external PostgreSQL 연결이 정상이라면 known diff로 간주합니다.

Push/pull 검증은 아래 문서를 따릅니다.

- `docs/harbor-push-pull-checklist.md`

Harbor metrics와 exporter는 활성화되어 있으며, Prometheus는 Harbor chart가 생성하는 ServiceMonitor를 수집합니다.

### Observability

메트릭은 Prometheus/Grafana, 로그는 Loki/Alloy로 수집합니다. 배포 후 로그 수집과 Grafana Explore 동작은 아래 문서로 점검합니다.

- `docs/platform-observability-checklist.md`
- `docs/platform-alerting-todo.md`

### Backup/Restore

현재 단계에서는 백업 저장소와 보관 정책이 확정되지 않았으므로 자동 백업 CronJob은 아직 배포하지 않습니다. PostgreSQL, Harbor registry PVC, Sealed Secrets controller key를 중심으로 수동 백업/복구 절차를 먼저 검증합니다.

- `docs/platform-backup-restore-runbook.md`

## 9. 다음 작업 후보

- Platform alerting rule과 Alertmanager receiver 설계
- Harbor 외부 push/pull 최종 검증
- 백업 저장소와 보관 정책 확정 후 백업 CronJob 자동화
- Keycloak 도메인/TLS 확정 후 prod values 적용
- Keycloak SSO client와 redirect URI 설정
- 반복 배포가 필요해질 경우 `keycloakConfigCli` 자동화 검토
- NetworkPolicy를 CNI 지원과 트래픽 경로 확인 후 강화

# Keycloak 운영 가이드

이 문서는 단독 운영 환경을 기준으로, 현재 구성을 이해하고 기본 장애를 점검할 수 있도록 작성한 운영 메모입니다.

## 현재 운영 상태

- 현재 Argo CD 애플리케이션은 `helm-values/iam/keycloak-values-prod.yaml`을 사용합니다 (2026-07-03 전환).
- 외부 도메인 `https://aporiax-auth.duckdns.org`로 노출되어 있습니다 (Traefik Ingress + cert-manager `letsencrypt-prod`).
- `production: true`, `hostnameStrict: true`, `proxyHeaders: xforwarded` — TLS는 Traefik에서 종료되고 Keycloak은 내부 HTTP로 서빙합니다.
- Keycloak은 자체 PostgreSQL을 띄우지 않고 `platform-db-postgres`의 `keycloak_db`를 사용합니다.
- `keycloak-values-dev.yaml`은 도메인 없이 재구축/디버깅할 때를 위한 대비책으로 유지합니다.

## 관련 리소스

- Argo CD Application: `platform-iam-keycloak`
- Namespace: `platform-iam`
- Admin Secret: `keycloak-admin-secret`
- DB Secret: `keycloak-db-secret`
- External DB Service: `platform-db-postgres-postgresql.platform-db.svc.cluster.local`
- DB User: `keycloak_admin`
- DB Name: `keycloak_db`

## 기본 상태 확인

```bash
kubectl get application platform-iam-keycloak -n argocd
kubectl get pods -n platform-iam -o wide
kubectl get svc -n platform-iam
kubectl get secret -n platform-iam
```

정상 기준:

- Keycloak pod가 `Running` / `Ready` 상태입니다.
- `keycloak-admin-secret`와 `keycloak-db-secret`가 존재합니다.
- Keycloak service가 생성되어 있습니다.

## 로그 확인

```bash
kubectl logs -n platform-iam statefulset/platform-iam-keycloak --tail=200
```

반복해서 확인할 오류 유형:

- DB 연결 실패
- 관리자 비밀번호 Secret 누락
- hostname 또는 redirect URI 관련 오류
- readiness probe 실패

## 관리자 콘솔 접속

기본 경로는 외부 도메인입니다.

```text
https://aporiax-auth.duckdns.org
```

> `hostnameStrict: true`이므로 port-forward로 `127.0.0.1:8080`에 접속하면 설정된 hostname으로 리다이렉트되거나 URL 불일치 오류가 날 수 있습니다. port-forward 진단은 Ingress/도메인 장애로 외부 경로가 죽었을 때의 보조 수단으로만 사용하고, 이때도 콘솔 로그인이 아니라 헬스 엔드포인트 확인 위주로 씁니다.

관리자 계정:

- ID: `admin`
- Password: `keycloak-admin-secret`의 `admin-password`

비밀번호 확인:

```bash
kubectl get secret keycloak-admin-secret -n platform-iam -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

## DB 연결 확인

Keycloak이 사용하는 DB 계정과 DB가 존재하는지 확인합니다.

```bash
kubectl exec -it platform-db-postgres-postgresql-0 -n platform-db -- psql -U postgres -d postgres
```

```sql
SELECT rolname FROM pg_roles WHERE rolname = 'keycloak_admin';
SELECT datname FROM pg_database WHERE datname = 'keycloak_db';
SELECT d.datname, pg_catalog.pg_get_userbyid(d.datdba) AS owner
FROM pg_database d
WHERE d.datname = 'keycloak_db';
```

정상 기준:

- `keycloak_admin` role이 존재합니다.
- `keycloak_db` database가 존재합니다.
- `keycloak_db` owner가 `keycloak_admin`입니다.

## Secret 정합성

아래 두 Secret의 Keycloak DB 비밀번호는 같은 값이어야 합니다.

- `postgres-db-secret`의 `keycloak-password`
- `keycloak-db-secret`의 `keycloak-password`

값이 다르면 Keycloak은 DB에 접속하지 못합니다.

## dev 값의 의미 (대비책 파일 `keycloak-values-dev.yaml`)

- `ingress.enabled: false`
  - 도메인이 아직 없으므로 외부 노출을 하지 않습니다.
- `production: false`
  - 운영 hostname/TLS가 확정되지 않은 상태에서 엄격한 운영 모드를 켜지 않습니다.
- `hostnameStrict: false`
  - port-forward와 내부 테스트를 허용하기 위한 설정입니다.
- `proxyHeaders: ""`
  - reverse proxy 구성이 아직 확정되지 않았기 때문에 비워둡니다.
- `automountServiceAccountToken: false`
  - Keycloak이 Kubernetes API를 직접 호출하지 않으므로 pod에 ServiceAccount 토큰을 마운트하지 않습니다.

## 도메인 확정 후 전환 항목 — ✅ 전환 완료 (2026-07-03)

- ~~`keycloak-values-prod.yaml`의 `ingress.hostname`~~ → `aporiax-auth.duckdns.org`
- ~~`keycloak-values-prod.yaml`의 cert-manager issuer~~ → `letsencrypt-prod`
- ~~`production: true` / `proxyHeaders: xforwarded` / `hostnameStrict: true`~~ → 적용됨
- ~~OIDC client redirect URI~~ → `grafana` client 생성 완료 (2026-07-06, redirect `https://aporiax.duckdns.org/login/generic_oauth`)
- ~~Grafana와의 SSO 연동~~ → `auth.generic_oauth` 배포 완료 (API Gateway 연동은 향후 과제)

## 장애별 빠른 점검

### Pod가 뜨지 않는 경우

```bash
kubectl describe pod -n platform-iam -l app.kubernetes.io/name=keycloak
kubectl logs -n platform-iam statefulset/platform-iam-keycloak --tail=200
```

주로 확인할 것:

- Secret 누락
- DB 접속 실패
- 이미지 pull 실패
- readiness/liveness probe 실패

### 관리자 로그인이 안 되는 경우

```bash
kubectl get secret keycloak-admin-secret -n platform-iam -o yaml
kubectl logs -n platform-iam statefulset/platform-iam-keycloak --tail=200
```

주로 확인할 것:

- `admin-password` 키가 존재하는지
- 최초 부팅 이후 관리자 비밀번호 변경 이력이 있는지
- DB가 기존 데이터를 유지하고 있는지

### 외부 연동에서 redirect URI 오류가 나는 경우

확인할 것:

- Keycloak client의 valid redirect URI
- 외부 서비스가 바라보는 Keycloak issuer URL
- `hostnameStrict`, `proxyHeaders`, Ingress host 설정
- HTTP/HTTPS 혼용 여부

## 운영 원칙

- prod values가 기본입니다. dev values는 도메인/Ingress 없이 재구축·디버깅하는 상황의 대비책입니다.
- realm, client, role 변경은 수동으로 하더라도 반드시 문서에 남깁니다.
- 반복 배포가 필요해지면 `keycloakConfigCli`를 검토합니다.

## 관련 문서

- `docs/keycloak-rbac-plan.md`: Keycloak realm/client/role/group 설계 초안
- `docs/keycloak-manual-rbac-checklist.md`: 도메인 없이 진행 가능한 수동 RBAC 설정 체크리스트

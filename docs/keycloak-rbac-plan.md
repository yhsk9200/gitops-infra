# Keycloak RBAC 설계 초안

이 문서는 Keycloak 내부 권한 모델을 GitOps로 자동화하기 전에 먼저 확정해 둘 기본 구조를 정리한 초안입니다.

## 현재 판단

- 지금은 도메인이 없으므로 SSO 최종 연동까지 진행하지 않습니다.
- realm, client, role, group 구조는 미리 설계할 수 있습니다.
- 실제 redirect URI와 issuer URL은 도메인 확정 후 채웁니다.
- 추적성을 위해 UI에서 수동 변경한 내용도 이 문서에 기록합니다.

## 권장 Realm

- Realm name: `platform`
- 목적: 플랫폼 공통 서비스의 인증/인가 기준점

초기에는 `master` realm을 운영자 로그인 외 용도로 확장하지 않는 편이 좋습니다.

## 권장 Client 초안

| Client ID | 용도 | 현재 단계 |
| --- | --- | --- |
| `grafana` | Grafana SSO 연동 | 도메인 확정 후 설정 |
| `platform-api` | 향후 API Gateway 또는 백엔드 API | 설계만 보류 |
| `platform-console` | 향후 운영 콘솔 UI | 설계만 보류 |

## 권장 Realm Role

| Role | 의미 |
| --- | --- |
| `platform-admin` | 플랫폼 전체 관리자 |
| `platform-operator` | 운영 작업 수행자 |
| `platform-viewer` | 조회 전용 사용자 |
| `service-admin` | 개별 서비스 관리자 |

## 권장 Group

| Group | 포함 Role |
| --- | --- |
| `platform-admins` | `platform-admin` |
| `platform-operators` | `platform-operator` |
| `platform-viewers` | `platform-viewer` |

## 서비스별 매핑 초안

| 서비스 | 필요한 Role | 비고 |
| --- | --- | --- |
| Grafana | `platform-admin`, `platform-operator`, `platform-viewer` | Grafana role mapping 검토 필요 |
| API Gateway | `platform-admin`, `platform-operator`, `platform-viewer` | 실제 API 권한 모델 확정 후 설계 |

## 도메인 확정 후 채워야 할 항목

- Keycloak external URL
- Client redirect URI
- Client web origin
- TLS 여부
- 각 서비스의 OIDC callback URL
- group/role claim 이름
- 서비스별 role mapping 방식

## 자동화 후보

반복 배포가 필요해지면 Bitnami Keycloak chart의 `keycloakConfigCli`를 검토합니다.

자동화 전에 먼저 합의할 것:

- realm 이름
- client ID 목록
- role 이름
- group 이름
- redirect URI 규칙
- 운영자 계정 생성 방식

현재 단계에서는 `docs/keycloak-manual-rbac-checklist.md`를 기준으로 수동 설정을 먼저 검증합니다. 이 체크리스트가 안정화되면 같은 내용을 `keycloakConfigCli` 설정으로 옮깁니다.

## 수동 변경 기록

Keycloak UI에서 수동 변경을 했다면 아래 표에 기록합니다.

| 날짜 | 작업자 | 변경 내용 | 비고 |
| --- | --- | --- | --- |
|  |  |  |  |

# Keycloak 수동 RBAC 설정 체크리스트

> **✅ 실행 완료 (2026-07-06)**: 본 체크리스트의 realm/role/group/user 전체와 §5에서 보류했던 `grafana` client까지 kcadm 스크립트로 생성 완료 (도메인 확정됨). 상세는 `keycloak-rbac-plan.md`의 수동 변경 기록 참조. 이 문서는 재구축 시 재사용할 절차 템플릿으로 유지한다.

이 문서는 도메인이 아직 없는 현재 단계에서 Keycloak 관리자 콘솔로 수동 생성할 수 있는 최소 RBAC 기준을 정리합니다.

목표는 SSO 최종 연동이 아니라, 나중에 Grafana/API 연동을 붙일 때 재사용할 수 있는 realm, role, group, test user의 기준점을 만드는 것입니다.

## 전제 조건

- Keycloak pod가 정상 기동되어 있습니다.
- 관리자 콘솔에 접속할 수 있습니다.
- 현재는 `kubectl port-forward` 기반으로 접속합니다.

```bash
kubectl port-forward -n platform-iam svc/platform-iam-keycloak 8080:80
```

```text
http://127.0.0.1:8080
```

관리자 계정:

- ID: `admin`
- Password: `keycloak-admin-secret`의 `admin-password`

## 1. Realm 생성

- [ ] 관리자 콘솔에 로그인한다.
- [ ] 좌측 상단 realm 선택 메뉴를 연다.
- [ ] `Create realm`을 선택한다.
- [ ] Realm name에 `platform`을 입력한다.
- [ ] realm을 생성한다.
- [ ] 생성 후 현재 realm이 `platform`인지 확인한다.

운영 기준:

- `master` realm은 Keycloak 관리자 운영 용도로만 사용한다.
- 플랫폼 서비스 SSO와 권한 관리는 `platform` realm에서 진행한다.

## 2. Realm Role 생성

`platform` realm에서 아래 realm role을 생성한다.

| Role | 용도 |
| --- | --- |
| `platform-admin` | 플랫폼 전체 관리자 |
| `platform-operator` | 운영 작업 수행자 |
| `platform-viewer` | 조회 전용 사용자 |
| `service-admin` | 개별 서비스 관리자 |

체크리스트:

- [ ] `platform-admin` role을 생성한다.
- [ ] `platform-operator` role을 생성한다.
- [ ] `platform-viewer` role을 생성한다.
- [ ] `service-admin` role을 생성한다.

주의:

- Role 이름은 소문자와 하이픈을 기준으로 유지한다.
- 서비스별 권한 매핑에서 이 이름을 재사용할 수 있으므로 임의 변경하지 않는다.

## 3. Group 생성

`platform` realm에서 아래 group을 생성한다.

| Group | 부여할 Role |
| --- | --- |
| `platform-admins` | `platform-admin` |
| `platform-operators` | `platform-operator` |
| `platform-viewers` | `platform-viewer` |

체크리스트:

- [ ] `platform-admins` group을 생성한다.
- [ ] `platform-admins` group에 `platform-admin` role을 부여한다.
- [ ] `platform-operators` group을 생성한다.
- [ ] `platform-operators` group에 `platform-operator` role을 부여한다.
- [ ] `platform-viewers` group을 생성한다.
- [ ] `platform-viewers` group에 `platform-viewer` role을 부여한다.

운영 기준:

- 사용자는 직접 role을 받기보다 group을 통해 role을 받는다.
- 예외적으로 긴급 계정에 직접 role을 줄 경우 변경 기록에 남긴다.

## 4. 테스트 사용자 생성

연동 전 검증을 위해 아래 테스트 사용자를 만든다.

| Username | Group | 목적 |
| --- | --- | --- |
| `platform-admin-test` | `platform-admins` | 관리자 권한 검증 |
| `platform-operator-test` | `platform-operators` | 운영자 권한 검증 |
| `platform-viewer-test` | `platform-viewers` | 조회 권한 검증 |

체크리스트:

- [ ] `platform-admin-test` 사용자를 생성한다.
- [ ] 임시 비밀번호를 설정한다.
- [ ] `platform-admins` group에 추가한다.
- [ ] `platform-operator-test` 사용자를 생성한다.
- [ ] 임시 비밀번호를 설정한다.
- [ ] `platform-operators` group에 추가한다.
- [ ] `platform-viewer-test` 사용자를 생성한다.
- [ ] 임시 비밀번호를 설정한다.
- [ ] `platform-viewers` group에 추가한다.

권장:

- 테스트 사용자는 운영 계정과 구분하기 위해 `-test` suffix를 유지한다.
- 초기 비밀번호는 임시값으로 두고, 첫 로그인 시 변경하도록 설정한다.

## 5. Client 생성은 보류

도메인이 확정되기 전에는 Grafana용 client 생성을 보류한다.

이유:

- Redirect URI가 도메인에 강하게 묶입니다.
- Issuer URL이 나중에 바뀌면 연동 서비스 설정도 같이 바뀝니다.
- 임시 URL 기준 client를 많이 만들면 운영 전환 때 정리 비용이 커집니다.

도메인 확정 후 생성할 client 후보:

| Client ID | 대상 서비스 |
| --- | --- |
| `grafana` | Grafana OAuth |
| `platform-api` | 향후 API Gateway |
| `platform-console` | 향후 운영 콘솔 |

## 6. 기본 검증

- [ ] `platform` realm이 존재한다.
- [ ] 네 개 realm role이 존재한다.
- [ ] 세 개 group이 존재한다.
- [ ] 각 group에 올바른 realm role이 연결되어 있다.
- [ ] 테스트 사용자가 각 group에 들어 있다.
- [ ] 테스트 사용자로 로그인할 수 있다.

## 7. 변경 기록

수동 변경 후 아래 내용을 `docs/keycloak-rbac-plan.md`의 수동 변경 기록 표에 남긴다.

- 변경 날짜
- 작업자
- 생성한 realm / role / group / user
- 특이사항

## 다음 단계

이 체크리스트가 한 번 검증되면, 이후 반복 배포를 위해 `keycloakConfigCli` 자동화 후보로 옮길 수 있습니다.

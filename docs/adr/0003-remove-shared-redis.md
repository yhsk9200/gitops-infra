# ADR-0003: 공용 Redis 제거 — Harbor는 internal Redis 유지

## 상태

승인됨

## 날짜

2026-06-10

## 맥락

`platform-db` 네임스페이스에 공용 Redis(`platform-db-redis`, bitnami chart standalone)를 배포해 두었으나, 실제 소비자가 없었다.

- Keycloak: Redis를 사용하지 않는다 (세션은 자체 관리, DB는 PostgreSQL).
- Harbor: chart 기본값인 **internal Redis**(`redis.type: internal`)를 사용 중이었다.

"공용 데이터 계층"을 표방하면서 정작 Redis가 필요한 유일한 컴포넌트(Harbor)가 자체 Redis를 쓰는 모순이 있었다. 후보 해법은 둘이었다.

1. Harbor를 공용 Redis로 전환 (`redis.type: external`) — external PostgreSQL과 같은 패턴
2. 공용 Redis를 제거하고 Harbor internal Redis를 유지

## 시도: Harbor external Redis 전환 (기각)

전환을 구현하고 `helm template` 렌더링 검증에서 차트 수준의 제약을 확인했다.

harbor chart(1.16.2)의 `redis.external.existingSecret`은 템플릿 헬퍼에서 helm `lookup` 함수로 클러스터의 Secret을 직접 읽어 Redis URL에 비밀번호를 **인라인**한다:

```text
harbor.redis.pwdfromsecret:
  (lookup "v1" "Secret" .Release.Namespace .Values.redis.external.existingSecret).data.REDIS_PASSWORD
```

`lookup`은 라이브 클러스터 연결이 있어야만 동작하고, `helm template`에서는 nil을 반환한다. **ArgoCD는 차트를 `helm template`으로 렌더링하므로**, 이 GitOps 구조에서 `existingSecret` 방식은 렌더링 단계에서 nil pointer로 실패한다 (core/jobservice/registry/trivy의 Redis URL Secret 생성 전부 해당).

남는 대안은 `redis.external.password`에 평문 비밀번호를 넣는 것뿐인데, 이는 "시크릿은 SealedSecret으로만 Git에 둔다"는 이 레포의 원칙에 위배되어 기각했다.

## 결정

1. **공용 Redis(`platform-db-redis`)를 제거한다.** 소비자가 없는 컴포넌트를 단일 노드의 한정된 자원 위에 유지하지 않는다.
   - 제거 대상: `apps/platform-db-redis.yaml`, `helm-values/database/redis-values.yaml`, `manifests/security/redis-sealed-secret.yaml`, `redis-pvc`
2. **Harbor는 internal Redis를 유지한다.** 캐시/작업큐 용도이므로 데이터 내구성 요구가 없고, chart가 자체 운영하는 구성이 GitOps 호환성 측면에서 가장 단순하다.

## 근거

- 빈 공용 컴포넌트는 자원·운영 표면만 늘리고 아무 가치도 주지 않는다.
- Harbor internal Redis는 휘발되어도 무방한 캐시 데이터만 가진다 (백업 대상 제외, 백업 런북 참조).
- GitOps 파이프라인과 호환되지 않는 구성(`lookup` 의존)을 우회 해킹으로 떠받치는 것보다, 차트가 지원하는 기본 경로를 쓰는 편이 유지보수 비용이 낮다.

## 재검토 조건

아래 중 하나가 충족되면 공용 Redis 재도입을 검토한다.

- Redis를 사용하는 두 번째 워크로드가 실제로 배포됨 (예: 향후 시뮬레이터 백엔드의 캐시/세션)
- harbor chart가 `lookup` 없이 환경변수/secretKeyRef 방식의 external Redis 비밀번호 주입을 지원

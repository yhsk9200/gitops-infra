# ADR-0006: Harbor 제거 — 컨테이너 레지스트리 오프클러스터화 (GHCR)

## 상태

승인됨

## 날짜

2026-07-02

## 맥락

클러스터 재구축(런북 Phase 3) 중 Harbor 전 컴포넌트가 CrashLoopBackOff로 기동에 실패했다. 원인은 로그로 즉시 확정됐다:

```text
exec /usr/bin/redis-server: exec format error   (redis-photon)
exec /usr/sbin/nginx: exec format error         (harbor-portal)
```

**아키텍처 불일치**다. 노드는 OCI Always Free Ampere A1(**arm64**)인데, 공식 `goharbor/*:v2.12.2` 이미지는 Docker Hub manifest 확인 결과 **amd64 단일 아치**로만 배포된다(manifest list 없음 — DB나 시크릿에 의존하지 않는 portal/redis까지 동일하게 실패한 것이 방증). `helm-values`에 이미지 오버라이드도 없었으므로, 현 구성으로는 이 노드에서 Harbor가 기동할 수 없다.

이 시점에 Harbor의 가치 제안을 재평가했다:

- **실수요 부재**: 현재 Harbor에 push하는 소비자가 없다. 유일한 예정 소비자는 AI 시뮬레이터(ADR-0001, 별도 레포)의 커스텀 이미지인데, 이 수요는 GHCR이 비용 0·운영부담 0으로 충족한다.
- **가치 제안 붕괴**: Trivy 스캐닝은 이미 ADR-0004로 비활성화됐다. 스캐닝 없는 Harbor는 사실상 Distribution 위의 무거운 UI다.
- **최중량 컴포넌트**: 파드 7개 + 전용 Redis + external PostgreSQL DB + 500Gi PVC 클레임 — free-tier 단일 노드에서 가장 뚱뚱한 워크로드였다.
- **원칙과의 정합**: 이 레포는 "GitHub = 상시 source-of-truth(오프사이트)" 원칙을 채택했다(코드·매니페스트). 이미지 저장을 GHCR에 두는 것은 같은 원칙의 자연스러운 확장이다.

## 검토한 대안

| 대안 | 기각 사유 |
|---|---|
| bitnami(legacy) Harbor 이미지로 오버라이드 | Broadcom 개편으로 bitnamilegacy는 동결 상태(업데이트 없음) — 동결된 이미지 위에 최중량 스택을 새로 얹는 것은 부채 확대 |
| 커뮤니티 arm64 빌드 (harbor-arm 등) | 공급망 신뢰·유지보수 리스크. 개인 인프라에서 감수할 이유가 없음 |
| QEMU 에뮬레이션 | 성능·복잡도 모두 비합리 |
| arm64 네이티브 대체(zot, Distribution) 즉시 도입 | 소비자가 없는 지금 도입하면 ADR-0003이 제거한 "빈 공용 컴포넌트"를 다시 만드는 것 |

## 결정

1. **Harbor를 제거한다.** 제거 대상: `apps/platform-registry-harbor.yaml`, `helm-values/registry/`, `manifests/security/harbor-sealed-secret.yaml`(3종), `platform-registry` 네임스페이스, AppProject sourceRepos의 `helm.goharbor.io`, CI 렌더링 잡, postgres initdb의 harbor 스크립트, `docs/harbor-push-pull-checklist.md`.
2. **컨테이너 이미지 저장은 GHCR을 기본으로 한다.** GitHub source-of-truth 원칙과 일관, 운영 부담 0.
3. **self-hosted 레지스트리가 실제로 필요해지면** arm64 네이티브 경량 대안(zot 우선 검토)을 `apps-ondemand/`로 도입한다 — 상시가 아닌 on-demand(ADR-0004 패턴).

## 근거

- ADR-0003과 같은 원칙: 소비자 없는 컴포넌트를 한정된 단일 노드 자원 위에 유지하지 않는다. Harbor 운영 역량의 증명은 프로덕션 경험이 담당하고, 이 레포는 **제약 하의 판단**을 기록한다.
- 아치 제약은 우회(커뮤니티 빌드·에뮬레이션)할수록 공급망·운영 리스크가 커진다. 제약을 수용하고 경계를 다시 긋는 쪽이 총비용이 낮다.
- 제거로 상시 메모리 추정치가 내려가 12GB worst-case 여유가 커진다(ADR-0004의 설계 여유 확대).

## 이행 메모 (2026-07-02 기준 잔여물)

- **postgres 고아 객체**: 제거 결정 직전 postgres가 initdb를 완료해 `harbor_admin` 롤과 `harbor_registry` DB가 현 PVC 세대에 존재한다. 무해하므로 즉시 정리하지 않고, 다음 재구축(빈 PVC) 때 자연 소멸한다. 수동 정리 시: `DROP DATABASE harbor_registry; DROP ROLE harbor_admin;`
- **postgres-db-secret의 고아 키**: 현 SealedSecret에 `harbor-password` 키가 남아 있다(어떤 컴포넌트도 참조하지 않음). 다음 reseal 때 2키(postgres-password, keycloak-password)로 재생성한다 — 런북 3.4는 이미 2키 기준으로 갱신됨.
- **백업 런북**: Harbor 절차가 무효화되어 문서 상단에 개정 필요 표기. 작업 3(백업 스크립트화) 때 전면 개정.

## 교훈

핀 고정한 이미지의 **아치 지원 검증이 컴포넌트 도입 체크리스트에 없었다**. 이번에 postgres/keycloak/os-shell은 Docker Hub manifest 조회로 arm64 지원을 수동 확인했다. 후속 개선 후보: CI에 "핀 고정 이미지 전수의 linux/arm64 manifest 존재 검증" 잡 추가.

## 재검토 조건

아래 중 하나가 충족되면 self-hosted 레지스트리(zot 등) 도입을 재검토한다.

- GHCR로 충족되지 않는 요구가 실제 발생 (private 저장 용량 한도, pull rate, 폐쇄망 요구 등)
- AI 시뮬레이터 플랫폼(ADR-0001)이 클러스터 내 레지스트리를 실질적으로 요구
- 노드가 amd64로 바뀌거나 Harbor가 공식 arm64 이미지를 배포 (이 경우에도 "실수요" 기준은 유지)

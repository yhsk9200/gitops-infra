# ADR-0007: 첫 제품 테넌트 온보딩 — `aporiax-pulse`

## 상태

승인됨

## 날짜

2026-07-07

## 맥락

ADR-0005는 "경계는 제품 단위로 긋는다"를 선언했지만 실제 테넌트는 아직 없었다. `aporiax-pulse`(라이브 플랫폼 상태 대시보드, 별도 레포)가 첫 사례다. 두 가지를 이 시점에 확정해야 했다: ① 제품 레포의 기술 스택, ② 플랫폼 레포가 제품 레포에게 실제로 얼마나 열어줄 것인가.

## 검토한 대안

### 스택: Go vs 주력 웹 스택(TypeScript/Next.js)

| 대안 | 기각/채택 사유 |
|---|---|
| Go | arm64 이미지가 가볍고(15MB급) DevOps 진영 표준이지만, 사용자의 주력 언어가 아니다. 이 테넌트는 **제품/프론트엔드**를 보여주는 자리 — 처음 쓰는 언어로는 시니어급 코드가 나오기 어려워 맞지 않는다 |
| TypeScript/Next.js (채택) | 주력 스택 — 프론트 품질 자체가 크래프트 증거가 된다. 이미지가 Go보다 무겁지만(~276MB vs 추정 15MB) free-tier 여유(~19Gi)에서 실익 없는 차이 |

### 제품 레포 내부 App-of-Apps 중첩 여부

| 대안 | 기각/채택 사유 |
|---|---|
| 제품 레포가 자체 root Application으로 자기 Application CR을 생성(중첩 App-of-Apps) | ArgoCD `AppProject.namespaceResourceWhitelist`는 **프로젝트 전체 단위**로만 적용되고 Application별로 좁힐 수 없다. `argoproj.io/Application` kind를 프로젝트에 한 번 허용하면, 그 프로젝트 아래 모든 Application(리프 웹앱 포함)이 새 Application을 만들 수 있게 되어 `spec.project`를 임의로 선언해 테넌트 경계를 탈출할 수 있다. 이 트레이드는 "실제로 신뢰 수준이 다른 별도 팀"이 있을 때만 값어치가 있다 — 단독 운영자에게는 불필요한 위험 |
| 제품 레포는 플랫폼의 기존 App-of-Apps에 리프 하나로 편입(채택) | `Application` kind를 whitelist에서 아예 제외 — 경계가 정책이 아니라 **구조적으로** 막힌다. 컴포넌트가 늘어나면 플랫폼 레포에 `apps/*.yaml` 한 줄 추가 — 몇 줄의 반복 비용으로 이 위험 전체를 없앤다 |
| `platform-infra` 프로젝트처럼 `destinations: "*"` + 전체 리소스 허용 | `platform-infra`는 단일 운영자의 한 신뢰 영역(레포 전체)이라 넓어도 안전하지만, 제품 레포는 **다른 레포·다른 소유 경계**이므로 같은 개방성을 적용하면 ADR-0005가 선언한 경계 자체가 무의미해진다 |

## 결정

1. **레포**: `aporiax-pulse` (TypeScript/Next.js, public), CI에 ADR-0006 교훈(arm64 manifest 검증)을 첫 커밋부터 내장.
2. **AppProject `product-pulse`**: `sourceRepos`는 해당 레포 1개만, `destinations`는 `product-pulse` 네임스페이스 1개만, `clusterResourceWhitelist` 없음(클러스터 리소스 전면 차단), `namespaceResourceWhitelist`는 ServiceAccount/Service/Deployment/Ingress 4종만 — `Application`(argoproj.io)은 목록에 없다.
3. **네임스페이스 `product-pulse`**: 플랫폼 레포가 생성(`manifests/namespaces/product-tenants.yaml`) — 테넌트가 자신의 네임스페이스를 스스로 만들지 않는다.
4. **argocd 네임스페이스로의 경계 교차 RBAC**(대시보드가 Application 상태를 읽기 위한 Role+RoleBinding)는 **플랫폼 레포가 소유·리뷰**한다(`manifests/argocd/product-pulse-read-access.yaml`). 제품 레포의 AppProject destinations에 argocd가 없으므로 테넌트 스스로는 이 권한을 요청할 수 없다 — 교차 경계 권한 부여는 항상 플랫폼 쪽의 명시적 PR로만 일어난다.
5. **제품 레포 내부에는 중첩 App-of-Apps를 두지 않는다.** `deploy/manifests/web`를 플랫폼의 기존 App-of-Apps(`apps/product-pulse-web.yaml`, wave 5)가 리프로 직접 가리킨다.

## 근거

- 경계가 "정책 위반을 감지"가 아니라 "애초에 리소스 종류가 존재하지 않아서 불가능"이 되도록 설계 — 검증 가능한 강한 경계.
- 단독 운영자 환경에서 팀 간 신뢰 분리는 실재하지 않는다. 셀프서비스 확장성(중첩 App-of-Apps)의 실제 수요자가 없는 상태에서 그 복잡도와 위험을 먼저 들이는 것은 ADR-0003/0006과 같은 원칙 위반("소비자 없는 컴포넌트를 먼저 만들지 않는다")이다.
- 컴포넌트 추가 비용(플랫폼 레포에 `apps/*.yaml` 한 파일)은 낮다 — 위험 제거 대비 트레이드가 명확히 남는다.

## 재검토 조건

- 실제로 신뢰 수준이 다른 두 번째 제품 팀/레포가 생겨 셀프서비스 컴포넌트 추가가 반복 비용으로 체감될 때 — 이때는 ArgoCD Applications-in-any-namespace + `sourceNamespaces` 기반의 정식 멀티테넌시 모델로 재설계.
- GHCR/Next.js 조합이 실제 운영 부담(이미지 크기, 콜드스타트 등)으로 문제가 될 때 — 이 시점에 스택 재평가.

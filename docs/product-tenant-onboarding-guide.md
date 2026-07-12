# 제품 테넌트 온보딩 가이드 — 앱을 이 플랫폼에 배포하기

> **대상 독자: 앱 레포에서 열린 Claude 세션.** 이 문서만 읽고 플랫폼 컨텍스트 없이 온보딩을 완주할 수 있도록 쓰였다. 사람이 직접 따라 해도 된다.
> 계약의 근거는 [ADR-0005](adr/0005-iac-layering-and-repo-strategy.md)(레포 경계)·[ADR-0007](adr/0007-first-product-tenant-onboarding.md)(테넌트 격리 패턴). 규범 예시는 첫 테넌트 **aporiax-pulse**의 실파일이며, 이 가이드의 템플릿은 전부 그 파일에서 추출했다.

## 0. 원칙 — 무엇이 어느 레포 몫인가

| | 소유 레포 | 이유 |
|---|---|---|
| 앱 코드·Dockerfile·CI(이미지 빌드/push)·**배포 매니페스트**(Deployment/Service/Ingress)·이미지 태그 범프 | **앱 레포** | 제품 수명주기는 플랫폼과 분리 (ADR-0005) |
| AppProject·네임스페이스·(필요시) 경계 넘는 RBAC·리프 Application | **gitops-infra** | 테넌트 경계는 플랫폼이 소유·리뷰 (ADR-0007) |

앱 세션은 Part A를 자기 레포에서 수행하고, Part B는 아래 템플릿으로 gitops-infra에 **기계적으로 PR 가능**하다(브랜치 보호 + CI kubeconform이 게이트). 단 §5 에스컬레이션 조건에 하나라도 걸리면 Part B는 플랫폼 세션에서 진행한다.

## 1. 하드 제약 (위반 시 배포 실패 또는 PR 거절)

- **arm64 필수.** 노드는 OCI Ampere(arm64) 단일 노드다. 이미지는 `linux/arm64` manifest가 있어야 하며, CI에 arm64 가드(§2.3)를 넣는다. amd64 전용 베이스 이미지로 Harbor를 통째로 들어냈던 전례가 [ADR-0006](adr/0006-remove-harbor-registry-off-cluster.md).
- **Git에 평문 시크릿 절대 금지.** k8s Secret은 SealedSecret만(§4).
- **replicas: 1.** 단일 노드라 다중 replica는 가용성 이득이 없다 (ADR-0002).
- **리소스 requests/limits 필수.** 기본 상한: `requests 50m/128Mi, limits 200m/256Mi` (pulse와 동일). 더 필요하면 §5.
- **stateless만 템플릿 온보딩.** PVC/DB가 필요하면 §5 — 백업 런북 범위가 바뀌는 문제라 플랫폼 결정이다.
- 레지스트리는 **GHCR** (`ghcr.io/yhsk9200/<app>`), 태그는 `sha-<git sha 12자>` 형식의 불변 태그. `latest` 금지.

## 2. Part A — 앱 레포에서 할 일

### 2.1 컨테이너화

- 헬스체크 가능한 HTTP 엔드포인트 1개(readiness/liveness가 때릴 경로, `/` 무방).
- Next.js면 `output: "standalone"` + 멀티스테이지 Dockerfile 권장(이미지 축소). 다른 스택은 관례대로 하되 최종 스테이지가 arm64에서 도는지만 보장.

### 2.2 배포 매니페스트 — `deploy/manifests/web/app.yaml`

규범 예시: [aporiax-pulse의 app.yaml](https://github.com/yhsk9200/aporiax-pulse/blob/main/deploy/manifests/web/app.yaml). 치환 규칙:

- 리소스 4종: ServiceAccount + Deployment + Service + Ingress, 전부 `namespace: product-<name>`.
- 이름은 전부 `product-<name>-web` 통일 (ArgoCD Application 이름과 일치).
- Ingress: host `<name>.aporiax.duckdns.org` — DuckDNS가 `*.aporiax.duckdns.org`를 같은 IP로 풀어주므로 **DNS 작업 불필요**, cert-manager 어노테이션(`cert-manager.io/cluster-issuer: letsencrypt-prod`) + `traefik.ingress.kubernetes.io/router.entrypoints: websecure`로 **TLS 자동 발급**(pulse에서 실증).
- probes(readiness+liveness) 필수, 리소스 상한은 §1 기본값.

### 2.3 CI — `.github/workflows/ci.yaml`

규범 예시: [aporiax-pulse의 ci.yaml](https://github.com/yhsk9200/aporiax-pulse/blob/main/.github/workflows/ci.yaml). 필수 잡:

1. 스택별 lint/typecheck/build
2. `kubeconform`으로 `deploy/manifests/**` 검증
3. PR: 빌드만(`push: false`, `platforms: linux/arm64`) / main push: GHCR push + **arm64 manifest 가드**(`docker buildx imagetools inspect`에 `linux/arm64` 없으면 실패)

브랜치 보호(권장): PR 필수 + required checks + enforce_admins — pulse·gitops-infra와 동일 레시피.

### 2.4 배포 플로우 (온보딩 후 반복되는 일상)

main 머지 → CI가 `sha-<12자>` 이미지 push → **별도 PR**로 `deploy/manifests/web/app.yaml`의 이미지 태그 범프 → 머지 → ArgoCD가 ~3분 내 auto-sync. **main 머지 = 배포**가 앱 레포에도 그대로 적용된다.

## 3. Part B — gitops-infra에 넣을 온보딩 매니페스트 (4곳)

`<name>` = 제품명(소문자), `<repo>` = `https://github.com/yhsk9200/<앱레포>.git`. 전부 한 PR로.

### 3.1 `apps/appproject-product-<name>.yaml`

[appproject-product-pulse.yaml](../apps/appproject-product-pulse.yaml)을 복사해 이름·`sourceRepos`·`destinations.namespace`만 치환. **주의: `clusterResourceWhitelist: []`와 `namespaceResourceWhitelist`(SA/Service/Deployment/Ingress 4종만)는 그대로 둔다** — 화이트리스트를 비우면 "전부 허용"이 되어 테넌트가 Application 리소스를 만들어 경계를 탈출할 수 있다(파일 내 주석이 canonical 설명).

### 3.2 `apps/product-<name>-web.yaml`

[product-pulse-web.yaml](../apps/product-pulse-web.yaml) 복사, 치환: `metadata.name`, `spec.project: product-<name>`, `source.repoURL: <repo>`, `source.path: deploy/manifests/web`, `destination.namespace: product-<name>`. sync-wave `"5"` 유지(플랫폼 뜬 뒤 제품).

### 3.3 `manifests/namespaces/product-tenants.yaml`에 추가

기존 파일에 `---`로 Namespace 문서 추가 (라벨 2종 포함, [기존 파일](../manifests/namespaces/product-tenants.yaml) 참조). `platform-infra-namespaces` 앱이 이 경로를 스캔한다.

### 3.4 RBAC — **기본은 없음**

기본 앱은 경계 넘는 권한이 필요 없다. pulse의 `manifests/argocd/product-pulse-read-access.yaml`은 대시보드라는 특수 목적의 **의도적 경계 관통**이며 플랫폼이 소유·리뷰한다. 필요하다고 판단되면 §5로.

## 4. 시크릿이 필요하면

1. 앱 세션은 **평문을 절대 레포·채팅에 넣지 않는다.** 사용자가 로컬에서 실행할 kubeseal 명령을 만들어 건넨다:
   ```bash
   kubectl create secret generic <name>-secret -n product-<name> \
     --from-literal=KEY=<평문은 사용자가 직접 입력> --dry-run=client -o yaml \
   | kubeseal --cert <gitops-infra>/pub-cert.pem -o yaml > deploy/manifests/web/<name>-sealed-secret.yaml
   ```
2. SealedSecret은 **앱 레포** `deploy/manifests/web/`에 커밋(테넌트 네임스페이스 리소스이므로). 단 AppProject 화이트리스트에 `bitnami.com/SealedSecret` 추가가 필요하다 → 이 한 줄은 gitops-infra 쪽 변경이라 Part B PR에 포함하고 사유를 남긴다.
3. 평문 원본은 비밀번호 관리자로 이관 후 로컬에서 삭제.

## 5. 에스컬레이션 — 플랫폼 세션(gitops-infra)으로 가져올 것

하나라도 해당하면 템플릿 온보딩이 아니다. 아래를 정리해 플랫폼 세션에 전달:

- **DB/PVC 등 stateful** — 공용 postgres에 DB 추가 + 백업 런북(`platform-backup-restore-runbook.md`, 현재 keycloak_db 단일 전제) 개정이 걸린다
- **리소스 기본 상한 초과** — 단일 노드 예산 조정 (worst-case 2 OCPU/12GB, ADR-0004)
- **경계 넘는 RBAC** (다른 네임스페이스 읽기 등)
- **비공개 서비스** (Ingress 없이 터널/tailnet 전용 — 노출 정책 결정 필요)
- **Keycloak SSO 연동** (realm client 추가는 IAM 운영 작업)

전달 양식(앱 세션이 출력해줄 것): 앱 이름 / 레포 URL / 요구사항(위 항목 중 무엇) / 리소스 추정 / 근거.

## 6. 온보딩 검증 체크리스트 (앱 세션이 완료 선언 전에 확인)

1. 두 PR(앱 레포 + gitops-infra) 모두 CI green 후 머지
2. gitops-infra 머지 후 ~3분 내: ArgoCD Application `product-<name>-web` **Synced/Healthy** — 확인 수단이 없으면 사용자에게 요청하거나, `https://pulse.aporiax.duckdns.org`의 ArgoCD Applications 패널에 새 앱이 초록 도트로 뜨는 것으로 갈음 가능
3. `https://<name>.aporiax.duckdns.org` — HTTP 200 + LE 인증서 (첫 발급 ~1분)
4. pulse의 Recent Deployments 피드에 온보딩 커밋이 보이면 GitOps 경로 전체가 증명된 것

## 7. 기록

- 2026-07-12 최초 작성 — pulse(ADR-0007) 온보딩 산출물에서 템플릿 추출. 두 번째 테넌트부터 이 가이드가 계약이며, 패턴이 바뀌면 ADR로 결정하고 이 문서를 갱신한다.

# platform-infra

대구테크노파크 제조데이터플랫폼 — 인프라 공용 컴포넌트 GitOps 저장소

## Getting started

To make it easy for you to get started with GitLab, here's a list of recommended next steps.

Already a pro? Just edit this README.md and make it your own. Want to make it easy? [Use the template at the bottom](#editing-this-readme)!

## Add your files

- [ ] [Create](https://docs.gitlab.com/ee/user/project/repository/web_editor.html#create-a-file) or [upload](https://docs.gitlab.com/ee/user/project/repository/web_editor.html#upload-a-file) files
- [ ] [Add files using the command line](https://docs.gitlab.com/ee/gitlab-basics/add-file.html#add-a-file-using-the-command-line) or push an existing Git repository with the following command:

```bash
cd existing_repo
git remote add origin https://gitlab.am.micube.dev/daegu-tp/mfg-data-platform/gitops/platform-infra.git
git branch -M main
git push -uf origin main
```

## Integrate with your tools

- [ ] [Set up project integrations](https://gitlab.am.micube.dev/daegu-tp/mfg-data-platform/gitops/platform-infra/-/settings/integrations)

## Collaborate with your team

- [ ] [Invite team members and collaborators](https://docs.gitlab.com/ee/user/project/members/)
- [ ] [Create a new merge request](https://docs.gitlab.com/ee/user/project/merge_requests/creating_merge_requests.html)
- [ ] [Automatically close issues from merge requests](https://docs.gitlab.com/ee/user/project/issues/managing_issues.html#closing-issues-automatically)
- [ ] [Enable merge request approvals](https://docs.gitlab.com/ee/user/project/merge_requests/approvals/)
- [ ] [Set auto-merge](https://docs.gitlab.com/ee/user/project/merge_requests/merge_when_pipeline_succeeds.html)

---

# 프로젝트 상세 아키텍처 및 구조 (App of Apps)

이 저장소는 ArgoCD **App of Apps** 패턴을 사용하여 플랫폼 인프라 공용 컴포넌트들을 선언적으로 관리합니다.
엔터프라이즈 환경의 베스트 프랙티스(네임스페이스 격리, Sync Wave 등)를 적용하여 설계되었습니다.

## 1. 아키텍처 및 배포 흐름 (Sync Waves)

```text
┌─────────────────────────────────────────────────────────────────┐
│                    ArgoCD (argocd 네임스페이스)                     │
│                                                                 │
│  platform-root-infra (Root App)                                │
│  └─ path: apps/ ──────────────────────────────────────────┐    │
│                                                            │    │
│  ┌─────────────── Sync Wave 배포 순서 ────────────────────┐  │    │
│  │                                                      │  │    │
│  │  Wave -3: platform-infra-namespaces (NS 일괄 생성)      │  │    │
│  │  Wave -2: platform-system-sealed-secrets (Controller)│  │    │
│  │  Wave -1: platform-infra-secrets (SealedSecrets)     │  │    │
│  │  Wave  0: platform-infra-storage, cert-manager       │  │    │
│  │  Wave  1: platform-db-postgres, platform-db-redis    │  │    │
│  │  Wave  2: platform-iam-keycloak                      │  │    │
│  │  Wave  3: platform-monitoring-prometheus             │  │    │
│  │  Wave  4: platform-registry-harbor                   │  │    │
│  │                                                      │  │    │
│  └──────────────────────────────────────────────────────┘  │    │
└─────────────────────────────────────────────────────────────────┘
```

## 2. 도메인별 네임스페이스 분리

보안 및 리소스 관리 효율을 위해 워크로드 특성별로 네임스페이스를 분리하여 운영합니다.

| 네임스페이스      | 용도            | 배포 리소스                                     |
| ----------------- | --------------- | ----------------------------------------------- |
| `platform-system` | 시스템 컴포넌트 | Sealed Secrets Controller, Cert-Manager         |
| `platform-db`     | 데이터베이스    | PostgreSQL, Redis, 관련 Secret 및 PV/PVC        |
| `platform-iam`    | 인증/인가       | Keycloak, 관련 Secret (`keycloak-db-secret` 등) |
| `platform-monitoring` | 관측 시스템  | Prometheus, Grafana, Alertmanager, Node Exporter|
| `platform-registry`   | 이미지/차트 저장 | Harbor Container Registry, Trivy 스캐너          |

## 3. 디렉토리 구조 상세

```text
platform-infra/
├── bootstrap/                              # ArgoCD 부트스트랩 (클러스터 최초 1회 수동 적용)
│   ├── platform-root-infra.yaml           # Root Application (App of Apps 진입점)
│   └── platform-project.yaml              # 인프라 전용 AppProject (RBAC 및 권한 통제)
│
├── apps/                                   # 자식 Application 리소스
│   ├── platform-infra-namespaces.yaml     # 네임스페이스 자동 배포
│   ├── platform-system-sealed-secrets.yaml
│   ├── platform-system-cert-manager.yaml  # Cert-Manager 배포
│   ├── platform-infra-secrets.yaml
│   ├── platform-infra-storage.yaml
│   ├── platform-db-postgres.yaml
│   ├── platform-db-redis.yaml
│   ├── platform-iam-keycloak.yaml
│   ├── platform-monitoring-prometheus.yaml # Kube-Prometheus-Stack 배포
│   └── platform-registry-harbor.yaml      # Harbor 배포
│
├── manifests/                              # K8s 순수 매니페스트 리소스
│   ├── namespaces/                        # 네임스페이스 선언
│   ├── security/                          # SealedSecret 리소스 모음
│   │   ├── keycloak-*-secret.yaml         # Keycloak용 시크릿
│   │   ├── postgres/redis-*-secret.yaml   # DB용 시크릿
│   │   ├── grafana-sealed-secret.yaml     # Grafana 관리자용 시크릿
│   │   └── harbor-sealed-secret.yaml      # Harbor 관리자 및 내부 통신용 코어 시크릿
│   └── storage/                           # PV/PVC
│
└── helm-values/                            # Helm Chart 커스텀 Values
    ├── database/
    │   ├── postgres/redis-values.yaml
    ├── iam/
    │   ├── keycloak-values-*.yaml
    ├── monitoring/
    │   └── kube-prometheus-stack-values.yaml
    ├── registry/
    │   └── harbor-values.yaml
    └── system/
        └── sealed-secrets-values.yaml
```

## 4. 필수 작업: SealedSecret 재암호화 안내

본 프로젝트의 SealedSecret은 네임스페이스 변경을 방지하는 **`strict` scope**로 암호화되어 있습니다. 기존(`default` 등)에서 전용 네임스페이스(`platform-db`, `platform-iam`)로 설계를 변경함에 따라 **클러스터 배포 전 반드시 재암호화**가 필요합니다.

### 재암호화 절차

```bash
# 1. Sealed Secrets Controller의 퍼블릭 인증서 추출 (설치된 클러스터에서)
kubeseal --fetch-cert \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=platform-system \
  > pub-cert.pem

# 2. PostgreSQL 암호화 (Namespace: platform-db)
kubectl create secret generic postgres-db-secret \
  --namespace=platform-db \
  --from-literal=postgres-password='비밀번호' \
  --from-literal=keycloak-password='비밀번호' \
  --dry-run=client -o yaml | \
  kubeseal --cert pub-cert.pem --format=yaml > manifests/security/postgres-sealed-secret.yaml

# 3. Redis 암호화 (Namespace: platform-db)
kubectl create secret generic redis-secret \
  --namespace=platform-db \
  --from-literal=redis-password='비밀번호' \
  --dry-run=client -o yaml | \
  kubeseal --cert pub-cert.pem --format=yaml > manifests/security/redis-sealed-secret.yaml

# 4. Keycloak 관리자 암호화 (Namespace: platform-iam)
kubectl create secret generic keycloak-admin-secret \
  --namespace=platform-iam \
  --from-literal=admin-password='비밀번호' \
  --dry-run=client -o yaml | \
  kubeseal --cert pub-cert.pem --format=yaml > manifests/security/keycloak-sealed-secret.yaml

# 5. Keycloak용 DB 연결 암호화 (Namespace: platform-iam)
kubectl create secret generic keycloak-db-secret \
  --namespace=platform-iam \
  --from-literal=keycloak-password='비밀번호' \
  --dry-run=client -o yaml | \
  kubeseal --cert pub-cert.pem --format=yaml > manifests/security/keycloak-db-sealed-secret.yaml

# 6. Grafana 관리자 암호화 (Namespace: platform-monitoring)
kubectl create secret generic grafana-admin-secret \
  --namespace=platform-monitoring \
  --from-literal=admin-user='admin' \
  --from-literal=admin-password='비밀번호' \
  --dry-run=client -o yaml | \
  kubeseal --cert pub-cert.pem --format=yaml > manifests/security/grafana-sealed-secret.yaml

# 7. Harbor 관련 비밀번호 암호화 (Namespace: platform-registry)
# (관리자 비밀번호, 내부 통신 코어 키 16자리, 자체 Postgres 비밀번호 등)
kubectl create secret generic harbor-admin-secret \
  --namespace=platform-registry \
  --from-literal=admin-password='비밀번호' \
  --dry-run=client -o yaml | \
  kubeseal --cert pub-cert.pem --format=yaml > manifests/security/harbor-sealed-secret.yaml
# (나머지 core 키와 db 비밀번호는 harbor-sealed-secret.yaml 주석 참조하여 덧붙이기)
```

## 5. 클러스터 적용 가이드

모든 재암호화가 끝났다면 다음 명령어를 통해 최초 1회 부트스트랩을 실행합니다.

```bash
kubectl apply -f bootstrap/platform-root-infra.yaml
```

이후 ArgoCD는 `apps/` 폴더 내의 Application 명세(Sync Wave)에 따라 Namespace → Controller → Secret → Storage → DB → IAM 순으로 안전하게 배포 의존성을 보장하며 구성됩니다.

## 6. 컴포넌트 버전 정보

| 컴포넌트       | 차트/이미지                  | 버전    |
| -------------- | ---------------------------- | ------- |
| PostgreSQL     | bitnami/postgresql           | 18.5.19 |
| Redis          | bitnami/redis                | 25.3.11 |
| Keycloak       | bitnami/keycloak             | 25.2.0  |
| Sealed Secrets | bitnami/sealed-secrets       | 2.18.4  |
| Cert-Manager   | jetstack/cert-manager        | v1.17.0 |
| Prometheus Stack| prometheus-community       | 83.6.0  |
| Harbor         | goharbor/harbor              | 1.16.2  |

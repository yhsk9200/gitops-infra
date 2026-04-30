# Platform Backup/Restore Runbook

이 문서는 현재 플랫폼 인프라의 백업/복구 기준을 정리합니다.

현재 단계에서는 백업 저장소, 보관 기간, 암호화 방식이 아직 확정되지 않았으므로 Kubernetes `CronJob`을 바로 추가하지 않습니다. 우선 수동 백업 절차를 검증하고, 이후 같은 절차를 자동화 대상으로 전환합니다.

## 1. 백업 대상

| 우선순위 | 대상 | 위치 | 백업 방식 |
| --- | --- | --- | --- |
| 1 | PostgreSQL `keycloak_db` | `platform-db` | `pg_dump` |
| 1 | PostgreSQL `harbor_registry` | `platform-db` | `pg_dump` |
| 1 | Harbor registry 파일 | `platform-registry` PVC | PVC 또는 node local-path 파일 백업 |
| 1 | Sealed Secrets controller key | `platform-system` | Secret YAML 보안 보관 |
| 2 | GitOps 저장소 | GitLab | 원격 저장소와 별도 mirror |
| 2 | Grafana/Loki 데이터 | `platform-monitoring` | 필요 시 PVC 백업 |
| 3 | Redis | `platform-db` | 현재는 캐시 성격, 필요 시 별도 검토 |

## 2. 백업 기본 원칙

- DB와 파일이 함께 필요한 서비스는 가능한 같은 점검 시간대에 백업합니다.
- Harbor는 DB 메타데이터와 registry 파일이 함께 맞아야 합니다.
- 복구 테스트를 하지 않은 백업은 운영 백업으로 간주하지 않습니다.
- `SealedSecret` 리소스만으로는 전체 복구가 보장되지 않습니다. 기존 `SealedSecret`을 다시 복호화하려면 Sealed Secrets controller private key가 필요합니다.
- local-path PVC는 노드 로컬 디스크에 묶이므로, 노드 장애까지 고려하려면 외부 저장소로 복사해야 합니다.

## 3. 사전 확인

```bash
kubectl get application -n argocd
kubectl get pods -n platform-db -o wide
kubectl get pods -n platform-iam -o wide
kubectl get pods -n platform-registry -o wide
kubectl get pvc -A
```

PostgreSQL pod 이름 확인:

```bash
kubectl get pods -n platform-db | grep postgres
```

예상 pod:

```text
platform-db-postgres-postgresql-0
```

## 4. 백업 디렉토리 준비

운영자가 백업을 실행하는 서버에서 아래처럼 작업 디렉토리를 만듭니다.

```bash
BACKUP_DATE="$(date +%Y%m%d-%H%M%S)"
BACKUP_ROOT="$HOME/platform-backups/$BACKUP_DATE"
mkdir -p "$BACKUP_ROOT"
```

## 5. PostgreSQL 백업

현재 PostgreSQL은 `platform-db` 네임스페이스의 Bitnami PostgreSQL chart로 배포됩니다.

백업 대상 DB:

- `keycloak_db`
- `harbor_registry`

### 5.1 DB 목록 확인

```bash
POSTGRES_PASSWORD="$(kubectl get secret postgres-db-secret -n platform-db -o jsonpath='{.data.postgres-password}' | base64 -d)"

kubectl exec -n platform-db platform-db-postgres-postgresql-0 -c postgresql -- \
  env PGPASSWORD="$POSTGRES_PASSWORD" \
  psql -U postgres -d postgres -c "\l"
```

### 5.2 Keycloak DB 백업

```bash
kubectl exec -n platform-db platform-db-postgres-postgresql-0 -c postgresql -- \
  env PGPASSWORD="$POSTGRES_PASSWORD" \
  pg_dump -U postgres -d keycloak_db -Fc \
  > "$BACKUP_ROOT/keycloak_db.dump"
```

### 5.3 Harbor DB 백업

```bash
kubectl exec -n platform-db platform-db-postgres-postgresql-0 -c postgresql -- \
  env PGPASSWORD="$POSTGRES_PASSWORD" \
  pg_dump -U postgres -d harbor_registry -Fc \
  > "$BACKUP_ROOT/harbor_registry.dump"
```

백업이 끝나면 로컬 shell 변수에서 비밀번호를 제거합니다.

```bash
unset POSTGRES_PASSWORD
```

### 5.4 백업 파일 확인

```bash
ls -lh "$BACKUP_ROOT"
file "$BACKUP_ROOT/keycloak_db.dump"
file "$BACKUP_ROOT/harbor_registry.dump"
```

## 6. Harbor registry 파일 백업

Harbor는 external PostgreSQL을 사용하지만, 실제 이미지 layer는 Harbor registry PVC에 저장됩니다.

현재 values 기준:

- Namespace: `platform-registry`
- PVC: `platform-registry-harbor-registry`
- StorageClass: `local-path`

### 6.1 PVC와 PV 확인

```bash
kubectl get pvc -n platform-registry
PV_NAME="$(kubectl get pvc platform-registry-harbor-registry -n platform-registry -o jsonpath='{.spec.volumeName}')"
echo "$PV_NAME"
kubectl get pv "$PV_NAME" -o yaml
```

local-path 물리 경로 확인:

```bash
kubectl get pv "$PV_NAME" -o jsonpath='{.spec.hostPath.path}{"\n"}'
```

### 6.2 백업 전 쓰기 중지

Harbor registry 파일 백업은 이미지 push가 없는 점검 시간에 수행합니다.

권장 순서:

1. 외부 push 작업을 중지합니다.
2. Harbor UI와 API 사용자를 잠시 차단합니다.
3. 필요하면 ArgoCD에서 `platform-registry-harbor` 자동 동기화를 임시 중지합니다.
4. Harbor 관련 pod가 재기동되지 않는 상태에서 DB와 registry 파일을 같은 시점에 백업합니다.

주의:

- ArgoCD self-heal이 켜져 있으면 임의 scale-down이 되돌아갈 수 있습니다.
- 복구나 긴 백업 작업이 필요하면 ArgoCD UI에서 자동 동기화를 잠시 끄고 작업합니다.

### 6.3 node local-path 백업

아래 명령은 Harbor registry PV가 붙어 있는 노드에서 실행합니다.

```bash
PV_NAME="$(kubectl get pvc platform-registry-harbor-registry -n platform-registry -o jsonpath='{.spec.volumeName}')"
PV_PATH="$(kubectl get pv "$PV_NAME" -o jsonpath='{.spec.hostPath.path}')"
echo "$PV_PATH"
sudo tar -C "$PV_PATH" -czf "$BACKUP_ROOT/harbor-registry-files.tgz" .
```

백업 파일 확인:

```bash
ls -lh "$BACKUP_ROOT/harbor-registry-files.tgz"
tar -tzf "$BACKUP_ROOT/harbor-registry-files.tgz" | head
```

## 7. Sealed Secrets controller key 백업

이 백업은 매우 민감합니다. 유출되면 저장소의 `SealedSecret`을 복호화할 수 있습니다.

```bash
kubectl get secret -n platform-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > "$BACKUP_ROOT/sealed-secrets-controller-keys.yaml"
```

권장:

- 이 파일은 평문 상태로 장기 보관하지 않습니다.
- 별도 암호화 저장소, 보안 USB, 또는 내부 보안 파일 서버에 보관합니다.
- Git 저장소에는 커밋하지 않습니다.

## 8. GitOps 저장소 백업

GitLab이 주 저장소이지만, 재해복구 관점에서는 별도 mirror가 있으면 좋습니다.

```bash
git clone --mirror https://gitlab.am.micube.dev/daegu-tp/mfg-data-platform/gitops/platform-infra.git platform-infra.git
tar -czf "$BACKUP_ROOT/platform-infra-git-mirror.tgz" platform-infra.git
```

## 9. 복구 기본 순서

전체 복구는 아래 순서로 진행합니다.

1. Kubernetes 클러스터와 StorageClass를 준비합니다.
2. Sealed Secrets controller를 먼저 복구합니다.
3. 기존 Sealed Secrets controller key를 복구합니다.
4. `bootstrap/platform-root-infra.yaml`을 적용합니다.
5. PostgreSQL을 복구합니다.
6. Harbor registry 파일을 복구합니다.
7. Keycloak, Harbor를 순서대로 기동합니다.
8. UI 접속, 로그인, Harbor push/pull을 검증합니다.

## 10. PostgreSQL 복구

복구는 파괴적인 작업입니다. 반드시 점검 시간에 수행하고, 대상 앱을 먼저 중지합니다.

### 10.1 앱 쓰기 중지

Keycloak과 Harbor를 사용하는 작업을 중지합니다.

필요 시 ArgoCD에서 아래 앱의 자동 동기화를 임시 중지합니다.

- `platform-iam-keycloak`
- `platform-registry-harbor`

### 10.2 Keycloak DB 복구

```bash
POSTGRES_PASSWORD="$(kubectl get secret postgres-db-secret -n platform-db -o jsonpath='{.data.postgres-password}' | base64 -d)"

kubectl exec -i -n platform-db platform-db-postgres-postgresql-0 -c postgresql -- \
  env PGPASSWORD="$POSTGRES_PASSWORD" \
  pg_restore -U postgres -d keycloak_db --clean --if-exists \
  < "$BACKUP_ROOT/keycloak_db.dump"
```

### 10.3 Harbor DB 복구

```bash
kubectl exec -i -n platform-db platform-db-postgres-postgresql-0 -c postgresql -- \
  env PGPASSWORD="$POSTGRES_PASSWORD" \
  pg_restore -U postgres -d harbor_registry --clean --if-exists \
  < "$BACKUP_ROOT/harbor_registry.dump"
```

복구가 끝나면 로컬 shell 변수에서 비밀번호를 제거합니다.

```bash
unset POSTGRES_PASSWORD
```

## 11. Harbor registry 파일 복구

Harbor registry PVC를 비운 뒤 백업 파일을 되돌립니다.

주의:

- DB와 registry 파일 백업 시점이 다르면 Harbor UI에는 메타데이터가 있는데 실제 blob이 없거나, 반대로 파일은 있는데 DB에 repository가 없는 상태가 될 수 있습니다.
- 가능하면 Harbor DB와 registry 파일은 같은 점검 시간에 백업하고 같은 세트로 복구합니다.

예시:

```bash
PV_NAME="$(kubectl get pvc platform-registry-harbor-registry -n platform-registry -o jsonpath='{.spec.volumeName}')"
PV_PATH="$(kubectl get pv "$PV_NAME" -o jsonpath='{.spec.hostPath.path}')"
echo "$PV_PATH"
sudo tar -C "$PV_PATH" -xzf "$BACKUP_ROOT/harbor-registry-files.tgz"
```

## 12. 복구 후 검증

### 12.1 ArgoCD 상태

```bash
kubectl get application -n argocd
```

정상 기준:

- 주요 앱이 `Healthy`입니다.
- Harbor는 known diff로 인해 `Healthy + OutOfSync`일 수 있습니다.

### 12.2 Keycloak 검증

```bash
kubectl get pods -n platform-iam -o wide
kubectl logs -n platform-iam statefulset/platform-iam-keycloak --tail=200
kubectl port-forward -n platform-iam svc/platform-iam-keycloak 8080:80
```

브라우저:

```text
http://127.0.0.1:8080
```

정상 기준:

- 관리자 콘솔에 로그인할 수 있습니다.
- realm, client, role, group 설정이 유지되어 있습니다.

### 12.3 Harbor 검증

```bash
kubectl get pods -n platform-registry -o wide
kubectl get configmap platform-registry-harbor-core -n platform-registry -o yaml | grep EXT_ENDPOINT
curl -I http://harbor.210.113.225.245.nip.io
docker login harbor.210.113.225.245.nip.io
docker pull harbor.210.113.225.245.nip.io/library/busybox:push-test
```

정상 기준:

- Harbor UI에 접속할 수 있습니다.
- 기존 project, repository, tag가 보입니다.
- 기존 이미지를 pull 할 수 있습니다.

## 13. 자동화 전환 TODO

아래가 결정되면 백업 `CronJob` 또는 외부 백업 도구로 자동화합니다.

- 백업 저장 위치: NFS, S3 호환 스토리지, NAS, 외부 백업 서버 중 선택
- 보관 기간: 예: 일 7개, 주 4개, 월 6개
- 암호화 방식: 파일 단위 암호화 또는 저장소 암호화
- 백업 성공/실패 알림 채널
- 복구 리허설 주기

자동화 후보:

- PostgreSQL `pg_dump` CronJob
- Harbor registry PVC 백업 Job
- Sealed Secrets controller key 보안 백업 절차
- GitLab mirror 또는 scheduled export

## 14. 검증 기록

| 날짜 | 작업자 | 백업 대상 | 백업 결과 | 복구 리허설 결과 | 비고 |
| --- | --- | --- | --- | --- | --- |
|  |  |  |  |  |  |

# Platform Backup/Restore Runbook

이 문서는 현재 단일 k3s 클러스터와 망분리 NAS 조건에서 현실적으로 운영 가능한 백업/복구 기준을 정리합니다.

현재 단계에서는 NAS와 k3s 서버가 완전히 별도 망에 있으므로 NAS 자동 반출, NFS mount, 백업 전용 gateway, Kubernetes `CronJob` 기반 원격 백업은 바로 도입하지 않습니다.

1차 정책은 아래처럼 정의합니다.

```text
로컬 백업 세트 생성 + checksum/manifest 검증 + 수동 NAS 반출
```

이 방식은 완전한 재해복구 자동화는 아니지만, 지금 환경에서 과한 기술 도입 없이 백업 신뢰도를 올리는 현실적인 타협안입니다.

## 1. 현재 백업 정책

| 항목 | 정책 |
| --- | --- |
| 백업 실행 위치 | k3s 서버 |
| 1차 저장 위치 | k3s 서버 로컬 디스크 |
| 2차 저장 위치 | 망분리 Synology NAS |
| NAS 반출 방식 | 수동 반출 |
| 자동화 범위 | 로컬 백업 세트 생성, checksum 생성, 기본 검증 |
| 자동화 보류 | NAS 자동 전송, Kubernetes CronJob, NFS/SMB PV mount |
| 복구 리허설 | 초기 1회, 이후 분기 1회 또는 주요 변경 후 |

운영 백업으로 인정하려면 최소한 아래 조건을 만족해야 합니다.

- PostgreSQL dump가 생성되어 있습니다.
- Harbor registry 파일 백업이 생성되어 있습니다.
- Sealed Secrets controller key가 포함되어 있습니다.
- 백업 시점의 Git commit이 기록되어 있습니다.
- `manifest.yaml`이 포함되어 있습니다.
- `checksums.sha256` 검증이 성공합니다.
- 백업 세트가 클러스터 외부 저장소로 반출되었습니다.

## 2. 백업 대상

| 우선순위 | 대상 | 위치 | 백업 방식 |
| --- | --- | --- | --- |
| 1 | PostgreSQL `keycloak_db` | `platform-db` | `pg_dump -Fc` |
| 1 | PostgreSQL `harbor_registry` | `platform-db` | `pg_dump -Fc` |
| 1 | Harbor registry 파일 | `platform-registry` PVC | node local-path tar |
| 1 | Sealed Secrets controller key | `platform-system` | Secret YAML 보안 보관 |
| 1 | 백업 manifest/checksum | 백업 세트 | YAML, SHA256 |
| 2 | GitOps 저장소 기준점 | GitHub | commit hash 기록 |
| 2 | Grafana/Loki 데이터 | `platform-monitoring` | 필요 시 별도 검토 |
| 3 | Harbor internal Redis | `platform-registry` | 캐시 성격, 백업 제외 (ADR-0003) |

## 3. 백업 기본 원칙

- 같은 클러스터 내부에만 있는 백업은 임시 백업입니다.
- 운영 백업은 클러스터 장애와 분리된 저장소로 반출되어야 합니다.
- Harbor는 DB 메타데이터와 registry 파일이 함께 맞아야 합니다.
- Sealed Secrets controller key가 없으면 기존 `SealedSecret`을 새 클러스터에서 복호화할 수 없습니다.
- 복구 테스트를 하지 않은 백업은 신뢰할 수 없습니다.
- 처음부터 완전 자동화를 목표로 하지 않습니다. 사람이 이해하고 반복할 수 있는 절차를 먼저 고정합니다.

## 4. 백업 세트 구조

백업은 단일 파일이 아니라 하나의 디렉토리 세트로 관리합니다.

```text
/opt/platform-backups/
└── 20260504-020000/
    ├── manifest.yaml
    ├── checksums.sha256
    ├── postgres/
    │   ├── keycloak_db.dump
    │   └── harbor_registry.dump
    ├── harbor/
    │   └── registry-files.tgz
    ├── sealed-secrets/
    │   └── sealed-secrets-controller-keys.yaml
    └── gitops/
        └── platform-infra-commit.txt
```

주의:

- `sealed-secrets-controller-keys.yaml`은 매우 민감한 파일입니다.
- 수동 NAS 반출 시에는 별도 암호화 보관을 권장합니다.
- 이 파일은 Git 저장소에 커밋하지 않습니다.

## 5. 사전 확인

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

Harbor registry PVC 확인:

```bash
kubectl get pvc -n platform-registry
```

예상 PVC:

```text
platform-registry-harbor-registry
```

## 6. 백업 디렉토리 준비

k3s 서버에서 실행합니다.

```bash
BACKUP_DATE="$(date +%Y%m%d-%H%M%S)"
BACKUP_ROOT="/opt/platform-backups/$BACKUP_DATE"
sudo mkdir -p "$BACKUP_ROOT"/{postgres,harbor,sealed-secrets,gitops}
sudo chown -R "$USER":"$USER" "$BACKUP_ROOT"
```

백업 기준 commit을 기록합니다.

```bash
git -C /opt/platform-infra rev-parse HEAD > "$BACKUP_ROOT/gitops/platform-infra-commit.txt"
```

주의:

- 위 명령은 k3s 서버의 GitOps checkout 경로가 `/opt/platform-infra`인 경우입니다.
- 실제 경로가 다르면 `git -C` 경로를 환경에 맞게 수정합니다.

## 7. PostgreSQL 백업

현재 PostgreSQL은 `platform-db` 네임스페이스의 Bitnami PostgreSQL chart로 배포됩니다.

백업 대상 DB:

- `keycloak_db`
- `harbor_registry`

### 7.1 DB 목록 확인

```bash
POSTGRES_PASSWORD="$(kubectl get secret postgres-db-secret -n platform-db -o jsonpath='{.data.postgres-password}' | base64 -d)"

kubectl exec -n platform-db platform-db-postgres-postgresql-0 -c postgresql -- \
  env PGPASSWORD="$POSTGRES_PASSWORD" \
  psql -U postgres -d postgres -c "\l"
```

### 7.2 Keycloak DB 백업

```bash
kubectl exec -n platform-db platform-db-postgres-postgresql-0 -c postgresql -- \
  env PGPASSWORD="$POSTGRES_PASSWORD" \
  pg_dump -U postgres -d keycloak_db -Fc \
  > "$BACKUP_ROOT/postgres/keycloak_db.dump"
```

### 7.3 Harbor DB 백업

```bash
kubectl exec -n platform-db platform-db-postgres-postgresql-0 -c postgresql -- \
  env PGPASSWORD="$POSTGRES_PASSWORD" \
  pg_dump -U postgres -d harbor_registry -Fc \
  > "$BACKUP_ROOT/postgres/harbor_registry.dump"
```

백업이 끝나면 로컬 shell 변수에서 비밀번호를 제거합니다.

```bash
unset POSTGRES_PASSWORD
```

### 7.4 DB 백업 파일 확인

```bash
ls -lh "$BACKUP_ROOT/postgres"
file "$BACKUP_ROOT/postgres/keycloak_db.dump"
file "$BACKUP_ROOT/postgres/harbor_registry.dump"
kubectl exec -i -n platform-db platform-db-postgres-postgresql-0 -c postgresql -- \
  pg_restore --list \
  < "$BACKUP_ROOT/postgres/keycloak_db.dump" \
  > /dev/null
kubectl exec -i -n platform-db platform-db-postgres-postgresql-0 -c postgresql -- \
  pg_restore --list \
  < "$BACKUP_ROOT/postgres/harbor_registry.dump" \
  > /dev/null
```

정상 기준:

- dump 파일 크기가 0이 아닙니다.
- `pg_restore --list`가 실패하지 않습니다.

## 8. Harbor registry 파일 백업

Harbor는 external PostgreSQL을 사용하지만 실제 image layer는 registry PVC에 저장됩니다.

현재 values 기준:

- Namespace: `platform-registry`
- PVC: `platform-registry-harbor-registry`
- StorageClass: `local-path`

### 8.1 백업 전 쓰기 중지

Harbor registry 파일 백업은 image push가 없는 시간대에 수행합니다.

권장 운영:

1. 백업 시간대에는 Harbor push 작업을 중지합니다.
2. 가능하면 Harbor UI/API 사용을 잠시 제한합니다.
3. DB dump와 registry 파일 백업을 같은 백업 세트에 넣습니다.
4. 긴 작업이 예상될 때만 ArgoCD 자동 동기화 임시 중지를 검토합니다.

주의:

- ArgoCD self-heal이 켜져 있으면 임의 scale-down이 되돌아갈 수 있습니다.
- 초기 1차 정책에서는 Harbor scale-down까지 강제하지 않습니다.
- 대신 push가 없는 조용한 시간대에 백업하는 것을 기본으로 합니다.

### 8.2 PV 물리 경로 확인

```bash
PV_NAME="$(kubectl get pvc platform-registry-harbor-registry -n platform-registry -o jsonpath='{.spec.volumeName}')"
PV_PATH="$(kubectl get pv "$PV_NAME" -o jsonpath='{.spec.hostPath.path}')"
echo "$PV_NAME"
echo "$PV_PATH"
```

### 8.3 registry 파일 백업

아래 명령은 Harbor registry PV가 붙어 있는 노드에서 실행합니다.

```bash
sudo tar -C "$PV_PATH" -czf "$BACKUP_ROOT/harbor/registry-files.tgz" .
```

백업 파일 확인:

```bash
ls -lh "$BACKUP_ROOT/harbor/registry-files.tgz"
tar -tzf "$BACKUP_ROOT/harbor/registry-files.tgz" | head
```

정상 기준:

- `registry-files.tgz` 파일 크기가 0이 아닙니다.
- `tar -tzf` 목록 조회가 실패하지 않습니다.

## 9. Sealed Secrets controller key 백업

이 백업은 매우 민감합니다. 유출되면 저장소의 `SealedSecret`을 복호화할 수 있습니다.

```bash
kubectl get secret -n platform-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > "$BACKUP_ROOT/sealed-secrets/sealed-secrets-controller-keys.yaml"
```

파일 확인:

```bash
ls -lh "$BACKUP_ROOT/sealed-secrets/sealed-secrets-controller-keys.yaml"
grep -n "sealed-secrets-key" "$BACKUP_ROOT/sealed-secrets/sealed-secrets-controller-keys.yaml"
```

권장:

- 평문 상태로 장기 보관하지 않습니다.
- 수동 NAS 반출 전 별도 암호화 보관을 권장합니다.
- Git 저장소에는 커밋하지 않습니다.

## 10. manifest 생성

`manifest.yaml`은 백업 세트를 사람이 이해할 수 있게 만드는 기준 파일입니다.

```bash
cat > "$BACKUP_ROOT/manifest.yaml" <<EOF
backup_id: "$BACKUP_DATE"
created_at: "$(date -Iseconds)"
cluster: "platform-infra"
mode: "local-backup-set-with-manual-nas-export"
git_commit: "$(cat "$BACKUP_ROOT/gitops/platform-infra-commit.txt")"
postgres:
  namespace: "platform-db"
  pod: "platform-db-postgres-postgresql-0"
  databases:
    - "keycloak_db"
    - "harbor_registry"
harbor:
  namespace: "platform-registry"
  registry_pvc: "platform-registry-harbor-registry"
  registry_pv: "$PV_NAME"
  registry_path: "$PV_PATH"
sealed_secrets:
  namespace: "platform-system"
included:
  - "postgres/keycloak_db.dump"
  - "postgres/harbor_registry.dump"
  - "harbor/registry-files.tgz"
  - "sealed-secrets/sealed-secrets-controller-keys.yaml"
  - "gitops/platform-infra-commit.txt"
EOF
```

확인:

```bash
cat "$BACKUP_ROOT/manifest.yaml"
```

## 11. checksum 생성과 검증

백업 세트 루트에서 checksum을 생성합니다.

```bash
cd "$BACKUP_ROOT"
find . -type f ! -name checksums.sha256 -print0 | sort -z | xargs -0 sha256sum > checksums.sha256
sha256sum -c checksums.sha256
```

정상 기준:

```text
OK
```

주의:

- NAS 반출 후에도 NAS에 있는 파일 기준으로 `sha256sum -c checksums.sha256`를 다시 실행합니다.
- Synology DSM shell에서 checksum 검증이 어렵다면, NAS에서 백업 세트를 다시 내려받아 k3s 서버 또는 검증용 Linux PC에서 검증합니다.
- checksum 검증이 실패한 백업은 운영 백업으로 인정하지 않습니다.

## 12. 로컬 보관 정책

초기에는 단순하게 유지합니다.

권장:

- 최근 백업 세트 7개 보관
- 주요 변경 전후 백업은 별도 표시 후 수동 반출
- 용량 부족 시 Harbor registry 파일이 가장 크게 증가하므로 먼저 확인

예시:

```bash
ls -1dt /opt/platform-backups/* | tail -n +8
```

삭제는 자동화하지 않습니다. 초기에는 운영자가 목록을 확인하고 직접 삭제합니다.

## 13. 수동 NAS 반출 정책

NAS와 k3s 서버가 완전히 별도 망이므로, 현재 단계에서는 수동 반출을 기본 정책으로 둡니다.

권장 반출 시점:

- 주 1회
- Harbor/Keycloak/PostgreSQL 주요 변경 후
- Sealed Secrets controller key 변경 후
- 복구 리허설 전에 최신 백업 세트를 고정할 때

수동 반출 절차:

1. k3s 서버에서 백업 세트를 생성합니다.
2. `sha256sum -c checksums.sha256`를 통과시킵니다.
3. 백업 세트 전체를 외장 디스크 또는 승인된 반출 매체로 복사합니다.
4. NAS의 지정 경로에 복사합니다.
5. NAS에 복사된 백업 세트에서 checksum을 다시 검증합니다.
6. 반출 기록 표에 날짜, 백업 ID, 작업자, 검증 결과를 남깁니다.

NAS 권장 경로:

```text
/volume1/platform-backups/platform-infra/
├── daily/
├── weekly/
└── restore-tests/
```

반출 기록:

| 날짜 | 백업 ID | 작업자 | NAS 저장 경로 | checksum 결과 | 비고 |
| --- | --- | --- | --- | --- | --- |
|  |  |  |  |  |  |

## 14. 복구 리허설 정책

처음부터 매월 복구 리허설을 강제하면 부담이 큽니다. 초기에는 아래 기준을 사용합니다.

권장:

- 최초 백업 체계 수립 후 1회 리허설
- 이후 분기 1회 리허설
- 주요 구조 변경 후 1회 리허설

리허설 범위:

- `pg_restore --list` 확인
- 임시 DB에 `keycloak_db.dump` restore
- 임시 DB에 `harbor_registry.dump` restore
- `tar -tzf harbor/registry-files.tgz` 확인
- Sealed Secrets key 파일 존재와 암호화 보관 여부 확인
- NAS에서 내려받은 백업 세트 기준 checksum 검증

전체 클러스터 복구는 별도 점검 일정에서만 수행합니다.

## 15. 복구 기본 순서

전체 복구는 아래 순서로 진행합니다.

1. Kubernetes 클러스터와 StorageClass를 준비합니다.
2. Sealed Secrets controller를 먼저 복구합니다.
3. 기존 Sealed Secrets controller key를 복구합니다.
4. 백업 세트의 `gitops/platform-infra-commit.txt` 기준으로 GitOps 저장소를 맞춥니다.
5. `bootstrap/platform-root-infra.yaml`을 적용합니다.
6. PostgreSQL을 복구합니다.
7. Harbor registry 파일을 복구합니다.
8. Keycloak, Harbor를 순서대로 기동합니다.
9. UI 접속, 로그인, Harbor push/pull을 검증합니다.

## 16. PostgreSQL 복구

복구는 파괴적인 작업입니다. 반드시 점검 시간에 수행하고 대상 앱의 쓰기를 먼저 중지합니다.

필요 시 ArgoCD에서 아래 앱의 자동 동기화를 임시 중지합니다.

- `platform-iam-keycloak`
- `platform-registry-harbor`

### 16.1 Keycloak DB 복구

```bash
POSTGRES_PASSWORD="$(kubectl get secret postgres-db-secret -n platform-db -o jsonpath='{.data.postgres-password}' | base64 -d)"

kubectl exec -i -n platform-db platform-db-postgres-postgresql-0 -c postgresql -- \
  env PGPASSWORD="$POSTGRES_PASSWORD" \
  pg_restore -U postgres -d keycloak_db --clean --if-exists \
  < "$BACKUP_ROOT/postgres/keycloak_db.dump"
```

### 16.2 Harbor DB 복구

```bash
kubectl exec -i -n platform-db platform-db-postgres-postgresql-0 -c postgresql -- \
  env PGPASSWORD="$POSTGRES_PASSWORD" \
  pg_restore -U postgres -d harbor_registry --clean --if-exists \
  < "$BACKUP_ROOT/postgres/harbor_registry.dump"
```

복구가 끝나면 로컬 shell 변수에서 비밀번호를 제거합니다.

```bash
unset POSTGRES_PASSWORD
```

## 17. Harbor registry 파일 복구

Harbor registry PVC를 비운 뒤 백업 파일을 되돌립니다.

주의:

- DB와 registry 파일 백업 시점이 다르면 Harbor UI에는 메타데이터가 있는데 실제 blob이 없거나, 반대로 파일은 있는데 DB에 repository가 없는 상태가 될 수 있습니다.
- 가능하면 Harbor DB와 registry 파일은 같은 백업 세트로 복구합니다.

예시:

```bash
PV_NAME="$(kubectl get pvc platform-registry-harbor-registry -n platform-registry -o jsonpath='{.spec.volumeName}')"
PV_PATH="$(kubectl get pv "$PV_NAME" -o jsonpath='{.spec.hostPath.path}')"
echo "$PV_PATH"
sudo tar -C "$PV_PATH" -xzf "$BACKUP_ROOT/harbor/registry-files.tgz"
```

## 18. 복구 후 검증

### 18.1 ArgoCD 상태

```bash
kubectl get application -n argocd
```

정상 기준:

- 주요 앱이 `Healthy`입니다.
- Harbor는 known diff로 인해 `Healthy + OutOfSync`일 수 있습니다.

### 18.2 Keycloak 검증

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

### 18.3 Harbor 검증

```bash
kubectl get pods -n platform-registry -o wide
kubectl get configmap platform-registry-harbor-core -n platform-registry -o yaml | grep EXT_ENDPOINT
curl -I http://harbor.158.179.169.201.nip.io
docker login harbor.158.179.169.201.nip.io
docker pull harbor.158.179.169.201.nip.io/library/busybox:push-test
```

정상 기준:

- Harbor UI에 접속할 수 있습니다.
- 기존 project, repository, tag가 보입니다.
- 기존 이미지를 pull 할 수 있습니다.

## 19. 지금 하지 않는 것

아래 항목은 현재 단계에서 보류합니다.

- NAS 자동 전송
- NAS NFS/SMB를 Kubernetes PV로 mount
- Kubernetes `CronJob` 기반 원격 백업
- MinIO를 백업 저장소로 신규 구축
- Velero 도입
- Longhorn/Rook-Ceph 도입
- 백업 gateway 구축
- 복잡한 retention policy 자동화

보류 사유:

- NAS와 k3s 서버가 완전히 별도 망입니다.
- 초기 운영자가 이해하고 반복할 수 있는 절차가 더 중요합니다.
- 지금 단계에서 과한 자동화는 절차를 이해하지 못한 채 동작하는 블랙박스를 만들 수 있습니다.

## 20. 자동화 전환 TODO

아래 조건이 충족되면 자동화를 검토합니다.

- 백업 절차를 2회 이상 수동 성공
- NAS 반출 절차 확정
- 백업 파일 용량과 소요 시간 파악
- 복구 리허설 1회 성공
- 망간 전송 정책 확정

자동화 후보:

- 로컬 백업 세트 생성 스크립트
- 로컬 백업 세트 검증 스크립트
- 최근 7개 보관 정리 스크립트
- NAS 전송 단계 자동화
- 백업 성공/실패 알림

## 21. 검증 기록

| 날짜 | 작업자 | 백업 ID | 백업 결과 | NAS 반출 | 복구 리허설 | 비고 |
| --- | --- | --- | --- | --- | --- | --- |
|  |  |  |  |  |  |  |

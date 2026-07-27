# Platform Backup/Restore Runbook

단일 k3s 클러스터와 망분리 NAS 조건에서 현실적으로 운영 가능한 백업/복구 기준을 정리합니다. 완전 자동 재해복구가 아니라, **사람이 이해하고 반복할 수 있는 절차**를 먼저 고정하는 것이 목표입니다.

> **개정 (2026-07-07)**: Harbor 제거([ADR-0006](adr/0006-remove-harbor-registry-off-cluster.md))로 백업 범위를 전면 재정의했습니다. 이전 판의 Harbor 관련 절차(Harbor DB·registry 파일 백업/복구)는 모두 삭제했고, 백업 대상을 실제로 재구성 불가능한 상태로 좁혔습니다(§2). 루틴 백업은 스크립트화했습니다(`scripts/platform-backup.sh`, §3).

## 1. 무엇을, 왜 백업하는가 (스코프)

Harbor를 제거한 뒤, 이 플랫폼에서 **재구성이 불가능한 stateful 자산은 두 개 — Keycloak 데이터베이스(`keycloak_db`)와 MLflow 데이터베이스(`mlflow_db`)** ([ADR-0008](adr/0008-mlops-platform-pivot.md)) 뿐입니다. 나머지는 전부 다른 곳에서 복원됩니다.

| 자산 | 재구성 경로 | 백업 필요? |
| --- | --- | --- |
| **`keycloak_db`** (realm·client·role·group·사용자) | 없음 — 런타임 상태 | **예 (P1)** |
| **`mlflow_db`** (실험 run·모델 레지스트리 메타데이터) | 없음 — 런타임 상태 | **예 (P1)** |
| MLflow 아티팩트 (모델 파일·run 산출물, MinIO@NAS 소재) | NAS 자체 — 별도 백업/반출 대상 | 아니오 — 이 런북·스크립트의 클러스터 백업 범위 밖 (ADR-0008) |
| GitOps 매니페스트 | GitHub (`origin`) | 아니오 (원격이 곧 원본) |
| `SealedSecret` 리소스 | GitHub | 아니오 |
| SealedSecret **평문** | 비밀번호 관리자 (사람 관리) | 백업 대상 아님 — reseal 경로의 전제(§9) |
| sealed-secrets 컨트롤러 키 | (옵션) — 아래 참조 | 기본 아니오 (§6) |
| Prometheus/Grafana 데이터 | retention 5d·프로비저닝 대시보드 | 아니오 (휘발성) |
| product-pulse 테넌트 | **무상태** (PVC 없음, 라이브 read만) | 아니오 |

따라서 루틴 백업 세트는 **`keycloak_db`·`mlflow_db` dump + GitOps commit 기준점 + manifest/checksum** 으로 구성합니다.

**컨트롤러 키를 루틴에서 뺀 이유** — 컨트롤러 키는 플랫폼 전체에서 가장 위험한 파일입니다(유출 시 모든 SealedSecret 복호화 가능). 기본 복구 경로가 "새 키 발급 → 비밀번호 관리자 평문으로 reseal"이고 평문은 이미 비밀번호 관리자에 이중 보관되므로, 키를 매 백업마다 디스크에 쓰고 NAS로 반출하는 것은 노출 표면만 키웁니다. 키 백업은 "reseal을 건너뛰고 싶을 때"의 **옵션·수동·암호화** 단계로 격리합니다(§6).

## 2. 백업 정책

| 항목 | 정책 |
| --- | --- |
| 자동 경로 (기본) | in-cluster `CronJob`(`platform-db/platform-backup`), 매일 02:00 KST — 덤프→검증→**MinIO@NAS 반출**→사본 checksum 재검증까지 한 번에 (§14) |
| 자동 경로 저장 | 노드 디스크를 쓰지 않는다(파드 `emptyDir`만 경유) → 1차 저장이 곧 NAS |
| 수동 경로 (폴백·리허설용) | `scripts/platform-backup.sh`, **노드가 아닌 곳**에서 실행 권장 (§3) |
| 수동 경로 저장 | 실행한 기기의 로컬 디스크 (`/opt/platform-backups` 또는 지정 경로) → NAS 반출은 수동 (§7) |
| NAS 보존 | 자동 경로는 삭제하지 않는다(세트 1개 ≈ 340KB → 연 125MB 수준). NAS측 정리는 별도 관심사 |
| 복구 리허설 | 초기 1회(완료: §12·§13), 이후 분기 1회 또는 주요 변경 후 (§10) |

두 경로를 함께 두는 이유는 실패 프로필이 다르기 때문이다 — 자동 경로는 클러스터가 살아 있을 때 매일 돌고, 수동 경로는 클러스터 API에 닿을 수 있으면 언제든 오프노드에서 돌 수 있다. 자동 경로만 두면 스케줄러(클러스터) 자체가 단일 실패점이 된다.

운영 백업으로 인정하는 최소 조건:

- `keycloak_db.dump`·`mlflow_db.dump`가 각각 생성되고 `pg_restore --list`가 성공한다.
- 백업 시점의 GitOps commit이 기록되어 있다.
- `manifest.yaml`이 포함되어 있다.
- `checksums.sha256` 검증이 성공한다.
- 백업 세트가 클러스터 외부(NAS)로 반출되었다.

## 3. 루틴 백업 — 스크립트

k3s 서버(또는 kubeconfig가 있는 곳)에서 실행합니다. 스크립트는 **클러스터에 대해 read-only**(pg_dump / get secret)라 언제 실행해도 안전합니다.

단일 노드 환경에서는 **노드가 아닌 곳에서 실행하는 편이 낫습니다** — 노드 디스크에 백업을 쌓으면 노드 소실 시 백업도 함께 사라집니다. tailnet kubeconfig를 가진 운영자 PC에서 실행해 검증했습니다(§13).

```bash
# 이 레포를 서버에 checkout 한 경우
./scripts/platform-backup.sh                 # 기본 /opt/platform-backups
./scripts/platform-backup.sh /data/backups   # 저장 위치 지정
RETAIN=14 ./scripts/platform-backup.sh       # 로컬 보관 세트 수 조정
```

스크립트가 하는 일:

1. `BACKUP_DBS` 배열(`keycloak_db`, `mlflow_db`)을 순회하며 각 DB를 `pg_dump -Fc`로 덤프하고 `pg_restore --list`로 아카이브 유효성 검증.
2. 현재 GitOps commit(`git rev-parse HEAD`)을 기록.
3. `manifest.yaml` 생성(백업 ID·시각·commit·대상·주의).
4. 세트 전체에 대한 `checksums.sha256` 생성 후 즉시 검증.
5. 로컬 보관 정리(기본 최신 7세트 유지).
6. 여기서 **멈춤** — NAS 반출과 (옵션) 컨트롤러 키는 수동 경계.

스크립트가 없는 환경에서 절차를 이해하려면 §4~§5의 수동 단계를 참조합니다.

## 4. 백업 세트 구조

백업은 단일 파일이 아니라 하나의 디렉토리 세트로 관리합니다.

```text
/opt/platform-backups/
└── 20260707-020000/
    ├── manifest.yaml
    ├── checksums.sha256
    ├── postgres/
    │   ├── keycloak_db.dump
    │   └── mlflow_db.dump
    └── gitops/
        └── commit.txt
```

## 5. 수동 백업 절차 (스크립트 없이 / 이해용)

```bash
BACKUP_ROOT="/opt/platform-backups/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_ROOT"/{postgres,gitops}

# GitOps 기준점
git -C "$(pwd)" rev-parse HEAD > "$BACKUP_ROOT/gitops/commit.txt"

# DB 덤프 — keycloak_db, mlflow_db 각각에 대해 반복 (DB 이름만 바뀜)
for DB in keycloak_db mlflow_db; do
  POSTGRES_PASSWORD="$(kubectl get secret postgres-db-secret -n platform-db -o jsonpath='{.data.postgres-password}' | base64 -d)"
  kubectl exec -n platform-db platform-db-postgres-postgresql-0 -c postgresql -- \
    env PGPASSWORD="$POSTGRES_PASSWORD" \
    pg_dump -U postgres -d "$DB" -Fc \
    > "$BACKUP_ROOT/postgres/${DB}.dump"

  # 덤프 검증
  kubectl exec -i -n platform-db platform-db-postgres-postgresql-0 -c postgresql -- \
    pg_restore --list < "$BACKUP_ROOT/postgres/${DB}.dump" > /dev/null
  unset POSTGRES_PASSWORD
done

# checksum
cd "$BACKUP_ROOT"
find . -type f ! -name checksums.sha256 -print0 | sort -z | xargs -0 sha256sum > checksums.sha256
sha256sum -c checksums.sha256
```

정상 기준: 덤프 크기가 0이 아니고, `pg_restore --list`가 실패하지 않으며, checksum이 `OK`.

## 6. (옵션) sealed-secrets 컨트롤러 키 백업

기본 복구는 reseal 경로(§9)를 사용하므로 이 단계는 **선택**입니다. reseal을 건너뛰는 빠른 복구를 원할 때만 수행합니다.

```bash
kubectl get secret -n platform-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > sealed-secrets-controller-keys.yaml
```

주의(강함):

- 이 파일은 플랫폼에서 **가장 민감한 자산**입니다 — 유출 시 저장소의 모든 `SealedSecret`을 복호화할 수 있습니다.
- 평문 상태로 디스크에 두지 않습니다. 즉시 암호화(예: `age`/`gpg`)하여 보관·반출합니다.
- **Git에 절대 커밋하지 않습니다.** 루틴 백업 세트에도 넣지 않습니다.
- 컨트롤러 키가 변경(reseal)되면 이 백업도 갱신합니다.

## 7. NAS 반출

**자동 경로(기본)**: in-cluster CronJob이 반출까지 수행합니다(§14). 아래 수동 절차는 폴백이며, 클러스터 밖에서 만든 세트(§3)를 올릴 때 씁니다.

> 이 절에는 원래 *"NAS와 k3s 서버가 완전히 별도 망이므로 수동 반출을 기본 정책으로 둔다"* 고 적혀 있었습니다. tailnet 도입 이후 이 전제는 사실이 아닙니다 — MLflow가 이미 클러스터에서 MinIO@NAS로 아티팩트를 씁니다(ADR-0008). 같은 경로를 백업 반출에 재사용하므로 새 신뢰 관계가 늘지 않습니다.

권장 수동 반출 시점: Keycloak/PostgreSQL 주요 변경 후 · 컨트롤러 키 변경 후 · 복구 리허설 전 최신 세트 고정 시.

절차:

1. 백업 세트를 생성하고 `sha256sum -c checksums.sha256`을 통과시킨다.
2. 세트 전체를 승인된 반출 매체로 복사한다.
3. NAS 지정 경로에 복사한다.
4. NAS에 복사된 세트에서 checksum을 **다시** 검증한다.
5. 반출 기록 표(§12)에 날짜·백업 ID·작업자·검증 결과를 남긴다.

NAS 권장 경로:

```text
/volume1/platform-backups/platform-infra/
├── daily/
├── weekly/
└── restore-tests/
```

## 8. 로컬 보관 정책

- 기본: 최신 7세트 유지(`scripts/platform-backup.sh`의 `RETAIN`).
- 주요 변경 전후 백업은 별도 표시 후 반출.
- 삭제는 스크립트가 retention 범위만 정리하며, 그 외 수동 삭제는 목록 확인 후 진행.

## 9. 복구 (수동, 파괴적)

복구는 파괴적인 작업입니다. 반드시 점검 시간에 수행하고, 대상 앱의 쓰기를 먼저 중지합니다. 시크릿 복구에는 두 경로가 있습니다.

**경로 A — reseal (기본).** 새 클러스터에 sealed-secrets 컨트롤러가 새 키로 뜬 뒤, 비밀번호 관리자의 평문으로 `SealedSecret`을 다시 봉인합니다. 컨트롤러 키 백업이 필요 없습니다. reseal은 **수동 경계**(자동화 제외)입니다.

**경로 B — 키 복원 (옵션).** §6에서 백업한 컨트롤러 키를 복원하면 reseal 없이 기존 `SealedSecret`이 그대로 복호화됩니다. 빠르지만 최고 민감 파일을 다루므로 신중히.

### 9.1 복구 기본 순서

1. Kubernetes 클러스터와 StorageClass를 준비한다.
2. sealed-secrets 컨트롤러를 복구한다.
   - 경로 A: 새 키로 기동 → §9.3에서 reseal.
   - 경로 B: 백업한 컨트롤러 키를 먼저 복원(`kubectl apply` 후 컨트롤러 재기동).
3. 백업 세트의 `gitops/commit.txt` 기준으로 GitOps 저장소를 맞춘다.
4. `bootstrap/platform-root-infra.yaml`을 적용한다.
5. PostgreSQL이 기동되면 `keycloak_db`·`mlflow_db`를 복구한다(§9.2).
6. Keycloak을 기동하고 로그인·realm 설정을 검증한다(§9.4).

### 9.2 keycloak_db·mlflow_db 복구

필요 시 ArgoCD에서 `platform-iam-keycloak`(및 `platform-mlops-mlflow`)의 자동 동기화를 임시 중지합니다.

```bash
POSTGRES_PASSWORD="$(kubectl get secret postgres-db-secret -n platform-db -o jsonpath='{.data.postgres-password}' | base64 -d)"
kubectl exec -i -n platform-db platform-db-postgres-postgresql-0 -c postgresql -- \
  env PGPASSWORD="$POSTGRES_PASSWORD" \
  pg_restore -U postgres -d keycloak_db --clean --if-exists \
  < "$BACKUP_ROOT/postgres/keycloak_db.dump"
unset POSTGRES_PASSWORD
```

`mlflow_db`는 동일 패턴(`pg_restore --clean --if-exists`)이지만, 재구축 직후에는 chart auth가 `keycloak_db`만 생성하므로 `mlflow_db`와 `mlflow_admin` 사용자가 아직 없을 수 있습니다 — 없다면 먼저 `docs/platform-mlops-setup.md` 4단계의 `CREATE USER`/`CREATE DATABASE` 명령을 실행합니다.

```bash
POSTGRES_PASSWORD="$(kubectl get secret postgres-db-secret -n platform-db -o jsonpath='{.data.postgres-password}' | base64 -d)"
kubectl exec -i -n platform-db platform-db-postgres-postgresql-0 -c postgresql -- \
  env PGPASSWORD="$POSTGRES_PASSWORD" \
  pg_restore -U postgres -d mlflow_db --clean --if-exists \
  < "$BACKUP_ROOT/postgres/mlflow_db.dump"
unset POSTGRES_PASSWORD
```

### 9.3 (경로 A) SealedSecret reseal

`docs/cluster-rebuild-runbook.md`의 reseal 절차를 따릅니다. 비밀번호 관리자의 평문으로 각 SealedSecret을 새 컨트롤러 공개키로 다시 봉인해 커밋합니다.

### 9.4 복구 후 검증

```bash
kubectl get application -n argocd            # 주요 앱 Healthy
kubectl get pods -n platform-iam -o wide
kubectl port-forward -n platform-iam svc/platform-iam-keycloak 8080:80
# 브라우저: http://127.0.0.1:8080 — 관리자 로그인, realm/client/role/group 유지 확인
```

## 10. 복구 리허설 정책

- 최초 백업 체계 수립 후 1회.
- 이후 분기 1회, 또는 주요 구조 변경 후 1회.

리허설 범위(비파괴):

- `pg_restore --list`로 덤프 목록 확인.
- **임시 DB**에 `keycloak_db.dump`를 restore(운영 DB 아님). `mlflow_db.dump`도 동일 절차.
- NAS에서 내려받은 세트 기준 checksum 재검증.
- (경로 B를 쓸 경우) 컨트롤러 키 파일 존재·암호화 보관 확인.

전체 클러스터 복구는 별도 점검 일정에서만 수행합니다.

## 11. 지금 하지 않는 것

NAS 자동 전송 · NFS/SMB PV mount · `CronJob` 원격 백업 · MinIO 백업 저장소 · Velero · Longhorn/Rook-Ceph · 백업 gateway · 복잡한 retention 자동화.

보류 사유: NAS와 서버가 완전 별도 망이고, 초기에는 운영자가 이해·반복할 수 있는 절차가 더 중요하며, 과한 자동화는 절차를 이해하지 못한 채 도는 블랙박스를 만들 수 있습니다.

## 12. 검증 기록

| 날짜 | 작업자 | 백업 ID | 백업 결과 | NAS 반출 | 복구 리허설 | 비고 |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-07-26 | 운영자 | `20260726-230501` | OK — keycloak_db 256K / mlflow_db 84K, checksum 4파일 검증 | 미완 (§13) | OK — 임시 DB restore, `pg_restore` rc=0 / error 0 | 체계 수립 후 **첫 실행**. 발견 사항은 §13 |

## 13. 첫 실행에서 확인한 것 (2026-07-26)

백업 스크립트와 이 런북은 완성돼 있었지만 **한 번도 실행된 적이 없었다**(§12가 빈 표였다). 무검증 절차를 자동화하기 전에 수동으로 전 구간을 돌려 검증했다.

**통과한 것**

- 스크립트가 수정 없이 첫 실행에 성공했다. 세트 구조가 §4 명세와 일치하고 checksum 4파일 전부 재검증됐다.
- 기록된 `git_commit`이 ArgoCD root Application의 배포 리비전과 정확히 일치했다 — GitOps 기준점이 실제 배포 상태를 가리킨다.
- 복구 리허설(§10)에서 `pg_restore`가 **플래그 우회 없이** rc=0·error 0으로 복구됐다. 스키마만이 아니라 데이터도 살아났다: keycloak 88테이블(realm 2·user 4·client 14), mlflow 34테이블(experiment 8·registered_model 3·model_version 11·run 18). 리허설 전후 운영 DB 목록이 동일해 비파괴 조건도 지켜졌다.

**오프노드 실행이 가능하고 더 안전하다**

이번 실행은 k3s 서버가 아니라 **tailnet kubeconfig를 가진 운영자 PC에서** 했다(§3이 허용하는 경로). 스크립트가 클러스터에 read-only이므로 동작에 차이가 없고, 단일 노드 환경에서는 이쪽이 낫다 — 노드 디스크에 백업을 쌓으면 노드 소실이라는 지배적 실패 모드에서 백업이 함께 사라진다. 자동화 시 이 점을 반영한다(§2 자동화 범위 개정 예정).

**발견: Harbor 잔재 (ADR-0006 미완 정리)**

- `harbor_registry` 데이터베이스가 남아 있다 — 7.3MB, public 테이블 0개(빈 껍데기).
- `harbor_admin` role도 남아 있다.
- `postgres-db-secret`의 `harbor-password` 고아 키는 이미 매니페스트 주석에 이연 항목으로 기록돼 있었다(다음 reseal 때 2키로 재생성).

백업 대상(`BACKUP_DBS`)에는 없으므로 백업·복구의 정합성 문제는 아니다. 다만 폐기된 컴포넌트의 DB와 role이 남아 있는 것은 정리 대상이며, `DROP DATABASE`/`DROP ROLE`은 파괴적 작업이라 별도 승인 후 수행한다. 정리 시 SealedSecret reseal(2키)과 함께 묶는 것이 적절하다.

**미완: NAS 반출**

반출에는 NAS 측 자격증명이 필요해 이번 회차에서는 수행하지 않았다. §7이 전제한 "NAS와 k3s 서버가 완전히 별도 망"은 tailnet 도입 이후 더 이상 사실이 아니다(MLflow가 이미 클러스터에서 MinIO@NAS로 아티팩트를 쓴다). 따라서 반출은 수동 정책을 유지할 이유가 없고, 전용 버킷·자격증명을 갖춰 자동화하는 것이 맞다 → §14로 자동화했다.

## 14. 자동 백업 (in-cluster CronJob)

매니페스트: `manifests/backup/platform-backup-cronjob.yaml`, Application: `apps/platform-backup.yaml`(wave 5).

### 동작

파드 하나가 두 단계로 돈다. 노드 디스크에는 아무것도 남기지 않는다(`emptyDir`만 경유).

1. **initContainer `dump`** — postgres 서버와 **같은 이미지**(pg_dump 메이저 버전 일치). Service로 직접 접속해 `keycloak_db`·`mlflow_db`를 `pg_dump -Fc`로 덤프하고 `pg_restore --list`로 아카이브 유효성을 확인한 뒤 `manifest.yaml`·`checksums.sha256`을 만든다.
2. **container `export`** — `minio/mc`. 세트를 `nas/platform-backups/<backup_id>/`로 올린 뒤 **되받아 `sha256sum -c`로 재검증**한다(§7의 4단계를 자동화한 것).

API 접근이 필요 없어 서비스어카운트 토큰을 마운트하지 않고, postgres에 `kubectl exec` 대신 Service로 붙으므로 exec 권한도 없다.

자동 경로는 레포 체크아웃이 없어 정확한 GitOps commit을 기록할 수 없다 — `gitops/commit.txt`에 시각으로 커밋을 되찾는 방법을 적어둔다. 정확한 commit이 필요하면 수동 경로(§3)를 쓴다.

### 감시

`manifests/monitoring/rules/platform-rules.yaml`의 `platform.backup` 그룹이 Telegram으로 연결된다.

| 알림 | 조건 | 의미 |
| --- | --- | --- |
| `PlatformBackupStale` | 마지막 성공 > 36h | 핵심 룰. 잡 실패·suspend·스케줄러 이상·클러스터 정지까지 한 번에 잡힌다 |
| `PlatformBackupMissing` | 성공 이력 메트릭 자체가 없음 (26h) | CronJob 삭제/최초 실행 미성공 — Stale이 못 잡는 구멍 |
| `PlatformBackupJobFailing` | 6h 내 실패 파드 존재 | 재시도로 최종 성공했을 수 있으나 원인 확인용(warning) |

실패 이벤트가 아니라 **staleness**를 핵심으로 삼은 이유는, 재시도가 최종 성공하는 경우에 헛발화하지 않으면서 모든 실패 모드를 한 룰로 덮기 때문이다.

### 최초 설정 (운영자 직접 — 시크릿 경계)

`scripts/setup-backup-nas-credentials.sh` 한 번으로 버킷·최소권한 정책·전용 사용자·SealedSecret이 만들어집니다. **터미널에서 직접 실행하세요** — 비밀번호 입력에 TTY가 필요합니다.

```bash
export KUBECONFIG=~/.kube/oci-platform-tailnet.yaml

./scripts/setup-backup-nas-credentials.sh --preflight   # 변경 없이 사전 점검만
./scripts/setup-backup-nas-credentials.sh               # 실제 실행
```

MinIO 루트 비밀번호를 한 번 물어보는 것이 유일한 입력입니다. 스크립트가 하는 일:

1. 사전 점검(도구·클러스터·sealed-secrets 컨트롤러·MinIO 도달성)
2. 버킷 `platform-backups` 생성(있으면 재사용)
3. **최소권한 정책** — 이 버킷에만 `ListBucket`/`GetObject`/`PutObject`. **`DeleteObject`는 주지 않습니다** — 백업 주체가 백업을 지울 수 없어야 합니다. 읽기 권한은 반출 후 checksum 재검증에 필요합니다.
4. 전용 사용자 `platform-backup` 생성 + 정책 연결 (비밀번호는 스크립트가 생성)
5. **권한 검증** — 조회·쓰기·읽기가 되는지, **삭제가 막히는지**, **다른 버킷(`mlflow-artifacts`)이 차단되는지**까지 실제로 시험합니다. 의도와 다르면 경고합니다.
6. SealedSecret을 `manifests/security/platform-backup-nas-sealed-secret.yaml`로 생성

비밀값이 남는 곳을 최소화하도록 설계했습니다 — 생성된 비밀번호를 화면에 찍지 않고, 명령행 인자로도 넘기지 않으며(호스트 `ps` 노출 방지: 컨테이너에는 환경변수, `kubectl`에는 파일로 전달), 평문은 `~/platform-backup-nas.secret`(권한 600) 한 파일에만 기록합니다. 그래서 **AI 에이전트가 이 스크립트를 대신 실행하더라도 비밀값이 대화 기록에 들어가지 않습니다.**

**실행 후 반드시**:

1. `~/platform-backup-nas.secret`의 값을 **패스워드 매니저에 저장** — 이 플랫폼은 컨트롤러 키를 백업하지 않는 대신 "평문으로 재봉인"을 기본 복구 경로로 삼으므로(§6), 사람이 이 값을 보관해야 재구축이 가능합니다.
2. 저장을 확인했으면 파일 삭제: `rm -P ~/platform-backup-nas.secret`
3. SealedSecret 커밋·머지 → ArgoCD가 Secret(wave -1)과 CronJob(wave 5)을 동기합니다.

> 기존 사용자의 비밀번호를 교체하려면 `ROTATE=1`을 붙입니다. 새 SealedSecret이 배포되기 전까지 백업 잡이 실패하므로 의도적으로 기본 동작에서 제외했습니다.

**첫 실행은 스케줄(02:00 KST)까지 기다리지 말고 수동 검증**:

```bash
kubectl create job --from=cronjob/platform-backup platform-backup-manual-1 -n platform-db
kubectl logs -n platform-db job/platform-backup-manual-1 -c dump
kubectl logs -n platform-db job/platform-backup-manual-1 -c export
kubectl delete job platform-backup-manual-1 -n platform-db      # 확인 후 정리
```

`export` 로그의 마지막 줄이 `DONE — nas/platform-backups/<id> 검증 완료`면 반출과 사본 checksum 재검증까지 성공한 것입니다. §12에 기록을 남기세요.

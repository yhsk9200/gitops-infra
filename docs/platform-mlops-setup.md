# platform-mlops 활성화 체크리스트 (Step 2 선작업 → 배포)

이 문서는 `feat/platform-mlops-mlflow` 브랜치(선작업)를 main에 머지하기 **전**
완료해야 할 수동 단계의 순서를 기록한다. 근거는 [ADR-0008](adr/0008-mlops-platform-pivot.md)
(설계)·[ADR-0009](adr/0009-isolated-ml-experiment-cluster.md)(실행계획 통합).

이 브랜치 자체(Dockerfile, ArgoCD Application, Deployment/Service, 네임스페이스)는
선작업일 뿐이다 — main에 머지되는 순간 ArgoCD가 `platform-mlops-mlflow` 앱을
동기화하므로, 아래 전제가 갖춰지지 않은 채 머지하면 앱이 CrashLoop/Pending 상태로
Unhealthy에 머문다("머지 = 배포"는 여기서도 예외 없음).

## 순서

> 1~3단계의 구체 명령·함정(OCI iptables INPUT REJECT, 파드 내 MagicDNS 불가,
> k3s tls-san, NAS 재부팅 바인딩)은 **[tailnet-minio-runbook.md](tailnet-minio-runbook.md)**
> 가 기준 절차다. 아래는 게이트 요약.

- [x] **1. tailnet 편입 (OCI 노드 + NAS)** — ✅ 2026-07-18 검증 완료: 노드
      `aporiax-instance`=`100.69.52.25`, NAS `yhs-ds920`=`100.69.142.125`,
      3자 상호 ping 성공(노드 경로는 DERP — 직결 승격은 Security List UDP
      41641 개방 시). kubeconfig 방식 C 전환 완료(노드 무변경 — 런북 0.4).
- [x] **2. NAS에 MinIO 기동** — ✅ 2026-07-18 완료: 127.0.0.1 바인딩 +
      tailscaled userspace 인바운드 프록시(TUN 부재 실측 — 런북 1.1 정정),
      이미지 핀 RELEASE.2025-09-07T16-13-09Z, `mlflow-artifacts` 버킷 생성.
      MLflow 전용 키(mlflow-rw 정책)는 발급 여부 확인 후 3단계 인증
      테스트에서 검증 — 키는 **비밀번호 관리자에 즉시 보관**.
- [x] **3. 클러스터 → tailnet 경유 S3 접근 실측** — 연결성 ✅ 완료
      (2026-07-18: Mac→tailnet 200, LAN 차단 확인, **클러스터 파드→MinIO
      HTTP 200** — MLflow가 쓸 체인 전 구간 실측). 전용 키 인증 테스트는
      9단계(배포 후 검증)로 통합 — 배포되면 mlflow-secret을 envFrom으로
      참조하는 파드로 검증(시크릿이 세션/히스토리에 안 나오는 경로).
**실행 위치 (4·5 공통)**: OCI 노드에 SSH 불필요 — `kubectl exec`는
원격 클라이언트 명령이라 **Mac 터미널**에서 실행한다(kubectl이 API 서버에
"그 파드 안에서 이 명령을 실행해달라"고 요청하는 구조). 단 아래 두 전제가
빠지면 실패한다:

```bash
cd ~/projects/gitops-infra                          # 5단계 출력 경로가 상대경로라 레포 루트 필수
export KUBECONFIG=~/.kube/oci-platform-tailnet.yaml  # 기본 컨텍스트는 orbstack(로컬) — 명시 안 하면 엉뚱한 클러스터로 감
kubectl config current-context                       # 확인 습관: oci-platform-tailnet 이어야 함
```

- [x] **4. mlflow_db 생성 (one-off)** — ✅ 2026-07-18 완료·검증됨(mlflow_db owner=mlflow_admin 실측). 기존 postgres PVC 세대에는 차트
      initdb가 다시 돌지 않으므로 수동 생성이 필요하다. 재구축(cluster-rebuild-runbook)
      때는 이 단계가 빠지지 않도록 런북에 단계 추가가 필요하다는 점을 메모해 둔다.

  ```bash
  # (위 cd/export 실행된 셸에서 이어서)
  # LC_ALL=C 필수: macOS에서 로케일이 UTF-8이면 tr이 "Illegal byte sequence"로 실패 (2026-07-19 실측)
  gen() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "${1:-32}"; echo; }
  MLFLOW_DB_PW=$(gen 32)                               # cluster-rebuild-runbook과 동일 생성 방식

  POSTGRES_PW="$(kubectl get secret postgres-db-secret -n platform-db \
    -o jsonpath='{.data.postgres-password}' | base64 -d)"

  kubectl exec -it platform-db-postgres-postgresql-0 -n platform-db -c postgresql -- \
    env PGPASSWORD="$POSTGRES_PW" psql -U postgres -c \
    "CREATE USER mlflow_admin WITH PASSWORD '$MLFLOW_DB_PW';" -c \
    "CREATE DATABASE mlflow_db OWNER mlflow_admin;"

  unset POSTGRES_PW
  echo "$MLFLOW_DB_PW"    # ← 이 값을 비밀번호 관리자에 즉시 저장 (5단계에서 재사용)
  ```

  `postgres-db-secret`의 `postgres-password`는 `scripts/platform-backup.sh`가
  이미 같은 방식으로 읽는 값 — 신규 발급이 아니라 기존 값을 그대로 쓴다.
  `MLFLOW_DB_PW`는 이번에 새로 발급하는 값이라 비밀번호 관리자 저장이 필요.
  평문을 쉘 히스토리에 남기지 않도록 주의(새 셸, 히스토리 무시 옵션, 또는
  실행 후 즉시 히스토리 삭제 중 편한 방법으로).

- [x] **5. mlflow-secret SealedSecret 생성** — ✅ 2026-07-18 완료·검증됨(kubeconform Valid, 3키 확인). namespace `platform-mlops`,
      keys:
      - `MLFLOW_BACKEND_STORE_URI` = `postgresql://mlflow_admin:<$MLFLOW_DB_PW>@platform-db-postgres-postgresql.platform-db.svc.cluster.local:5432/mlflow_db`
      - `AWS_ACCESS_KEY_ID` = `mlflow` (런북 1.2에서 만든 사용자명)
      - `AWS_SECRET_ACCESS_KEY` = (런북 1.2에서 발급한 MinIO secret key)

  `kubeseal`은 컨트롤러 공개키를 먼저 파일로 받아두는
  레포 관례(`cluster-rebuild-runbook.md` 3.3)를 따른다. `pub-cert.pem`은
  공개키라 민감하지 않지만 `.gitignore` 대상(레포 루트에 임시로만 둠).

  > **주의 (2026-07-19 실사고)**: 4단계 셸 변수(`$MLFLOW_DB_PW`)에 의존하지
  > 말 것 — 다른 셸에서 실행하면 빈 문자열로 치환돼 **빈 비밀번호가 그대로
  > 실링**되고, 배포 후 `fe_sendauth: no password supplied` CrashLoop으로
  > 나타난다. 값은 아래처럼 직접 입력받고 **길이 확인**을 거친다.

  > **실링 전 로그인 검증 (2차 사고 후 추가)**: 저장·붙여넣기 불일치로
  > "password authentication failed"가 실링된 사례가 있었다. 실링 직전에
  > 반드시 그 값으로 실제 DB 로그인을 검증한다 — 통과한 값만 실링:
  > ```
  > kubectl exec -i platform-db-postgres-postgresql-0 -n platform-db -c postgresql -- \
  >   env PGPASSWORD="$MLFLOW_DB_PW" psql -U mlflow_admin -d mlflow_db -t -c 'SELECT 1;'
  > ```

  ```bash
  kubeseal --fetch-cert \
    --controller-name=sealed-secrets-controller \
    --controller-namespace=platform-system \
    > pub-cert.pem

  read -rs MLFLOW_DB_PW   # 4단계에서 비밀번호 관리자에 저장한 값 붙여넣기
  echo "입력 길이: ${#MLFLOW_DB_PW}"   # 0이면 다시 — 빈 값 실링 사고 방지
  read -rs MINIO_SK    # 런북 1.2에서 발급한 mlflow secret key 붙여넣고 엔터 (화면에 안 보임)
  echo "입력 길이: ${#MINIO_SK}"

  kubectl create secret generic mlflow-secret \
    --namespace platform-mlops --dry-run=client -o yaml \
    --from-literal=MLFLOW_BACKEND_STORE_URI="postgresql://mlflow_admin:${MLFLOW_DB_PW}@platform-db-postgres-postgresql.platform-db.svc.cluster.local:5432/mlflow_db" \
    --from-literal=AWS_ACCESS_KEY_ID='mlflow' \
    --from-literal=AWS_SECRET_ACCESS_KEY="$MINIO_SK" \
    | kubeseal --cert pub-cert.pem --format yaml \
    > manifests/security/mlflow-sealed-secret.yaml

  unset MINIO_SK MLFLOW_DB_PW
  rm pub-cert.pem
  ```

  결과 파일(`manifests/security/mlflow-sealed-secret.yaml`)을 git add·커밋한다.
  암호화된 결과물만 git에 들어간다는 점은 기존 SealedSecret들과 동일 — 평문은
  이 저장소 어디에도 남기지 않는다.

- [x] **6. tailnet IP 치환** — ✅ 2026-07-18 반영: `MLFLOW_S3_ENDPOINT_URL`
      = `http://100.69.142.125:9000` (NAS tailnet IP는 장비 고정이라 MinIO
      기동 전 선반영 가능).
- [ ] **7. 커스텀 이미지 선빌드** — 머지 전 GHCR에 `ghcr.io/yhsk9200/mlflow:v3.6.0-pg1`이
      이미 존재해야 `validate.yaml`의 arm64 가드가 통과한다(가드는 존재하는
      태그만 검사할 수 있다). 둘 중 하나로 진행:
      - 방법 A) 로컬에서 선빌드·푸시: `gh auth token`으로 GHCR 로그인 후
        `docker buildx build --platform linux/amd64,linux/arm64 --push -t ghcr.io/yhsk9200/mlflow:v3.6.0-pg1 images/mlflow`
      - 방법 B) `build-mlflow-image.yaml` 워크플로우가 먼저 main에 올라간
        뒤(이 선작업 PR과 별도, 혹은 같은 PR 머지 직후) `workflow_dispatch`로
        수동 실행
- [ ] **8. PR ready → CI 3종 green 확인 → 머지** (머지 = 배포).
- [ ] **9. 배포 후 검증**:
      - ArgoCD app `platform-mlops-mlflow`가 Healthy/Synced인지 확인
      - `kubectl port-forward svc/mlflow -n platform-mlops 5000:5000` 후
        `curl localhost:5000/health` → 200
      - 테스트 run을 하나 기록하고, 아티팩트 업로드가 MinIO
        `mlflow-artifacts` 버킷에 실제로 생성되는지 확인
      - S3 전용 키 인증 검증(3단계 잔여 통합): platform-mlops 네임스페이스에
        `envFrom: secretRef mlflow-secret` 파드(amazon/aws-cli)를 띄워
        `s3 ls s3://mlflow-artifacts` — 시크릿을 화면에 노출하지 않고 검증
- [ ] **10. 백업 확장 검증** — `scripts/platform-backup.sh` 실행 후 결과
      backup set에 `mlflow_db.dump`가 포함돼 있는지 확인.

## 이 선작업 PR에 포함되지 않은 것

- Grafana datasource 연결 (ADR-0009 Step 4) — 별도 PR.
- Mac 실험 클러스터 (ADR-0009) — 별도 레포.
- 재학습 CronJob (Phase C) — 제품 테넌트 레포 몫.

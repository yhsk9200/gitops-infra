# platform-mlops 활성화 체크리스트 (Step 2 선작업 → 배포)

이 문서는 `feat/platform-mlops-mlflow` 브랜치(선작업)를 main에 머지하기 **전**
완료해야 할 수동 단계의 순서를 기록한다. 근거는 [ADR-0008](adr/0008-mlops-platform-pivot.md)
(설계)·[ADR-0009](adr/0009-isolated-ml-experiment-cluster.md)(실행계획 통합).

이 브랜치 자체(Dockerfile, ArgoCD Application, Deployment/Service, 네임스페이스)는
선작업일 뿐이다 — main에 머지되는 순간 ArgoCD가 `platform-mlops-mlflow` 앱을
동기화하므로, 아래 전제가 갖춰지지 않은 채 머지하면 앱이 CrashLoop/Pending 상태로
Unhealthy에 머문다("머지 = 배포"는 여기서도 예외 없음).

## 순서

- [ ] **1. tailnet 편입 (OCI 노드 + NAS)** — Tailscale을 OCI 클러스터 노드와
      Synology NAS(DS920+)에 설치·조인. 검증: 노드·NAS·운영 단말 3자 상호
      `tailscale ping` 성공.
- [ ] **2. NAS에 MinIO 기동** — tailnet 인터페이스에만 바인딩(공인 노출 금지,
      ADR-0008의 tailnet-only 조건). `mlflow-artifacts` 버킷 생성 + MLflow
      전용 access key 1쌍 발급(범위를 이 버킷으로 제한할 수 있으면 제한).
      발급된 키는 **비밀번호 관리자에 즉시 보관**.
- [ ] **3. 클러스터 → tailnet 경유 S3 접근 실측** — 임시 파드(예: `curlimages/curl`
      또는 `amazon/aws-cli`)에서 tailnet IP로 MinIO 엔드포인트에 HEAD 요청을
      보내 버킷이 보이는지 확인. 이 IP가 다음 단계의 실측값이다.
- [ ] **4. mlflow_db 생성 (one-off)** — 기존 postgres PVC 세대에는 차트
      initdb가 다시 돌지 않으므로 수동 생성이 필요하다. 재구축(cluster-rebuild-runbook)
      때는 이 단계가 빠지지 않도록 런북에 단계 추가가 필요하다는 점을 메모해 둔다.

  ```bash
  kubectl exec -it platform-db-postgres-postgresql-0 -n platform-db -c postgresql -- \
    env PGPASSWORD='<postgres-password from postgres-db-secret>' psql -U postgres -c \
    "CREATE USER mlflow_admin WITH PASSWORD '<비밀번호 관리자에서 신규 생성>';" -c \
    "CREATE DATABASE mlflow_db OWNER mlflow_admin;"
  ```

  평문 비밀번호는 비밀번호 관리자에만 남긴다 — 위 명령을 쉘 히스토리에 그대로
  남기지 않도록 주의(새 셸, 히스토리 무시 옵션, 또는 실행 후 즉시 히스토리
  삭제 중 편한 방법으로).

- [ ] **5. mlflow-secret SealedSecret 생성** — namespace `platform-mlops`,
      keys:
      - `MLFLOW_BACKEND_STORE_URI` = `postgresql://mlflow_admin:<pw>@platform-db-postgres-postgresql.platform-db.svc.cluster.local:5432/mlflow_db`
      - `AWS_ACCESS_KEY_ID` = (2단계에서 발급한 MinIO access key)
      - `AWS_SECRET_ACCESS_KEY` = (2단계에서 발급한 MinIO secret key)

  ```bash
  kubectl create secret generic mlflow-secret \
    --namespace platform-mlops --dry-run=client -o yaml \
    --from-literal=MLFLOW_BACKEND_STORE_URI='postgresql://mlflow_admin:<pw>@platform-db-postgres-postgresql.platform-db.svc.cluster.local:5432/mlflow_db' \
    --from-literal=AWS_ACCESS_KEY_ID='<access-key>' \
    --from-literal=AWS_SECRET_ACCESS_KEY='<secret-key>' \
    | kubeseal --format yaml \
    > manifests/security/mlflow-sealed-secret.yaml
  ```

  결과 파일을 커밋한다. 암호화된 결과물만 git에 들어간다는 점은 기존
  SealedSecret들과 동일 — 평문은 이 저장소 어디에도 남기지 않는다.

- [ ] **6. tailnet IP 치환** — `manifests/mlops/mlflow-deployment.yaml`의
      `MLFLOW_S3_ENDPOINT_URL` 값 `http://REPLACE-NAS-TAILNET-IP:9000`을
      3단계에서 실측한 실제 tailnet IP로 치환한다.
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
- [ ] **10. 백업 확장 검증** — `scripts/platform-backup.sh` 실행 후 결과
      backup set에 `mlflow_db.dump`가 포함돼 있는지 확인.

## 이 선작업 PR에 포함되지 않은 것

- Grafana datasource 연결 (ADR-0009 Step 4) — 별도 PR.
- Mac 실험 클러스터 (ADR-0009) — 별도 레포.
- 재학습 CronJob (Phase C) — 제품 테넌트 레포 몫.

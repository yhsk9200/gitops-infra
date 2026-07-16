# ---------------------------------------------------------------------------
# 커스텀 MLflow 이미지 — PostgreSQL 드라이버 + S3 클라이언트 베이킹
# ---------------------------------------------------------------------------
# 공식 이미지 ghcr.io/mlflow/mlflow:v3.6.0에는 psycopg2(backend store가
# PostgreSQL일 때 필요)와 boto3(artifact store가 S3 호환 — MinIO@NAS일 때
# 필요)가 포함돼 있지 않다 (2026-07-16 docker 실측: import 실패). ADR-0008
# 설계(backend store = platform-db의 mlflow_db, artifact store = MinIO@NAS,
# --serve-artifacts로 프록시)를 그대로 쓰려면 두 패키지가 서버 이미지에
# 있어야 해서 커스텀 이미지를 GHCR로 베이킹한다(레지스트리는 GHCR — Harbor는
# ADR-0006으로 제거됨).
#
# 태그 규칙: 업스트림 MLflow 버전 + `-pgN` 리비전 (예: v3.6.0-pg1). 이
# Dockerfile을 바꿀 때는 태그를 올리고, manifests/mlops의 image와
# validate.yaml의 arm64 가드 IMAGES를 같은 PR에서 함께 갱신한다 — 셋이
# 어긋나면 arm64 가드가 존재하지 않는 옛 태그를 검사하거나 배포가 GHCR에
# 없는 새 태그를 당겨 ImagePullBackOff가 난다.
#
# 버전 pin은 2026-07-16 로컬 arm64 빌드에서 pip이 해석한 실측값
# (psycopg2-binary 2.9.12 / boto3 1.43.49, import 성공 확인).
# ---------------------------------------------------------------------------
FROM ghcr.io/mlflow/mlflow:v3.6.0
RUN pip install --no-cache-dir psycopg2-binary==2.9.12 boto3==1.43.49

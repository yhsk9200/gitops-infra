# ADR-0001: AI 모델 시뮬레이터 플랫폼 구성 방향

## 상태

제안됨

## 날짜

2026-05-03

## 맥락

현재 `platform-infra` 저장소는 Kubernetes 기반 공용 인프라를 App of Apps 패턴으로 관리합니다.

현재 제공되는 주요 기반 요소:

- PostgreSQL
- Keycloak
- Harbor
- Prometheus/Grafana/Alertmanager
- Loki/Alloy
- Sealed Secrets
- local-path 기반 PVC

향후 별도 팀에서 모델 시뮬레이터 서비스를 개발할 예정입니다. 이 서비스는 AI 모델 파일을 사용하고, 특정 모델 버전을 기준으로 시뮬레이션을 수행하며, 결과를 검증/기록해야 합니다.

이 문서는 모델 시뮬레이터 서비스를 현재 플랫폼에 붙일 때의 권장 아키텍처와 책임 경계를 정리합니다. 실제 구현 매니페스트나 Helm values를 추가하지 않습니다.

## 결정

모델 시뮬레이터 영역은 `platform-infra`에 직접 통합하지 않고, 별도 GitOps 저장소 또는 별도 App of Apps 단위로 분리하는 방향을 권장합니다.

권장 1차 구성:

- MinIO: AI 모델 artifact와 시뮬레이션 입출력 파일을 저장하는 S3-compatible object storage
- MLflow: 모델 registry, 모델 버전, alias, metric, tag, 검증 이력 관리
- Simulator Backend: 모델 조회, artifact 접근, 시뮬레이션 실행, 검증 결과 기록
- Simulator UI: 업무 사용자용 시뮬레이션 실행/결과 조회 화면

초기에는 Kubeflow 전체 도입을 보류합니다. 학습, 검증, 시뮬레이션 workflow 자동화 요구가 명확해지면 Kubeflow Pipelines부터 부분 도입을 검토합니다.

## 권장 저장소 경계

`platform-infra`는 공용 기반 인프라를 유지합니다.

예:

- PostgreSQL
- Keycloak
- Harbor
- Monitoring
- Logging
- Sealed Secrets
- StorageClass/PVC 기본 리소스

AI/시뮬레이터 영역은 별도 저장소를 권장합니다.

예:

- `platform-ai`
- `platform-model-simulator`
- `ai-simulation-platform`

권장 구조:

```text
platform-ai
├── bootstrap/
├── apps/
│   ├── platform-ai-minio.yaml
│   ├── platform-ai-mlflow.yaml
│   └── platform-ai-model-simulator.yaml
├── helm-values/
│   ├── minio/
│   ├── mlflow/
│   └── simulator/
├── manifests/
│   ├── namespaces/
│   ├── security/
│   └── bootstrap-jobs/
└── docs/
```

`platform-infra`에서는 필요 시 아래 정도만 연결합니다.

- ArgoCD AppProject source repo 허용
- 최상위 Root App에서 `platform-ai` Root App 참조
- 공용 Keycloak/PostgreSQL/Grafana와의 연동 기준 문서화

## 개념 아키텍처

```text
User
  -> Simulator UI
  -> Simulator Backend
  -> MLflow API
  -> MinIO Artifact Store

Operator / AI Engineer
  -> MLflow UI
  -> 모델 버전, metric, alias, tag, 검증 이력 확인

Platform Operator
  -> MinIO Console
  -> bucket, policy, 용량, object 상태 확인
```

권장 데이터 흐름:

```text
1. 학습 또는 수동 등록 과정에서 모델 artifact를 MLflow에 기록
2. MLflow artifact root는 MinIO bucket을 사용
3. 모델은 MLflow Model Registry에 등록
4. candidate model version에 alias 또는 tag 부여
5. Simulator Backend가 MLflow에서 검증 대상 모델 조회
6. Simulator Backend가 MinIO에서 모델 artifact 로드
7. Simulator Backend가 시뮬레이션 실행
8. 검증 결과를 자체 DB와 MLflow metric/tag로 기록
9. 운영자 또는 승인자가 결과 확인 후 champion alias 승격 여부 결정
```

## MLflow와 MinIO 책임

MLflow는 모델 파일 저장소 자체가 아니라 모델 lifecycle metadata를 관리합니다.

MLflow 책임:

- Registered Model 관리
- Model Version 관리
- Model alias 관리
- Run, metric, parameter, tag 기록
- 검증 결과와 모델 lineage 추적
- 운영자/AI 엔지니어용 UI 제공

MinIO 책임:

- 모델 파일 저장
- 학습 checkpoint 저장
- 시뮬레이션 입력 데이터 저장
- 시뮬레이션 결과 파일 저장
- MLflow artifact store 제공
- 폐쇄망 내부 S3-compatible API 제공

권장 bucket 예시:

```text
mlflow-artifacts
model-artifacts
simulation-inputs
simulation-results
kfp-artifacts
```

`kfp-artifacts`는 Kubeflow Pipelines를 나중에 도입할 경우를 대비한 후보입니다.

## Simulator UI 책임

Simulator UI는 일반 사용자 또는 업무 담당자가 사용하는 제품 화면입니다. MLflow UI를 대체하는 것이 아니라, 시뮬레이션 업무 흐름을 제공해야 합니다.

MVP 화면:

- 모델 목록
- 모델 상세
- 시뮬레이션 실행
- 실행 결과 상세
- 실행 이력

확장 화면:

- 대시보드
- 모델 버전 비교
- 시뮬레이션 시나리오 관리
- candidate 모델 승인/반려
- threshold 설정
- 결과 리포트
- 알림 이력

## Simulator Backend 책임

Simulator Backend는 UI가 MLflow와 MinIO를 직접 호출하지 않도록 감싸는 업무 API 계층입니다.

주요 책임:

- Keycloak 기반 인증/RBAC 연동
- MLflow registered model 목록 조회
- MLflow model version, alias, tag 조회
- 특정 model version artifact 접근
- MinIO presigned URL 발급 또는 내부 다운로드 처리
- 표준 시뮬레이션 시나리오 관리
- 시뮬레이션 실행 요청 접수
- 동기/비동기 실행 제어
- 시뮬레이션 결과 저장
- 검증 metric 계산
- pass/fail 판정
- MLflow metric/tag/run 기록
- 감사 로그 기록

초기에는 사람이 승인하는 흐름을 권장합니다.

```text
simulator-candidate -> 시뮬레이터 검증 -> 결과 확인 -> 사람이 champion 승격
```

자동 승격은 검증 기준과 운영 책임이 안정화된 뒤 검토합니다.

## 권장 alias/tag 모델

MLflow Model Registry에서는 고정 stage보다 alias와 tag 중심 운영을 권장합니다.

권장 alias:

- `simulator-candidate`
- `champion`
- `rollback`

권장 tag:

- `validation_status=pending`
- `validation_status=passed`
- `validation_status=failed`
- `simulator_run_id=<run-id>`
- `simulator_score=<score>`
- `dataset_version=<version>`
- `model_format=onnx`
- `approved_by=<user>`

Simulator Backend는 최소한 아래 정보를 MLflow에 남겨야 합니다.

- 어떤 모델 버전을 검증했는지
- 어떤 시나리오를 사용했는지
- 어떤 입력 데이터 버전을 사용했는지
- 어떤 metric이 계산되었는지
- pass/fail 결과가 무엇인지
- 누가 승인 또는 반려했는지

## Kubeflow 검토 기준

Kubeflow는 모델 저장소 때문에 도입하는 도구가 아닙니다. 학습/검증/배포 workflow가 복잡해질 때 검토합니다.

Kubeflow 도입 후보 조건:

- 학습, 검증, 시뮬레이션 단계를 반복 가능한 pipeline으로 관리해야 함
- 데이터 사이언티스트가 Notebook을 클러스터 안에서 사용해야 함
- 하이퍼파라미터 튜닝이 필요함
- GPU 기반 분산 학습이 필요함
- 모델 serving, canary, autoscaling이 필요함
- 여러 팀이 AI 플랫폼을 공용으로 사용하고 namespace/RBAC/quota가 필요함

현 단계 권장:

```text
1단계: MLflow + MinIO + Simulator
2단계: Kubeflow Pipelines 부분 도입 검토
3단계: Notebooks, Katib, Trainer, KServe 필요성 재평가
```

Kubeflow를 나중에 도입하더라도 AI artifact storage는 MinIO를 공통 저장소로 유지하는 방향을 우선 검토합니다.

## SeaweedFS와 MinIO 판단

Kubeflow Pipelines는 버전에 따라 기본 object store로 SeaweedFS를 사용할 수 있습니다. 하지만 현재 팀 운영 난이도와 S3 호환 생태계를 고려하면 AI artifact store의 기본 후보는 MinIO가 더 적합합니다.

MinIO를 우선 검토하는 이유:

- S3-compatible API가 명확함
- MLflow artifact store와 연동하기 쉬움
- bucket, access key, policy 중심이라 설명이 쉬움
- 폐쇄망 내부 object storage로 이해하기 쉬움
- 운영 경험이 없는 팀에게 전달하기 좋음

SeaweedFS는 Kubeflow 내부 구성으로는 사용할 수 있지만, 플랫폼 공통 모델 저장소 전략의 1차 후보로 삼기에는 운영 개념이 더 복잡합니다.

## 보안과 접근 제어

초기 접근 원칙:

- MLflow UI는 일반 사용자에게 공개하지 않음
- MLflow UI는 운영자/AI 엔지니어 내부 접근으로 제한
- MinIO Console은 플랫폼 운영자 접근으로 제한
- Simulator UI만 업무 사용자에게 노출
- Simulator Backend가 MLflow/MinIO 접근을 중계

향후 연동:

- Keycloak OIDC
- namespace 단위 RBAC
- bucket policy 분리
- read/write service account 분리
- audit log 수집

## 비목표

이 ADR은 아래 항목을 결정하지 않습니다.

- 모델 형식
- 시뮬레이션 알고리즘
- 합격/불합격 기준
- 모델 학습 방식
- 모델 serving 방식
- GPU 사용 여부
- Kubeflow 도입 확정
- MinIO 운영 토폴로지 확정
- 별도 AI GitOps 저장소 이름 확정

## 미해결 질문

- 모델 파일 형식은 무엇인가?
- 모델 크기와 예상 저장량은 어느 정도인가?
- 시뮬레이션은 동기 요청인가, 장기 실행 batch인가?
- 시뮬레이션 입력 데이터는 사용자가 업로드하는가, 표준 시나리오를 사용하는가?
- 검증 metric과 pass/fail 기준은 누가 정의하는가?
- 모델 승인 권한자는 누구인가?
- 모델 artifact와 시뮬레이션 결과 보관 기간은 얼마인가?
- MinIO는 단일 노드 PoC로 시작할 것인가, 별도 디스크/NAS/다중 노드 구성을 할 것인가?
- AI 플랫폼 저장소를 어떤 이름과 책임 범위로 만들 것인가?

## 결과

이 결정은 모델 시뮬레이터 팀의 구현 방식을 강제하지 않습니다. 대신 현재 플랫폼 환경에서 잘 맞는 기준 인터페이스를 제안합니다.

플랫폼 팀은 아래를 제공하는 방향으로 준비합니다.

- MLflow/MinIO 기반 모델 저장/버전 관리 reference architecture
- Keycloak 연동 기준
- App of Apps 기반 배포 기준
- observability/logging 연동 기준
- 백업/복구 고려사항

시뮬레이터 팀은 아래를 책임지는 방향이 적절합니다.

- Simulator UI
- Simulator Backend
- 모델 로딩 방식
- 시뮬레이션 시나리오
- 검증 metric
- 합격/불합격 기준
- 업무 승인 흐름

따라서 현재 권장안은 다음과 같습니다.

```text
MLflow + MinIO를 1차 reference architecture로 두고,
Simulator UI/Backend는 별도 플랫폼 또는 서비스 저장소에서 App of Apps 패턴으로 관리한다.
Kubeflow는 workflow 자동화 요구가 명확해진 뒤 부분 도입부터 검토한다.
```

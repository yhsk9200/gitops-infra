# ADR-0005: IaC 레이어링과 레포 전략 — 플랫폼 모노레포 + 3-레이어

## 상태

제안됨 (초안). 비준·실행 시 `승인됨`으로 전환.

## 날짜

2026-06-15

## 맥락

이 레포는 시작부터 **배포 레이어**(ArgoCD App-of-Apps)만 코드화되어 있었다. 그 아래 두 레이어는 코드 밖에 있다.

- **프로비저닝**: OCI 인스턴스·네트워크를 콘솔에서 수동 생성 (런북 Phase 0)
- **노드 설정**: sysctl·k3s 설치·ArgoCD 부트스트랩을 SSH로 수동 실행 (런북 Phase 1~3)

`docs/cluster-rebuild-runbook.md`가 이 수동 절차를 문서로 메우고 있지만, "콘솔 클릭 + SSH 50줄"은 재현성이 사람 손에 의존한다. 동시에 레포에 손댈 일이 늘고 있다 (Ansible/Terraform 도입 검토, Alertmanager receiver, SSO 통합, 향후 AI 시뮬레이터 — ADR-0001). 새 코드·도구가 들어오기 전에 **무엇을 어느 레포의 어디에 두고 어떻게 관리할지**를 먼저 정해야 구조가 흐트러지지 않는다.

판단 기준은 이 레포의 일관된 가치다: 단독 운영·단일 클러스터·무료 티어라는 제약 위에서 **운영 표면을 늘리지 않으면서** 플랫폼 수명주기를 증거로 보여주는 것.

## 결정

### A. 3-레이어 IaC 모델

플랫폼 수명주기를 명시적 3레이어로 코드화하고, 각 레이어의 소유 범위를 분리한다.

| 레이어 | 도구 | 소유 범위 |
|---|---|---|
| 프로비저닝 | **Terraform** | OCI VCN·subnet·Security List(22/80/443), 기존 인스턴스 `import` |
| 설정 | **Ansible** | sysctl(inotify), k3s 설치, kubeconfig 회수, ArgoCD 설치, Root App 적용 |
| 배포 | **ArgoCD** (현행) | `apps/`·`apps-ondemand/` Application, helm-values, manifests |

도구별 채택 범위는 의도적으로 다르게 잡는다 (근거 3).

- **Ansible — 지금 채택, 풀 범위.** 런북 Phase 1~3을 멱등 playbook으로. **단, reseal(런북 3.4)은 제외** — 평문 시크릿이 Ansible vars/로그에 닿으면 안 되므로, ArgoCD 설치와 Root App 적용 사이의 *수동 경계*로 남긴다.
- **Terraform — 범위 축소 채택.** "한 줄 프로비저닝"이 아니라 **network + 기존 인스턴스 import**로 한정.

### B. 레포 경계 — 플랫폼 모노레포 + 제품 단위 분리

- 3레이어 전부를 **이 레포(`gitops-infra`) 한 곳**에 둔다 (형제 디렉토리 `terraform/`, `ansible/`, 그리고 현행 GitOps 디렉토리들).
- 레포를 쪼개는 경계는 **제품 단위**에 둔다 — AI 시뮬레이터(ADR-0001, MLflow+MinIO)는 별도 레포로 유지.

### C. 브랜치/배포 모델 — 트렁크 기반

- **main = 배포 대상.** ArgoCD가 `main`을 auto-sync하므로 main 머지 = 배포.
- 모든 변경: 짧은 수명 브랜치 → PR → CI(`validate.yaml`) 통과 → 머지. 장수 dev/staging 브랜치는 두지 않는다 (단일 클러스터 = 단일 환경).

### D. 시크릿·CI·문서 (기존 원칙 재확인 + 확장)

- **시크릿**: Git 평문 금지 (ADR-0003 원칙 계승). k8s는 SealedSecret만, Terraform `.tfvars`/state·Ansible vars는 gitignore, reseal은 수동 경계(위 A).
- **CI**: `validate.yaml`에 `terraform fmt -check`/`validate`, `ansible-lint`/`--syntax-check`를 경로 필터 잡으로 추가.
- **문서 역할**: ADR(*왜*, canonical) / README(*무엇*) / CLAUDE.md(세션 상태·다음 작업) / runbook·checklist(운영 절차).

## 근거

### 1. 단독 운영·단일 클러스터에선 모노레포가 우월하다

멀티레포의 이점(독립 릴리스·접근 제어·blast radius 분리)은 팀·다환경에서 나온다. 운영자 1명·클러스터 1개에선 그 이점이 발생하지 않고 레포 동기화·교차 PR·컨텍스트 전환 비용만 남는다. 반대로 한 레포에 프로비저닝→설정→배포가 모여 있으면 리뷰어가 플랫폼 수명주기 전체를 한 번에 읽는다 — "초점은 노드 수가 아니라 플랫폼 운영"이라는 ADR-0002의 논리와 일치한다.

ArgoCD Root App은 `apps/`만 스캔하므로 `terraform/`·`ansible/`를 같은 레포에 둬도 배포에 간섭이 없다 → 모노레포의 기술적 비용도 0이다.

### 2. 경계는 제품에서 끊는다

모노레포의 실패 모드는 "잡탕"이다. 경계를 *레이어*가 아니라 *제품 수명주기*에 두면 이를 막는다. 공용 플랫폼 인프라(이 레포)와 그 위에 얹히는 제품(AI 시뮬레이터)은 변경 주기·소유권·배포 대상이 다르므로 레포를 가른다. ADR-0001의 "별도 레포" 결정을 이 원칙으로 일반화한다.

### 3. 도구는 "재현 가능한가"로 범위를 정한다

- **Ansible 풀 채택**: 런북 Phase 1~3이 task에 1:1로 매핑되고, 결과물이 *멱등·실행 가능*하다. 임의 Ubuntu 노드에 겨눠도 k3s+ArgoCD가 재현된다. 재구축을 playbook의 첫 실행으로 삼으면 코드가 곧바로 검증된다.
- **Terraform 축소**: OCI Always Free A1은 capacity 부족("Out of host capacity")으로 `apply` 생성이 비결정적이고, 인스턴스는 이미 존재한다(`158.179.169.201`). 따라서 TF로 "한 줄 생성"은 지킬 수 없는 약속이다. 대신 재현 가능한 부분(network/Security List 선언 + 기존 인스턴스 import)으로 한정하고, A1 capacity 한계 자체를 트레이드오프로 기록한다. 단일 박스에 풀 TF를 짜는 것은 오히려 over-engineering 신호가 될 수 있다.

### 4. main = 프로덕션이므로 PR 게이트가 유일한 사전 안전장치

auto-sync 구조에서 머지는 곧 배포다. 단독이어도 PR은 (a) CI 실행 지점, (b) 클러스터 반영 전 diff 확인 지점이며, 의례가 아니라 사전 검증의 유일한 자리다. 다환경 승격 경로를 만들지 않는 것은 환경이 하나뿐이기 때문이다 — 억지 staging은 가짜 신호다.

## 결과 / 영향

- 디렉토리: `terraform/`, `ansible/` 신설 예정. 기존 GitOps 디렉토리(`apps/` 등)는 불변.
- `.gitignore`에 `*.tfvars`, `*.tfstate*`, `.terraform/` 추가 필요.
- `validate.yaml`에 TF/Ansible lint 잡 추가 → CI가 3레이어 전부를 검증.
- 런북(`cluster-rebuild-runbook.md`) Phase 1~3은 Ansible playbook으로 대체/참조되고, reseal 수동 단계만 절차로 남는다.
- CLAUDE.md "레포 전략" 섹션이 이 ADR의 운영 요약으로 연결된다.

## 비목표

- 멀티 환경(dev/staging/prod) 승격 파이프라인 — 클러스터가 하나뿐.
- Terraform 원격 state 백엔드(OCI Object Storage 등) — 단독 운영이라 로컬 state로 시작, 협업 발생 시 재검토.
- Ansible로 시크릿 생성/주입 자동화 — 수동 reseal 경계 유지(결정 A).
- 멀티레포 전환 — 두 번째 제품이 생기기 전까지.

## 재검토 조건

- **두 번째 운영자/환경**이 생기면: 원격 state 백엔드 + 환경별 승격 경로 + 접근 제어 단위 레포 분리를 재설계.
- **두 번째 제품**이 추가되면: 제품 경계로 레포를 가르는 본 원칙을 적용(또는 모노레포 + 명확한 디렉토리 경계로 재평가).
- OCI가 A1 on-demand 생성을 안정적으로 제공하게 되면: Terraform 범위를 인스턴스 생성까지 확장.

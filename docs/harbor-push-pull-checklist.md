# Harbor Push/Pull 검증 체크리스트

이 문서는 외부 Docker 클라이언트에서 Harbor에 로그인하고 이미지를 push/pull 하는 절차를 정리합니다.

현재 Harbor 외부 접속 주소:

```text
http://harbor.210.113.225.245.nip.io
```

Docker registry 주소:

```text
harbor.210.113.225.245.nip.io
```

## 1. Harbor 상태 확인

```bash
kubectl get application platform-registry-harbor -n argocd
kubectl get pods -n platform-registry -o wide
kubectl get ingress -n platform-registry
kubectl get svc -n platform-registry
```

정상 기준:

- Harbor 관련 pod가 `Running` / `Ready` 상태입니다.
- Harbor exporter pod가 `Running` / `Ready` 상태입니다.
- Harbor UI에 접속할 수 있습니다.
- `platform-registry-harbor`가 `Healthy` 상태입니다.
- `Healthy + OutOfSync`는 README의 Harbor 운영 메모에 기록된 known diff일 수 있습니다.

## 2. externalURL 반영 확인

Harbor core ConfigMap에 표준 HTTP 80 포트 기준 주소가 반영되어야 합니다.

```bash
kubectl get configmap platform-registry-harbor-core -n platform-registry -o yaml | grep EXT_ENDPOINT
```

기대값:

```text
EXT_ENDPOINT: http://harbor.210.113.225.245.nip.io
```

core pod 내부 설정도 확인할 수 있습니다.

```bash
kubectl get pods -n platform-registry | grep harbor-core
kubectl exec -it <harbor-core-pod> -n platform-registry -c core -- sh -c 'env | grep EXT_ENDPOINT'
```

## 3. Docker insecure registry 설정

현재 Harbor는 HTTP로 노출되어 있습니다. 외부 Docker 클라이언트에서 아래 registry를 insecure registry로 허용해야 합니다.

```text
harbor.210.113.225.245.nip.io
```

Linux Docker 예시:

```bash
sudo mkdir -p /etc/docker
sudo vi /etc/docker/daemon.json
```

```json
{
  "insecure-registries": [
    "harbor.210.113.225.245.nip.io"
  ]
}
```

Docker 재시작:

```bash
sudo systemctl restart docker
docker info | grep -A5 "Insecure Registries"
```

Docker Desktop을 사용하는 경우:

- Docker Desktop 설정 화면을 엽니다.
- Docker Engine 설정에 `insecure-registries` 값을 추가합니다.
- Docker Desktop을 재시작합니다.

## 4. Harbor 프로젝트 준비

Harbor UI에서 테스트용 프로젝트를 생성합니다.

권장 테스트 프로젝트:

```text
library
```

또는 별도 테스트 프로젝트:

```text
push-test
```

주의:

- 프로젝트가 없으면 push가 실패합니다.
- public/private 여부는 테스트 목적에 맞게 선택합니다.

## 5. Docker 로그인

```bash
docker login harbor.210.113.225.245.nip.io
```

관리자 계정:

- ID: `admin`
- Password: `harbor-admin-secret`의 `admin-password`

비밀번호 확인:

```bash
kubectl get secret harbor-admin-secret -n platform-registry -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

정상 기준:

```text
Login Succeeded
```

## 6. 테스트 이미지 Push

로컬에 테스트 이미지가 없다면 작은 이미지를 사용합니다.

```bash
docker pull busybox:latest
docker tag busybox:latest harbor.210.113.225.245.nip.io/library/busybox:push-test
docker push harbor.210.113.225.245.nip.io/library/busybox:push-test
```

별도 프로젝트를 사용한다면 `library` 대신 해당 프로젝트명을 사용합니다.

```bash
docker tag busybox:latest harbor.210.113.225.245.nip.io/push-test/busybox:push-test
docker push harbor.210.113.225.245.nip.io/push-test/busybox:push-test
```

정상 기준:

- push가 끝까지 완료됩니다.
- Harbor UI에서 repository와 tag가 보입니다.

## 7. 테스트 이미지 Pull

로컬 이미지를 지운 뒤 Harbor에서 다시 pull 합니다.

```bash
docker rmi harbor.210.113.225.245.nip.io/library/busybox:push-test
docker pull harbor.210.113.225.245.nip.io/library/busybox:push-test
```

정상 기준:

- Harbor에서 이미지가 정상적으로 다운로드됩니다.

## 8. 자주 나는 오류와 확인 포인트

### `server gave HTTP response to HTTPS client`

원인:

- Docker 클라이언트가 Harbor를 HTTPS registry로 간주했습니다.

확인:

- Docker daemon의 `insecure-registries`에 `harbor.210.113.225.245.nip.io`가 들어 있는지 확인합니다.
- Docker daemon 또는 Docker Desktop을 재시작했는지 확인합니다.

### `unauthorized` 또는 `authentication required`

원인:

- 로그인이 안 되었거나 계정 권한이 부족합니다.
- push 대상 프로젝트가 없거나 권한이 없습니다.

확인:

```bash
docker logout harbor.210.113.225.245.nip.io
docker login harbor.210.113.225.245.nip.io
```

Harbor UI에서 프로젝트와 사용자 권한을 확인합니다.

### 토큰 또는 redirect URL이 예전 22280 포트로 보이는 경우

원인:

- Harbor `externalURL` 변경이 아직 반영되지 않았습니다.

확인:

```bash
kubectl get configmap platform-registry-harbor-core -n platform-registry -o yaml | grep EXT_ENDPOINT
```

조치:

- `helm-values/registry/harbor-values.yaml`의 `externalURL` 값을 확인합니다.
- ArgoCD에서 `platform-registry-harbor`를 `Hard Refresh + Sync` 합니다.

### `connection refused` 또는 timeout

원인:

- 외부 방화벽/NAT가 80 포트를 Harbor ingress로 전달하지 못합니다.

확인:

```bash
curl -I http://harbor.210.113.225.245.nip.io
```

조치:

- 외부 방화벽/NAT의 `80 -> ingress 80` 포워딩을 확인합니다.
- 클러스터 ingress controller 상태를 확인합니다.

## 9. 검증 기록

| 날짜 | 작업자 | 프로젝트 | Push 결과 | Pull 결과 | 비고 |
| --- | --- | --- | --- | --- | --- |
|  |  |  |  |  |  |

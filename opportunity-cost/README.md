# Opportunity Cost Dashboard 🌱

작고 가벼운 단일 페이지 기회비용 계산기입니다.

- 입력한 지출 금액을 쓰지 않고 일정 기간 굴렸을 때의 복리 이자를 계산합니다.
- 기준 금리는 미국 재무부 **Fiscal Data API**의 `Treasury Bills` 평균금리 최신 1개 레코드만 요청합니다.
- API 요청은 페이지 로드 시 1회, 필드는 3개만 받고 `page[size]=1`로 제한합니다.
- API가 실패하거나 느리면 4.00% 기본값으로 즉시 동작합니다.
- 빌드 도구/프레임워크/외부 폰트/분석 스크립트가 없습니다.

## 실행

`opportunity-cost/index.html`을 브라우저에서 열면 됩니다. 브라우저의 CORS 정책이나 로컬 파일 정책 때문에 API 호출이 차단되면 기본 금리로 계산됩니다.

## 계산

`미래가치 = 원금 × (1 + 연이율)^기간`

`기회비용 = 미래가치 - 원금`

세금, 물가, 환율, 투자 위험을 반영하지 않는 단순 비교 도구이며 투자 조언이 아닙니다.

## 데이터 출처

U.S. Department of the Treasury, Bureau of the Fiscal Service — Fiscal Data API, Average Interest Rates on U.S. Treasury Securities.

# WKWebView 이미지 로딩 문제 디버깅

**날짜**: 2026-02-24
**세션**: 이전 세션에서 이어진 작업 (context compaction 후 계속)

## 배경

macOS용 Markdown Viewer 앱 ("Markdown Viewser")에서 마크다운 내 상대 경로 이미지가 표시되지 않는 문제를 해결 중.

### 이전 세션에서 파악된 사항
- `fileURL`이 올바르게 전달됨 (`/private/tmp/md-test/imgtest.md`)
- `baseDirectory`가 올바르게 설정됨 (`/private/tmp/md-test`)
- `setImageBaseDir()` JS 함수가 호출됨
- `resolveRelativePaths()`가 상대 경로를 올바르게 식별
- `fetch()`는 `file://` URL에 접근 불가 (status 0)
- **핵심 발견**: 하드코딩된 `<img src="file:///absolute">` HTML은 WKWebView에서 동작함
- 마지막 시도: `img.setAttribute('src', 'file://' + baseDir + '/' + src)` 접근법

## 이번 세션의 작업 흐름

### 1차 시도: HTML 문자열 내 경로 치환 (innerHTML 전)

WKWebView가 DOM 삽입 후 동적으로 변경된 `file://` src를 차단한다는 가설 하에, `md.render()` 결과 HTML 문자열을 `innerHTML`에 할당하기 **전에** 정규식으로 상대 경로를 절대 경로로 변환하는 `resolveImagePathsInHTML()` 함수 작성.

```javascript
function resolveImagePathsInHTML(html) {
    if (!_imageBaseDir) return html;
    html = html.replace(
        /(<img\s[^>]*?\bsrc\s*=\s*")(?!https?:\/\/|file:\/\/|data:|blob:)([^"]+)(")/gi,
        '$1file://' + _imageBaseDir + '/$2$3'
    );
    // 단따옴표 버전도 처리
    ...
    return html;
}
```

**결과**: 실패. 모든 4가지 테스트 케이스에서 이미지 로딩 안됨.
- 이전에 동작했던 하드코딩 `<img src="file:///...">` (test case #4)도 이번에는 동작하지 않음.
- 이는 경로 치환 문제가 아니라 **WKWebView 자체가 `file://` URL 이미지 로딩을 차단**하고 있음을 의미.

### 2차 시도: WKURLSchemeHandler (custom scheme)

`file://` 대신 커스텀 URL 스킴 (`localfile://`)을 등록하여 WKWebView의 file:// 보안 제한을 우회하는 접근.

**새로 생성한 파일**: `LocalFileSchemeHandler.swift`
- `WKURLSchemeHandler` 프로토콜 구현
- `localfile:///path/to/file` URL을 받아서 로컬 파일을 읽어 응답
- MIME 타입은 `UTType`으로 자동 감지

**변경 사항**:
- `MarkdownWebView.swift`: `config.setURLSchemeHandler()` 등록
- `render.html`: `resolveImagePathsInHTML()`에서 `localfile://` 사용으로 변경
- `render.html`: `file://` → `localfile://` 변환 추가 (절대 경로 마크다운용)

**결과**: 실패. scheme handler의 debug 파일이 생성되지 않음 → handler가 아예 호출되지 않음.

### 3차: 디버깅 시도

여러 가지 디버깅 접근 시도:
1. **JS debug element** (`container.prepend(debugEl)`): 화면에 표시되지 않음
2. **`document.title` 변경**: SwiftUI가 window title을 override하여 볼 수 없음
3. **Swift 측 `evaluateJavaScript` debug**: render 후 상태를 `/tmp/mv-render-debug.txt`에 쓰기 시도 → 파일 생성 안됨
4. **Scheme handler debug log**: `/tmp/mv-scheme-debug.txt` → 파일 생성 안됨

**핵심 의문점**:
- `render()` JS 함수는 호출되고 있음 (콘텐츠가 렌더링됨: 헤딩, 텍스트 보임)
- 하지만 debug 코드가 작동하지 않음
- scheme handler도 호출되지 않음
- Swift evaluateJavaScript 결과 파일도 생성 안됨

## 테스트 파일

**위치**: `/tmp/md-test/imgtest.md`

```markdown
# Image Test

## Relative path (should be resolved by JS)
![test image](diagrams/inference.png)

## Absolute file URL (should work directly)
![test image](file:///private/tmp/md-test/diagrams/inference.png)

## HTML img tag relative
<img src="diagrams/inference.png" alt="html relative" height="100px"/>

## HTML img tag absolute
<img src="file:///private/tmp/md-test/diagrams/inference.png" alt="html absolute" height="100px"/>
```

**이미지 파일**: `/tmp/md-test/diagrams/inference.png` (2.4MB, 존재 확인됨)

## 현재 상태 (미해결)

### 확인된 사실
- App Sandbox: **비활성화** (`ENABLE_APP_SANDBOX = NO`)
- `allowingReadAccessTo: URL(fileURLWithPath: "/")` 설정됨
- `allowFileAccessFromFileURLs` 설정됨
- `webView.isInspectable = true` 설정됨
- 정규식 로직은 정상 동작 (node.js 테스트 통과)

### 미스터리
1. `render()` 함수가 콘텐츠를 렌더링하지만, 같은 함수 내의 debug 코드가 효과 없음
2. Swift의 `evaluateJavaScript` completion handler에서 파일 쓰기가 안됨
3. `WKURLSchemeHandler`가 등록되었지만 호출되지 않음

### 다음 세션에서 시도할 것
1. **Safari Web Inspector로 직접 디버깅** - `isInspectable = true`로 설정되어 있으므로 Safari > Develop 메뉴에서 WKWebView 콘솔 확인 가능
2. **render.html 자체를 브라우저에서 테스트** - WKWebView 없이 render.html의 JS가 정상 동작하는지 확인
3. **markdown-it의 file:// URL 처리 확인** - test case #2가 raw text로 출력됨 → markdown-it이 `file://` scheme을 이미지 URL로 인식 안하는 것일 수 있음
4. **WKWebView의 로그 캡처** - `WKNavigationDelegate`의 에러 콜백이나 `webView(_:didFail:)` 등으로 에러 확인
5. **다른 접근법 고려**:
   - 이미지를 base64로 인코딩하여 data: URL로 삽입 (Swift에서 전처리)
   - WKWebView 대신 local HTTP server 실행하여 localhost로 리소스 제공

## 변경된 파일 목록

| 파일 | 변경 내용 |
|------|-----------|
| `MarkdownViewser/LocalFileSchemeHandler.swift` | **신규** - WKURLSchemeHandler 구현 |
| `MarkdownViewser/MarkdownWebView.swift` | scheme handler 등록, debug JS 추가 |
| `MarkdownViewser/Resources/render.html` | `resolveImagePathsInHTML()` 함수 (localfile:// 사용), debug 코드 |

## 프로젝트 구조 참고

- XcodeGen 기반 (`project.yml`)
- `xcodegen generate` → `xcodebuild` 워크플로우
- 리소스는 `MarkdownViewser/Resources/`에서 빌드 스크립트로 복사
- 디버그 빌드는 sandbox 없이 ad-hoc 서명

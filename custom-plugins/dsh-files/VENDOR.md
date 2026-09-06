# Vendored third-party plugin: `dsh-files` (v0.4.1)

- **Upstream:** https://github.com/taxueseek/dsh-files (MIT)
- **Pin:** tag `v0.4.1` — commit `6b761bba1ccf55ffa5ecbf132b50937f934f73f1`
- **Contents:** the published package file set (`lib/`, `cordis.patch.yml`,
  `package.json`, `LICENSE`, `CHANGELOG.md`, `README.md`, `README.zh.md`),
  copied verbatim from the npm install layout. Runtime dependencies are NOT
  vendored — the installers run `npm install` for `mammoth` / `pdfjs-dist` /
  `read-excel-file` (see install.sh / install.ps1 / Dockerfile).

## Why this version (and not latest 0.5.x)

This deployment pins `@deepseek-ai/dsh@0.1.1-rc.2` (read-only employee
assistant, no shell / no file tools). dsh-files **0.5.x** requires a host
with the native upload pipeline ("harness >= 0.1.3") and removed its own
composer upload surface — on 0.1.1-rc.2 it would register only `read_document`
and lose the attach UI. **0.4.1** is the last release whose paperclip / folder /
drag-drop upload, image draft path and `@` file references work on this host
pair (verified against the reference web profile running the same
`@deepseek-ai/dsh@0.1.1-rc.2`). Bump together with the dsh pin and re-test.

## Behaviour on this profile

- Composer buttons: 「上传文件」(📎) / 「上传文件夹」(📁) + drag-drop + `@`
  file candidates, occupying `conversation.input.left` and
  `conversation.input.dock`.
- Uploads `POST /api/upload` (auth-proxy → harness; login-gate protected),
  stored per session under the pinned workspace:
  `<FMS_WORKSPACE_DIR>/.dsh-filess/<sessionId>/`, TTL-swept
  (`uploadTtlMs`, default 7 days).
- `read_document` tool: sniffed-format text extraction for
  text/PDF/DOCX/XLSX with offset/limit paging and XLSX `list_sheets`/`sheet`.
- No file ever leaves the instance — extraction happens locally, nothing is
  sent to Rails (the retired `fms-doc-attach` pipeline uploaded to Rails and
  read extracted text via the `document.read` MCP tool).

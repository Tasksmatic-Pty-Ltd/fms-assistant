// fms-doc-attach — the composer's "📎 上传文档" row (方案 B document pipeline).
//
// Occupies the `conversation.input.dock` seat with a small row above the
// composer card. Flow: pick a file → POST it to Rails
// /api/assistant/v1/documents (same-origin — the auth-proxy forwards
// /api/assistant/* to Rails with the FMS session cookie) → on 201, send the
// agent a "请处理文档 #<id>" prompt through the conversation service. The
// agent reads the extracted text on demand via the `document.read` MCP tool;
// the binary never reaches the harness.
//
// The upload endpoint authenticates by the browser's FMS session cookie (the
// login gate already verified it) or by a Bearer api_key / Basic pair, so
// employees do not need to mint anything to attach a document.
window.__ModuleLoader__.load({
	id: "fms-doc-attach",
	factory: (require) => {
		var module = { exports: {} };
		var exports = module.exports;

		var react = require("react");
		var react_jsx_runtime = require("react/jsx-runtime");

		var ACCEPT = ".pdf,.xlsx,.docx,.csv,.txt,.png,.jpg,.jpeg,.webp";
		var MAX_BYTES = 10 * 1024 * 1024;

		function DocDock(props) {
			var fileRef = react.useRef(null);
			var busyRef = react.useRef(false);
			var [, force] = react.useReducer(function (x) { return x + 1; }, 0);

			function setBusy(v) {
				busyRef.current = v;
				force();
			}

			function pick() {
				if (fileRef.current) fileRef.current.click();
			}

			function onFile(e) {
				var file = e.target.files && e.target.files[0];
				e.target.value = ""; // allow re-picking the same file
				if (!file) return;

				if (file.size > MAX_BYTES) {
					props.notify("error", "文件超过 10MB 上限，请压缩后重试");
					return;
				}
				setBusy(true);
				var form = new FormData();
				form.append("file", file);
				fetch("/api/assistant/v1/documents", { method: "POST", body: form })
					.then(function (res) {
						return res.json().catch(function () { return {}; }).then(function (data) {
							return { status: res.status, data: data };
						});
					})
					.then(function (out) {
						if (out.status === 201) {
							var d = out.data;
							var label = d.filename || "上传的文件";
							props.sendDoc("请处理文档 #" + d.id + "（" + label + "）");
							if (d.status === "error") {
								props.notify("error", "文档已上传，但文本提取失败：" + (d.error || "未知原因"));
							}
						} else {
							props.notify("error", "上传失败（" + out.status + "）：" + (out.data.error || "请重试"));
						}
					})
					.catch(function () {
						props.notify("error", "上传失败：无法连接服务器，请重试");
					})
					.finally(function () {
						setBusy(false);
					});
			}

			var buttonStyle = {
				display: "inline-flex",
				alignItems: "center",
				gap: 6,
				padding: "3px 10px",
				border: "1px solid var(--dsw-alias-interactive-bg-hover, #d8dee8)",
				borderRadius: 999,
				background: "transparent",
				color: "var(--dsw-alias-label-primary-bluish, #3b5b92)",
				fontSize: 12,
				lineHeight: "18px",
				cursor: "pointer",
				userSelect: "none",
			};

			return react_jsx_runtime.jsx("div", {
				style: { display: "flex", alignItems: "center", gap: 8, padding: "0 2px" },
				children: [
					react_jsx_runtime.jsx("button", {
						type: "button",
						disabled: busyRef.current,
						onClick: pick,
						style: busyRef.current ? Object.assign({}, buttonStyle, { opacity: 0.6, cursor: "default" }) : buttonStyle,
						title: "上传 PDF / XLSX / DOCX / CSV / TXT / 图片（≤10MB），在对话内引用处理",
						children: busyRef.current ? "上传中…" : "📎 上传文档",
					}),
					react_jsx_runtime.jsx("input", {
						ref: fileRef,
						type: "file",
						accept: ACCEPT,
						style: { display: "none" },
						onChange: onFile,
					}),
				],
			});
		}

		exports.apply = function (ctx) {
			ctx.slots.inject("conversation.input.dock", function () {
				return ctx.slots.register({
					name: "conversation.input.dock",
					id: "fms-doc-attach",
					order: 30,
					inject: function (sessionId) {
						var actx = ctx.sessions.scope(sessionId);
						if (!actx) throw new Error("fms-doc-attach: no scope for session " + sessionId);
						var conversation = actx.get("conversation");
						if (!conversation) throw new Error("fms-doc-attach: conversation service unavailable");
						return {
							// Queued turn into this session — the draft the user is
							// typing stays untouched.
							sendDoc: function (text) { return conversation.send(text); },
							// Session-routed composer notice (info | error).
							notify: function (level, text) { conversation.input.for(actx).notify(level, text); },
						};
					},
				}, DocDock);
			});
		};
		exports.inject = ["slots", "conversation", "sessions"];
		return module.exports;
	}
});

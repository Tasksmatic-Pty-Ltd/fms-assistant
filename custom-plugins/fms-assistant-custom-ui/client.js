// fms-assistant custom UI — brand slots override.
//
// Occupies the three shipped brand slots (sidebar.brand.mark / .name /
// conversation.hero.brand.mark) with CITO branding. The official package only
// registers when built with the `official` profile, so without this occupant
// the shell falls back to the DeepSeek fish + "DSH Local Build".
//
// To use your real logo: replace the SVG inside CITO_MARK (or swap it for an
// <img> pointing at your hosted asset). The browser title is a build-time
// variable (DSH_CLIENT_TITLE) and is not reachable from a plugin.
window.__ModuleLoader__.load({
	id: "fms-assistant-custom-ui",
	factory: (require) => {
		var module = { exports: {} };
		var exports = module.exports;

		var react_jsx_runtime = require("react/jsx-runtime");

		// ── CITO mark: rounded-square monogram placeholder ──────────────────
		// Replace the path/children below with your real logo.
		function CITO_MARK({ size, className }) {
			return react_jsx_runtime.jsx("svg", {
				width: size,
				height: size,
				viewBox: "0 0 24 24",
				className: className,
				"aria-hidden": "true",
				children: react_jsx_runtime.jsx("g", {
					children: [
						react_jsx_runtime.jsx("rect", { x: "1", y: "1", width: "22", height: "22", rx: "5", fill: "#1a3a6b" }),
						react_jsx_runtime.jsx("text", {
							x: "12", y: "16.5", "text-anchor": "middle", "font-size": "12",
							"font-weight": "700", fill: "#ffffff", "font-family": "system-ui, sans-serif",
							children: "C"
						})
					]
				})
			});
		}

		function CITO_NAME() {
			return react_jsx_runtime.jsx("span", {
				style: { fontWeight: 600, fontSize: 14, color: "var(--dsh-color-text-strong, #1a1a1a)", whiteSpace: "nowrap" },
				children: "CITO Logistics FMS"
			});
		}

		// Fill every shipped brand slot as one declaration-aware registration
		// set (same shape as the official brand package).
		function apply(ctx) {
			ctx.slots.inject("sidebar.brand.mark", () =>
				ctx.slots.inject("sidebar.brand.name", () =>
					ctx.slots.inject("conversation.hero.brand.mark", function* () {
						yield ctx.slots.register({ name: "sidebar.brand.mark" }, CITO_MARK);
						yield ctx.slots.register({ name: "sidebar.brand.name" }, CITO_NAME);
						yield ctx.slots.register({ name: "conversation.hero.brand.mark" }, CITO_MARK);
					})));
		}

		exports.apply = apply;
		exports.inject = ["slots"];
		return module.exports;
	}
});

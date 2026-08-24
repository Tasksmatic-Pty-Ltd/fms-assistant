// fms-workspace-pin — pin the assistant to ONE fixed workspace.
//
// Pre-creates the single workspace record bound to FMS_WORKSPACE_DIR (the
// same folder the instance runs from / the sandbox workspaceRoot), so the
// sidebar shows exactly one workspace and employees never choose a directory.
// Combined with the profile patch disabling the directory picker, the
// "Add workspace…" affordance disappears entirely.
export function apply(ctx) {
	const dir = process.env.FMS_WORKSPACE_DIR || process.cwd();
	const title = process.env.FMS_WORKSPACE_TITLE || "公司工作区";
	Promise.resolve()
		.then(() => ctx.workspaceRegistry.create(dir, title))
		.then(() => {
			console.error(`[fms-workspace-pin] pinned workspace: ${dir}`);
		})
		.catch((err) => {
			// Fail soft: the workspace is cosmetic (the agent has no file tools
			// either way); log loudly so a misconfig is visible.
			console.error(`[fms-workspace-pin] ${err.message}`);
		});
}

export const inject = ["workspaceRegistry"];

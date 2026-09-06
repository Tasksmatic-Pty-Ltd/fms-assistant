// Workspace file index for the @ mention dual-source: worktree files are
// listed as RELATIVE paths (the agent resolves them against the session cwd),
// uploaded files keep absolute paths. Read-only; same network guards as the
// upload surface. BFS traversal with ignore lists, depth and count caps, and
// symlink skipping (avoids cycles and index escape through link targets).
import { readdir } from 'node:fs/promises';
import { join } from 'node:path';
import { jsonError, networkGuard } from "./guard.js";
import { sanitizeSessionId } from "./upload.js";
/** Directory names skipped at any depth. */
export const DEFAULT_IGNORED_DIRS = new Set([
    'node_modules',
    '.git',
    '.svn',
    '.hg',
    '.dsh',
    '.dsh-filess',
    '.dsh-files',
    'dist',
    'build',
    'out',
    '.next',
    '.nuxt',
    '.cache',
    '.trash',
    'uploads',
    '.venv',
    'venv',
    '__pycache__',
    'coverage',
    '.idea',
    '.vscode',
    'Pods',
    '.turbo',
    '.pnpm-store',
    'target',
    'vendor'
]);
/** File names skipped (platform noise). */
export const DEFAULT_IGNORED_FILES = new Set([
    '.DS_Store',
    '.localized',
    'Thumbs.db',
    'desktop.ini'
]);
/** Extensions skipped (artifacts and lockfiles that are rarely read). */
export const DEFAULT_IGNORED_EXTENSIONS = new Set([
    'log',
    'lock',
    'pyc',
    'class',
    'o',
    'a',
    'so',
    'dylib',
    'exe',
    'dll',
    'png',
    'jpg',
    'jpeg',
    'gif',
    'webp',
    'ico',
    'woff',
    'woff2',
    'ttf',
    'otf',
    'map'
]);
/**
 * BFS over a workspace, returning RELATIVE POSIX-style paths (forward
 * slashes) of files that pass the ignore lists. Symlinks are skipped
 * entirely so a link into another tree cannot balloon the index. Any
 * unreadable directory is skipped, not fatal.
 */
export async function indexWorkspace(cwd, options = {}) {
    const ignoredDirs = options.ignoredDirs ?? DEFAULT_IGNORED_DIRS;
    const ignoredFiles = options.ignoredFiles ?? DEFAULT_IGNORED_FILES;
    const ignoredExtensions = options.ignoredExtensions ?? DEFAULT_IGNORED_EXTENSIONS;
    const maxDepth = options.maxDepth ?? 12;
    const maxFiles = options.maxFiles ?? 500;
    const files = [];
    const queue = [{ rel: '', depth: 0 }];
    while (queue.length > 0 && files.length < maxFiles) {
        const { rel, depth } = queue.shift();
        if (depth > maxDepth)
            continue;
        let entries;
        try {
            entries = await readdir(join(cwd, rel), { withFileTypes: true });
        }
        catch {
            continue;
        }
        for (const entry of entries) {
            if (entry.isSymbolicLink())
                continue;
            const childRel = rel === '' ? entry.name : `${rel}/${entry.name}`;
            if (entry.isDirectory()) {
                if (!ignoredDirs.has(entry.name))
                    queue.push({ rel: childRel, depth: depth + 1 });
            }
            else if (entry.isFile()) {
                if (ignoredFiles.has(entry.name))
                    continue;
                const dot = entry.name.lastIndexOf('.');
                const ext = dot > 0 ? entry.name.slice(dot + 1).toLowerCase() : '';
                if (ext !== '' && ignoredExtensions.has(ext))
                    continue;
                files.push(childRel);
                if (files.length >= maxFiles)
                    break;
            }
        }
    }
    return files;
}
/**
 * HTTP handler for `GET /api/workspace-files?session=<id>`.
 * Returns `{ files: string[] }` of relative workspace paths.
 */
export function createWorkspaceFilesHandler(options) {
    const { sessionCwd, indexOptions, trustedHosts = [] } = options;
    return async (req, res) => {
        if (req.method !== 'GET') {
            res.writeHead(405, { allow: 'GET' });
            res.end('method not allowed');
            return;
        }
        const denied = networkGuard(req, trustedHosts);
        if (denied !== null) {
            res.writeHead(403);
            res.end(denied);
            return;
        }
        if (sessionCwd === undefined) {
            jsonError(res, 500, 'workspace files unavailable: no sessions service');
            return;
        }
        const url = new URL(req.url ?? '/', 'http://localhost');
        const sessionId = sanitizeSessionId(url.searchParams.get('session') ?? '');
        const cwd = await sessionCwd(sessionId);
        if (cwd === undefined) {
            jsonError(res, 403, 'unknown session');
            return;
        }
        try {
            const files = await indexWorkspace(cwd, indexOptions);
            res.writeHead(200, { 'content-type': 'application/json' });
            res.end(JSON.stringify({ files }));
        }
        catch (err) {
            jsonError(res, 500, `workspace index failed: ${String(err)}`);
        }
    };
}

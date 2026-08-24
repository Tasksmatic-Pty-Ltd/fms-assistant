// Node half of the custom UI plugin — empty on purpose: all the work is the
// client half (client.js). The loader row needs a node-side module to import,
// and the client-modules registry picks up the package through its
// `dsh.client` declaration + `exports["./client"]`.
export function apply() {}

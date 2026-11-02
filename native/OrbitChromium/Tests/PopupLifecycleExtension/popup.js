// Keep the popup's load notification pending while the native anchor is revoked.
const deadline = performance.now() + 400;
while (performance.now() < deadline) {}

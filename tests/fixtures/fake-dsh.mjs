// Stands in for the dsh CLI so the boot path can be tested without installing
// DeepSeek Harness: it echoes the argv and environment the launcher handed it,
// then serves HTTP so the readiness probe succeeds.
//
//   --fail   exit immediately instead, to exercise the early-exit path
import http from 'node:http';

const args = process.argv.slice(2);
const valueOf = (name) => {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : undefined;
};

console.log(`fake-dsh: argv ${args.join(' ')}`);
console.log(`fake-dsh: DSH_HOME=${process.env.DSH_HOME ?? '<unset>'}`);
console.log(`fake-dsh: cwd=${process.cwd()}`);

if (args.includes('--fail')) {
  console.error('fake-dsh: exiting 3 on purpose');
  process.exit(3);
}

const host = valueOf('--host') ?? '127.0.0.1';
const port = Number(valueOf('--port') ?? 0);
http
  .createServer((_request, response) => response.end('fake dsh'))
  .listen(port, host, () => console.log(`fake-dsh: listening on ${host}:${port}`));

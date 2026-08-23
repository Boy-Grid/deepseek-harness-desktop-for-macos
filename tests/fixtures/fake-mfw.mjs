// Stands in for dsh-mfw: a `provision` subcommand that returns straight away,
// and otherwise a server -- enough to exercise the launcher's two-phase boot
// (prepare the runtime, then boot) without a 300 MB runtime tree.
import http from 'node:http';

const args = process.argv.slice(2);
const valueOf = (name) => {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : undefined;
};

console.log(`fake-mfw: argv ${args.join(' ')}`);

if (args[0] === 'provision') {
  console.log('fake-mfw: ready to boot\n  runtime tree  <fake> (reused)');
  process.exit(0);
}

console.log(`fake-mfw: DSH_HOME=${process.env.DSH_HOME ?? '<unset>'}`);
const host = valueOf('--host') ?? '127.0.0.1';
const port = Number(valueOf('--port') ?? 0);
http
  .createServer((_request, response) => response.end('fake mfw'))
  .listen(port, host, () => console.log(`fake-mfw: listening on ${host}:${port}`));

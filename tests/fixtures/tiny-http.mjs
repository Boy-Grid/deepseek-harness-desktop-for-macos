// A stand-in for "some other server on the port we care about".
// Usage: node tiny-http.mjs <port>
import http from 'node:http';

const port = Number(process.argv[2]);
http.createServer((_request, response) => response.end('not dsh')).listen(port, '127.0.0.1');

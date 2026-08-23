# Third-Party Notices

This project redistributes or derives from the following third-party works.

## DeepSeek Harness ("dsh")

DSH Desktop launches the DeepSeek Harness Web UI. The `dsh` runtime is **not
bundled and not installed by this app** — it is resolved from the user's own
installation at launch time.

- Project: <https://github.com/deepseek-ai/deepseek-harness>
- License: MIT (reproduced below)

```
MIT License

Copyright (c) 2026 DeepSeek

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

For the full dependency tree of DeepSeek Harness itself, see its own
[THIRD_PARTY_NOTICES.md](https://github.com/deepseek-ai/deepseek-harness/blob/master/THIRD_PARTY_NOTICES.md).

## Application icon

The application icon is **derived from the favicon of the DeepSeek Harness
Web UI** (fetched from a running instance at `/favicon.svg` and composited
onto a macOS-style rounded tile by `make-icon.py`).

"DeepSeek" and "DeepSeek Harness" are trademarks of DeepSeek. This project is
**not affiliated with, endorsed by, or sponsored by DeepSeek**.

## Node.js

DSH Desktop resolves and executes a Node.js runtime that is already installed
on the system; it neither bundles nor downloads one. Node.js is distributed
under the terms of its own license; see
<https://raw.githubusercontent.com/nodejs/node/master/LICENSE>.

> This file describes what the app does today. Bundling or on-demand
> installation of a runtime is a planned change (see `OPENSOURCE-PLAN.md`); if
> it lands, the redistribution notices land with it.
